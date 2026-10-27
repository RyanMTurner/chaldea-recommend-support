// Probe: does solving the saved Team Generator setup write the account data file?
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/modules/battle/team_generator/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('write probe', () async {
    final out = <String>[];
    final file = File(db.paths.userDataPath);
    String stamp() => '${file.lastModifiedSync()} ${file.lengthSync()}';
    out.add('start: ${stamp()}');
    final saved = db.settings.battleSim.teamGenerator;
    final info = saved.quest!;
    final quest = await AtlasApi.questPhase(info.id, info.phase, hash: info.enemyHash);
    out.add('after quest fetch: ${stamp()}');
    final svts = <PlayerSvtData>[for (final s in saved.formation.svts) await PlayerSvtData.fromStoredData(s)];
    final team = BattleTeamSetup(svts: svts, mysticCodeData: MysticCodeData()..loadStoredData(saved.formation.mysticCode));
    out.add('after team: ${stamp()}');
    final result = await TeamGeneratorSolver(
      quest: quest!,
      formation: team,
      settings: TeamGeneratorSettings(maxTurns: 3, maxCommandSpells: 0, timeLimitSeconds: 120, workers: 0),
    ).solve();
    out.add('after solve (${result.success}): ${stamp()}');
    await Future.delayed(const Duration(seconds: 12)); // debounced saves fire after 10s
    out.add('after 12s: ${stamp()}');
    await File('test_trace.log').writeAsString(out.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
