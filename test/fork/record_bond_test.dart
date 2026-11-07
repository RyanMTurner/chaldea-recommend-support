// Fork feature test:
//  Battle record export: total bond from the clear (servants, not the support) and bond per AP
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/modules/bond/formation_bond_calc.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('every servant adds the same bond, the support none of its own; per AP divides by the AP cost', () {
    int waveCount(QuestPhase q) => q.stages.map((e) => e.wave).fold(0, (a, b) => a > b ? a : b);
    final quest = db.gameData.questPhases.values.firstWhere(
      (q) => q.type == QuestType.free && q.bond > 0 && q.consumeType == ConsumeType.ap && waveCount(q) == 3,
    );
    // Mash (no bond CE, no bond passives) so each servant gets the same bond
    PlayerSvtData mash({bool support = false}) =>
        PlayerSvtData.id(800100)..supportType = support ? SupportSvtType.friend : SupportSvtType.none;

    final (one, perAp) = questClearBond(quest, BattleTeamSetup(svts: [mash()]));
    expect(one, greaterThanOrEqualTo(quest.bond));
    final (two, _) = questClearBond(quest, BattleTeamSetup(svts: [mash(), mash()]));
    expect(two, one * 2);
    final (withSupport, _) = questClearBond(quest, BattleTeamSetup(svts: [mash(), mash(support: true)]));
    // the support gets no bond itself (a friend support may still raise the others' bond a little)
    expect(withSupport, greaterThanOrEqualTo(one));
    expect(withSupport, lessThan(two), reason: 'the support gets no bond');
    final ap = db.gameData.questPhaseDetails[quest.id * 100 + quest.phase]?.actConsume ?? quest.consume;
    expect(perAp, closeTo(one / ap, 1e-9));
  });
}
