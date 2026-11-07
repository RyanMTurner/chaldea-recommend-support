// Fork feature test:
//   6. Translate battle record into an FGA (Fate Grand Automata) command
//
// FGA syntax: servant skills a-i (field slot x skill), master skills j/k/l, single ally target 1-3,
// order change x<front><sub>, command spell (NP charge) o<target>, NP 4/5/6, choices [Ch2A]/[Ch3B]...,
// turn ",", wave ",#,".
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';
import 'package:tuple/tuple.dart';

import 'package:chaldea/app/battle/interactions/_delegate.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/modules/battle/simulation/fga_export.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import '../test_init.dart';

const int kAltria = 100100;
const int kMerlin = 500800; // S1 party, S3 single ally
const int kCombatUniform = 20; // mystic code with Order Change as skill 3
const int kQuest = 9300040603; // local free quest used by battle_test.dart

/// Mirrors the exporter's rule: target number only for single-ally skills.
bool targetsSingleAlly(BaseSkill skill) {
  if (skill.script?.condBranchSkillInfo?.isNotEmpty == true) return true;
  return skill.functions.any(
    (func) =>
        func.funcTargetTeam != FuncApplyTarget.enemy &&
        const {
          FuncTargetType.ptOne,
          FuncTargetType.ptOneOther,
          FuncTargetType.playerAttackPreselectTargetPtOne,
        }.contains(func.funcTargetType),
  );
}

void main() async {
  await initiateForTest();

  test('empty record exports an empty command', () {
    expect(FgaCommandExporter([]).export(), '');
  });

  test('skills, targets, master skill, order change, command spell, NP and turn separators', () async {
    final battle = BattleData();
    await battle.init(
      db.gameData.questPhases[kQuest]!,
      [
        PlayerSvtData.id(kAltria),
        PlayerSvtData.id(kMerlin),
        PlayerSvtData.id(kAltria),
        PlayerSvtData.id(kMerlin), // backup 1
      ],
      MysticCodeData()
        ..mysticCode = db.gameData.mysticCodes[kCombatUniform]!
        ..level = 10,
    );
    battle.delegate = BattleDelegate()
      ..replaceMember = (onField, backup) async => Tuple2(onField[2]!, backup[0]!); // slot 3 <-> sub 1

    final expected = StringBuffer();

    await battle.activateSvtSkill(1, 0); // Merlin S1, party
    expected.write('d');
    battle.playerTargetIndex = 0;
    await battle.activateSvtSkill(1, 2); // Merlin S3, single ally -> Altria
    expected.write('f1');
    await battle.activateSvtSkill(0, 1); // Altria S2, self
    expected.write('b');

    final mcSkill1 = battle.masterSkillInfo[0].skill!;
    await battle.activateMysticCodeSkill(0);
    expected.write('j${targetsSingleAlly(mcSkill1) ? '1' : ''}');

    await battle.activateMysticCodeSkill(2); // Order Change: x only, no "l"
    expected.write('x31');
    await battle.activateSvtSkill(2, 2); // the swapped-in Merlin, now slot 3
    expected.write('i1');

    await battle.commandSpellReleaseNP(); // NP charge on Altria
    expected.write('o1');
    await battle.commandSpellRepairHp(); // not supported by FGA -> skipped with warning

    final altria = battle.onFieldAllyServants[0]!;
    final waveBefore = battle.waveCount;
    await battle.playerTurn([CombatAction(altria, altria.getNPCard()!)]);
    expected.write('4');
    expect(battle.isBattleFinished, isFalse, reason: 'test needs a second turn');

    expected.write(battle.waveCount > waveBefore ? ',#,' : ',');
    await battle.activateSvtSkill(0, 0); // Altria S1, party
    expected.write('a');

    final exporter = FgaCommandExporter(battle.recorder.records);
    expect(exporter.export(), expected.toString());
    expect(exporter.warnings.where((w) => w.contains('not supported by FGA')), hasLength(1));
  });

  test('skill choice options (Kukulkan) use [ChNx], grouped with an ally target', () async {
    final kukulkan = db.gameData.servantsNoDup.values.firstWhereOrNull(
      (svt) => svt.isUserSvt && svt.name.contains('ククルカン'),
    );
    if (kukulkan == null) {
      markTestSkipped('Kukulkan not found in game data');
      return;
    }
    final data = PlayerSvtData.id(kukulkan.id);
    final skillIndex = [0, 1, 2].firstWhereOrNull((i) => data.skills[i]?.script?.SelectAddInfo?.isNotEmpty == true);
    expect(skillIndex, isNotNull, reason: 'Kukulkan should have a skill with options');
    final skill = data.skills[skillIndex!]!;
    final btnCount = skill.script!.SelectAddInfo![data.skillLvs[skillIndex] - 1].btn.length;

    final battle = BattleData();
    await battle.init(db.gameData.questPhases[kQuest]!, [data], null);
    battle.delegate = BattleDelegate()..skillActSelect = (_) async => 1; // second option
    battle.criticalStars = 50;
    battle.playerTargetIndex = 0;
    await battle.activateSvtSkill(0, skillIndex);

    final choice = '[Ch$btnCount${'ABC'[1]}]';
    final letter = 'abc'[skillIndex];
    final expected = targetsSingleAlly(skill) ? '$letter(${choice}1)' : '$letter$choice';
    expect(FgaCommandExporter(battle.recorder.records).export(), expected);
  });
}
