import 'dart:async';
import 'dart:math';

import 'package:chaldea/app/app.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_worker_pool.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/logger.dart';
import 'package:chaldea/packages/split_route/split_route.dart';
import 'package:chaldea/utils/utils.dart';
import 'package:chaldea/widgets/widgets.dart';

import 'solver.dart';

// Team recommendations for the Team Generator: teams from the user's roster that the solver can clear.
//
// 1. Pools: the user's owned servants below the bond cap ("own pool"), and every servant in the game for the
//    support slot (the user's data when owned, otherwise 10/10/10 skills, max level, no grails, no appends).
// 2. Attackers: each candidate fires a full NP with its own skills against each wave on its own, scored by the
//    share of the wave's HP it removes (simulated, on worker threads).
// 3. Supports: NP charge and ATK/card/NP damage buffs they give allies (from skill data).
// 4. Front lines in three shapes: one attacker + two supports, two attackers + one support, three attackers;
//    at most one member from the support slot. Ranked by how well the attackers cover the waves.
// 5. The best candidates are checked with the solver; teams that clear are listed first.
// Order Change isn't used, so the backups don't affect the clear: they're filled from the own pool.

const kTeamRecommendWorkerTag = 'team_recommend';

/// A team member candidate: the servant's battle data and whether it can only be the support.
class TgCandidate {
  final PlayerSvtData data;

  /// From the support pool only (not owned below the bond cap): must be the team's support.
  final bool supportOnly;
  TgCandidate(this.data, {required this.supportOnly});

  Servant get svt => data.svt!;
}

enum TgTeamStatus { pending, checking, cleared, failed }

class RecommendedTeam {
  /// Six slots, front line first. The support slot has [SupportSvtType.friend].
  final List<PlayerSvtData?> svts;
  final double estimate;
  TgTeamStatus status = TgTeamStatus.pending;
  int commandSpells = 0;
  String message = '';

  RecommendedTeam(this.svts, this.estimate);

  int? get supportIndex {
    final index = svts.indexWhere((e) => e?.supportType.isSupport == true);
    return index < 0 ? null : index;
  }
}

class TeamRecommender {
  /// Owned servants (favorites) below [maxBond] (0 = any), newest first.
  static List<Servant> ownPool({int maxBond = 0}) {
    final owned = <Servant>[];
    for (final svt in db.gameData.servantsNoDup.values) {
      if (!svt.isUserSvt) continue;
      final status = db.curUser.servants[svt.collectionNo];
      if (status == null || !status.favorite) continue;
      if (maxBond > 0 && status.bond >= maxBond) continue;
      owned.add(svt);
    }
    owned.sort((a, b) => b.collectionNo - a.collectionNo);
    return owned;
  }

  /// The user's data for an owned servant.
  static PlayerSvtData ownData(Servant svt) =>
      PlayerSvtData.base()..onSelectServant(svt, source: PreferPlayerSvtDataSource.current);

  /// Support data: the user's when owned, otherwise 10/10/10 skills, max level, no grails, no appends.
  static PlayerSvtData supportData(Servant svt) {
    final owned = db.curUser.servants[svt.collectionNo]?.favorite == true;
    final data = PlayerSvtData.base();
    if (owned) {
      data.onSelectServant(svt, source: PreferPlayerSvtDataSource.current);
    } else {
      data
        ..onSelectServant(svt, source: PreferPlayerSvtDataSource.none)
        ..limitCount = 4
        ..lv = svt.lvMax
        ..skillLvs = List.filled(kActiveSkillNums.length, 10)
        ..appendLvs = List.filled(kAppendSkillNums.length, 0);
    }
    return data..supportType = SupportSvtType.friend;
  }

  /// Own pool members, plus every other servant as a support-only candidate. Owned servants at or above the
  /// bond cap are support candidates only with [supportIgnoresBondCap].
  static List<TgCandidate> candidates({int maxBond = 0, bool supportIgnoresBondCap = false}) {
    final own = ownPool(maxBond: maxBond).toSet();
    final result = [for (final svt in own) TgCandidate(ownData(svt), supportOnly: false)];
    for (final svt in db.gameData.servantsNoDup.values) {
      if (!svt.isUserSvt || own.contains(svt)) continue;
      final owned = db.curUser.servants[svt.collectionNo]?.favorite == true;
      if (owned && !supportIgnoresBondCap) continue; // owned at the bond cap
      result.add(TgCandidate(supportData(svt), supportOnly: true));
    }
    return result;
  }

  /// What a servant's skills give allies: NP charge (×2) plus ATK/card/NP damage buffs, in percent.
  static double supportScore(PlayerSvtData data) {
    double charge = 0, buffs = 0;
    for (final (index, skill) in data.skills.indexed) {
      if (skill == null) continue;
      final lv = data.skillLvs.getOrNull(index) ?? 10;
      for (final func in skill.functions) {
        if (func.isEnemyOnlyFunc) continue;
        final target = func.funcTargetType;
        if (!target.isAlly || target == FuncTargetType.self) continue;
        final value = (func.svals.getOrNull(lv - 1) ?? func.svals.lastOrNull)?.Value ?? 0;
        if (func.funcType == FuncType.gainNp) charge += value / 100;
        final type = func.buffs.firstOrNull?.type;
        if (type == BuffType.upAtk || type == BuffType.upCommandall || type == BuffType.upNpdamage) {
          buffs += value / 10;
        }
      }
    }
    return charge * 2 + buffs;
  }

  /// Candidate front lines (3 members, at most one support-only) from attacker coverage [ratios]
  /// (per candidate, per wave: share of the wave's HP its NP removes), best first.
  static List<(List<int> members, double estimate)> frontLines(
    List<TgCandidate> candidates,
    List<List<double>> ratios, {
    int limit = 48,
  }) {
    const attackerThreshold = 0.5; // alone it removes half the wave: supports should do the rest
    final waves = ratios.firstOrNull?.length ?? 0;
    if (waves == 0) return [];
    double best(List<int> members, int wave) =>
        members.map((m) => ratios[m][wave]).reduce(max).clamp(0, 1).toDouble();
    bool covers(List<int> attackers) =>
        List.generate(waves, (w) => w).every((w) => best(attackers, w) >= attackerThreshold);

    final attackers = [
      for (int i = 0; i < candidates.length; i++)
        if (ratios[i].any((r) => r >= attackerThreshold)) i,
    ]..sort((a, b) => Maths.sum(ratios[b]).compareTo(Maths.sum(ratios[a])));
    final topAttackers = attackers.take(25).toList();
    final supportScores = [for (final c in candidates) supportScore(c.data)];
    final topSupports = List.generate(candidates.length, (i) => i)
      ..sort((a, b) => supportScores[b].compareTo(supportScores[a]));
    final supports = topSupports.take(10).toList();

    bool valid(List<int> members) {
      if (members.toSet().length != members.length) return false;
      if (members.where((m) => candidates[m].supportOnly).length > 1) return false;
      // the same servant twice only as an own copy + a support copy
      final ids = members.map((m) => candidates[m].svt.id).toList();
      return ids.toSet().length == ids.length;
    }

    double estimate(List<int> members, List<int> attackersInTeam) {
      double coverage = 0;
      for (int w = 0; w < waves; w++) {
        coverage += best(attackersInTeam, w);
      }
      final support = members.map((m) => supportScores[m]).fold<double>(0, (a, b) => a + b);
      return coverage * 100 + support;
    }

    final teams = <String, (List<int>, double)>{};
    void add(List<int> members, List<int> attackersInTeam) {
      if (!valid(members) || !covers(attackersInTeam)) return;
      final key = (members.toList()..sort()).join(',');
      final value = estimate(members, attackersInTeam);
      if ((teams[key]?.$2 ?? -1) < value) teams[key] = (members, value);
    }

    for (final a in topAttackers) {
      // loop: one attacker, two supports
      for (int i = 0; i < supports.length; i++) {
        for (int j = i + 1; j < supports.length; j++) {
          add([a, supports[i], supports[j]], [a]);
        }
      }
      for (final b in topAttackers) {
        if (b <= a) continue;
        // two attackers, one support
        for (final s in supports) {
          add([a, b, s], [a, b]);
        }
        // three attackers
        for (final c in topAttackers) {
          if (c <= b) continue;
          add([a, b, c], [a, b, c]);
        }
      }
    }

    final sorted = teams.values.toList()..sort((x, y) => y.$2.compareTo(x.$2));
    // variety: at most 4 teams per attacker
    final perAttacker = <int, int>{};
    final result = <(List<int>, double)>[];
    for (final team in sorted) {
      final lead = team.$1.first;
      if ((perAttacker[lead] ?? 0) >= 4) continue;
      perAttacker[lead] = (perAttacker[lead] ?? 0) + 1;
      result.add(team);
      if (result.length >= limit) break;
    }
    return result;
  }
}

// ===== worker tasks =====

/// Payload of [_scoreTask]: the quest and candidates (stored data).
class _ScorePayload {
  final QuestPhase quest;
  final List<SvtSaveData?> svts;
  const _ScorePayload(this.quest, this.svts);
}

/// Per candidate, per wave: share of the wave's HP a full NP with the candidate's own skills removes.
Future<Object?> _scoreTask(Object? payload, void Function(Object? progress) report) async {
  final work = payload as _ScorePayload;
  final results = <List<double>>[];
  for (final (index, stored) in work.svts.indexed) {
    results.add(await scoreAttacker(work.quest, await PlayerSvtData.fromStoredData(stored)));
    report(index + 1);
  }
  return results;
}

/// Share of each wave's HP [svt]'s NP removes (1.0 = cleared), firing with its own skills and a full gauge.
Future<List<double>> scoreAttacker(QuestPhase quest, PlayerSvtData svt) async {
  final waves = Maths.max(quest.stages.map((e) => e.wave), 1);
  final ratios = List<double>.filled(waves, 0);
  final copy = svt.copy()..supportType = SupportSvtType.none;
  if (copy.svt == null || copy.td == null) return ratios;
  try {
    final battle = BattleData();
    battle.options
      ..random = ConstData.constants.attackRateRandomMin
      ..threshold = 1000;
    await battle.init(quest, [copy], null);
    for (int wave = 0; wave < waves; wave++) {
      if (battle.isBattleFinished) break;
      final depth = battle.snapshots.length;
      battle.pushSnapshot();
      final actor = battle.onFieldAllyServants.getOrNull(0);
      final hpBefore = Maths.sum(battle.nonnullEnemies.map((e) => max(0, e.hp)));
      if (actor != null && hpBefore > 0) {
        actor.np = ConstData.constants.fullTdPoint;
        for (final skill in TeamGeneratorSolver.availableSkills(battle)) {
          if (skill.isMysticCode) continue;
          battle.playerTargetIndex = 0;
          await battle.activateSvtSkill(skill.slot!, skill.skillIndex);
        }
        final card = actor.getNPCard();
        if (card != null && actor.canNP()) {
          final waveBefore = battle.waveCount;
          await battle.playerTurn([CombatAction(actor, card)]);
          if (battle.isBattleWin || battle.waveCount > waveBefore) {
            ratios[wave] = 1;
          } else {
            final hpAfter = Maths.sum(battle.nonnullEnemies.map((e) => max(0, e.hp)));
            ratios[wave] = (1 - hpAfter / hpBefore).clamp(0, 1).toDouble();
          }
        }
      }
      while (battle.snapshots.length > depth) {
        battle.popSnapshot();
      }
      battle.battleLogger.logs.clear();
      if (wave < waves - 1) await battle.skipWave();
    }
  } catch (e) {
    // engine refused something: this candidate scores what it has
  }
  return ratios;
}

/// Payload of [_verifyTask]: the quest, teams (stored data), mystic code and solver settings.
class _VerifyPayload {
  final QuestPhase quest;
  final List<(int index, List<SvtSaveData?> svts)> teams;
  final MysticCodeSaveData mysticCode;
  final int maxCommandSpells;
  final int timeLimitSeconds;
  const _VerifyPayload(this.quest, this.teams, this.mysticCode, this.maxCommandSpells, this.timeLimitSeconds);
}

/// Solves each team; reports (team index, cleared, Command Spells used, message) after each.
Future<Object?> _verifyTask(Object? payload, void Function(Object? progress) report) async {
  final work = payload as _VerifyPayload;
  for (final (index, stored) in work.teams) {
    report((index, null, 0, ''));
    final result = await verifyTeam(
      work.quest,
      [for (final s in stored) await PlayerSvtData.fromStoredData(s)],
      MysticCodeData()..loadStoredData(work.mysticCode),
      maxCommandSpells: work.maxCommandSpells,
      timeLimitSeconds: work.timeLimitSeconds,
    );
    report((index, result.success, result.commandSpellsUsed, result.message));
  }
  return null;
}

/// Runs the solver on a team, giving up at the time limit.
Future<TeamGeneratorResult> verifyTeam(
  QuestPhase quest,
  List<PlayerSvtData> svts,
  MysticCodeData mysticCode, {
  required int maxCommandSpells,
  required int timeLimitSeconds,
}) async {
  late final TeamGeneratorSolver solver;
  solver = TeamGeneratorSolver(
    quest: quest,
    formation: BattleTeamSetup(svts: svts, mysticCodeData: mysticCode),
    settings: TeamGeneratorSettings(
      maxCommandSpells: maxCommandSpells,
      timeLimitSeconds: timeLimitSeconds,
      workers: 0,
    ),
    onPaused: (_, _) => Future.microtask(() => solver.cancel()),
  );
  try {
    return await solver.solve();
  } catch (e) {
    return TeamGeneratorResult(success: false, message: 'Error: $e', simulations: 0, elapsedMilliseconds: 0);
  }
}

// ===== run =====

/// One recommendation run: scores the candidates, builds teams and checks them, notifying listeners as it goes.
class TeamRecommendRun extends ChangeNotifier {
  final QuestPhase quest;
  final MysticCodeData mysticCode;
  final TeamGeneratorSettings settings;

  /// Seconds the solver gets per team.
  final int timeLimitPerTeam;

  TeamRecommendRun({
    required this.quest,
    required this.mysticCode,
    required this.settings,
    this.timeLimitPerTeam = 20,
  });

  String stage = '';
  int done = 0;
  int total = 0;
  bool running = false;
  bool _cancelled = false;
  final List<RecommendedTeam> teams = [];

  int get workerCount => max(0, settings.workers);

  void _update(String stage, {int? done, int? total}) {
    if (_cancelled) return;
    this.stage = stage;
    if (done != null) this.done = done;
    if (total != null) this.total = total;
    notifyListeners();
  }

  void cancel() {
    if (!running) return;
    _cancelled = true;
    running = false;
    stage = 'Stopped';
    unawaited(BattleWorkerPool.disposeTag(kTeamRecommendWorkerTag));
    notifyListeners();
  }

  /// Teams to show: cleared (fewest Command Spells first), then unchecked, best estimate first.
  List<RecommendedTeam> get shownTeams {
    int rank(TgTeamStatus status) => switch (status) {
      TgTeamStatus.cleared => 0,
      TgTeamStatus.checking => 1,
      TgTeamStatus.pending => 2,
      TgTeamStatus.failed => 3,
    };
    return teams.where((t) => t.status != TgTeamStatus.failed).toList()..sort((a, b) {
      final r = rank(a.status) - rank(b.status);
      if (r != 0) return r;
      if (a.commandSpells != b.commandSpells) return a.commandSpells - b.commandSpells;
      return b.estimate.compareTo(a.estimate);
    });
  }

  int get failedCount => teams.where((t) => t.status == TgTeamStatus.failed).length;

  Future<void> start() async {
    running = true;
    try {
      await _run();
      if (!_cancelled) {
        _update(
          teams.isEmpty
              ? 'No candidate teams: no attacker removes half of a wave on its own.'
              : 'Done: ${teams.where((t) => t.status == TgTeamStatus.cleared).length} of ${teams.length} teams clear.',
        );
      }
    } catch (e, s) {
      logger.e('team recommendation failed', e, s);
      _update('Failed: $e');
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Future<void> _run() async {
    final candidates = TeamRecommender.candidates(
      maxBond: settings.maxBond,
      supportIgnoresBondCap: settings.supportIgnoresBondCap,
    );
    final ownPool = [
      for (final c in candidates)
        if (!c.supportOnly) c.svt,
    ];

    // 2. attacker scoring (only servants with a damage NP)
    final attackerIndexes = [
      for (int i = 0; i < candidates.length; i++)
        if (candidates[i].data.td?.damageType != TdEffectFlag.support) i,
    ];
    final waves = Maths.max(quest.stages.map((e) => e.wave), 1);
    final ratios = List.generate(candidates.length, (_) => List<double>.filled(waves, 0));
    _update('Scoring attackers…', done: 0, total: attackerIndexes.length);
    final scored = await _runParallel<List<double>>(
      [for (final i in attackerIndexes) candidates[i].data.toStoredData()],
      (part) => _ScorePayload(quest, part.cast<SvtSaveData?>()),
      _scoreTask,
      onDone: (count) => _update('Scoring attackers…', done: count),
    );
    if (_cancelled) return;
    for (final (k, i) in attackerIndexes.indexed) {
      ratios[i] = scored[k];
    }

    // 3-4. candidate front lines
    _update('Building teams…');
    final fronts = TeamRecommender.frontLines(candidates, ratios);
    for (final (members, estimate) in fronts) {
      final front = [for (final m in members) candidates[m].data.copy()];
      // the support-only member is the support; otherwise none
      for (final (k, m) in members.indexed) {
        front[k].supportType = candidates[m].supportOnly ? SupportSvtType.friend : SupportSvtType.none;
      }
      final used = {for (final m in members) candidates[m].svt.id};
      final backups = [
        for (final svt in ownPool)
          if (!used.contains(svt.id)) svt,
      ].take(3).map(TeamRecommender.ownData).toList();
      teams.add(RecommendedTeam([...front, ...backups, ...List.filled(3 - backups.length, null)], estimate));
    }
    if (_cancelled || teams.isEmpty) return;

    // 5. check with the solver
    _update('Checking teams with the solver…', done: 0, total: teams.length);
    int checked = 0;
    await _runParallel<Object?>(
      [for (final (index, team) in teams.indexed) (index, [for (final s in team.svts) s?.toStoredData()])],
      (part) => _VerifyPayload(
        quest,
        part.cast<(int, List<SvtSaveData?>)>(),
        mysticCode.toStoredData(),
        settings.maxCommandSpells,
        timeLimitPerTeam,
      ),
      _verifyTask,
      onReport: (progress) {
        final (index, success, commandSpells, message) = progress as (int, bool?, int, String);
        final team = teams[index];
        if (success == null) {
          team.status = TgTeamStatus.checking;
        } else {
          team
            ..status = success ? TgTeamStatus.cleared : TgTeamStatus.failed
            ..commandSpells = commandSpells
            ..message = message;
          checked++;
        }
        _update('Checking teams with the solver…', done: checked);
      },
    );
  }

  /// Splits [items] round-robin between the workers (or runs on this thread), returning the results in order.
  /// [onDone] gets the number of items finished; [onReport] gets every progress report.
  Future<List<R>> _runParallel<R>(
    List<Object?> items,
    Object Function(List<dynamic> part) payload,
    BattleWorkerTask task, {
    void Function(int done)? onDone,
    void Function(Object? progress)? onReport,
  }) async {
    if (items.isEmpty) return [];
    final count = max(1, min(workerCount, items.length));
    final parts = [
      for (int p = 0; p < count; p++) [for (int i = p; i < items.length; i += count) items[i]],
    ];
    final progress = List<int>.filled(count, 0);
    List<Object?> outputs;
    if (workerCount <= 0) {
      outputs = [
        await task(payload(parts.single), (p) {
          onReport?.call(p);
          if (p is int) onDone?.call(p);
        }),
      ];
    } else {
      final pool = await BattleWorkerPool.obtain(kTeamRecommendWorkerTag, count);
      outputs = await pool.runAll(
        [for (final part in parts) (task, payload(part))],
        onProgress: (worker, p) {
          onReport?.call(p);
          if (p is int) {
            progress[worker] = p;
            onDone?.call(Maths.sum(progress));
          }
        },
      );
    }
    // re-interleave the round-robin parts
    final results = List<R?>.filled(items.length, null);
    for (int p = 0; p < count; p++) {
      final list = (outputs[p] as List?) ?? const [];
      for (int k = 0; k < list.length; k++) {
        results[p + k * count] = list[k] as R;
      }
    }
    return results.cast<R>();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}

// ===== UI =====

/// Recommended teams, shown in the right half of the screen; "Select" fills a team into the Team Generator.
class TeamRecommendPage extends StatefulWidget {
  final TeamRecommendRun run;
  final void Function(RecommendedTeam team) onSelect;

  const TeamRecommendPage({super.key, required this.run, required this.onSelect});

  @override
  State<TeamRecommendPage> createState() => _TeamRecommendPageState();
}

class _TeamRecommendPageState extends State<TeamRecommendPage> {
  TeamRecommendRun get run => widget.run;

  @override
  void dispose() {
    run.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recommended Teams')),
      body: ListenableBuilder(
        listenable: run,
        builder: (context, _) {
          final teams = run.shownTeams;
          final failed = run.failedCount;
          return ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              _header(context),
              for (final (index, team) in teams.indexed) _teamCard(context, index, team),
              if (failed > 0)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '$failed checked team(s) didn\'t clear and are hidden.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  run.total > 0 && run.running ? '${run.stage} ${run.done}/${run.total}' : run.stage,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (run.running) TextButton(onPressed: run.cancel, child: const Text('Stop')),
            ],
          ),
          if (run.running) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: run.total > 0 ? run.done / run.total : null),
          ],
        ],
      ),
    );
  }

  Widget _teamCard(BuildContext context, int index, RecommendedTeam team) {
    final theme = Theme.of(context);
    final supportIndex = team.supportIndex;

    // servant icon with its CE slot on the right (CEs aren't recommended yet: always empty)
    Widget slot(int i) {
      final data = team.svts.getOrNull(i);
      final svt = data?.svt;
      return Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: svt == null
                      ? const SizedBox(width: 44, height: 48)
                      : svt.iconBuilder(context: context, width: 44, jumpToDetail: true),
                ),
                const SizedBox(width: 2),
                Flexible(child: db.getIconImage(Atlas.common.emptyCeIcon, width: 32)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              i == supportIndex ? '${S.current.support_servant_short} · ${svt?.lName.l ?? ''}' : svt?.lName.l ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: i == supportIndex ? theme.colorScheme.primary : null,
              ),
            ),
          ],
        ),
      );
    }

    final (IconData icon, Color? color, String label) = switch (team.status) {
      TgTeamStatus.cleared => (
        Icons.check_circle,
        theme.colorScheme.primary,
        team.commandSpells > 0 ? 'Clears · ${team.commandSpells} ${S.current.command_spell}' : 'Clears',
      ),
      TgTeamStatus.checking => (Icons.hourglass_top, null, 'Checking…'),
      TgTeamStatus.pending => (Icons.help_outline, theme.disabledColor, 'Not checked yet'),
      TgTeamStatus.failed => (Icons.error_outline, theme.colorScheme.error, 'Doesn\'t clear'),
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Team ${index + 1}', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color)),
                ),
                const Spacer(),
                FilledButton.tonal(
                  onPressed: () {
                    widget.onSelect(team);
                    if (!SplitRoute.isSplit(context)) Navigator.of(context).maybePop();
                  },
                  child: Text(S.current.select),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < 3; i++) slot(i),
                const SizedBox(height: 56, child: VerticalDivider(width: 12)),
                for (int i = 3; i < 6; i++) slot(i),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
