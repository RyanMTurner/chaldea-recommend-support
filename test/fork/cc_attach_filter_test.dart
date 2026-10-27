// Fork feature test:
//  14. Command Code filter "Attach": 0 / >=1 owned servants with the code equipped
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('counts owned servants that have the command code equipped', () {
    final cc = db.gameData.commandCodes.values.first;
    final svts = db.gameData.servantsNoDup.values.where((svt) => svt.isUserSvt).take(3).toList();
    final saved = [for (final svt in svts) (svt.status.cur.favorite, svt.status.equipCmdCodes.toList())];
    // start from a clean slate for this command code
    final others = [
      for (final status in db.curUser.servants.values)
        if (status.equipCmdCodes.contains(cc.collectionNo)) (status, status.equipCmdCodes.toList()),
    ];
    try {
      for (final (status, _) in others) {
        status.equipCmdCodes = status.equipCmdCodes.map((e) => e == cc.collectionNo ? null : e).toList();
      }
      expect(CmdCodeFilterData.attachedServantCount(cc.collectionNo), 0);

      svts[0].status
        ..favorite = true
        ..setCmdCode(0, cc.collectionNo);
      svts[1].status
        ..favorite = true
        ..setCmdCode(2, cc.collectionNo)
        ..setCmdCode(4, cc.collectionNo); // twice on one servant still counts once
      svts[2].status
        ..favorite =
            false // not owned -> not counted
        ..setCmdCode(1, cc.collectionNo);
      expect(CmdCodeFilterData.attachedServantCount(cc.collectionNo), 2);
    } finally {
      for (final (index, svt) in svts.indexed) {
        svt.status
          ..favorite = saved[index].$1
          ..equipCmdCodes = saved[index].$2;
      }
      for (final (status, codes) in others) {
        status.equipCmdCodes = codes;
      }
    }
  });

  test('filter group options', () {
    final filter = CmdCodeFilterData();
    expect(filter.groups, contains(filter.attach));
    filter.attach.options = {false};
    expect(filter.attach.matchOne(false), isTrue);
    expect(filter.attach.matchOne(true), isFalse);
  });
}
