import 'dart:async';
import 'dart:math';

import 'package:tuple/tuple.dart';

import 'package:chaldea/app/battle/interactions/_delegate.dart';
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

/// Order Change: front-line slot (0-2) swapped with backup index (0-2).
typedef TgOrderChange = ({int onField, int backup});

/// What the solver did in one turn.
class TgTurnPlan {
  final int wave;
  final List<(TgSkillRef skill, int? target)> skills;
  final TgOrderChange? orderChange;
  final List<int> commandSpellTargets;
  final List<int> npSlots;

  /// Human readable steps in order, with servant names at the time of the action.
  final List<String> steps;

  const TgTurnPlan({
    required this.wave,
    required this.skills,
    required this.orderChange,
    required this.commandSpellTargets,
    required this.npSlots,
    required this.steps,
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

/// Finds a skill / Order Change / Command Spell / NP sequence that clears [quest] with a fixed team.
///
/// Worst case only: minimum damage roll and only 100% effects (the battle defaults),
/// no critical hits and no face cards, so a found plan clears every time in the simulator.
/// Depth-first search turn by turn; a turn either clears its wave or, when turns are to spare,
/// may be a charge turn. Each branch is simulated with the real battle engine and rewound with
/// battle snapshots.
///
/// Within a turn: skills of servants that don't fire (and of the servant about to be swapped out),
/// other mystic code skills, Order Change, the incoming servant's skills, then the firing servants' skills.
///
/// Limits: ST NPs hit the default target, and skills with options use the engine's default (no choice).
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

  /// Swap the battle engine performs on the next Order Change.
  TgOrderChange? _pendingSwap;

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
    battle.delegate = BattleDelegate()
      ..replaceMember = (onField, backup) async {
        final swap = _pendingSwap;
        if (swap == null) return null;
        final out = onField.getOrNull(swap.onField);
        final incoming = backup.getOrNull(swap.backup);
        if (out == null || incoming == null) return null;
        return Tuple2(out, incoming);
      };
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
    final swaps = orderChangeOptions(battle);
    for (final fire in _fireSets(battle, mustClear, swaps.length > 1)) {
      for (final held in _heldSets(skills, fire)) {
        for (final swap in swaps) {
          final waveBefore = battle.waveCount;
          final depth = battle.snapshots.length;
          battle.pushSnapshot();
          TgTurnPlan? plan;
          try {
            plan = await _applyTurn(battle, skills, held, swap, fire, settings.maxCommandSpells - csUsed);
          } catch (e) {
            plan = null; // engine refused an action, treat as a dead branch
          }
          _pendingSwap = null;
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
    }
    return false;
  }

  void _restore(BattleData battle, int depth) {
    while (battle.snapshots.length > depth) {
      battle.popSnapshot();
    }
  }

  static bool _isOrderChange(BaseSkill skill) =>
      skill.functions.any((func) => func.funcType == FuncType.replaceMember);

  /// Ready-to-use skills of the current turn, front line first, then mystic code (Order Change excluded).
  static List<TgSkillRef> availableSkills(BattleData battle, {Iterable<int> slots = const [0, 1, 2]}) {
    final skills = <TgSkillRef>[];
    for (final slot in slots) {
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
    if (slots.length < 3) return skills; // only a servant's own skills requested
    for (int index = 0; index < battle.masterSkillInfo.length; index++) {
      final info = battle.masterSkillInfo[index];
      final skill = info.skill;
      if (skill == null || info.chargeTurn > 0 || _isOrderChange(skill)) continue;
      if (!battle.canUseMysticCodeSkillIgnoreCoolDown(index)) continue;
      skills.add(
        TgSkillRef(slot: null, skillIndex: index, needsAllyTarget: _needsAllyTarget(skill), name: 'MC S${index + 1}'),
      );
    }
    return skills;
  }

  /// Index of a ready Order Change mystic code skill, if any.
  static int? orderChangeSkillIndex(BattleData battle) {
    for (int index = 0; index < battle.masterSkillInfo.length; index++) {
      final info = battle.masterSkillInfo[index];
      final skill = info.skill;
      if (skill == null || info.chargeTurn > 0 || !_isOrderChange(skill)) continue;
      if (battle.canUseMysticCodeSkillIgnoreCoolDown(index)) return index;
    }
    return null;
  }

  /// null (no swap) first, then every possible front-line/backup pair.
  static List<TgOrderChange?> orderChangeOptions(BattleData battle) {
    final options = <TgOrderChange?>[null];
    if (orderChangeSkillIndex(battle) == null) return options;
    for (int onField = 0; onField < 3; onField++) {
      final out = battle.onFieldAllyServants.getOrNull(onField);
      if (out == null || !out.canOrderChange()) continue;
      for (int backup = 0; backup < battle.backupAllyServants.length; backup++) {
        final incoming = battle.backupAllyServants[backup];
        if (incoming == null || !incoming.canOrderChange()) continue;
        options.add((onField: onField, backup: backup));
      }
    }
    return options;
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

  /// Which front-line slots fire their NP this turn (whoever is in the slot at NP time).
  /// Smallest sets first; a clearing turn needs a damage NP unless an Order Change may bring one in.
  Iterable<List<int>> _fireSets(BattleData battle, bool mustClear, bool canSwap) sync* {
    final slots = <int>[
      for (int slot = 0; slot < 3; slot++)
        if (battle.onFieldAllyServants.getOrNull(slot) != null) slot,
    ];
    final subsets = <List<int>>[];
    for (int mask = 1; mask < (1 << slots.length); mask++) {
      subsets.add([
        for (int i = 0; i < slots.length; i++)
          if (mask & (1 << i) != 0) slots[i],
      ]);
    }
    subsets.sort((a, b) => a.length - b.length);
    for (final subset in subsets) {
      final hasDamage = subset.any((slot) {
        final svt = battle.onFieldAllyServants[slot]!;
        return svt.getNPCard() != null && _isDamageNp(svt);
      });
      if (mustClear && !hasDamage && !canSwap) continue;
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
    TgOrderChange? swap,
    List<int> fire,
    int commandSpellsLeft,
  ) async {
    final wave = battle.waveCount;
    final steps = <String>[];
    String nameOf(int slot) => battle.onFieldAllyServants.getOrNull(slot)?.lBattleName ?? 'Slot ${slot + 1}';

    // main attacker: first firing slot whose occupant has a damage NP (the incoming servant if swapped in)
    int primaryAfterSwap() {
      for (final slot in fire) {
        final svt = battle.onFieldAllyServants.getOrNull(slot);
        if (svt != null && _isDamageNp(svt)) return slot;
      }
      return fire.firstOrNull ?? 0;
    }

    final used = <(TgSkillRef, int?)>[];
    Future<void> useSkill(TgSkillRef skill) async {
      int? target;
      if (skill.needsAllyTarget) {
        target = primaryAfterSwap();
        battle.playerTargetIndex = target;
      }
      if (skill.isMysticCode) {
        await battle.activateMysticCodeSkill(skill.skillIndex);
      } else {
        if (battle.onFieldAllyServants.getOrNull(skill.slot!) == null) return;
        await battle.activateSvtSkill(skill.slot!, skill.skillIndex);
      }
      used.add((skill, target));
      steps.add('${skill.isMysticCode ? skill.name : '${nameOf(skill.slot!)} S${skill.skillIndex + 1}'}'
          '${target == null ? '' : ' → ${nameOf(target)}'}');
    }

    final swapOut = swap?.onField;
    bool before(TgSkillRef s) => !s.isMysticCode && (!fire.contains(s.slot) || s.slot == swapOut);
    // 1. supports and the servant leaving, 2. mystic code
    for (final (i, skill) in skills.indexed) {
      if (!held.contains(i) && before(skill)) await useSkill(skill);
    }
    for (final (i, skill) in skills.indexed) {
      if (!held.contains(i) && skill.isMysticCode) await useSkill(skill);
    }
    // 3. Order Change and the incoming servant's skills
    if (swap != null) {
      final ocIndex = orderChangeSkillIndex(battle);
      if (ocIndex == null) return null;
      final outName = nameOf(swap.onField);
      final inName = battle.backupAllyServants.getOrNull(swap.backup)?.lBattleName;
      _pendingSwap = swap;
      await battle.activateMysticCodeSkill(ocIndex);
      _pendingSwap = null;
      if (inName == null || battle.onFieldAllyServants.getOrNull(swap.onField)?.lBattleName != inName) {
        return null; // swap did not happen
      }
      steps.add('Order Change: $outName ⇄ $inName');
      for (final skill in availableSkills(battle, slots: [swap.onField])) {
        await useSkill(skill);
      }
    }
    // 4. the servants who fire
    for (final (i, skill) in skills.indexed) {
      if (!held.contains(i) && !skill.isMysticCode && !before(skill)) await useSkill(skill);
    }

    final commandSpells = <int>[];
    for (final slot in fire) {
      final svt = battle.onFieldAllyServants.getOrNull(slot);
      if (svt == null || svt.getNPCard() == null) return null;
      if (!svt.canNP()) {
        if (commandSpells.length >= commandSpellsLeft || svt.isNpFull()) return null;
        battle.playerTargetIndex = slot;
        await battle.commandSpellReleaseNP();
        commandSpells.add(slot);
        steps.add('Command Spell → ${nameOf(slot)}');
        if (!svt.canNP()) return null;
      }
    }

    if (fire.isEmpty) {
      await battle.skipTurn();
      steps.add('No NP (charge turn)');
    } else {
      final damageSlots = fire.where((slot) => _isDamageNp(battle.onFieldAllyServants[slot]!)).toList();
      final npOrder = [
        ...fire.where((slot) => !damageSlots.contains(slot)), // buff NPs before damage NPs
        ...damageSlots,
      ];
      steps.add('NP: ${npOrder.map(nameOf).join(', ')}');
      await battle.playerTurn([
        for (final slot in npOrder)
          CombatAction(battle.onFieldAllyServants[slot]!, battle.onFieldAllyServants[slot]!.getNPCard()!),
      ]);
    }
    return TgTurnPlan(
      wave: wave,
      skills: used,
      orderChange: swap,
      commandSpellTargets: commandSpells,
      npSlots: fire,
      steps: steps,
    );
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
