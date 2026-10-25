import 'dart:async';
import 'dart:math';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

/// User settings for the Team Generator solver.
class TeamGeneratorSettings {
  int maxTurns;
  int maxCommandSpells;
  int timeLimitSeconds;

  /// How many usable skills may be saved for later turns in one turn (search width).
  int maxHeldSkills;

  TeamGeneratorSettings({
    this.maxTurns = 3,
    this.maxCommandSpells = 0,
    this.timeLimitSeconds = 60,
    this.maxHeldSkills = 2,
  });
}

/// A servant skill (slot 0-2, skill 0-2) or a mystic code skill (slot == null).
class TgSkillRef {
  final int? slot;
  final int skillIndex;
  final bool needsAllyTarget;
  final String name;

  const TgSkillRef({required this.slot, required this.skillIndex, required this.needsAllyTarget, required this.name});

  bool get isMysticCode => slot == null;
}

/// What the solver did in one turn.
class TgTurnPlan {
  final int wave;
  final List<(TgSkillRef skill, int? target)> skills;
  final List<int> commandSpellTargets;
  final List<int> npSlots;

  const TgTurnPlan({
    required this.wave,
    required this.skills,
    required this.commandSpellTargets,
    required this.npSlots,
  });
}

class TeamGeneratorResult {
  final bool success;
  final String message;
  final List<TgTurnPlan> turns;

  /// Final battle state of a successful plan (records for replay/FGA export).
  final BattleData? battle;
  final int simulations;
  final int elapsedMilliseconds;

  const TeamGeneratorResult({
    required this.success,
    required this.message,
    this.turns = const [],
    this.battle,
    required this.simulations,
    required this.elapsedMilliseconds,
  });

  int get commandSpellsUsed => turns.fold(0, (sum, turn) => sum + turn.commandSpellTargets.length);
}

/// Finds a skill / Command Spell / NP sequence that clears [quest] with a fixed team.
///
/// Worst case only: minimum damage roll and only 100% effects (the battle defaults),
/// no critical hits and no face cards, so a found plan clears every time in the simulator.
/// Depth-first search turn by turn; a turn either clears its wave or, when turns are to spare,
/// may be a charge turn. Each branch is simulated with the real battle engine and rewound with
/// battle snapshots.
///
/// Version 1 limits: Order Change skills are not used, ST NPs hit the default target, and
/// skills with options use the engine's default (no choice).
class TeamGeneratorSolver {
  final QuestPhase quest;
  final BattleTeamSetup formation;
  final TeamGeneratorSettings settings;
  final void Function(int simulations, int elapsedMilliseconds)? onProgress;

  TeamGeneratorSolver({required this.quest, required this.formation, required this.settings, this.onProgress});

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  final Stopwatch _watch = Stopwatch();
  int simulations = 0;
  late final int _totalWaves = Maths.max(quest.stages.map((e) => e.wave), 1);

  bool get _timedOut => _watch.elapsed.inSeconds >= settings.timeLimitSeconds;

  Future<TeamGeneratorResult> solve() async {
    _watch
      ..reset()
      ..start();
    simulations = 0;
    final team = formation.copy();
    if (team.svts.take(3).every((svt) => svt.svt == null)) {
      return _result(false, 'No servant in the front line.');
    }
    final battle = BattleData();
    battle.options
      ..random = ConstData.constants.attackRateRandomMin
      ..threshold = 1000
      ..manualAllySkillTarget = false;
    await battle.init(quest, team.svts, team.mysticCodeData);

    final plans = <TgTurnPlan>[];
    final found = await _search(battle, plans, 0);
    _watch.stop();
    if (found) {
      return _result(true, 'Cleared in ${plans.length} turn(s).', turns: plans, battle: battle);
    }
    if (_cancelled) return _result(false, 'Cancelled.');
    if (_timedOut) return _result(false, 'No plan found within ${settings.timeLimitSeconds}s.');
    return _result(false, 'No plan clears the quest within ${settings.maxTurns} turn(s).');
  }

  TeamGeneratorResult _result(bool success, String message, {List<TgTurnPlan> turns = const [], BattleData? battle}) {
    return TeamGeneratorResult(
      success: success,
      message: message,
      turns: turns,
      battle: battle,
      simulations: simulations,
      elapsedMilliseconds: _watch.elapsedMilliseconds,
    );
  }

  Future<bool> _search(BattleData battle, List<TgTurnPlan> plans, int csUsed) async {
    if (battle.isBattleWin) return true;
    if (battle.nonnullPlayers.isEmpty || _cancelled || _timedOut) return false;

    final remainingTurns = settings.maxTurns - plans.length;
    final remainingWaves = _totalWaves - battle.waveCount + 1;
    if (remainingTurns <= 0 || remainingWaves > remainingTurns) return false;
    final mustClear = remainingWaves == remainingTurns;

    final skills = availableSkills(battle);
    for (final fire in _fireSets(battle, mustClear)) {
      for (final held in _heldSets(skills, fire)) {
        final waveBefore = battle.waveCount;
        final depth = battle.snapshots.length;
        battle.pushSnapshot();
        TgTurnPlan? plan;
        try {
          plan = await _applyTurn(battle, skills, held, fire, settings.maxCommandSpells - csUsed);
        } catch (e) {
          plan = null; // engine refused an action, treat as a dead branch
        }
        simulations++;
        if (plan != null) {
          final cleared = battle.isBattleWin || battle.waveCount > waveBefore;
          if (!mustClear || cleared) {
            plans.add(plan);
            if (await _search(battle, plans, csUsed + plan.commandSpellTargets.length)) return true;
            plans.removeLast();
          }
        }
        _restore(battle, depth);
        if (simulations % 8 == 0) {
          battle.battleLogger.logs.clear();
          onProgress?.call(simulations, _watch.elapsedMilliseconds);
          await Future.delayed(Duration.zero); // keep the UI responsive
        }
        if (_cancelled || _timedOut) return false;
      }
    }
    return false;
  }

  void _restore(BattleData battle, int depth) {
    while (battle.snapshots.length > depth) {
      battle.popSnapshot();
    }
  }

  /// Ready-to-use skills of the current turn, front line first, then mystic code.
  static List<TgSkillRef> availableSkills(BattleData battle) {
    final skills = <TgSkillRef>[];
    for (int slot = 0; slot < 3; slot++) {
      final svt = battle.onFieldAllyServants.getOrNull(slot);
      if (svt == null) continue;
      for (int index = 0; index < svt.skillInfoList.length; index++) {
        final info = svt.skillInfoList[index];
        final skill = info.skill;
        if (skill == null || info.chargeTurn > 0) continue;
        if (!battle.canUseSvtSkillIgnoreCoolDown(slot, index)) continue;
        skills.add(
          TgSkillRef(
            slot: slot,
            skillIndex: index,
            needsAllyTarget: _needsAllyTarget(skill),
            name: '${svt.lBattleName} S${index + 1}',
          ),
        );
      }
    }
    for (int index = 0; index < battle.masterSkillInfo.length; index++) {
      final info = battle.masterSkillInfo[index];
      final skill = info.skill;
      if (skill == null || info.chargeTurn > 0) continue;
      if (skill.functions.any((func) => func.funcType == FuncType.replaceMember)) continue; // v1: no order change
      if (!battle.canUseMysticCodeSkillIgnoreCoolDown(index)) continue;
      skills.add(
        TgSkillRef(slot: null, skillIndex: index, needsAllyTarget: _needsAllyTarget(skill), name: 'MC S${index + 1}'),
      );
    }
    return skills;
  }

  static bool _needsAllyTarget(BaseSkill skill) {
    return skill.functions.any(
      (func) => func.funcTargetTeam != FuncApplyTarget.enemy && func.funcTargetType.needNormalOneTarget,
    );
  }

  static bool _isDamageNp(BattleServantData svt) {
    final td = svt.getCurrentNP();
    return td != null && td.damageType != TdEffectFlag.support;
  }

  /// Which servants fire their NP this turn. Smallest sets first; a clearing turn needs a damage NP.
  Iterable<List<int>> _fireSets(BattleData battle, bool mustClear) sync* {
    final npSlots = <int>[
      for (int slot = 0; slot < 3; slot++)
        if (battle.onFieldAllyServants.getOrNull(slot)?.getNPCard() != null) slot,
    ];
    final subsets = <List<int>>[];
    for (int mask = 1; mask < (1 << npSlots.length); mask++) {
      subsets.add([
        for (int i = 0; i < npSlots.length; i++)
          if (mask & (1 << i) != 0) npSlots[i],
      ]);
    }
    subsets.sort((a, b) => a.length - b.length);
    for (final subset in subsets) {
      final hasDamage = subset.any((slot) => _isDamageNp(battle.onFieldAllyServants[slot]!));
      if (mustClear && !hasDamage) continue;
      yield subset;
    }
    if (!mustClear) yield const []; // charge turn: skills only, then skip
  }

  /// Sets of skill indices to save for later, smallest first; skills of servants that don't fire are held first.
  Iterable<Set<int>> _heldSets(List<TgSkillRef> skills, List<int> fire) sync* {
    yield const {};
    final maxHeld = min(settings.maxHeldSkills, skills.length);
    for (int size = 1; size <= maxHeld; size++) {
      final combos = <List<int>>[];
      void build(int start, List<int> current) {
        if (current.length == size) {
          combos.add(current.toList());
          return;
        }
        for (int i = start; i < skills.length; i++) {
          current.add(i);
          build(i + 1, current);
          current.removeLast();
        }
      }

      build(0, []);
      int firingOwners(List<int> combo) => combo.where((i) => fire.contains(skills[i].slot)).length;
      combos.sort((a, b) => firingOwners(a) - firingOwners(b));
      for (final combo in combos) {
        yield combo.toSet();
      }
    }
  }

  Future<TgTurnPlan?> _applyTurn(
    BattleData battle,
    List<TgSkillRef> skills,
    Set<int> held,
    List<int> fire,
    int commandSpellsLeft,
  ) async {
    final wave = battle.waveCount;
    final damageSlots = fire.where((slot) => _isDamageNp(battle.onFieldAllyServants[slot]!)).toList();
    final primary = damageSlots.firstOrNull ?? fire.firstOrNull ?? 0;

    // supports' skills first, then mystic code, then the servants who fire
    final order = <int>[
      for (final (i, s) in skills.indexed)
        if (!s.isMysticCode && !fire.contains(s.slot)) i,
      for (final (i, s) in skills.indexed)
        if (s.isMysticCode) i,
      for (final (i, s) in skills.indexed)
        if (!s.isMysticCode && fire.contains(s.slot)) i,
    ];
    final used = <(TgSkillRef, int?)>[];
    for (final i in order) {
      if (held.contains(i)) continue;
      final skill = skills[i];
      int? target;
      if (skill.needsAllyTarget) {
        target = primary;
        battle.playerTargetIndex = primary;
      }
      if (skill.isMysticCode) {
        await battle.activateMysticCodeSkill(skill.skillIndex);
      } else {
        if (battle.onFieldAllyServants.getOrNull(skill.slot!) == null) continue;
        await battle.activateSvtSkill(skill.slot!, skill.skillIndex);
      }
      used.add((skill, target));
    }

    final commandSpells = <int>[];
    for (final slot in fire) {
      final svt = battle.onFieldAllyServants.getOrNull(slot);
      if (svt == null) return null;
      if (!svt.canNP()) {
        if (commandSpells.length >= commandSpellsLeft || svt.isNpFull()) return null;
        battle.playerTargetIndex = slot;
        await battle.commandSpellReleaseNP();
        commandSpells.add(slot);
        if (!svt.canNP()) return null;
      }
    }

    if (fire.isEmpty) {
      await battle.skipTurn();
    } else {
      final npOrder = [
        ...fire.where((slot) => !damageSlots.contains(slot)), // buff NPs before damage NPs
        ...damageSlots,
      ];
      await battle.playerTurn([
        for (final slot in npOrder)
          CombatAction(battle.onFieldAllyServants[slot]!, battle.onFieldAllyServants[slot]!.getNPCard()!),
      ]);
    }
    return TgTurnPlan(wave: wave, skills: used, commandSpellTargets: commandSpells, npSlots: fire);
  }

  /// Battle Simulation share data: team, quest and the recorded actions, for replay.
  static BattleShareData toShareData(QuestPhase quest, BattleTeamSetup formation, BattleData battle) {
    return BattleShareData(
      quest: BattleQuestInfo.quest(quest),
      formation: formation.toFormationData(),
      delegate: battle.replayDataRecord.copy(),
      actions: [
        for (final record in battle.recorder.records)
          if (record.toUploadRecord() != null) record.toUploadRecord()!,
      ],
    );
  }
}
