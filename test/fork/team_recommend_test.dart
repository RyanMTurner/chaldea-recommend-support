// Fork feature test:
//  Team Generator: "Recommend Teams" (placeholder: owned servants newest first, 6 per team)
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

  test('owned servants, newest first, 6 per team', () {
    db.userData = UserData(); // test account only: tests never save it
    final picked = db.gameData.servantsNoDup.values.where((svt) => svt.collectionNo > 1).take(8).toList();
    for (final svt in picked) {
      db.curUser.svtStatusOf(svt.collectionNo).favorite = true;
    }
    final teams = TeamRecommender.recommend();
    expect(teams.map((t) => t.length).toList(), [6, 2]);
    final order = [for (final team in teams) ...team.map((svt) => svt.collectionNo)];
    final expected = picked.map((svt) => svt.collectionNo).toList()..sort((a, b) => b - a);
    expect(order, expected);
  });
}
