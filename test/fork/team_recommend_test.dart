// Fork feature test:
//  Team Generator: "Recommend Teams" (pools, support data, front lines from attacker coverage)
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/battle/team_generator/recommend.dart';
// ignore: unused_import
import 'package:chaldea/app/modules/battle/team_generator/team_generator.dart'; // the page compiles
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  final playable = db.gameData.servantsNoDup.values.where((svt) => svt.isUserSvt && svt.collectionNo > 1).toList();

  setUp(() => db.userData = UserData()); // test account only: tests never save it

  test('own pool: owned, newest first, bond filter like Team Bond', () {
    final picked = playable.take(8).toList();
    for (final (i, svt) in picked.indexed) {
      db.curUser.svtStatusOf(svt.collectionNo)
        ..favorite = true
        ..bond = i; // bonds 0-7
    }
    final all = TeamRecommender.ownPool();
    expect(all.map((s) => s.collectionNo), picked.map((s) => s.collectionNo).toList()..sort((a, b) => b - a));
    final below5 = TeamRecommender.ownPool(maxBond: 5);
    expect(below5.length, 5, reason: 'bond 5 or higher left out');
  });

  test('support data: the player\'s when owned, otherwise 10/10/10, max level, no appends', () {
    final svt = playable.firstWhere((s) => s.rarity == 5);
    final friend = TeamRecommender.supportData(svt);
    expect(friend.supportType, SupportSvtType.friend);
    expect(friend.skillLvs, [10, 10, 10]);
    expect(friend.lv, svt.lvMax);
    expect(friend.appendLvs.every((lv) => lv == 0), isTrue);

    db.curUser.svtStatusOf(svt.collectionNo)
      ..favorite = true
      ..cur.skills = [4, 5, 6];
    expect(TeamRecommender.supportData(svt).skillLvs, [4, 5, 6]);
  });

  test('capped owned servants are support candidates only when the support ignores the cap', () {
    final svt = playable.first;
    db.curUser.svtStatusOf(svt.collectionNo)
      ..favorite = true
      ..bond = 10;
    bool listed(List<TgCandidate> list) => list.any((c) => c.svt.id == svt.id);
    expect(listed(TeamRecommender.candidates(maxBond: 10)), isFalse);
    final withCap = TeamRecommender.candidates(maxBond: 10, supportIgnoresBondCap: true);
    expect(withCap.firstWhere((c) => c.svt.id == svt.id).supportOnly, isTrue);
  });

  test('front lines cover every wave, at most one support-only member', () {
    final candidates = [
      for (final (i, svt) in playable.take(6).indexed)
        TgCandidate(TeamRecommender.supportData(svt), supportOnly: i >= 4),
    ];
    // 0 clears everything alone; 1 and 2 cover different waves; 3-5 can't attack
    final ratios = [
      [1.0, 1.0, 1.0],
      [0.9, 0.9, 0.1],
      [0.1, 0.1, 0.8],
      [0.0, 0.0, 0.0],
      [0.0, 0.0, 0.0],
      [0.0, 0.0, 0.0],
    ];
    final fronts = TeamRecommender.frontLines(candidates, ratios);
    expect(fronts, isNotEmpty);
    for (final (members, _) in fronts) {
      expect(members.length, 3);
      expect(members.toSet().length, 3);
      expect(members.where((m) => candidates[m].supportOnly).length, lessThanOrEqualTo(1));
      for (int w = 0; w < 3; w++) {
        expect(members.any((m) => ratios[m][w] >= 0.5), isTrue, reason: 'wave ${w + 1} covered: $members');
      }
    }
    expect(fronts.any((f) => f.$1.contains(1) && f.$1.contains(2) && !f.$1.contains(0)), isTrue);
  });
}
