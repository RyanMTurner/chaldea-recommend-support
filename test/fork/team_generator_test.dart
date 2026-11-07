// Fork feature test:
//  15. Team Generator: one turn per wave, NPs + the weakest face cards, NP users charged with as little waste
//      as possible (skills, then Command Spells), buffs added one at a time until the wave is cleared
//  18. Team Generator: pause at the time limit, "Add more time" continues the same search
//  19. Team Generator: parallel search on worker isolates
//  21. Team Generator: skills that can't help are never used; long party buffs are used right away
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/modules/battle/simulation/fga_export.dart';
import 'package:chaldea/app/modules/battle/team_generator/solver.dart';
import 'package:chaldea/app/modules/battle/team_generator/workers.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int kAltria = 100100; // AOE Buster NP
const int kMerlin = 500800; // support NP, no damage

BattleTeamSetup altriaTeam() => BattleTeamSetup(
  svts: [
    PlayerSvtData.id(kAltria)
      ..lv = 90
      ..tdLv = 5,
  ],
  mysticCodeData: MysticCodeData()..mysticCode = null,
);

void main() async {
  await initiateForTest();

  // the easiest 3-wave free quest in the local data (lowest toughest-enemy HP), so a lone Altria NP5
  // clears every wave even with the minimum damage roll
  int waveCount(QuestPhase q) => q.stages.map((e) => e.wave).fold(0, (a, b) => a > b ? a : b);
  int toughest(QuestPhase q) => [
    for (final stage in q.stages)
      for (final enemy in stage.enemies) enemy.hp,
  ].fold(0, (a, b) => a > b ? a : b);
  final candidates = db.gameData.questPhases.values
      .where((q) => q.type == QuestType.free && waveCount(q) == 3 && q.stages.every((s) => s.enemies.isNotEmpty))
      .toList();
  candidates.sort((a, b) => toughest(a) - toughest(b));
  final quest = candidates.first;
  final waves = quest.stages.map((e) => e.wave).reduce((a, b) => a > b ? a : b);

  test('empty front line is rejected', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: BattleTeamSetup(),
      settings: TeamGeneratorSettings(),
    ).solve();
    expect(result.success, isFalse);
  });

  test('no NP gauge and no Command Spells: no plan', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxCommandSpells: 0, timeLimitSeconds: 30),
    ).solve();
    expect(result.success, isFalse);
  });

  test('Command Spells charge the NP each wave; plan replays and exports', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxCommandSpells: 3, timeLimitSeconds: 60),
    ).solve();
    expect(result.success, isTrue, reason: 'quest ${quest.id}: ${result.message}');
    expect(result.turns.length, waves, reason: 'one turn per wave');
    expect(result.commandSpellsUsed, inInclusiveRange(1, 3));
    expect(result.battle!.isBattleWin, isTrue);
    for (final turn in result.turns) {
      expect(turn.npSlots, contains(0));
    }

    final command = FgaCommandExporter(result.battle!.recorder.records).export();
    expect(command, contains('o1'));
    expect(command, contains('4'));

    final share = TeamGeneratorSolver.toShareData(quest, altriaTeam(), result.battle!);
    expect(share.actions, isNotEmpty);
    expect(share.quest?.id, quest.id);
  });

  test('Command Spell limit is respected', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxCommandSpells: 1, timeLimitSeconds: 30),
    ).solve();
    if (result.success) expect(result.commandSpellsUsed, lessThanOrEqualTo(1));
  });

  group('Cards and NP order', () {
    BattleTeamSetup trio() => BattleTeamSetup(
      svts: [
        PlayerSvtData.id(kAltria)
          ..lv = 90
          ..tdLv = 5,
        PlayerSvtData.id(kMerlin),
        PlayerSvtData.id(kMerlin),
      ],
      mysticCodeData: MysticCodeData()..mysticCode = null,
    );

    test('NP users: each servant alone, then ordered pairs, then every order of three', () async {
      final battle = BattleData();
      final team = trio();
      await battle.init(quest, team.svts, team.mysticCodeData);
      final orders = TeamGeneratorSolver.npOrders(battle);
      expect(orders.take(3).toList(), [
        [0],
        [1],
        [2],
      ]);
      expect(orders.skip(3).take(6).every((o) => o.length == 2 && o[0] != o[1]), isTrue);
      expect(orders.skip(9).every((o) => o.length == 3 && o.toSet().length == 3), isTrue);
      expect(orders.length, 3 + 6 + 6);
    });

    test('one NP + the two weakest face cards, avoiding Brave and color chains', () async {
      final battle = BattleData();
      final team = trio();
      await battle.init(quest, team.svts, team.mysticCodeData);
      expect(TeamGeneratorSolver.attackCards(battle, [0]), isNull, reason: 'NP not charged');

      battle.onFieldAllyServants[0]!.np = ConstData.constants.fullTdPoint;
      final cards = TeamGeneratorSolver.attackCards(battle, [0])!;
      expect(cards.length, 3);
      expect(cards[0].cardData.isTD, isTrue);
      expect(cards.skip(1).every((c) => !c.cardData.isTD), isTrue);
      expect(cards.every((c) => c.actor == cards[0].actor), isFalse, reason: 'no Brave Chain');

      // Merlin (low ATK) has weaker cards than Altria, so the faces come from Merlin
      final altria = battle.onFieldAllyServants[0]!;
      expect(cards.skip(1).any((c) => c.actor == altria), isFalse);
      final ratings = [for (final c in cards.skip(1)) TeamGeneratorSolver.cardRating(c.actor, c.cardData).$1];
      final weakest = [
        for (final svt in battle.nonnullPlayers)
          for (final card in svt.getCards()) TeamGeneratorSolver.cardRating(svt, card).$1,
      ]..sort();
      expect(ratings.first, weakest.first);
    });

    test('solo servant: a Brave Chain is unavoidable and allowed', () async {
      final battle = BattleData();
      final team = altriaTeam();
      await battle.init(quest, team.svts, team.mysticCodeData);
      battle.onFieldAllyServants[0]!.np = ConstData.constants.fullTdPoint;
      expect(TeamGeneratorSolver.attackCards(battle, [0])?.length, 3);
    });

    test('NP charge choice: fewest Command Spells, then least overflow, then fewest skills', () {
      // options of a source with no target: the gain of the single NP user
      List<List<int>> gives(int gain) => [
        [gain],
      ];
      final cs = gives(10000);
      List<int?>? pick(int need, List<List<List<int>>> sources) =>
          TeamGeneratorSolver.pickCharges([need], sources, [for (final s in sources) identical(s, cs)]);

      expect(pick(5000, [gives(3000), gives(2000), gives(5000), cs]), [null, null, 0, null], reason: 'one skill');
      expect(
        pick(7000, [gives(2000), gives(2000), gives(5000), cs]),
        anyOf([
          [null, 0, 0, null],
          [0, null, 0, null],
        ]),
        reason: '20+50: no waste',
      );
      expect(pick(7000, [gives(5000), gives(5000), cs]), [0, 0, null], reason: 'waste beats a Command Spell');
      expect(pick(10000, [gives(2000), cs]), [null, 0], reason: 'only the Command Spell gets there');
      expect(pick(10000, [gives(2000)]), isNull);

      // every way, cheapest first: the solver falls back to the next one when a later wave fails
      expect(
        TeamGeneratorSolver.chargeChoices([5000], [gives(3000), gives(2000), gives(5000)], [false, false, false]),
        [
          [null, null, 0], // 50: no waste, 1 skill
          [0, 0, null], // 30+20: no waste, 2 skills
          [null, 0, 0], // 20+50: 20 waste
          [0, null, 0], // 30+50: 30 waste
        ],
      );

      // single-ally skills: one option per NP user; two NP users needing 20 each
      final either = [
        [2000, 0],
        [0, 2000],
      ];
      expect(
        TeamGeneratorSolver.pickCharges([2000, 2000], [either, either], [false, false]),
        anyOf([
          [0, 1],
          [1, 0],
        ]),
      );
    });
  });

  group('Time limit', () {
    test('pauses at the limit and continues where it stopped after adding time', () async {
      int pauses = 0;
      int simulationsAtPause = -1;
      late TeamGeneratorSolver solver;
      solver = TeamGeneratorSolver(
        quest: quest,
        formation: altriaTeam(),
        settings: TeamGeneratorSettings(maxCommandSpells: 3, timeLimitSeconds: 0),
        onPaused: (simulations, _) {
          pauses++;
          simulationsAtPause = simulations;
          expect(solver.isPaused, isTrue);
          Future.microtask(() => solver.addTime(60));
        },
      );
      final result = await solver.solve();
      expect(pauses, 1, reason: '0s limit pauses once, then 60s is plenty');
      expect(simulationsAtPause, 0, reason: 'paused before the first simulation');
      expect(solver.timeLimitSeconds, 60);
      expect(result.success, isTrue, reason: result.message);
      expect(solver.isPaused, isFalse);
    });

    test('Stop while paused ends without a plan', () async {
      late TeamGeneratorSolver solver;
      solver = TeamGeneratorSolver(
        quest: quest,
        formation: altriaTeam(),
        settings: TeamGeneratorSettings(maxCommandSpells: 3, timeLimitSeconds: 0),
        onPaused: (_, _) => Future.microtask(solver.cancel),
      );
      final result = await solver.solve();
      expect(result.success, isFalse);
      expect(result.message, contains('No plan found within 0s'));
    });
  });

  group('Parallel', () {
    TeamGeneratorSettings csSettings({int workers = 0}) =>
        TeamGeneratorSettings(maxCommandSpells: 3, timeLimitSeconds: 120, workers: workers);

    test('first-turn options are split between partitions; together they find the plan', () async {
      final results = [
        for (int index = 0; index < 2; index++)
          await TeamGeneratorSolver(
            quest: quest,
            formation: altriaTeam(),
            settings: csSettings(),
            partitionIndex: index,
            partitionCount: 2,
          ).solve(),
      ];
      expect(results.any((r) => r.success), isTrue, reason: results.map((r) => r.message).join(' / '));
      final full = await TeamGeneratorSolver(quest: quest, formation: altriaTeam(), settings: csSettings()).solve();
      expect(full.success, isTrue);
    });

    test('external pause and resume (used by parallel runs to share one clock)', () async {
      final solver = TeamGeneratorSolver(quest: quest, formation: altriaTeam(), settings: csSettings());
      solver.pause();
      expect(solver.isPaused, isTrue);
      final future = solver.solve();
      await Future.delayed(const Duration(milliseconds: 100));
      expect(solver.simulations, 0, reason: 'paused before the first simulation');
      solver.resume();
      final result = await future;
      expect(result.success, isTrue, reason: result.message);
      expect(result.fgaCommand, isNotEmpty);
      expect(result.shareData, isNotNull);
    });

    test('workers find a plan; FGA command and replay data come back without the battle object', () async {
      try {
        final run = ParallelTeamGeneratorRun(quest: quest, formation: altriaTeam(), settings: csSettings(workers: 2));
        final result = await run.solve();
        expect(result.success, isTrue, reason: result.message);
        expect(result.battle, isNull);
        expect(result.fgaCommand, contains('o1'));
        expect(result.shareData?.actions, isNotEmpty);
        expect(result.commandSpellsUsed, inInclusiveRange(1, 3));

        // the pool is reused for the next solve
        final again = await ParallelTeamGeneratorRun(
          quest: quest,
          formation: altriaTeam(),
          settings: csSettings(workers: 2),
        ).solve();
        expect(again.success, isTrue);
      } finally {
        await TeamGeneratorWorkerPool.disposeCurrent();
      }
    });

    test('workers: impossible plan ends with "No plan" once every worker is done', () async {
      try {
        final result = await ParallelTeamGeneratorRun(
          quest: quest,
          formation: altriaTeam(),
          settings: TeamGeneratorSettings(maxCommandSpells: 0, timeLimitSeconds: 120, workers: 2),
        ).solve();
        expect(result.success, isFalse);
        expect(result.message, TeamGeneratorSolver.noPlanMessage);
      } finally {
        await TeamGeneratorWorkerPool.disposeCurrent();
      }
    });
  });

  group('Ally targets', () {
    bool singleAlly(NiceFunction f) =>
        f.funcTargetTeam != FuncApplyTarget.enemy && f.funcTargetType.needNormalOneTarget;
    bool npCharge(NiceFunction f) => f.funcType.name.startsWith('gainNp');

    /// first servant active skill whose single-ally functions match [test]
    NiceSkill? findSkill(bool Function(List<NiceFunction> funcs) test) {
      for (final svt in db.gameData.servantsNoDup.values) {
        for (final skill in svt.skills) {
          final funcs = skill.functions.where(singleAlly).toList();
          if (funcs.isNotEmpty && test(funcs)) return skill;
        }
      }
      return null;
    }

    test('NP charge may target anyone', () {
      final skill = findSkill((funcs) => funcs.any(npCharge));
      expect(skill, isNotNull);
      expect(TeamGeneratorSolver.mayTargetAnyAlly(skill!), isTrue);
    });

    test('1-turn buffs only (no NP charge) stay on the attacker', () {
      final skill = findSkill(
        (funcs) => !funcs.any(npCharge) && funcs.every((f) => f.buffs.isNotEmpty && f.svals.firstOrNull?.Turn == 1),
      );
      expect(skill, isNotNull);
      expect(TeamGeneratorSolver.mayTargetAnyAlly(skill!), isFalse);
    });

    test('buffs lasting longer than 1 turn may target anyone', () {
      final skill = findSkill(
        (funcs) =>
            !funcs.any(npCharge) && funcs.any((f) => f.buffs.isNotEmpty && (f.svals.firstOrNull?.Turn ?? 0) >= 3),
      );
      expect(skill, isNotNull);
      expect(TeamGeneratorSolver.mayTargetAnyAlly(skill!), isTrue);
    });

    test('skills without a single-ally effect have no target choice', () {
      final skill = db.gameData.servantsById[kAltria]!.skills.firstWhere((skill) => !skill.functions.any(singleAlly));
      expect(TeamGeneratorSolver.mayTargetAnyAlly(skill), isFalse);
    });
  });

  group('Skill use by effect', () {
    NiceSkill? findSkill(bool Function(NiceSkill skill) test) {
      for (final svt in db.gameData.servantsNoDup.values) {
        for (final skill in svt.skills) {
          if (skill.functions.isNotEmpty && test(skill)) return skill;
        }
      }
      return null;
    }

    const starOnlyBuffs = {'upStarweight', 'upCriticalpoint', 'regainStar', 'upCriticalrate'};

    test('star-only skill is never used', () {
      final skill = findSkill(
        (skill) => skill.functions.every(
          (f) =>
              f.funcType == FuncType.gainStar ||
              (f.buffs.isNotEmpty && f.buffs.every((b) => starOnlyBuffs.contains(b.type.name))),
        ),
      );
      expect(skill, isNotNull);
      expect(TeamGeneratorSolver.skillUse(skill!), TgSkillUse.never);
    });

    test('party ATK up for 3 turns is used right away', () {
      final skill = findSkill(
        (skill) => skill.functions.every(
          (f) =>
              f.funcTargetType == FuncTargetType.ptAll &&
              f.buffs.isNotEmpty &&
              f.buffs.every((b) => b.type == BuffType.upAtk) &&
              f.svals.firstOrNull?.Turn == 3,
        ),
      );
      expect(skill, isNotNull);
      expect(TeamGeneratorSolver.skillUse(skill!), TgSkillUse.always);
    });

    test('NP charge and single-target skills are not used right away', () {
      final charge = findSkill(
        (skill) =>
            skill.functions.any((f) => f.funcType == FuncType.gainNp && f.funcTargetType == FuncTargetType.ptAll),
      );
      expect(charge, isNotNull);
      expect(TeamGeneratorSolver.skillUse(charge!), TgSkillUse.choose);

      final single = findSkill(
        (skill) => skill.functions.any(
          (f) => f.funcTargetType == FuncTargetType.ptOne && f.buffs.any((b) => b.type == BuffType.upAtk),
        ),
      );
      expect(single, isNotNull);
      expect(TeamGeneratorSolver.skillUse(single!), TgSkillUse.choose);
    });

    test('enemy debuffs are not used right away (wasted on the next wave if used early)', () {
      final debuff = findSkill(
        (skill) => skill.functions.any(
          (f) => f.funcTargetType == FuncTargetType.enemyAll && f.buffs.any((b) => b.type == BuffType.downDefence),
        ),
      );
      expect(debuff, isNotNull);
      expect(TeamGeneratorSolver.skillUse(debuff!), TgSkillUse.choose);
    });

    test('never-used skills are left out', () async {
      final battle = BattleData();
      final team = altriaTeam();
      await battle.init(quest, team.svts, team.mysticCodeData);
      final altria = battle.onFieldAllyServants[0]!;
      final listed = TeamGeneratorSolver.availableSkills(battle).map((s) => s.skillIndex).toSet();
      for (final (index, info) in altria.skillInfoList.indexed) {
        final skill = info.skill;
        if (skill == null) continue;
        expect(
          listed.contains(index),
          TeamGeneratorSolver.skillUse(skill) != TgSkillUse.never,
          reason: 'Altria S${index + 1}',
        );
      }
    });
  });
}
