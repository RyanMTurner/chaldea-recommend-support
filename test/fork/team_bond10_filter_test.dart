// Fork feature test:
//  Shared team filter, Misc: "Max 1 Servant At Bond 10+" (the player's own bond, supports included)
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/battle/teams/filter.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('counts servants at bond 10+ in the players box, supports included', () {
    final svts = db.gameData.servantsNoDup.values.where((svt) => svt.collectionNo > 1).take(3).toList();
    final saved = {for (final svt in svts) svt.collectionNo: db.curUser.svtStatusOf(svt.collectionNo).bond};
    try {
      db.curUser.svtStatusOf(svts[0].collectionNo).bond = 10;
      db.curUser.svtStatusOf(svts[1].collectionNo).bond = 12;
      db.curUser.svtStatusOf(svts[2].collectionNo).bond = 9;

      expect(TeamFilterData.countBond10Plus([SvtSaveData(svtId: svts[0].id), SvtSaveData(svtId: svts[2].id), null]), 1);
      expect(TeamFilterData.countBond10Plus([SvtSaveData(svtId: svts[0].id), SvtSaveData(svtId: svts[1].id)]), 2);
      // the team's support may be the player's own servant
      expect(
        TeamFilterData.countBond10Plus([
          SvtSaveData(svtId: svts[0].id),
          SvtSaveData(svtId: svts[1].id, supportType: SupportSvtType.friend),
        ]),
        2,
      );

      // at most one servant at bond 10+
      expect(TeamFilterData.allowsBond10([SvtSaveData(svtId: svts[0].id), SvtSaveData(svtId: svts[2].id)]), true);
      expect(TeamFilterData.allowsBond10([SvtSaveData(svtId: svts[0].id), SvtSaveData(svtId: svts[1].id)]), false);
      // the same servant twice: no servant at bond 10+
      expect(
        TeamFilterData.allowsBond10([
          SvtSaveData(svtId: svts[2].id),
          SvtSaveData(svtId: svts[2].id, supportType: SupportSvtType.friend),
          SvtSaveData(svtId: svts[0].id),
        ]),
        false,
      );
      expect(
        TeamFilterData.allowsBond10([
          SvtSaveData(svtId: svts[2].id),
          SvtSaveData(svtId: svts[2].id, supportType: SupportSvtType.friend),
        ]),
        true,
      );
    } finally {
      saved.forEach((no, bond) => db.curUser.svtStatusOf(no).bond = bond);
    }
  });

  test('listed last in Misc', () {
    expect(TeamFilterMiscType.values.last, TeamFilterMiscType.maxOneBond10);
    expect(TeamFilterMiscType.maxOneBond10.shownName, 'Max 1 Servant At Bond 10+');
  });
}
