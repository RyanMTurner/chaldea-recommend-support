// Fork feature test:
//  22. Laplace NP Damage on worker threads ("CPU Cores" option): damage list, Best Supports, Best CE
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/utils/battle_worker_pool.dart';
import 'package:chaldea/app/modules/battle/td_damage/model.dart';
import 'package:chaldea/app/modules/battle/td_damage/td_workers.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

/// a top-level task: workers can run it because functions are sendable between the app's isolates
Future<Object?> _sumTask(Object? payload, void Function(Object? progress) report) async {
  final numbers = payload as List<int>;
  report(numbers.length);
  // the worker has the game data
  return (numbers.fold(0, (a, b) => a + b), db.gameData.servantsById.length);
}

void main() async {
  await initiateForTest();

  setUp(() {
    db.settings.battleSim.tdDmgOptions = TdDamageOptions()..initBuffs();
  });

  test('splitIds: round-robin, at most N parts, never empty', () {
    expect(splitIds([1, 2, 3, 4, 5], 2), [
      [1, 3, 5],
      [2, 4],
    ]);
    expect(splitIds([1, 2], 4), [
      [1],
      [2],
    ]);
    expect(splitIds([], 3), [<int>[]]);
  });

  test('CPU Cores option: saved, defaults to cores - 1 (1-4)', () {
    TdDamageOptions roundTrip(TdDamageOptions o) => TdDamageOptions.fromJson(jsonDecode(jsonEncode(o.toJson())));
    expect(roundTrip(TdDamageOptions()..cores = 3).cores, 3);
    expect(roundTrip(TdDamageOptions()..cores = 0).cores, 0);
    expect(TdDamageOptions().cores, TdDamageOptions.defaultCores);
    expect(TdDamageOptions.defaultCores, inInclusiveRange(1, 4));
    final legacy = jsonDecode(jsonEncode(TdDamageOptions().toJson())) as Map<String, dynamic>..remove('cores');
    expect(TdDamageOptions.fromJson(legacy).cores, TdDamageOptions.defaultCores);
  });

  test('worker pool runs tasks with game data and reports progress', () async {
    try {
      final pool = await BattleWorkerPool.obtain('test_pool', 2);
      final progress = <int, Object?>{};
      final results = await pool.runAll([
        (_sumTask, [1, 2, 3]),
        (_sumTask, [10, 20]),
      ], onProgress: (worker, p) => progress[worker] = p);
      expect(results, [(6, db.gameData.servantsById.length), (30, db.gameData.servantsById.length)]);
      expect(progress, {0: 3, 1: 2});
      expect(identical(await BattleWorkerPool.obtain('test_pool', 2), pool), isTrue, reason: 'pool reused');
    } finally {
      await BattleWorkerPool.disposeTag('test_pool');
    }
  });

  test('damage list on workers matches the main thread', () async {
    final servants = TdDmgSolver().getServantList().where((svt) => svt.isUserSvt).take(12).toList();
    db.settings.battleSim.tdDmgOptions.cores = 2;

    final single = TdDmgSolver();
    await single.calculateServants(servants);
    final parallel = TdDmgSolver();
    try {
      await calculateRankingParallel(parallel, servants);
    } finally {
      await BattleWorkerPool.disposeTag(kTdWorkerTag);
    }

    List<(int, int)> summary(TdDmgSolver solver) {
      final rows = [for (final r in solver.results) (r.svt.id, r.totalDamage)];
      rows.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
      return rows;
    }

    expect(summary(parallel), summary(single));
    expect(parallel.errors.length, single.errors.length);
    expect(parallel.results.every((r) => r.attacks.isNotEmpty), isTrue, reason: 'details survive the transfer');
  });
}
