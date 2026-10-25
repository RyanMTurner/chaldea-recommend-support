// Fork feature test:
//  15. Team Generator: find a skill / Command Spell / NP plan that clears a quest with a fixed team
//  16. Team Generator: Order Change (mystic code) support
//  17. Team Generator: the incoming servant may save skills for later turns
//  18. Team Generator: pause at the time limit, "Add more time" continues the same search
//  19. Team Generator: parallel search on worker isolates
//  20. Team Generator: single-ally skill targets are searched (1-turn buffs stay on the attacker),
//      any number of skills may stay unused
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
const int kQuest = 9300040603; // local free quest used by battle_test.dart
const int kMerlin = 500800; // support NP, no damage
const int kCombatUniform = 20; // mystic code with Order Change

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

  final quest = db.gameData.questPhases[kQuest]!;
  final waves = quest.stages.map((e) => e.wave).reduce((a, b) => a > b ? a : b);

  test('empty front line is rejected', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: BattleTeamSetup(),
      settings: TeamGeneratorSettings(),
    ).solve();
    expect(result.success, isFalse);
  });

  test('fewer turns than waves cannot clear', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxTurns: waves - 1, maxCommandSpells: 3),
    ).solve();
    expect(result.success, isFalse);
  });

  test('no NP gauge and no Command Spells: no plan', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 0, timeLimitSeconds: 30),
    ).solve();
    expect(result.success, isFalse);
  });

  test('Command Spells charge the NP each wave; plan replays and exports', () async {
    final result = await TeamGeneratorSolver(
      quest: quest,
      formation: altriaTeam(),
      settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 3, timeLimitSeconds: 60),
    ).solve();
    expect(result.success, isTrue, reason: result.message);
    expect(result.turns.length, lessThanOrEqualTo(waves));
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
      settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 1, timeLimitSeconds: 30),
    ).solve();
    if (result.success) expect(result.commandSpellsUsed, lessThanOrEqualTo(1));
  });

  group('Order Change', () {
    // front line has no damage NP; the only attacker waits in the backup row
    BattleTeamSetup swapTeam() => BattleTeamSetup(
      svts: [
        PlayerSvtData.id(kMerlin),
        PlayerSvtData.id(kMerlin),
        PlayerSvtData.id(kMerlin),
        PlayerSvtData.id(kAltria)
          ..lv = 90
          ..tdLv = 5,
      ],
      mysticCodeData: MysticCodeData()
        ..mysticCode = db.gameData.mysticCodes[kCombatUniform]!
        ..level = 10,
    );

    test('options list every front-line / backup pair when the mystic code can swap', () async {
      final battle = BattleData();
      final team = swapTeam();
      await battle.init(quest, team.svts, team.mysticCodeData);
      expect(TeamGeneratorSolver.orderChangeSkillIndex(battle), isNotNull);
      final options = TeamGeneratorSolver.orderChangeOptions(battle);
      expect(options.first, isNull, reason: 'no swap is tried first');
      expect(options.skip(1).toSet(), {
        for (int onField = 0; onField < 3; onField++) (onField: onField, backup: 0),
      });
      expect(
        TeamGeneratorSolver.availableSkills(battle).where((s) => s.isMysticCode).map((s) => s.skillIndex),
        isNot(contains(TeamGeneratorSolver.orderChangeSkillIndex(battle))),
        reason: 'Order Change is handled separately',
      );
    });

    test('incoming servant hold options: none first, then subsets of its ready skills', () async {
      final battle = BattleData();
      final team = swapTeam();
      await battle.init(quest, team.svts, team.mysticCodeData);
      const swap = (onField: 0, backup: 0);
      final ready = [
        for (final (index, info) in battle.backupAllyServants[0]!.skillInfoList.indexed)
          if (info.skill != null && info.chargeTurn == 0) index,
      ];
      expect(ready, isNotEmpty);

      expect(TeamGeneratorSolver.incomingHeldSets(battle, null, 2), [<int>{}], reason: 'no swap, nothing to hold');
      expect(TeamGeneratorSolver.incomingHeldSets(battle, swap, 0), [<int>{}]);

      final sets = TeamGeneratorSolver.incomingHeldSets(battle, swap, 2);
      expect(sets.first, isEmpty);
      final n = ready.length;
      expect(sets.length, 1 + n + n * (n - 1) ~/ 2);
      for (final set in sets) {
        expect(set.length, lessThanOrEqualTo(2));
        expect(ready.toSet().containsAll(set), isTrue);
      }
      for (int i = 1; i < sets.length; i++) {
        expect(sets[i - 1].length <= sets[i].length, isTrue, reason: 'smallest sets first');
      }
    });

    test('swaps the backup attacker in, replays and exports x<front><sub>', () async {
      final result = await TeamGeneratorSolver(
        quest: quest,
        formation: swapTeam(),
        settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 3, timeLimitSeconds: 120),
      ).solve();
      expect(result.success, isTrue, reason: result.message);
      final first = result.turns.first;
      expect(first.orderChange, isNotNull);
      expect(first.orderChange!.backup, 0);
      expect(first.npSlots, contains(first.orderChange!.onField), reason: 'the incoming Altria fires');
      expect(first.steps.any((step) => step.startsWith('Order Change')), isTrue);

      final command = FgaCommandExporter(result.battle!.recorder.records).export();
      expect(command, contains('x${first.orderChange!.onField + 1}1'));
      expect(result.battle!.replayDataRecord.replaceMemberIndexes, isNotEmpty, reason: 'replay data has the swap');
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
        settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 3, timeLimitSeconds: 0),
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
        settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 3, timeLimitSeconds: 0),
        onPaused: (_, _) => Future.microtask(solver.cancel),
      );
      final result = await solver.solve();
      expect(result.success, isFalse);
      expect(result.message, contains('No plan found within 0s'));
    });
  });

  group('Parallel', () {
    TeamGeneratorSettings csSettings({int workers = 0}) =>
        TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 3, timeLimitSeconds: 120, workers: workers);

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
          settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 0, timeLimitSeconds: 120, workers: 2),
        ).solve();
        expect(result.success, isFalse);
        expect(result.message, contains('No plan clears'));
      } finally {
        await TeamGeneratorWorkerPool.disposeCurrent();
      }
    });
  });

  group('Targets and unused skills', () {
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
      final skill = db.gameData.servantsById[kAltria]!.skills.firstWhere(
        (skill) => !skill.functions.any(singleAlly),
      );
      expect(TeamGeneratorSolver.mayTargetAnyAlly(skill), isFalse);
    });

    test('the default plan (every skill used) is still found first when it works', () async {
      final result = await TeamGeneratorSolver(
        quest: quest,
        formation: altriaTeam(),
        settings: TeamGeneratorSettings(maxTurns: waves, maxCommandSpells: 3, timeLimitSeconds: 60, workers: 0),
      ).solve();
      expect(result.success, isTrue, reason: result.message);
      expect(result.turns.first.steps.any((step) => step.startsWith('Not used')), isFalse);
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

    test('NP charge and single-target skills stay a search choice', () {
      final charge = findSkill(
        (skill) =>
            skill.functions.any((f) => f.funcType == FuncType.gainNp && f.funcTargetType == FuncTargetType.ptAll),
      );
      expect(charge, isNotNull);
      expect(TeamGeneratorSolver.skillUse(charge!), TgSkillUse.choose);

      final single = findSkill(
        (skill) => skill.functions.every(
          (f) =>
              f.funcTargetType == FuncTargetType.ptOne &&
              f.buffs.isNotEmpty &&
              f.buffs.every((b) => b.type == BuffType.upAtk) &&
              f.svals.firstOrNull?.Turn == 3,
        ),
      );
      expect(single, isNotNull);
      expect(TeamGeneratorSolver.skillUse(single!), TgSkillUse.choose);
    });

    test('enemy debuffs stay a search choice (wasted on the next wave if used early)', () {
      final debuff = findSkill(
        (skill) => skill.functions.every(
          (f) =>
              f.funcTargetType == FuncTargetType.enemyAll &&
              f.buffs.isNotEmpty &&
              f.buffs.every((b) => b.type == BuffType.downDefence) &&
              f.svals.firstOrNull?.Turn == 3,
        ),
      );
      expect(debuff, isNotNull);
      expect(TeamGeneratorSolver.skillUse(debuff!), TgSkillUse.choose);
    });

    test('never-used skills are left out of the turn', () async {
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
