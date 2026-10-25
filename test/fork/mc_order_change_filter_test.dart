// Fork feature test:
//  11. Mystic Code filter: "Order Change" effect (after Field Type), mystic codes only
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/models/gamedata/effect.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int kCombatUniform = 20; // has Order Change

void main() async {
  await initiateForTest();

  test('listed after Field Type, hidden for servants, command codes and CEs', () {
    final others = SkillEffect.kOthers;
    expect(others.indexOf(SkillEffect.replaceMember), others.indexOf(SkillEffect.fieldIndividuality) + 1);
    expect(SkillEffect.mcIgnores, isNot(contains(SkillEffect.replaceMember)));
    expect(SkillEffect.svtIgnores, contains(SkillEffect.replaceMember));
    expect(SkillEffect.ccIgnores, contains(SkillEffect.replaceMember));
    expect(SkillEffect.ceIgnores, contains(SkillEffect.replaceMember));
    expect(SkillEffect.replaceMember.lName, 'Order Change');
  });

  test('matches exactly the mystic codes with an Order Change skill', () {
    final filter = MysticCodeFilterData()..effectType.options = {SkillEffect.replaceMember};
    final matched = db.gameData.mysticCodes.values.where(filter.filter).toList();
    expect(matched.map((mc) => mc.id), contains(kCombatUniform));
    for (final mc in db.gameData.mysticCodes.values) {
      final hasOrderChange = mc.skills.any(
        (skill) => skill.functions.any((func) => func.funcType == FuncType.replaceMember),
      );
      expect(matched.contains(mc), hasOrderChange, reason: 'MC ${mc.id} ${mc.name}');
    }
  });
}
