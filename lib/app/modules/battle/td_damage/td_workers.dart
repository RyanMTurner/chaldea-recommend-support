import 'dart:math';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_worker_pool.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import 'model.dart';

// Laplace NP Damage on worker isolates: the damage list, Best Supports and Best CE.
// Each worker gets the NP Damage options and the user data (player data, owned CEs, class score...) with
// every job, calculates its share of servants / candidates, and the results are merged here.

const kTdWorkerTag = 'laplace_np_damage';

/// Best CE results sent back from a worker: (base damage, base CE id, base lv, base MLB) and rows.
typedef _CeBase = (int?, int?, int, bool);
typedef _CeRow = (int?, int, bool, bool, int, int, int);

class TdWorkPayload {
  final TdDamageOptions options;
  final UserData userData;
  final List<int> ids;
  final PlayerSvtData? target;
  final bool includeNoCe;

  const TdWorkPayload({
    required this.options,
    required this.userData,
    required this.ids,
    this.target,
    this.includeNoCe = false,
  });
}

void _applyContext(TdWorkPayload payload) {
  db.userData = payload.userData;
  db.settings.battleSim.tdDmgOptions = payload.options;
}

/// Round-robin split of [ids] into at most [parts] lists (always at least one, possibly empty).
List<List<int>> splitIds(List<int> ids, int parts) {
  final count = max(1, min(parts, ids.length));
  return [
    for (int part = 0; part < count; part++)
      [for (int index = part; index < ids.length; index += count) ids[index]],
  ];
}

Future<BattleWorkerPool> _pool(TdDmgSolver solver) => BattleWorkerPool.obtain(kTdWorkerTag, solver.workerCount);

TdWorkPayload _payload(TdDmgSolver solver, List<int> ids, {PlayerSvtData? target, bool includeNoCe = false}) =>
    TdWorkPayload(
      options: solver.options,
      userData: db.userData,
      ids: ids,
      target: target,
      includeNoCe: includeNoCe,
    );

void Function(int worker, Object? progress) _progressSum(int parts, int total) {
  final done = List<int>.filled(parts, 0);
  TdDmgSolver.reportProgress(0, total, null);
  return (worker, progress) {
    if (progress is! int || worker >= parts) return;
    done[worker] = progress;
    TdDmgSolver.reportProgress(done.fold(0, (a, b) => a + b), total, null);
  };
}

// ===== damage list =====

Future<Object?> _rankingTask(Object? payload, void Function(Object? progress) report) async {
  final work = payload as TdWorkPayload;
  _applyContext(work);
  final solver = TdDmgSolver();
  final servants = work.ids.map((id) => db.gameData.servantsById[id]).whereType<Servant>().toList();
  await solver.calculateServants(servants, onProgress: (done, _) => report(done));
  for (final result in solver.results) {
    // keep what the result details need, drop undo history and callbacks
    result.battleData
      ..delegate = null
      ..snapshots.clear();
  }
  return (solver.results, <String>[for (final error in solver.errors) '$error']);
}

Future<void> calculateRankingParallel(TdDmgSolver solver, List<Servant> servants) async {
  final ids = [
    for (final svt in servants)
      if (svt.isUserSvt) svt.id,
  ];
  final pool = await _pool(solver);
  final parts = splitIds(ids, pool.count);
  final outputs = await pool.runAll([
    for (final part in parts) (_rankingTask, _payload(solver, part)),
  ], onProgress: _progressSum(parts.length, ids.length));
  for (final output in outputs) {
    final (results, errors) = output as (List<TdDmgResult>, List<String>);
    solver.results.addAll(results);
    solver.errors.addAll(errors);
  }
  final order = {for (final (index, id) in ids.indexed) id: index};
  solver.results.sortByList((e) => [order[e.svt.id] ?? 0]); // same order as on one thread
}

// ===== Best Supports =====

Future<Object?> _supportsTask(Object? payload, void Function(Object? progress) report) async {
  final work = payload as TdWorkPayload;
  _applyContext(work);
  final solver = TdDmgSolver();
  final target = TdDmgResult(work.target!, BattleData());
  final candidates = work.ids.map((id) => db.gameData.servantsById[id]).whereType<Servant>().toList();
  await solver.calcBestSupports(target, candidates: candidates, onProgress: (done, _) => report(done));
  return (
    target.supportBaseDamage,
    <(int, int, int, int)>[
      for (final gain in target.supportGains ?? const <TdSupportGain>[])
        (gain.support.id, gain.damage, gain.gain, gain.attackNp),
    ],
    target.supportErrors.toList(),
  );
}

Future<void> calcBestSupportsParallel(TdDmgSolver solver, TdDmgResult target) async {
  final ids = [
    for (final svt in solver.getServantList())
      if (svt.isUserSvt) svt.id,
  ];
  final pool = await _pool(solver);
  final parts = splitIds(ids, pool.count);
  final outputs = await pool.runAll([
    for (final part in parts) (_supportsTask, _payload(solver, part, target: target.originalSvtData)),
  ], onProgress: _progressSum(parts.length, ids.length));

  int? baseDamage;
  final gains = <TdSupportGain>[];
  final errors = <String>[];
  for (final output in outputs) {
    final (base, list, errs) = output as (int?, List<(int, int, int, int)>, List<String>);
    baseDamage ??= base;
    errors.addAll(errs);
    for (final (svtId, damage, gain, attackNp) in list) {
      final svt = db.gameData.servantsById[svtId];
      if (svt == null) continue;
      gains.add(TdSupportGain(support: svt, damage: damage, gain: gain, attackNp: attackNp));
    }
  }
  gains.sortByList((e) => [-e.gain, -e.attackNp, e.support.collectionNo]);
  target
    ..supportBaseDamage = baseDamage ?? target.totalDamage
    ..supportGains = gains
    ..supportErrors = errors;
}

// ===== Best CE =====

Future<Object?> _cesTask(Object? payload, void Function(Object? progress) report) async {
  final work = payload as TdWorkPayload;
  _applyContext(work);
  final solver = TdDmgSolver();
  final target = TdDmgResult(work.target!, BattleData());
  final candidates = work.ids.map((id) => db.gameData.craftEssencesById[id]).whereType<CraftEssence>().toList();
  await solver.calcBestCEs(
    target,
    candidates: candidates,
    onProgress: (done, _) => report(done),
    includeNoCe: work.includeNoCe,
  );
  return (
    (target.ceBaseDamage, target.ceBaseCeId, target.ceBaseLv, target.ceBaseMLB),
    <_CeRow>[
      for (final gain in target.ceGains ?? const <TdCeGain>[])
        (gain.ce?.id, gain.lv, gain.limitBreak, gain.isCurrent, gain.damage, gain.gain, gain.attackNp),
    ],
    target.ceErrors.toList(),
  );
}

Future<void> calcBestCEsParallel(TdDmgSolver solver, TdDmgResult target) async {
  final ids = TdDmgSolver.ownedCeCandidates().map((ce) => ce.id).toList();
  final pool = await _pool(solver);
  final parts = splitIds(ids, pool.count);
  final outputs = await pool.runAll([
    for (final (index, part) in parts.indexed)
      // only the first worker adds the "No CE" row
      (_cesTask, _payload(solver, part, target: target.originalSvtData, includeNoCe: index == 0)),
  ], onProgress: _progressSum(parts.length, ids.length));

  _CeBase? base;
  final gains = <TdCeGain>[];
  final errors = <String>[];
  for (final output in outputs) {
    final (info, list, errs) = output as (_CeBase, List<_CeRow>, List<String>);
    base ??= info;
    errors.addAll(errs);
    for (final (ceId, lv, limitBreak, isCurrent, damage, gain, attackNp) in list) {
      final ce = ceId == null ? null : db.gameData.craftEssencesById[ceId];
      if (ceId != null && ce == null) continue;
      gains.add(
        TdCeGain(
          ce: ce,
          lv: lv,
          limitBreak: limitBreak,
          isCurrent: isCurrent,
          damage: damage,
          gain: gain,
          attackNp: attackNp,
        ),
      );
    }
  }
  gains.sortByList((e) => [-e.damage, -e.attackNp, e.ce?.collectionNo ?? 0]);
  target
    ..ceBaseDamage = base?.$1 ?? target.totalDamage
    ..ceBaseCeId = base?.$2
    ..ceBaseLv = base?.$3 ?? 0
    ..ceBaseMLB = base?.$4 ?? false
    ..ceGains = gains
    ..ceErrors = errors;
}
