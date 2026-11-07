// Fork feature test:
//  Team Bond page: rarity filter on servants the solver may add to the team
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/user.dart';
import 'package:chaldea/app/modules/bond/solver/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('no rarity selected lets every rarity through', () {
    final option = FormationBondOption();
    expect(option.svtRarities, isEmpty);
    for (var rarity = 0; rarity <= 5; rarity++) {
      expect(option.matchesSvtRarity(rarity), isTrue);
    }
  });

  test('selected rarities are the only ones let through', () {
    final option = FormationBondOption()..svtRarities = {3, 5};
    expect([for (var r = 0; r <= 5; r++) option.matchesSvtRarity(r)], [false, false, false, true, false, true]);
  });

  test('the selection survives serialization and copy', () {
    final option = FormationBondOption()..svtRarities = {1, 4};
    expect(FormationBondOption.fromJson(option.toJson()).svtRarities, {1, 4});
    expect(FormationBondOption.fromJson({}).svtRarities, isEmpty);
    final copy = option.copy();
    expect(copy.svtRarities, {1, 4});
    copy.svtRarities.add(5);
    expect(option.svtRarities, {1, 4}, reason: 'copy must not share the set');
  });

  test('the solver only adds servants of a selected rarity, and ignores rarity when none is selected', () {
    Servant pick(int rarity) => db.gameData.servantsById.values.firstWhere(
      (svt) => svt.collectionNo > 0 && svt.isUserSvt && svt.rarity == rarity,
    );
    final five = pick(5), three = pick(3);
    final quest = QuestPhase(bond: 1000);

    FormationBondOption options(Set<int> rarities) => FormationBondOption(
      enableEvent: false,
      frontlineBonus: false,
      releaseReference: BondReleaseReference.jp,
      favoriteSvtOnly: false,
      favoriteSvtEquipOnly: false,
      maxBond: 0,
      maxCost: 999,
      maxServants: 2,
      searchFixedAscensions: false,
      svtRarities: rarities,
    )..excludedSvts = (db.gameData.servantsById.keys.toSet()..removeAll([five.id, three.id]));

    Set<int> added(Set<int> rarities) {
      final result = FormationBondSolver.solve(option: options(rarities), quest: quest, formation: BattleTeamSetup());
      return {for (final slot in result.best?.slots ?? const <BondSolvedSlot>[]) slot.servantId}
        ..removeWhere((id) => id == null || id == 0);
    }

    expect(added({3}), {three.id});
    expect(added({5}), {five.id});
    expect(added({3, 5}), {three.id, five.id});
    expect(added({}), {three.id, five.id});
  });
}
