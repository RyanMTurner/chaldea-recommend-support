// Fork feature test:
//   7. Servant filter "Append Available": >= 120 servant coins and fewer than 5 append skills unlocked
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/servant/filter.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import '../test_init.dart';

const int kAltria = 100100; // has servant coins

void main() async {
  await initiateForTest();

  final altria = db.gameData.servantsById[kAltria]!;
  final coinId = altria.coin!.item.id;

  SvtFilterData appendAvailableFilter() => SvtFilterData()..curStatus.options = {SvtStatusState.appendAvailable};

  bool matches(Servant svt) => ServantFilterPage.filter(appendAvailableFilter(), svt);

  late bool savedFavorite;
  late List<int> savedAppends;
  late int? savedCoins;
  setUp(() {
    final cur = altria.status.cur;
    savedFavorite = cur.favorite;
    savedAppends = cur.appendSkills.toList();
    savedCoins = db.curUser.items[coinId];
    cur.favorite = true;
  });
  tearDown(() {
    final cur = altria.status.cur;
    cur.favorite = savedFavorite;
    cur.appendSkills = savedAppends;
    if (savedCoins == null) {
      db.curUser.items.remove(coinId);
    } else {
      db.curUser.items[coinId] = savedCoins!;
    }
  });

  void setState({required int coins, required int unlockedAppends}) {
    db.curUser.items[coinId] = coins;
    altria.status.cur.appendSkills = List.generate(kAppendSkillNums.length, (i) => i < unlockedAppends ? 1 : 0);
  }

  test('option is listed with its label', () {
    expect(SvtStatusState.values, contains(SvtStatusState.appendAvailable));
    expect(SvtStatusState.appendAvailable.shownName, 'Append Available');
    expect(ServantFilterPage.kAppendUnlockCoins, 120);
  });

  test('120 coins and an append still locked -> shown', () {
    setState(coins: 120, unlockedAppends: 4);
    expect(matches(altria), isTrue);
    setState(coins: 500, unlockedAppends: 0);
    expect(matches(altria), isTrue);
  });

  test('fewer than 120 coins -> hidden', () {
    setState(coins: 119, unlockedAppends: 2);
    expect(matches(altria), isFalse);
    setState(coins: 0, unlockedAppends: 0);
    expect(matches(altria), isFalse);
  });

  test('all 5 appends unlocked -> hidden', () {
    setState(coins: 999, unlockedAppends: kAppendSkillNums.length);
    expect(matches(altria), isFalse);
  });

  test('servant not owned -> hidden', () {
    setState(coins: 999, unlockedAppends: 0);
    altria.status.cur.favorite = false;
    expect(matches(altria), isFalse);
  });

  test('servant without coins never matches', () {
    final noCoin = db.gameData.servantsNoDup.values.firstWhereOrNull((svt) => svt.isUserSvt && svt.coin == null);
    if (noCoin == null) {
      markTestSkipped('no playable servant without coins in game data');
      return;
    }
    final cur = noCoin.status.cur;
    final saved = (cur.favorite, cur.appendSkills.toList());
    cur
      ..favorite = true
      ..appendSkills = List.filled(kAppendSkillNums.length, 0);
    try {
      expect(matches(noCoin), isFalse);
    } finally {
      cur
        ..favorite = saved.$1
        ..appendSkills = saved.$2;
    }
  });

  test('combines with other options in the same row (match any)', () {
    setState(coins: 0, unlockedAppends: 0); // not append-available
    final filter = SvtFilterData()..curStatus.options = {SvtStatusState.appendAvailable, SvtStatusState.appendTwo8};
    expect(ServantFilterPage.filter(filter, altria), isTrue, reason: 'Append 2 < 9 matches');
  });
}
