import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'package:tuple/tuple.dart';

import 'package:chaldea/app/battle/interactions/_delegate.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import '../simulation/fga_export.dart';

/// User settings for the Team Generator solver.
class TeamGeneratorSettings {
  int maxTurns;
  int maxCommandSpells;
  int timeLimitSeconds;

  /// No longer limits the search (any number of skills may stay unused); kept for compatibility.
  int maxHeldSkills;

  /// Background worker isolates; 0 = search on the UI thread.
  int workers;

  TeamGeneratorSettings({
    this.maxTurns = 3,
    this.maxCommandSpells = 0,
    this.timeLimitSeconds = 60,
    this.maxHeldSkills = 2,
    int? workers,
  }) : workers = workers ?? defaultWorkers;

  /// CPU cores - 1, at least 1 and at most 4 (each worker holds its own copy of the game data). 0 on web.
  static int get defaultWorkers => kIsWeb ? 0 : max(1, min(4, Platform.numberOfProcessors - 1));

  TeamGeneratorSettings copy() => TeamGeneratorSettings(
    maxTurns: maxTurns,
    maxCommandSpells: maxCommandSpells,
    timeLimitSeconds: timeLimitSeconds,
    maxHeldSkills: maxHeldSkills,
    workers: workers,
  );
}

/// A running search, on the UI thread ([TeamGeneratorSolver]) or in workers (parallel run).
abstract class TeamGeneratorRun {
  Future<TeamGeneratorResult> solve();
  void cancel();

  /// Give a paused search more time; it continues from where it stopped.
  void addTime(int seconds);
  bool get isPaused;
  int get timeLimitSeconds;
}

/// A servant skill (slot 0-2, skill 0-2) or a mystic code skill (slot == null).
class TgSkillRef {
  final int? slot;
  final int skillIndex;
  final bool needsAllyTarget;

  /// Single-ally skill that may target anyone (NP charge or a buff lasting more than 1 turn).
  /// Otherwise it only goes to this turn's main attacker.
  final bool anyAllyTarget;

  /// Party/self buffs lasting 3+ turns without NP charge: used as soon as ready, never saved.
  final bool alwaysUse;
  final String name;

  const TgSkillRef({
    required this.slot,
    required this.skillIndex,
    required this.needsAllyTarget,
    this.anyAllyTarget = false,
    this.alwaysUse = false,
    required this.name,
  });

  bool get isMysticCode => slot == null;
}

/// Order Change: front-line slot (0-2) swapped with backup index (0-2).
typedef TgOrderChange = ({int onField, int backup});

/// How the solver treats a skill, see [TeamGeneratorSolver.skillUse].
enum TgSkillUse { never, always, choose }

/// One way to play a turn. The default is "use every ready skill, single-ally skills on this turn's
/// main attacker"; [cost] counts the departures from it (each unused skill or other target = 1).
class _TurnChoice {
  final List<int> fire;
  final TgOrderChange? swap;

  /// Indices into the turn's skill list (front line + mystic code) left unused.
  final Set<int> held;

  /// Skill indices (0-2) the incoming servant leaves unused.
  final Set<int> incomingHeld;

  /// Non-default targets by skill key ('f<index>' front/mystic code, 'i<skillIndex>' incoming servant).
  final Map<String, int> targets;
  final int cost;

  const _TurnChoice({
    required this.fire,
    required this.swap,
    required this.held,
    required this.incomingHeld,
    required this.targets,
    required this.cost,
  });
}

/// A per-skill decision with its non-default options.
class _Decision {
  final String key;

  /// null = leave the skill unused, otherwise target this slot.
  final List<int?> alternatives;
  const _Decision(this.key, this.alternatives);
}

/// What the solver did in one turn.
class TgTurnPlan {
  final int wave;
  final List<(TgSkillRef skill, int? target)> skills;
  final TgOrderChange? orderChange;

  /// Skill indices (0-2) the incoming servant saved for later turns.
  final Set<int> incomingHeld;
  final List<int> commandSpellTargets;
  final List<int> npSlots;

  /// Human readable steps in order, with servant names at the time of the action.
  final List<String> steps;

  const TgTurnPlan({
    required this.wave,
    required this.skills,
    required this.orderChange,
    this.incomingHeld = const {},
    required this.commandSpellTargets,
    required this.npSlots,
    required this.steps,
  });
}

class TeamGeneratorResult {
  final bool success;
  final String message;
  final List<TgTurnPlan> turns;

  /// Final battle state of a successful plan, only when solved on this isolate (null from workers).
  final BattleData? battle;

  /// FGA command and Battle Simulation replay data of a successful plan.
  final String fgaCommand;
  final BattleShareData? shareData;
  final int simulations;
  final int elapsedMilliseconds;

  const TeamGeneratorResult({
    required this.success,
    required this.message,
    this.turns = const [],
    this.battle,
    this.fgaCommand = '',
    this.shareData,
    required this.simulations,
    required this.elapsedMilliseconds,
  });

  TeamGeneratorResult copyWith({String? message, int? simulations, int? elapsedMilliseconds}) => TeamGeneratorResult(
    success: success,
    message: message ?? this.message,
    turns: turns,
    battle: battle,
    fgaCommand: fgaCommand,
    shareData: shareData,
    simulations: simulations ?? this.simulations,
    elapsedMilliseconds: elapsedMilliseconds ?? this.elapsedMilliseconds,
  );

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
/// Each turn starts from "use every ready skill, single-ally skills on this turn's main attacker" and may
/// depart from it: any skill may stay unused, and single-ally skills that charge NP or give buffs lasting
/// more than 1 turn may target any front-line servant (1-turn buffs always go to the main attacker).
/// Plans with fewer departures in total are tried first (iterative deepening).
///
/// Limits: ST NPs hit the default target, and skills with options use the engine's default (no choice).
class TeamGeneratorSolver implements TeamGeneratorRun {
  final QuestPhase quest;
  final BattleTeamSetup formation;
  final TeamGeneratorSettings settings;
  final void Function(int simulations, int elapsedMilliseconds)? onProgress;

  /// Called when the time limit is reached; the search waits (state kept) until [addTime] or [cancel].
  final void Function(int simulations, int elapsedMilliseconds)? onPaused;

  TeamGeneratorSolver({
    required this.quest,
    required this.formation,
    required this.settings,
    this.onProgress,
    this.onPaused,
    this.partitionIndex = 0,
    this.partitionCount = 1,
  }) : _timeLimitSeconds = settings.timeLimitSeconds;

  /// Parallel runs: this solver only explores first-turn options where `option % partitionCount == partitionIndex`.
  final int partitionIndex;
  final int partitionCount;

  bool _cancelled = false;
  @override
  void cancel() {
    _cancelled = true;
    final pause = _pause;
    if (pause != null && !pause.isCompleted) pause.complete(false);
  }

  /// Current time limit; grows with [addTime].
  int _timeLimitSeconds;
  @override
  int get timeLimitSeconds => _timeLimitSeconds;
  bool _reachedTimeLimit = false;
  Completer<bool>? _pause;
  @override
  bool get isPaused => _pause != null;

  @override
  void addTime(int seconds) {
    _timeLimitSeconds += seconds;
    resume();
  }

  /// Pause from outside (parallel runs keep one clock for all workers). Takes effect at the next check.
  void pause() {
    _pause ??= Completer<bool>();
  }

  void resume() {
    final pause = _pause;
    if (pause != null && !pause.isCompleted) pause.complete(true);
  }

  /// At the time limit or when paused from outside, wait. Returns false if the search should stop.
  Future<bool> _continueAfterTimeLimit() async {
    if (_cancelled) return false;
    if (_pause == null && _watch.elapsed.inSeconds >= _timeLimitSeconds) {
      _reachedTimeLimit = true;
      _pause = Completer<bool>();
      onPaused?.call(simulations, _watch.elapsedMilliseconds);
    }
    final pause = _pause;
    if (pause == null) return true;
    _watch.stop();
    final resume = await pause.future;
    _pause = null;
    if (!resume || _cancelled) return false;
    _watch.start();
    return _continueAfterTimeLimit();
  }

  final Stopwatch _watch = Stopwatch();
  int simulations = 0;
  late final int _totalWaves = Maths.max(quest.stages.map((e) => e.wave), 1);

  /// Swap the battle engine performs on the next Order Change.
  TgOrderChange? _pendingSwap;


  @override
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
    bool found = false;
    // Plans closest to the default first: every turn may depart from it, the total is capped by
    // [budget], which grows until a plan is found or no plan has more departures to try.
    for (int budget = 0; ; budget++) {
      _budgetLimited = false;
      found = await _search(battle, plans, 0, budget);
      if (found || _cancelled || !_budgetLimited) break;
    }
    _watch.stop();
    if (found) {
      return TeamGeneratorResult(
        success: true,
        message: 'Cleared in ${plans.length} turn(s).',
        turns: plans,
        battle: battle,
        fgaCommand: FgaCommandExporter(battle.recorder.records).export(),
        shareData: toShareData(quest, team, battle),
        simulations: simulations,
        elapsedMilliseconds: _watch.elapsedMilliseconds,
      );
    }
    if (_reachedTimeLimit && _cancelled) return _result(false, 'No plan found within ${_timeLimitSeconds}s.');
    if (_cancelled) return _result(false, 'Cancelled.');
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

  /// Set when some turn had more departures available than the budget allowed.
  bool _budgetLimited = false;

  Future<bool> _search(BattleData battle, List<TgTurnPlan> plans, int csUsed, int budget) async {
    if (battle.isBattleWin) return true;
    if (battle.nonnullPlayers.isEmpty || !await _continueAfterTimeLimit()) return false;

    final remainingTurns = settings.maxTurns - plans.length;
    final remainingWaves = _totalWaves - battle.waveCount + 1;
    if (remainingTurns <= 0 || remainingWaves > remainingTurns) return false;
    final mustClear = remainingWaves == remainingTurns;

    final skills = availableSkills(battle);
    final swaps = orderChangeOptions(battle);
    final fireSets = _fireSets(battle, mustClear, swaps.length > 1).toList();
    final decisions = {
      for (final fire in fireSets)
        for (final swap in swaps) (fire, swap): _decisions(battle, skills, fire, swap),
    };
    final firstTurn = plans.isEmpty;
    int option = 0;
    for (int cost = 0; cost <= budget; cost++) {
      for (final fire in fireSets) {
        for (final swap in swaps) {
          final turnDecisions = decisions[(fire, swap)]!;
          if (cost == budget && turnDecisions.length > budget) _budgetLimited = true;
          for (final picked in _combinations(turnDecisions, cost)) {
            if (firstTurn && (option++ % partitionCount) != partitionIndex) continue;
            final choice = _choice(fire, swap, picked, cost);
            final waveBefore = battle.waveCount;
            final depth = battle.snapshots.length;
            battle.pushSnapshot();
            TgTurnPlan? plan;
            try {
              plan = await _applyTurn(battle, skills, choice, settings.maxCommandSpells - csUsed);
            } catch (e) {
              plan = null; // engine refused an action, treat as a dead branch
            }
            _pendingSwap = null;
            simulations++;
            if (plan != null) {
              final cleared = battle.isBattleWin || battle.waveCount > waveBefore;
              if (!mustClear || cleared) {
                plans.add(plan);
                if (await _search(battle, plans, csUsed + plan.commandSpellTargets.length, budget - cost)) {
                  return true;
                }
                plans.removeLast();
              }
            }
            _restore(battle, depth);
            if (simulations % 8 == 0) {
              battle.battleLogger.logs.clear();
              onProgress?.call(simulations, _watch.elapsedMilliseconds);
              await Future.delayed(Duration.zero); // keep the UI responsive
            }
            if (!await _continueAfterTimeLimit()) return false;
          }
        }
      }
    }
    return false;
  }

  /// Main attacker the turn would target by default: the first firing slot whose occupant at NP time
  /// (the incoming servant if that slot is swapped) has a damage NP.
  static int _defaultTarget(BattleData battle, List<int> fire, TgOrderChange? swap) {
    for (final slot in fire) {
      final occupant = swap != null && slot == swap.onField
          ? battle.backupAllyServants.getOrNull(swap.backup)
          : battle.onFieldAllyServants.getOrNull(slot);
      if (occupant != null && _isDamageNp(occupant)) return slot;
    }
    return fire.firstOrNull ?? 0;
  }

  /// Everything that may depart from the default this turn: leaving a skill unused, or sending a
  /// single-ally skill that may target anyone to another front-line servant.
  static List<_Decision> _decisions(
    BattleData battle,
    List<TgSkillRef> skills,
    List<int> fire,
    TgOrderChange? swap,
  ) {
    final defaultTarget = _defaultTarget(battle, fire, swap);
    final occupied = [
      for (int slot = 0; slot < 3; slot++)
        if (battle.onFieldAllyServants.getOrNull(slot) != null) slot,
    ];
    final swapOut = swap?.onField;
    final decisions = <_Decision>[];
    for (final (index, skill) in skills.indexed) {
      if (skill.alwaysUse) continue; // no choice: used right away
      // used before the swap: the leaving servant's own slot would waste the effect
      final usedBeforeSwap = skill.isMysticCode || !fire.contains(skill.slot) || skill.slot == swapOut;
      decisions.add(
        _Decision('f$index', [
          null,
          if (skill.needsAllyTarget && skill.anyAllyTarget)
            for (final slot in occupied)
              if (slot != defaultTarget && !(usedBeforeSwap && slot == swapOut)) slot,
        ]),
      );
    }
    if (swap != null) {
      final incoming = battle.backupAllyServants.getOrNull(swap.backup);
      for (final (index, info) in (incoming?.skillInfoList ?? <BattleSkillInfoData>[]).indexed) {
        final skill = info.skill;
        if (skill == null || info.chargeTurn > 0) continue;
        if (skillUse(skill) != TgSkillUse.choose) continue; // never used, or always used right away
        final anyTarget = _needsAllyTarget(skill) && _anyAllyTarget(skill);
        decisions.add(
          _Decision('i$index', [
            null,
            if (anyTarget)
              for (final slot in occupied)
                if (slot != defaultTarget) slot,
          ]),
        );
      }
    }
    return decisions;
  }

  /// Every way to pick [count] decisions and one non-default option for each, in a fixed order.
  static Iterable<List<(String, int?)>> _combinations(List<_Decision> decisions, int count) sync* {
    if (count == 0) {
      yield const [];
      return;
    }
    Iterable<List<(String, int?)>> build(int start, int left) sync* {
      if (left == 0) {
        yield const [];
        return;
      }
      for (int i = start; i <= decisions.length - left; i++) {
        for (final alternative in decisions[i].alternatives) {
          for (final rest in build(i + 1, left - 1)) {
            yield [(decisions[i].key, alternative), ...rest];
          }
        }
      }
    }

    yield* build(0, count);
  }

  static _TurnChoice _choice(List<int> fire, TgOrderChange? swap, List<(String, int?)> picked, int cost) {
    final held = <int>{};
    final incomingHeld = <int>{};
    final targets = <String, int>{};
    for (final (key, alternative) in picked) {
      if (alternative != null) {
        targets[key] = alternative;
      } else if (key.startsWith('f')) {
        held.add(int.parse(key.substring(1)));
      } else {
        incomingHeld.add(int.parse(key.substring(1)));
      }
    }
    return _TurnChoice(
      fire: fire,
      swap: swap,
      held: held,
      incomingHeld: incomingHeld,
      targets: targets,
      cost: cost,
    );
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
        final use = skillUse(skill);
        if (use == TgSkillUse.never) continue;
        skills.add(
          TgSkillRef(
            slot: slot,
            skillIndex: index,
            needsAllyTarget: _needsAllyTarget(skill),
            anyAllyTarget: _anyAllyTarget(skill),
            alwaysUse: use == TgSkillUse.always,
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
      final use = skillUse(skill);
      if (use == TgSkillUse.never) continue;
      skills.add(
        TgSkillRef(
          slot: null,
          skillIndex: index,
          needsAllyTarget: _needsAllyTarget(skill),
          anyAllyTarget: _anyAllyTarget(skill),
          alwaysUse: use == TgSkillUse.always,
          name: 'MC S${index + 1}',
        ),
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

  /// Skills the incoming servant may save for later: none first, then every subset up to [maxHeld].
  /// Read from the backup row before the swap (skills off cooldown).
  static List<Set<int>> incomingHeldSets(BattleData battle, TgOrderChange? swap, int maxHeld) {
    if (swap == null) return const [{}];
    final incoming = battle.backupAllyServants.getOrNull(swap.backup);
    if (incoming == null) return const [{}];
    final ready = <int>[
      for (final (index, info) in incoming.skillInfoList.indexed)
        if (info.skill != null && info.chargeTurn == 0) index,
    ];
    final sets = <Set<int>>[{}];
    for (int size = 1; size <= min(maxHeld, ready.length); size++) {
      void build(int start, List<int> current) {
        if (current.length == size) {
          sets.add(current.toSet());
          return;
        }
        for (int i = start; i < ready.length; i++) {
          current.add(ready[i]);
          build(i + 1, current);
          current.removeLast();
        }
      }

      build(0, []);
    }
    return sets;
  }

  static bool _needsAllyTarget(BaseSkill skill) {
    return skill.functions.any(_isSingleAllyFunc);
  }

  static bool _isSingleAllyFunc(NiceFunction func) =>
      func.funcTargetTeam != FuncApplyTarget.enemy && func.funcTargetType.needNormalOneTarget;

  static bool _isNpCharge(NiceFunction func) {
    final name = func.funcType.name;
    return name.startsWith('gainNp') || name == 'gainMultiplyNp';
  }

  /// A single-ally skill may target anyone if it charges NP or gives something other than 1-turn buffs;
  /// a skill whose single-ally effects are all 1-turn buffs only goes to this turn's main attacker.
  static bool _anyAllyTarget(BaseSkill skill) {
    final funcs = skill.functions.where(_isSingleAllyFunc).toList();
    if (funcs.isEmpty) return false;
    if (funcs.any(_isNpCharge)) return true;
    final oneTurnBuffsOnly = funcs.every((func) => func.buffs.isNotEmpty && func.svals.firstOrNull?.Turn == 1);
    return !oneTurnBuffsOnly;
  }

  /// Buffs that change damage dealt by the holder or taken by the target (offense, defense, NP, traits, class).
  static const _damageBuffs = {
    'upCommandatk',
    'downCommandatk',
    'upAtk',
    'downAtk',
    'upDamage',
    'downDamage',
    'addDamage',
    'subDamage',
    'upNpdamage',
    'downNpdamage',
    'upCriticaldamage',
    'downCriticaldamage',
    'upCommandall',
    'downCommandall',
    'upChagetd',
    'upDamageIndividuality',
    'downDamageIndividuality',
    'upDamageIndividualityActiveonly',
    'downDamageIndividualityActiveonly',
    'pierceDefence',
    'pierceInvincible',
    'breakAvoidance',
    'multiattack',
    'overwriteBattleclass',
    'overwriteClassrelatioAtk',
    'overwriteClassrelatioDef',
    'overwriteClassRelation',
    'overwriteSubattribute',
    'addIndividuality',
    'subIndividuality',
    'fieldIndividuality',
    'subFieldIndividuality',
    'toFieldChangeField',
    'toFieldSubIndividualityField',
    'upDamageSpecial',
    'upDamageEventPoint',
    'addSpecialdamage',
    'subSpecialdamage',
    'upNpdamageIndividualitySum',
    'tdTypeChange',
    'tdTypeChangeArts',
    'tdTypeChangeBuster',
    'tdTypeChangeQuick',
    'changeCommandCardType',
    'overwriteSvtCardType',
    'upSpecialdefence',
    'downSpecialdefence',
    'upDefence',
    'downDefence',
    'upDefencecommandall',
    'downDefencecommandall',
    'upDefenceCommanddamage',
    'downDefenceCommanddamage',
    'upDefenceDamage',
    'downDefenceDamage',
    'upDefenceNpdamage',
    'downDefenceNpdamage',
    'upDefenceCriticaldamage',
    'downDefenceCriticaldamage',
    'skillRankUp',
    'buffRate',
    'upBuffUseRate',
    'downBuffUseRate',
    'overwriteBuffUseRate',
    'buffConvert',
    'masterSkillValueUp',
  };

  /// Buffs that charge NP now or later (gauge, NP gain).
  static const _npBuffs = {
    'regainNp',
    'upDropnp',
    'upCommandnp',
    'upDamagedropnp',
    'upFuncgainNp',
    'upGiveNp',
    'regainNpUsedNoble',
  };

  static const _cooldownBuffs = {'shortenSkillAfterUseSkill', 'shortenUserEquipSkill'};

  static bool _chargesNp(NiceFunction func) {
    final name = func.funcType.name;
    return name.startsWith('gainNp') ||
        name == 'gainMultiplyNp' ||
        func.buffs.any((b) => _npBuffs.contains(b.type.name));
  }

  /// Whether a function could matter for clearing: damage, NP charge or cooldown reduction.
  /// Unknown triggers ("...Function" buffs) count, to stay on the safe side.
  static bool _mattersForClear(NiceFunction func) {
    final name = func.funcType.name;
    if (_chargesNp(func)) return true;
    if (name == 'shortenSkill' ||
        name.startsWith('damage') ||
        name == 'instantDeath' ||
        name == 'forceInstantDeath') {
      return true;
    }
    if (name == 'transformServant' || name.startsWith('lossHp')) return true; // NP change, HP-based damage
    if (name == 'subState' && func.funcTargetType.isEnemy) return true; // removes enemy defenses
    final onEnemy = func.funcTargetType.isEnemy || func.funcTargetTeam == FuncApplyTarget.enemy;
    return func.buffs.any((buff) {
      final type = buff.type.name;
      // defense changes only matter on the enemies being hit, not on allies
      if (type.contains('efence') && !onEnemy) return false;
      return _damageBuffs.contains(type) || _cooldownBuffs.contains(type) || type.endsWith('Function');
    });
  }

  /// How the solver treats a skill:
  /// - never: nothing in it changes damage dealt, charges NP or reduces cooldowns (stars, healing, defense...)
  /// - always: buffs on allies only, all lasting 3+ turns, no single target, no NP charge: use when ready
  /// - choose: the search decides (use now, save, target)
  static TgSkillUse skillUse(BaseSkill skill) {
    final funcs = skill.functions;
    if (!funcs.any(_mattersForClear)) return TgSkillUse.never;
    if (funcs.any((f) => f.funcTargetType.needNormalOneTarget || f.funcTargetType == FuncTargetType.enemy)) {
      return TgSkillUse.choose;
    }
    if (funcs.any(_chargesNp)) return TgSkillUse.choose;
    final buffFuncs = funcs.where((f) => f.buffs.isNotEmpty).toList();
    if (buffFuncs.isEmpty) return TgSkillUse.choose;
    final longAllyBuffs = buffFuncs.every((f) {
      if (f.funcTargetType.isEnemy || f.funcTargetTeam == FuncApplyTarget.enemy) return false;
      final vals = f.svals.firstOrNull;
      final turn = vals?.Turn ?? 0;
      return turn >= 3 || (turn == -1 && (vals?.Count ?? -1) == -1);
    });
    return longAllyBuffs ? TgSkillUse.always : TgSkillUse.choose;
  }

  /// Decision summary for tests: whether [skill] may target allies other than this turn's main attacker.
  @visibleForTesting
  static bool mayTargetAnyAlly(BaseSkill skill) => _needsAllyTarget(skill) && _anyAllyTarget(skill);

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

  Future<TgTurnPlan?> _applyTurn(
    BattleData battle,
    List<TgSkillRef> skills,
    _TurnChoice choice,
    int commandSpellsLeft,
  ) async {
    final fire = choice.fire;
    final swap = choice.swap;
    final held = choice.held;
    final incomingHeld = choice.incomingHeld;
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
    Future<void> useSkill(TgSkillRef skill, String key) async {
      int? target;
      if (skill.needsAllyTarget) {
        target = choice.targets[key] ?? primaryAfterSwap();
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
      if (!held.contains(i) && before(skill)) await useSkill(skill, 'f$i');
    }
    for (final (i, skill) in skills.indexed) {
      if (!held.contains(i) && skill.isMysticCode) await useSkill(skill, 'f$i');
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
        if (incomingHeld.contains(skill.skillIndex)) continue;
        await useSkill(skill, 'i${skill.skillIndex}');
      }
      if (incomingHeld.isNotEmpty) {
        steps.add('$inName saves ${(incomingHeld.toList()..sort()).map((i) => 'S${i + 1}').join(', ')} for later');
      }
    }
    // 4. the servants who fire
    for (final (i, skill) in skills.indexed) {
      if (!held.contains(i) && !skill.isMysticCode && !before(skill)) await useSkill(skill, 'f$i');
    }

    if (held.isNotEmpty) {
      steps.add('Not used: ${[for (final i in held.toList()..sort()) skills[i].name].join(', ')}');
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
      incomingHeld: incomingHeld,
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
