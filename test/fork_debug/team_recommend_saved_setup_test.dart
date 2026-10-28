// Debugging aid: runs "Recommend Teams" for the quest saved in the Team Generator with the account data saved in
// the app, and writes the result to test_trace.log.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/modules/battle/team_generator/recommend.dart';
import 'package:chaldea/app/modules/battle/team_generator/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('recommend teams for the saved quest', () async {
    final userData = await db.loadUserData();
    if (userData != null) db.userData = userData;
    final saved = db.settings.battleSim.teamGenerator;
    final info = saved.quest!;
    final quest = await AtlasApi.questPhase(info.id, info.phase, hash: info.enemyHash);
    final watch = Stopwatch()..start();
    final run = TeamRecommendRun(
      quest: quest!,
      mysticCode: MysticCodeData()..loadStoredData(saved.formation.mysticCode),
      settings: TeamGeneratorSettings(
        maxCommandSpells: saved.maxCommandSpells,
        workers: saved.workers ?? 4,
        maxBond: saved.maxBond,
        supportIgnoresBondCap: saved.supportIgnoresBondCap,
      ),
    );
    final out = <String>['Quest ${quest.id} ${quest.lName.l}, bond ≤${saved.maxBond}'];
    String lastStage = '';
    run.addListener(() {
      if (run.stage != lastStage) out.add('${watch.elapsed} ${lastStage = run.stage}');
    });
    await run.start();
    out.add('${watch.elapsed} ${run.stage}');
    for (final team in run.teams) {
      out.add(
        '${team.status.name} est ${team.estimate.toStringAsFixed(0)}: '
        '${team.svts.take(3).map((s) => '${s?.svt?.lName.l}${s?.supportType.isSupport == true ? ' (support)' : ''}').join(', ')}'
        ' | ${team.message}',
      );
    }
    await File('test_trace.log').writeAsString(out.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
