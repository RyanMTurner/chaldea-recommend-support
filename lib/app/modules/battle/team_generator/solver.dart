import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';

import '../simulation/fga_export.dart';

/// User settings for the Team Generator solver.
class TeamGeneratorSettings {
  /// The solver clears one wave per turn, so this only has to be at least the number of waves.
  int maxTurns;
  int maxCommandSpells;
  int timeLimitSeconds;

  /// Not used by the solver; kept for compatibility.
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
  final bool anyAllyTarget;

  /// Party/self buffs lasting 3+ turns or NP over time, without NP charge: used at the start of every wave when ready.
  final bool alwaysUse;

  /// Charges the NP gauge right away: only used to charge the NP users.
  final bool chargesNp;

  /// Gives NP regen (NP at the end of every turn): counts as charge when pre-charging for the next wave.
  final bool addsNpRegen;

  /// Buffs on its user or one ally (no NP charge), all lasting 3+ turns: used before the attack when they land on
  /// one of this turn's NP users.
  final bool longPersonalBuff;

  /// Every buff in it lasts 1 turn.
  final bool oneTurnOnly;
  final String name;

  const TgSkillRef({
    required this.slot,
    required this.skillIndex,
    required this.needsAllyTarget,
    this.anyAllyTarget = false,
    this.alwaysUse = false,
    this.chargesNp = false,
    this.addsNpRegen = false,
    this.longPersonalBuff = false,
    this.oneTurnOnly = false,
    required this.name,
  });

  bool get isMysticCode => slot == null;
}

/// Order Change: front-line slot (0-2) swapped with backup index (0-2). Not used by the solver for now.
typedef TgOrderChange = ({int onField, int backup});

/// How the solver treats a skill, see [TeamGeneratorSolver.skillUse].
enum TgSkillUse { never, always, choose }

/// What the solver did in one turn.
class TgTurnPlan {
  final int wave;
  final List<(TgSkillRef skill, int? target)> skills;
  final TgOrderChange? orderChange;

  /// Skill indices (0-2) the incoming servant saved for later turns.
  final Set<int> incomingHeld;
  final List<int> commandSpellTargets;

  /// Front-line slots firing their NP, in firing order.
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

/// Skills, Command Spells and steps of the turn being built.
class _TurnLog {
  final List<(TgSkillRef, int?)> skills;
  final List<int> commandSpells;
  final List<String> steps;

  _TurnLog([List<(TgSkillRef, int?)>? skills, List<int>? commandSpells, List<String>? steps])
    : skills = skills ?? [],
      commandSpells = commandSpells ?? [],
      steps = steps ?? [];

  _TurnLog copy() => _TurnLog(List.of(skills), List.of(commandSpells), List.of(steps));
}

/// One way to use an NP charge source: its target (null = no target) and the NP each NP user gains.
class _ChargeOption {
  final int? target;
  final List<int> gains;
  const _ChargeOption(this.target, this.gains);
}

/// An NP charge skill, or a Command Spell when [skill] is null.
class _ChargeSource {
  final TgSkillRef? skill;
  final List<_ChargeOption> options;
  const _ChargeSource(this.skill, this.options);

  bool get isCommandSpell => skill == null;
}

enum _Outcome {
  /// the quest is cleared
  solved,

  /// this wave was cleared but a later one could not be
  clearedLaterFailed,
  notCleared,

  /// cancelled or stopped at the time limit
  stopped,
}

class _AttackResult {
  final _Outcome outcome;

  /// HP left on the wave's enemies when it wasn't cleared.
  final int enemyHp;
  const _AttackResult(this.outcome, [this.enemyHp = 0]);
}

/// Finds a plan that clears [quest] with a fixed team, one turn per wave. Order Change isn't used.
///
/// Every turn plays 3 cards: the NPs plus the weakest face cards of the 15 on the field (least damage, then
/// least NP gain), so a plan doesn't depend on face cards. Worst case only: minimum damage roll, only 100%
/// effects, no critical hits.
///
/// For each wave:
///  1. use every ready party buff lasting 3+ turns that doesn't charge NP
///  2. charge the NP users to 100%: fewest Command Spells, then least NP above 100%, then fewest skills. If a
///     later wave can't be cleared, the next-cheapest way to charge is tried before other NP users. After every
///     way without, the ways that also pre-charge a servant who doesn't fire this turn to 100% (with the NP
///     charge skills left, no Command Spells) so it can fire next wave. Pre-charging counts NP regen (one tick,
///     at the end of this turn), and skills that add NP regen can be used for it
///  3. use the buffs lasting 3+ turns that land on this turn's NP users (self-buffs of an NP user, single-ally
///     buffs on NP A), then attack: NP A + worst card + second-worst card
///  4. if the wave survives, add the other buffs lasting more than 1 turn one at a time and attack again after
///     each (a single-ally buff goes to the NP user that leaves the least enemy HP)
///  5. then the same with 1-turn buffs
///  6. NP users are tried in this order: servant 1, 2, 3 alone; every ordered pair (NP A, NP B, second-worst
///     card); every order of all three NPs
///  7. the first way that clears the wave moves on to the next wave. If a later wave can't be cleared, the
///     earlier wave goes on with its next NP user(s); when nothing is left the quest can't be solved this way
///
/// Command Spells are a last resort: a wave first tries every NP user combination charged with skills only, and
/// only then the combinations that need Command Spells. Later waves (usually the toughest) get to use them
/// before an earlier wave does.
///
/// Skills that can't help (nothing that changes damage, charges NP or reduces cooldowns) are never used, and
/// NP charge skills are only used in step 2.
class TeamGeneratorSolver implements TeamGeneratorRun {
  final QuestPhase quest;
  final BattleTeamSetup formation;
  final TeamGeneratorSettings settings;
  final void Function(int simulations, int elapsedMilliseconds)? onProgress;

  /// Called when the time limit is reached; the search waits (state kept) until [addTime] or [cancel].
  final void Function(int simulations, int elapsedMilliseconds)? onPaused;

  /// Debugging: called with one line per attempt (every attack and every NP combination that can't be charged).
  final void Function(String line)? trace;

  TeamGeneratorSolver({
    required this.quest,
    required this.formation,
    required this.settings,
    this.onProgress,
    this.onPaused,
    this.trace,
    this.partitionIndex = 0,
    this.partitionCount = 1,
  }) : _timeLimitSeconds = settings.timeLimitSeconds;

  /// Parallel runs: this solver only tries the first wave's NP users where `index % partitionCount == partitionIndex`.
  final int partitionIndex;
  final int partitionCount;

  static const noPlanMessage = 'No plan found: no NP combination with the weakest face cards clears every wave.';

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
    if (_totalWaves > settings.maxTurns) {
      return _result(
        false,
        'The quest has $_totalWaves waves and each wave takes a turn: Maximum Turns must be at least $_totalWaves.',
      );
    }
    final battle = BattleData();
    battle.options
      ..random = ConstData.constants.attackRateRandomMin
      ..threshold = 1000
      ..manualAllySkillTarget = false;
    await battle.init(quest, team.svts, team.mysticCodeData);
    await prefetchTriggeredSkills(battle);

    final plans = <TgTurnPlan>[];
    final found = await _solveWave(battle, plans, 0);
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
    return _result(false, noPlanMessage);
  }

  TeamGeneratorResult _result(bool success, String message) {
    _watch.stop();
    return TeamGeneratorResult(
      success: success,
      message: message,
      simulations: simulations,
      elapsedMilliseconds: _watch.elapsedMilliseconds,
    );
  }

  void _restore(BattleData battle, int depth) {
    while (battle.snapshots.length > depth) {
      battle.popSnapshot();
    }
  }

  static String _nameOf(BattleData battle, int slot) =>
      battle.onFieldAllyServants.getOrNull(slot)?.lBattleName ?? 'Slot ${slot + 1}';

  /// Tries the ways to clear the current wave in order (see the class doc). True once the quest is cleared;
  /// the battle is then left in its final state.
  Future<bool> _solveWave(BattleData battle, List<TgTurnPlan> plans, int csUsed) async {
    if (battle.isBattleWin) return true;
    if (plans.length >= settings.maxTurns || battle.nonnullPlayers.isEmpty) return false;
    if (!await _continueAfterTimeLimit()) return false;

    final start = battle.snapshots.length;
    battle.pushSnapshot();

    // 1. party buffs lasting 3+ turns
    final base = _TurnLog();
    for (final skill in availableSkills(battle)) {
      if (skill.alwaysUse) await _useSkill(battle, base, skill, null);
    }

    final afterBuffs = battle.snapshots.length;
    // Command Spells are a last resort: every way without them first, then only the ways that need them. A
    // wave reached through this one tries its own options (Command Spells included) before this wave spends
    // one, so they tend to be saved for the later, tougher waves.
    final commandSpellsLeft = settings.maxCommandSpells - csUsed;
    for (final withCommandSpells in [false, if (commandSpellsLeft > 0) true]) {
      for (final (index, users) in npOrders(battle).indexed) {
        if (plans.isEmpty && index % partitionCount != partitionIndex) continue;
        if (_cancelled) break;
        battle.pushSnapshot();
        final outcome = await _tryUsers(battle, plans, csUsed, users, base.copy(), withCommandSpells);
        if (outcome == _Outcome.solved) return true; // keep the final state
        _restore(battle, afterBuffs);
        if (outcome == _Outcome.stopped) break;
      }
      if (_cancelled) break;
    }
    _restore(battle, start);
    return false;
  }

  /// Steps 2-5 with [users] firing their NPs in this order. With [withCommandSpells], only the ways of charging
  /// that use at least one Command Spell (the ways without were already tried).
  ///
  /// Every way to charge the NP users is tried, cheapest first: when a later wave can't be cleared, the next
  /// way to charge may leave it the skills it needs.
  Future<_Outcome> _tryUsers(
    BattleData battle,
    List<TgTurnPlan> plans,
    int csUsed,
    List<int> users,
    _TurnLog log,
    bool withCommandSpells,
  ) async {
    // 2. ways to charge the NP users
    final full = ConstData.constants.fullTdPoint;
    final need = [for (final slot in users) max(0, full - (battle.onFieldAllyServants.getOrNull(slot)?.np ?? 0))];
    final List<_ChargeSource> sources;
    final List<List<int?>> choices;
    if (need.every((n) => n == 0)) {
      if (withCommandSpells) return _Outcome.notCleared;
      sources = [];
      choices = [[]];
    } else {
      sources = await _chargeSources(battle, users, withCommandSpells ? settings.maxCommandSpells - csUsed : 0);
      choices = [
        for (final choice in chargeChoices(
          need,
          [for (final source in sources) source.options.map((o) => o.gains).toList()],
          [for (final source in sources) source.isCommandSpell],
        ))
          if (!withCommandSpells || choice.indexed.any((e) => e.$2 != null && sources[e.$1].isCommandSpell)) choice,
      ];
    }

    if (trace != null && choices.isEmpty) {
      trace!(
        'W${battle.waveCount} ${users.map((slot) => _nameOf(battle, slot)).join(' + ')}: no way to charge '
        '(need ${need.map((n) => n / 100).join(', ')}%${withCommandSpells ? ', with Command Spells' : ''})',
      );
    }
    final beforeCharge = battle.snapshots.length;
    // every way to charge without pre-charging first, then with (not on the last wave: nothing comes next)
    for (final preCharge in [false, if (battle.waveCount < _totalWaves) true]) {
      for (final choice in choices) {
        battle.pushSnapshot();
        final attempt = log.copy();
        await _applyCharge(battle, sources, choice, attempt);
        final ready = users.every((slot) => battle.onFieldAllyServants.getOrNull(slot)?.canNP() == true);
        final outcome = !ready
            ? _Outcome.notCleared
            : preCharge
            ? await _preChargeAndAttack(battle, plans, csUsed, users, attempt)
            : await _attackWithBuffs(battle, plans, csUsed, users, attempt);
        if (outcome == _Outcome.solved) return outcome; // keep the final state
        _restore(battle, beforeCharge);
        if (outcome == _Outcome.stopped) return outcome;
      }
    }
    return _Outcome.notCleared;
  }

  /// Pre-charge: also charges a servant who doesn't fire this turn to 100% with the NP charge skills left (no
  /// Command Spells), so it can fire next wave. Each other servant and each way to charge it is tried, cheapest
  /// first, then steps 3-5 as usual.
  Future<_Outcome> _preChargeAndAttack(
    BattleData battle,
    List<TgTurnPlan> plans,
    int csUsed,
    List<int> users,
    _TurnLog log,
  ) async {
    final full = ConstData.constants.fullTdPoint;
    final start = battle.snapshots.length;
    for (int slot = 0; slot < 3; slot++) {
      if (users.contains(slot)) continue;
      final svt = battle.onFieldAllyServants.getOrNull(slot);
      // NP regen ticks at the end of this turn, before the next wave
      if (svt == null || svt.getNPCard() == null || svt.np + npRegen(svt) >= full) continue;
      // read before measuring: rewinding the battle swaps in copies, so [svt] goes stale
      final need = full - svt.np - npRegen(svt);
      final sources = await _chargeSources(battle, [slot], 0, nextTurn: true);
      final ways = chargeChoices(
        [need],
        [for (final source in sources) source.options.map((o) => o.gains).toList()],
        [for (final source in sources) source.isCommandSpell],
      );
      for (final way in ways) {
        battle.pushSnapshot();
        final attempt = log.copy()..steps.add('Pre-charge ${_nameOf(battle, slot)} for the next wave:');
        await _applyCharge(battle, sources, way, attempt);
        final outcome = await _attackWithBuffs(battle, plans, csUsed, users, attempt);
        if (outcome == _Outcome.solved) return outcome; // keep the final state
        _restore(battle, start);
        if (outcome == _Outcome.stopped) return outcome;
      }
    }
    return _Outcome.notCleared;
  }

  /// Steps 3-5: attack, then add buffs one at a time and attack again after each.
  Future<_Outcome> _attackWithBuffs(
    BattleData battle,
    List<TgTurnPlan> plans,
    int csUsed,
    List<int> users,
    _TurnLog log,
  ) async {
    // self-buffs lasting 3+ turns on this turn's NP users go first (still active on later waves)
    for (final skill in availableSkills(battle)) {
      if (!skill.longPersonalBuff || skill.alwaysUse || skill.chargesNp) continue;
      if (skill.needsAllyTarget) {
        await _useSkill(battle, log, skill, users.first);
      } else if (skill.slot != null && users.contains(skill.slot)) {
        await _useSkill(battle, log, skill, null);
      }
    }

    // 3. attack with what we have
    var result = await _attack(battle, plans, csUsed, users, log);
    if (result.outcome != _Outcome.notCleared) return result.outcome;

    // 4. buffs lasting more than 1 turn, 5. 1-turn buffs; one at a time, attacking after each
    for (final oneTurn in [false, true]) {
      final buffs = [
        for (final skill in availableSkills(battle))
          if (!skill.alwaysUse && !skill.chargesNp && skill.oneTurnOnly == oneTurn) skill,
      ];
      for (final skill in buffs) {
        final targets = skill.needsAllyTarget ? users : <int?>[null];
        if (targets.length == 1) {
          await _useSkill(battle, log, skill, targets.single);
          result = await _attack(battle, plans, csUsed, users, log);
          if (result.outcome != _Outcome.notCleared) return result.outcome;
          continue;
        }
        // several NP users: keep the target that leaves the least enemy HP
        int? bestTarget;
        int bestHp = -1;
        for (final target in targets) {
          final depth = battle.snapshots.length;
          battle.pushSnapshot();
          final probe = log.copy();
          await _useSkill(battle, probe, skill, target);
          result = await _attack(battle, plans, csUsed, users, probe);
          if (result.outcome == _Outcome.solved) return result.outcome;
          _restore(battle, depth);
          if (result.outcome != _Outcome.notCleared) return result.outcome;
          if (bestHp < 0 || result.enemyHp < bestHp) {
            bestHp = result.enemyHp;
            bestTarget = target;
          }
        }
        await _useSkill(battle, log, skill, bestTarget); // its attack was already tried
      }
    }
    return _Outcome.notCleared;
  }

  /// NP charge skills and up to [commandSpellsLeft] Command Spells, with what each gives every NP user,
  /// measured one source at a time from the current state.
  /// [nextTurn] (pre-charge): NP regen counts as one tick of charge, and skills that add NP regen are sources too.
  Future<List<_ChargeSource>> _chargeSources(
    BattleData battle,
    List<int> users,
    int commandSpellsLeft, {
    bool nextTurn = false,
  }) async {
    int npOf(int slot) {
      final svt = battle.onFieldAllyServants.getOrNull(slot);
      if (svt == null) return 0;
      return svt.np + (nextTurn ? npRegen(svt) : 0);
    }
    Future<List<int>> measure(Future<void> Function() action) async {
      final before = [for (final slot in users) npOf(slot)];
      final depth = battle.snapshots.length;
      battle.pushSnapshot();
      try {
        await action();
        return [for (final (i, slot) in users.indexed) npOf(slot) - before[i]];
      } catch (e) {
        return List.filled(users.length, 0);
      } finally {
        _restore(battle, depth);
      }
    }

    final sources = <_ChargeSource>[];
    for (final skill in availableSkills(battle)) {
      if (!skill.chargesNp && !(nextTurn && skill.addsNpRegen)) continue;
      final options = <_ChargeOption>[];
      for (final target in skill.needsAllyTarget ? users : <int?>[null]) {
        final gains = await measure(() => _activate(battle, skill, target));
        if (gains.any((g) => g > 0)) options.add(_ChargeOption(target, gains));
      }
      if (options.isNotEmpty) sources.add(_ChargeSource(skill, options));
    }
    final commandSpells = min(commandSpellsLeft, users.length);
    if (commandSpells > 0) {
      final options = <_ChargeOption>[];
      for (final target in users) {
        final gains = await measure(() => _activateCommandSpell(battle, target));
        if (gains.any((g) => g > 0)) options.add(_ChargeOption(target, gains));
      }
      if (options.isNotEmpty) {
        for (int i = 0; i < commandSpells; i++) {
          sources.add(_ChargeSource(null, options));
        }
      }
    }
    return sources;
  }

  /// Uses the charge sources picked in [choice] (option index per source, null = unused).
  Future<void> _applyCharge(BattleData battle, List<_ChargeSource> sources, List<int?> choice, _TurnLog log) async {
    for (final (index, option) in choice.indexed) {
      if (option == null) continue;
      final source = sources[index];
      final target = source.options[option].target;
      if (source.isCommandSpell) {
        await _activateCommandSpell(battle, target!);
        log.commandSpells.add(target);
        log.steps.add('Command Spell → ${_nameOf(battle, target)}');
      } else {
        await _useSkill(battle, log, source.skill!, target);
      }
    }
  }

  /// The cheapest way to charge, see [chargeChoices]; null if [need] can't be met.
  @visibleForTesting
  static List<int?>? pickCharges(List<int> need, List<List<List<int>>> options, List<bool> isCommandSpell) =>
      chargeChoices(need, options, isCommandSpell).firstOrNull;

  /// Every way to pick an option (or none) for each charge source so that every NP user gains at least [need],
  /// cheapest first: fewest Command Spells, then least overflow, then fewest skills.
  /// [options] per source: the gain of each NP user for each option. Each way is the option index per source
  /// (null = unused). Sources after the need is met are left unused (they would only add waste).
  @visibleForTesting
  static List<List<int?>> chargeChoices(List<int> need, List<List<List<int>>> options, List<bool> isCommandSpell) {
    final found = <((int, int, int), List<int?>)>[];
    final choice = List<int?>.filled(options.length, null);

    void search(int index, List<int> gained, int commandSpells, int skills) {
      final met = [for (final (i, n) in need.indexed) gained[i] >= n].every((e) => e);
      if (met) {
        int waste = 0;
        for (final (i, n) in need.indexed) {
          waste += gained[i] - n;
        }
        found.add(((commandSpells, waste, skills), List.of(choice)));
        return;
      }
      if (index == options.length) return;
      search(index + 1, gained, commandSpells, skills);
      for (final (o, gains) in options[index].indexed) {
        choice[index] = o;
        search(
          index + 1,
          [for (final (i, g) in gained.indexed) g + gains[i]],
          commandSpells + (isCommandSpell[index] ? 1 : 0),
          skills + (isCommandSpell[index] ? 0 : 1),
        );
      }
      choice[index] = null;
    }

    search(0, List.filled(need.length, 0), 0, 0);
    // stable sort: equal costs keep the search order
    final indexed = found.indexed.toList()
      ..sort((a, b) {
        final (x, y) = (a.$2.$1, b.$2.$1);
        if (x.$1 != y.$1) return x.$1 - y.$1;
        if (x.$2 != y.$2) return x.$2 - y.$2;
        if (x.$3 != y.$3) return x.$3 - y.$3;
        return a.$1 - b.$1;
      });
    return [for (final (_, (_, way)) in indexed) way];
  }

  /// Plays the turn: the NPs of [users] in order plus the weakest face cards. If the wave is cleared, goes on
  /// with the next wave; the battle is restored unless the quest gets cleared.
  Future<_AttackResult> _attack(
    BattleData battle,
    List<TgTurnPlan> plans,
    int csUsed,
    List<int> users,
    _TurnLog log,
  ) async {
    if (!await _continueAfterTimeLimit()) return const _AttackResult(_Outcome.stopped);
    final actions = attackCards(battle, users);
    if (actions == null) return const _AttackResult(_Outcome.notCleared, 1 << 30);
    final wave = battle.waveCount;
    final depth = battle.snapshots.length;
    battle.pushSnapshot();
    final cardsStep = 'Cards: ${actions.map((a) => _cardLabel(a)).join(', ')}';
    bool played = true;
    try {
      await battle.playerTurn(actions);
    } catch (e) {
      played = false; // the engine refused an action
    }
    simulations++;
    if (simulations % 8 == 0) {
      battle.battleLogger.logs.clear();
      onProgress?.call(simulations, _watch.elapsedMilliseconds);
      await Future.delayed(Duration.zero); // keep the UI responsive
    }
    final cleared = played && (battle.isBattleWin || battle.waveCount > wave);
    if (trace != null) {
      final hp = Maths.sum(battle.nonnullEnemies.map((e) => max(0, e.hp)));
      final result = !played
          ? 'NOT PLAYED'
          : cleared
          ? 'CLEARED'
          : 'not cleared, enemy HP $hp';
      trace!('W$wave ${'  ' * plans.length}${[...log.steps, cardsStep].join('; ')} => $result');
    }
    if (!cleared) {
      final hp = Maths.sum(battle.nonnullEnemies.map((e) => max(0, e.hp)));
      _restore(battle, depth);
      return _AttackResult(_Outcome.notCleared, hp);
    }
    plans.add(
      TgTurnPlan(
        wave: wave,
        skills: List.of(log.skills),
        orderChange: null,
        commandSpellTargets: List.of(log.commandSpells),
        npSlots: List.of(users),
        steps: [...log.steps, cardsStep],
      ),
    );
    if (await _solveWave(battle, plans, csUsed + log.commandSpells.length)) {
      return const _AttackResult(_Outcome.solved);
    }
    plans.removeLast();
    _restore(battle, depth);
    return _AttackResult(_cancelled ? _Outcome.stopped : _Outcome.clearedLaterFailed);
  }

  /// NP the servant's regen buffs give at the end of the turn.
  static int npRegen(BattleServantData svt) {
    int total = 0;
    for (final buff in svt.battleBuff.validBuffs) {
      if (buff.buff.type == BuffType.regainNp) total += buff.vals.Value ?? 0;
    }
    return total;
  }

  static String _cardLabel(CombatAction action) {
    final name = action.actor.lBattleName;
    if (action.cardData.isTD) return 'NP $name';
    return '${_cardTypeName(action.cardData.cardType)} ($name)';
  }

  static String _cardTypeName(int cardType) {
    if (CardType.isQuick(cardType)) return 'Quick';
    if (CardType.isArts(cardType)) return 'Arts';
    if (CardType.isBuster(cardType)) return 'Buster';
    return 'Card';
  }

  /// NP users in the order they are tried: each servant alone, then every ordered pair, then every order of
  /// all three.
  static List<List<int>> npOrders(BattleData battle) {
    final slots = [
      for (int slot = 0; slot < 3; slot++)
        if (battle.onFieldAllyServants.getOrNull(slot)?.getNPCard() != null) slot,
    ];
    final orders = <List<int>>[];
    void permute(List<int> current, int size) {
      if (current.length == size) {
        orders.add(List.of(current));
        return;
      }
      for (final slot in slots) {
        if (current.contains(slot)) continue;
        current.add(slot);
        permute(current, size);
        current.removeLast();
      }
    }

    for (int size = 1; size <= slots.length; size++) {
      permute([], size);
    }
    return orders;
  }

  /// Weakest first: least damage (ATK × card type), then least NP gain.
  static (int, int) cardRating(BattleServantData svt, CommandCardData card) {
    final type = card.cardType;
    final damage = CardType.isBuster(type) ? 150 : (CardType.isQuick(type) ? 80 : 100);
    final np = CardType.isArts(type) ? 3 : (CardType.isQuick(type) ? 1 : 0);
    return (svt.atk * damage, card.npGain * np);
  }

  static int _color(int cardType) {
    if (CardType.isQuick(cardType)) return CardType.quick.value;
    if (CardType.isArts(cardType)) return CardType.arts.value;
    if (CardType.isBuster(cardType)) return CardType.buster.value;
    return cardType;
  }

  /// Three cards of one servant (Brave Chain) or one color: they would add damage or NP.
  static bool _isChain(List<CombatAction> cards) {
    if (cards.length < 3) return false;
    final sameServant = cards.every((c) => c.actor.uniqueId == cards.first.actor.uniqueId);
    final sameColor = cards.every((c) => _color(c.cardData.cardType) == _color(cards.first.cardData.cardType));
    return sameServant || sameColor;
  }

  /// The turn's 3 cards: the NP cards of [users] in order, then the weakest face cards of the front line
  /// (1 NP: worst, second worst; 2 NPs: second worst; 3 NPs: none). Face cards that would make a Brave or
  /// same-color chain are skipped when there are others. Null if one of the NPs can't be used.
  static List<CombatAction>? attackCards(BattleData battle, List<int> users) {
    final nps = <CombatAction>[];
    for (final slot in users) {
      final svt = battle.onFieldAllyServants.getOrNull(slot);
      final card = svt?.getNPCard();
      if (svt == null || card == null || !svt.canNP()) return null;
      nps.add(CombatAction(svt, card));
    }
    if (nps.length >= 3) return nps;

    final faces = <(CombatAction, (int, int))>[
      for (final svt in battle.nonnullPlayers)
        for (final card in svt.getCards()) (CombatAction(svt, card), cardRating(svt, card)),
    ];
    faces.sort((a, b) => a.$2.$1 != b.$2.$1 ? a.$2.$1 - b.$2.$1 : a.$2.$2 - b.$2.$2);
    final sorted = [for (final face in faces) face.$1];
    if (sorted.isEmpty) return nps;

    if (nps.length == 2) {
      final valid = sorted.where((face) => !_isChain([...nps, face])).toList();
      final pool = valid.isNotEmpty ? valid : sorted;
      return [...nps, pool.getOrNull(1) ?? pool.first];
    }
    for (int i = 0; i < sorted.length; i++) {
      for (int j = i + 1; j < sorted.length; j++) {
        final cards = [...nps, sorted[i], sorted[j]];
        if (!_isChain(cards)) return cards;
      }
    }
    return [...nps, ...sorted.take(2)];
  }

  Future<void> _useSkill(BattleData battle, _TurnLog log, TgSkillRef skill, int? target) async {
    final user = skill.isMysticCode ? 'MC' : _nameOf(battle, skill.slot!);
    final targetName = target == null ? null : _nameOf(battle, target);
    await _activate(battle, skill, target);
    log.skills.add((skill, target));
    log.steps.add('$user S${skill.skillIndex + 1}${targetName == null ? '' : ' → $targetName'}');
  }

  static Future<void> _activate(BattleData battle, TgSkillRef skill, int? target) async {
    if (target != null) battle.playerTargetIndex = target;
    if (skill.isMysticCode) {
      await battle.activateMysticCodeSkill(skill.skillIndex);
    } else {
      await battle.activateSvtSkill(skill.slot!, skill.skillIndex);
    }
  }

  static Future<void> _activateCommandSpell(BattleData battle, int target) async {
    battle.playerTargetIndex = target;
    await battle.commandSpellReleaseNP();
  }

  static bool _isOrderChange(BaseSkill skill) => skill.functions.any((func) => func.funcType == FuncType.replaceMember);

  /// Ready-to-use skills, front line first, then mystic code. Skills that can't help and Order Change are left out.
  static List<TgSkillRef> availableSkills(BattleData battle) {
    final skills = <TgSkillRef>[];
    TgSkillRef? ref(BaseSkill skill, int? slot, int index, String name) {
      final use = skillUse(skill);
      if (use == TgSkillUse.never) return null;
      return TgSkillRef(
        slot: slot,
        skillIndex: index,
        needsAllyTarget: _needsAllyTarget(skill),
        anyAllyTarget: _anyAllyTarget(skill),
        alwaysUse: use == TgSkillUse.always,
        chargesNp: _playerFuncs(skill).any(_isNpCharge),
        addsNpRegen: _playerFuncs(skill).any((f) => f.buffs.any((b) => b.type == BuffType.regainNp)),
        longPersonalBuff: _longPersonalBuff(skill),
        oneTurnOnly: _oneTurnOnly(skill),
        name: name,
      );
    }

    for (int slot = 0; slot < 3; slot++) {
      final svt = battle.onFieldAllyServants.getOrNull(slot);
      if (svt == null) continue;
      for (int index = 0; index < svt.skillInfoList.length; index++) {
        final info = svt.skillInfoList[index];
        final skill = info.skill;
        if (skill == null || info.chargeTurn > 0) continue;
        if (!battle.canUseSvtSkillIgnoreCoolDown(slot, index)) continue;
        final r = ref(skill, slot, index, '${svt.lBattleName} S${index + 1}');
        if (r != null) skills.add(r);
      }
    }
    for (int index = 0; index < battle.masterSkillInfo.length; index++) {
      final info = battle.masterSkillInfo[index];
      final skill = info.skill;
      if (skill == null || info.chargeTurn > 0 || _isOrderChange(skill)) continue;
      if (!battle.canUseMysticCodeSkillIgnoreCoolDown(index)) continue;
      final r = ref(skill, null, index, 'MC S${index + 1}');
      if (r != null) skills.add(r);
    }
    return skills;
  }

  static bool _isTurnTrigger(BuffType type) =>
      type == BuffType.selfturnstartFunction || type == BuffType.selfturnendFunction;

  /// Turn start/end skills missing from the local game data, fetched by [prefetchTriggeredSkills].
  static final Map<int, BaseSkill> _fetchedSkills = {};

  /// Fetches the turn start/end skills the team's skills trigger that aren't in the local game data, so
  /// [skillUse] can tell whether they charge NP.
  static Future<void> prefetchTriggeredSkills(BattleData battle) async {
    final skills = <BaseSkill>[
      for (final svt in battle.nonnullPlayers)
        for (final info in svt.skillInfoList)
          if (info.skill != null) info.skill!,
      for (final info in battle.masterSkillInfo)
        if (info.skill != null) info.skill!,
    ];
    for (final skill in skills) {
      for (final func in _playerFuncs(skill)) {
        if (!func.buffs.any((b) => _isTurnTrigger(b.type))) continue;
        final id = func.svals.firstOrNull?.Value;
        if (id == null || db.gameData.baseSkills.containsKey(id) || _fetchedSkills.containsKey(id)) continue;
        try {
          final fetched = await AtlasApi.skill(id);
          if (fetched != null) _fetchedSkills[id] = fetched;
        } catch (e) {
          // unknown: treated as not charging NP
        }
      }
    }
  }

  /// NP regen, or a turn start/end trigger whose skill charges NP.
  static bool _givesNpOverTime(NiceFunction func) {
    return func.buffs.any((buff) {
      if (buff.type == BuffType.regainNp) return true;
      if (!_isTurnTrigger(buff.type)) return false;
      final id = func.svals.firstOrNull?.Value;
      final triggered = db.gameData.baseSkills[id] ?? _fetchedSkills[id];
      return triggered != null && _playerFuncs(triggered).any(_isNpCharge);
    });
  }

  /// The functions that apply when a player uses the skill (some only apply when an enemy uses it).
  static List<NiceFunction> _playerFuncs(BaseSkill skill) => skill.functions.where((f) => !f.isEnemyOnlyFunc).toList();

  static bool _needsAllyTarget(BaseSkill skill) {
    return _playerFuncs(skill).any(_isSingleAllyFunc);
  }

  static bool _isSingleAllyFunc(NiceFunction func) =>
      func.funcTargetTeam != FuncApplyTarget.enemy && func.funcTargetType.needNormalOneTarget;

  static bool _isNpCharge(NiceFunction func) {
    final name = func.funcType.name;
    return name.startsWith('gainNp') || name == 'gainMultiplyNp';
  }

  /// Buffs on its user or one ally, every ally buff lasting 3+ turns (or until used up), no NP charge.
  /// Effects on enemies don't matter.
  static bool _longPersonalBuff(BaseSkill skill) {
    final funcs = _playerFuncs(skill);
    if (funcs.any(_isNpCharge)) return false;
    final allyBuffs = [
      for (final func in funcs)
        if (func.buffs.isNotEmpty && !func.funcTargetType.isEnemy && func.funcTargetTeam != FuncApplyTarget.enemy) func,
    ];
    final personal = allyBuffs.any(
      (f) => f.funcTargetType == FuncTargetType.self || f.funcTargetType.needNormalOneTarget,
    );
    return personal &&
        allyBuffs.every((f) {
          final turn = f.svals.firstOrNull?.Turn ?? 0;
          return turn >= 3 || turn == -1;
        });
  }

  /// Every function with buffs gives buffs lasting exactly 1 turn.
  static bool _oneTurnOnly(BaseSkill skill) {
    final buffFuncs = _playerFuncs(skill).where((f) => f.buffs.isNotEmpty).toList();
    return buffFuncs.isNotEmpty && buffFuncs.every((f) => f.svals.firstOrNull?.Turn == 1);
  }

  /// A single-ally skill may target anyone if it charges NP or gives something other than 1-turn buffs;
  /// a skill whose single-ally effects are all 1-turn buffs only goes to the attacker.
  static bool _anyAllyTarget(BaseSkill skill) {
    final funcs = _playerFuncs(skill).where(_isSingleAllyFunc).toList();
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
    if (name == 'shortenSkill' || name.startsWith('damage') || name == 'instantDeath' || name == 'forceInstantDeath') {
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
  /// - always: buffs on allies only, all lasting 3+ turns, no single target, no NP charge; or NP over time
  ///   (regen, NP at turn start/end) without an immediate charge: used at the start of every wave when ready
  /// - choose: NP charge (step 2) or a buff tried one at a time (steps 4 and 5)
  static TgSkillUse skillUse(BaseSkill skill) {
    final funcs = _playerFuncs(skill);
    if (!funcs.any(_mattersForClear)) return TgSkillUse.never;
    if (funcs.any((f) => f.funcTargetType.needNormalOneTarget || f.funcTargetType == FuncTargetType.enemy)) {
      return TgSkillUse.choose;
    }
    // NP over time (regen, NP at turn start/end) without an immediate charge: the earlier, the more NP
    if (!funcs.any(_isNpCharge) && funcs.any(_givesNpOverTime)) return TgSkillUse.always;
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

  /// For tests: whether [skill] may target allies other than the attacker.
  @visibleForTesting
  static bool mayTargetAnyAlly(BaseSkill skill) => _needsAllyTarget(skill) && _anyAllyTarget(skill);

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
