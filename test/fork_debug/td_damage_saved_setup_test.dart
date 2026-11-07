// Debugging aid (not part of the fork test suite): runs the NP Damage ranking with the options and account data
// saved in the app, on worker threads and on the main thread, and writes a summary to test_trace.log.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/utils/battle_worker_pool.dart';
import 'package:chaldea/app/modules/battle/td_damage/model.dart';
import 'package:chaldea/app/modules/battle/td_damage/td_workers.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('NP Damage: saved options, workers and main thread', () async {
    final out = <String>[];
    final userDataFile = File(db.paths.userDataPath);
    out.add('userdata: ${userDataFile.path} ${userDataFile.existsSync() ? userDataFile.lengthSync() : -1} bytes, '
        'modified ${userDataFile.existsSync() ? userDataFile.lastModifiedSync() : '-'}');
    final userData = await db.loadUserData();
    out.add('loaded user data: ${userData != null}');
    if (userData != null) db.userData = userData;
    final user = db.curUser;
    out.add('users ${db.userData.users.length}, current "${user.name}", servants ${user.servants.length}, '
        'favorite ${user.servants.values.where((s) => s.favorite).length}');
    final options = db.settings.battleSim.tdDmgOptions;
    out.add('cores ${options.cores}, usePlayerSvt ${options.usePlayerSvt}');

    final solver = TdDmgSolver();
    final servants = solver.getServantList();
    out.add('servant list: ${servants.length} (user svts: ${servants.where((s) => s.isUserSvt).length})');

    final watch = Stopwatch()..start();
    final parallel = TdDmgSolver();
    try {
      await calculateRankingParallel(parallel, servants).timeout(const Duration(minutes: 2));
      out.add('workers: ${parallel.results.length} results, ${parallel.errors.length} errors, ${watch.elapsed}');
    } catch (e, s) {
      out.add('workers FAILED after ${watch.elapsed}: $e\n$s');
    } finally {
      await BattleWorkerPool.disposeTag(kTdWorkerTag);
    }
    out.addAll(parallel.errors.take(10).map((e) => '  worker error: $e'));
    out.add('userdata after workers: ${userDataFile.lengthSync()} bytes, modified ${userDataFile.lastModifiedSync()}');

    await File('test_trace.log').writeAsString(out.join('\n'));
    print(out.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
