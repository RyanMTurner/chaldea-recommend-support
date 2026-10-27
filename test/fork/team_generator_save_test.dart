// Fork feature test:
//  Team Generator: settings, quest and team are saved in the Battle Sim settings and restored
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('team generator setup survives a settings JSON round trip', () {
    final settings = BattleSimSetting()
      ..teamGenerator = TeamGeneratorSaveData(
        maxTurns: 4,
        maxCommandSpells: 2,
        timeLimitSeconds: 120,
        workers: 3,
        quest: BattleQuestInfo(id: 94000000, phase: 3, enemyHash: 'abc'),
        formation: BattleTeamFormation.fromList(
          svts: [
            SvtSaveData(svtId: 100100, lv: 90),
            null,
            null,
            SvtSaveData(svtId: 504500, supportType: .friend),
          ],
          mysticCode: MysticCodeSaveData(mysticCodeId: 20, level: 7),
        ),
      );
    final restored = BattleSimSetting.fromJson(settings.toJson()).teamGenerator;

    expect(restored.maxTurns, 4);
    expect(restored.maxCommandSpells, 2);
    expect(restored.timeLimitSeconds, 120);
    expect(restored.workers, 3);
    expect(restored.quest?.id, 94000000);
    expect(restored.quest?.phase, 3);
    expect(restored.quest?.enemyHash, 'abc');
    expect(restored.formation.mysticCode.mysticCodeId, 20);
    expect(restored.formation.mysticCode.level, 7);
    expect(restored.formation.svts[0]?.svtId, 100100);
    expect(restored.formation.svts[0]?.lv, 90);
    expect(restored.formation.svts[2], isNull); // empty slot 3 isn't turned into a support placeholder
    expect(restored.formation.svts[3]?.svtId, 504500);
    expect(restored.formation.svts[3]?.supportType, SupportSvtType.friend);
  });

  test('old settings without a team generator setup load the defaults', () {
    final json = BattleSimSetting().toJson()..remove('teamGenerator');
    final restored = BattleSimSetting.fromJson(json).teamGenerator;
    expect(restored.maxTurns, 3);
    expect(restored.workers, isNull);
    expect(restored.quest, isNull);
  });
}
