// Fork feature test:
//  12. War "Free Quest" list: "AP 40 | Bond 3797 | Eff 94.925", sorted by bond per AP
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/quest/quest_list.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('efficiency format: up to 3 decimals, no trailing zeros', () {
    expect(QuestListPage.formatEfficiency(3797 / 40), '94.925');
    expect(QuestListPage.formatEfficiency(95.0), '95');
    expect(QuestListPage.formatEfficiency(94.9), '94.9');
    expect(QuestListPage.formatEfficiency(100.0), '100');
    expect(QuestListPage.formatEfficiency(40.5), '40.5');
  });

  test('bond and AP come from the last phase of repeatable free quests', () {
    final frees = db.gameData.quests.values
        .where((q) => q.isAnyFree && q.afterClear.isRepeat && q.phases.isNotEmpty)
        .toList();
    expect(frees, isNotEmpty);
    int checked = 0;
    for (final quest in frees) {
      final key = quest.id * 100 + quest.phases.last;
      final detail = db.gameData.questPhaseDetails[key];
      final bond = db.gameData.questPhases[key]?.bond ?? detail?.bond ?? 0;
      final consume = detail?.actConsume ?? quest.consume;
      final eff = QuestListPage.bondEfficiency(quest);
      if (bond <= 0 || consume <= 0 || !quest.consumeType.useApOrBp) {
        expect(eff, isNull, reason: 'quest ${quest.id}');
        continue;
      }
      expect(eff, closeTo(bond / consume, 1e-9), reason: 'quest ${quest.id}');
      checked++;
    }
    expect(checked, greaterThan(0), reason: 'game data should include bond for free quests');
  });
}
