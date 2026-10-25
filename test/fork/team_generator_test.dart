// Fork feature test:
//  15. Team Generator: find a skill / Command Spell / NP plan that clears a quest with a fixed team
//  16. Team Generator: Order Change (mystic code) support
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
const int kMerlin = 500800; // support NP, no damage
const int kCombatUniform = 20; // mystic code with Order Change

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

  group('Order Change', () {
    // front line has no damage NP; the only attacker waits in the backup row
    BattleTeamSetup swapTeam() => BattleTeamSetup(
      svts: [
        PlayerSvtData.id(kMerlin),
        PlayerSvtData.id(kMerlin),
        PlayerSvtData.id(kMerlin),
        PlayerSvtData.id(kAltria)
          ..lv = 90
          ..tdLv = 5,
      ],
      mysticCodeData: MysticCodeData()
        ..mysticCode = db.gameData.mysticCodes[kCombatUniform]!
        ..level = 10,
    );

    test('options list every front-line / backup pair when the mystic code can swap', () async {
      final battle = BattleData();
      final team = swapTeam();
      await battle.init(quest, team.svts, team.mysticCodeData);
      expect(TeamGeneratorSolver.orderChangeSkillIndex(battle), isNotNull);
      final options = TeamGeneratorSolver.orderChangeOptions(battle);
      expect(options.first, isNull, reason: 'no swap is tried first');
      expect(options.skip(1).toSet(), {
        for (int onField = 0; onField < 3; onField++) (onField: onField, backup: 0),
      });
      expect(
        TeamGeneratorSolver.availableSkills(battle).where((s) => s.isMysticCode).map((s) => s.skillIndex),
        isNot(contains(TeamGeneratorSolver.orderChangeSkillIndex(battle))),
        reason: 'Order Change is handled separately',
      );
    });

    test('swaps the backup attacker in, replays and exports x<front><sub>', () async {
      final result = await TeamGeneratorSolver(
        quest: quest,
        formation: swapTeam(),
        settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 3, timeLimitSeconds: 120),
      ).solve();
      expect(result.success, isTrue, reason: result.message);
      final first = result.turns.first;
      expect(first.orderChange, isNotNull);
      expect(first.orderChange!.backup, 0);
      expect(first.npSlots, contains(first.orderChange!.onField), reason: 'the incoming Altria fires');
      expect(first.steps.any((step) => step.startsWith('Order Change')), isTrue);

      final command = FgaCommandExporter(result.battle!.recorder.records).export();
      expect(command, contains('x${first.orderChange!.onField + 1}1'));
      expect(result.battle!.replayDataRecord.replaceMemberIndexes, isNotEmpty, reason: 'replay data has the swap');
    });
  });
}
