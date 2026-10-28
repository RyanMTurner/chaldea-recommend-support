// Fork feature test:
//  Team Generator: "Recommend Teams" (pools, support data, front lines from attacker coverage)
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/battle.dart';
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

  test('excluded servants are never candidates, not even as the support', () {
    final owned = playable[0], other = playable[1];
    db.curUser.svtStatusOf(owned.collectionNo).favorite = true;
    final excluded = {owned.id, other.id};
    expect(TeamRecommender.ownPool(excluded: excluded).any((s) => s.id == owned.id), isFalse);
    final list = TeamRecommender.candidates(excluded: excluded);
    expect(list.any((c) => excluded.contains(c.svt.id)), isFalse);
    expect(TeamRecommender.candidates().any((c) => c.svt.id == other.id), isTrue, reason: 'listed when not excluded');
  });

  test('front lines cover every wave, at most one support-only member', () {
    final candidates = [
      for (final (i, svt) in playable.take(6).indexed)
        TgCandidate(TeamRecommender.supportData(svt), supportOnly: i >= 4),
    ];
    // 0 clears everything alone; 1 and 2 cover different waves; 3-5 can't attack (no CE option)
    final ratios = [
      [
        [1.0, 1.0, 1.0],
      ],
      [
        [0.9, 0.9, 0.1],
      ],
      [
        [0.1, 0.1, 0.8],
      ],
      for (int i = 0; i < 3; i++)
        [
          [0.0, 0.0, 0.0],
        ],
    ];
    final fronts = TeamRecommender.frontLines(candidates, ratios);
    expect(fronts, isNotEmpty);
    for (final (members, _, _) in fronts) {
      expect(members.length, 3);
      expect(members.toSet().length, 3);
      expect(members.where((m) => candidates[m].supportOnly).length, lessThanOrEqualTo(1));
      for (int w = 0; w < 3; w++) {
        expect(members.any((m) => ratios[m][0][w] >= 0.5), isTrue, reason: 'wave ${w + 1} covered: $members');
      }
    }
    expect(fronts.any((f) => f.$1.contains(1) && f.$1.contains(2) && !f.$1.contains(0)), isTrue);
  });

  test('the CE goes where it covers the waves', () {
    final candidates = [
      for (final (i, svt) in playable.take(4).indexed)
        TgCandidate(TeamRecommender.supportData(svt), supportOnly: i == 3),
    ];
    // per candidate: [no CE, with the CE]; 0 needs the CE for wave 3, 1 doesn't care
    final ratios = [
      [
        [0.9, 0.9, 0.3],
        [0.9, 0.9, 0.7],
      ],
      [
        [0.6, 0.6, 0.6],
        [0.6, 0.6, 0.6],
      ],
      for (int i = 0; i < 2; i++)
        [
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
        ],
    ];
    final fronts = TeamRecommender.frontLines(candidates, ratios, ceCount: 1);
    final loop0 = fronts.where((f) => f.$1.first == 0 && !f.$1.contains(1)).toList();
    expect(loop0, isNotEmpty, reason: 'attacker 0 loops only with the CE');
    for (final (members, ceOptions, _) in loop0) {
      expect(ceOptions[members.indexOf(0)], 1, reason: 'the CE is on attacker 0');
      expect(ceOptions.where((o) => o == 1).length, 1, reason: 'one CE, one member');
    }
  });

  test('a support set in the manual team is the only support, in every front line, keeping its CE', () {
    final own = playable.take(3).toList();
    for (final svt in own) {
      db.curUser.svtStatusOf(svt.collectionNo).favorite = true;
    }
    // the support is a friend's copy of an owned servant: own copy + support copy is allowed
    final fixed = TeamRecommender.supportData(own.first)..equip1 = SvtEquipData(ce: db.gameData.craftEssences[1]);
    final candidates = TeamRecommender.candidates(fixedSupport: fixed);
    expect(candidates.where((c) => c.supportOnly).length, 1);
    final required = candidates.indexWhere((c) => c.supportOnly);
    expect(candidates[required].data.equip1.ce, isNotNull);

    // everyone attacks well enough; one CE to hand out
    final ratios = [
      for (int i = 0; i < candidates.length; i++)
        [
          [0.8, 0.8, 0.8],
          [0.9, 0.9, 0.9],
        ],
    ];
    final fronts = TeamRecommender.frontLines(candidates, ratios, ceCount: 1, requiredMember: required);
    expect(fronts, isNotEmpty);
    expect(
      fronts.any((f) => f.$1.map((m) => candidates[m].svt.id).toSet().length < 3),
      isTrue,
      reason: 'the owned copy and the support copy of the same servant together',
    );
    for (final (members, ceOptions, _) in fronts) {
      expect(members, contains(required));
      expect(ceOptions[members.indexOf(required)], 0, reason: 'the support keeps its own CE');
      expect(ceOptions.where((o) => o == 1).length, 1, reason: 'the CE goes to another member');
    }
  });

  test('cheap scoring with the set support: its buffs raise the attacker\'s share of each wave', () async {
    int waveCount(QuestPhase q) => q.stages.map((e) => e.wave).fold(0, (a, b) => a > b ? a : b);
    final quest = db.gameData.questPhases.values.firstWhere(
      (q) => q.type == QuestType.free && waveCount(q) == 3 && q.stages.every((s) => s.enemies.isNotEmpty),
    );
    // a weak Altria (Lv.1 NP1) doesn't clear on her own; Merlin's party ATK/Buster buffs add damage
    final altria = PlayerSvtData.id(100100)
      ..lv = 1
      ..tdLv = 1;
    final merlin = TeamRecommender.supportData(db.gameData.servantsById[500800]!);
    final alone = await scoreAttacker(quest, altria);
    final helped = await scoreAttacker(quest, altria, support: merlin);
    expect(alone.length, 3);
    for (int w = 0; w < 3; w++) {
      expect(helped[w], greaterThanOrEqualTo(alone[w]), reason: 'wave ${w + 1}: $alone vs $helped');
    }
    expect(helped.reduce((a, b) => a + b), greaterThan(alone.reduce((a, b) => a + b)), reason: '$alone vs $helped');
  });
}
