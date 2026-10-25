// Fork feature test:
//  15. Team Generator: find a skill / Command Spell / NP plan that clears a quest with a fixed team
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/modules/battle/simulation/fga_export.dart';
import 'package:chaldea/app/modules/battle/team_generator/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int kAltria = 100100; // AOE Buster NP
const int kQuest = 9300040603; // local free quest used by battle_test.dart

BattleTeamSetup altriaTeam() => BattleTeamSetup(
  svts: [
    PlayerSvtData.id(kAltria)
      ..lv = 90
      ..tdLv = 5,
  ],
  mysticCodeData: MysticCodeData()..mysticCode = null,
);

void main() async {
  await initiateForTest();

  final quest = db.gameData.questPhases[kQuest]!;
  final waves = quest.stages.map((e) => e.wave).reduce((a, b) => a > b ? a : b);

  test('empty front line is rejected', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: BattleTeamSetup(),
      settings: TeamGeneratorSettings(),
    ).solve();
    expect(result.success, isFalse);
  });

  test('fewer turns than waves cannot clear', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxTurns: waves - 1, maxCommandSpells: 3),
    ).solve();
    expect(result.success, isFalse);
  });

  test('no NP gauge and no Command Spells: no plan', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 0, timeLimitSeconds: 30),
    ).solve();
    expect(result.success, isFalse);
  });

  test('Command Spells charge the NP each wave; plan replays and exports', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 3, timeLimitSeconds: 60),
    ).solve();
    expect(result.success, isTrue, reason: result.message);
    expect(result.turns.length, lessThanOrEqualTo(waves));
    expect(result.commandSpellsUsed, inInclusiveRange(1, 3));
    expect(result.battle!.isBattleWin, isTrue);
    for (final turn in result.turns) {
      expect(turn.npSlots, contains(0));
    }

    final command = FgaCommandExporter(result.battle!.recorder.records).export();
    expect(command, contains('o1'));
    expect(command, contains('4'));

    final share = TeamGeneratorSolver.toShareData(quest, altriaTeam(), result.battle!);
    expect(share.actions, isNotEmpty);
    expect(share.quest?.id, quest.id);
  });

  test('Command Spell limit is respected', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 1, timeLimitSeconds: 30),
    ).solve();
    if (result.success) expect(result.commandSpellsUsed, lessThanOrEqualTo(1));
  });
}
