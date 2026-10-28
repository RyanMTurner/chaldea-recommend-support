import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'package:flutter_easyloading/flutter_easyloading.dart';

import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/app/app.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_worker_pool.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/logger.dart';
import 'package:chaldea/utils/utils.dart';
import 'package:chaldea/widgets/widgets.dart';

import '../../bond/solver/results.dart';
import '../../mystic_code/mystic_code_list.dart';
import '../../servant/servant_list.dart';
import '../battle_simulation.dart';
import '../formation/team.dart';
import 'recommend.dart';
import 'solver.dart';
import 'workers.dart';

/// Kept while the app runs, so leaving and reopening the page keeps the setup and last result.
class _TeamGeneratorState {
  QuestPhase? quest;
  final BattleTeamSetup formation = BattleTeamSetup(mysticCodeData: MysticCodeData()..mysticCode = null);
  final TeamGeneratorSettings settings = TeamGeneratorSettings();
  TeamGeneratorResult? result;
  QuestPhase? resultQuest;
  BattleTeamSetup? resultFormation;

  /// the saved setup has been loaded (once per app run)
  bool restored = false;
}

class TeamGeneratorPage extends StatefulWidget {
  const TeamGeneratorPage({super.key});

  static final _state = _TeamGeneratorState();

  @override
  State<TeamGeneratorPage> createState() => _TeamGeneratorPageState();
}

class _TeamGeneratorPageState extends State<TeamGeneratorPage> {
  _TeamGeneratorState get state => TeamGeneratorPage._state;
  TeamGeneratorRun? _solver;
  int _simulations = 0;
  int _elapsedMs = 0;
  bool _paused = false;
  bool _startingWorkers = false;

  bool get solving => _solver != null;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    if (!state.restored) {
      state.restored = true;
      _restore();
    }
  }

  /// Load the setup saved by [_save]: settings, quest, servants, CEs and mystic code.
  Future<void> _restore() async {
    final saved = db.settings.battleSim.teamGenerator;
    setState(() => _restoring = true);
    try {
      state.settings
        ..maxCommandSpells = saved.maxCommandSpells
        ..timeLimitSeconds = saved.timeLimitSeconds;
      if (saved.workers != null) state.settings.workers = saved.workers!;
      state.settings
        ..maxBond = saved.maxBond
        ..supportIgnoresBondCap = saved.supportIgnoresBondCap
        ..excludedSvts = Set.of(saved.excludedSvts);

      final svts = <PlayerSvtData>[];
      for (final svt in saved.formation.svts) {
        svts.add(await PlayerSvtData.fromStoredData(svt));
      }
      state.formation.updateSvts(svts);
      state.formation.mysticCodeData.loadStoredData(saved.formation.mysticCode);

      final questInfo = saved.quest;
      if (questInfo != null) {
        final local = db.gameData.getQuestPhase(questInfo.id, questInfo.phase);
        state.quest = local != null && (questInfo.enemyHash == null || local.enemyHash == questInfo.enemyHash)
            ? local
            : await AtlasApi.questPhase(
                questInfo.id,
                questInfo.phase,
                hash: questInfo.enemyHash,
                region: questInfo.region ?? Region.jp,
              );
      }
    } catch (e, s) {
      logger.e('restore team generator setup failed', e, s);
    } finally {
      _restoring = false;
      if (mounted) setState(() {});
    }
  }

  void _save() {
    if (_restoring) return;
    final quest = state.quest;
    db.settings.battleSim.teamGenerator = TeamGeneratorSaveData(
      maxCommandSpells: state.settings.maxCommandSpells,
      timeLimitSeconds: state.settings.timeLimitSeconds,
      workers: state.settings.workers,
      maxBond: state.settings.maxBond,
      supportIgnoresBondCap: state.settings.supportIgnoresBondCap,
      excludedSvts: Set.of(state.settings.excludedSvts),
      quest: quest == null ? null : BattleQuestInfo.quest(quest),
      // fromList: an empty 3rd slot stays empty instead of becoming a support placeholder
      formation: BattleTeamFormation.fromList(
        svts: state.formation.svts.map((e) => e.isEmpty ? null : e.toStoredData()).toList(),
        mysticCode: state.formation.mysticCodeData.toStoredData(),
      ),
    );
    db.notifySettings();
  }

  @override
  void dispose() {
    _save(); // also catches edits made directly on the servants (e.g. in the servant settings page)
    _solver?.cancel();
    // each worker holds a copy of the game data, free it when leaving the page
    unawaited(TeamGeneratorWorkerPool.disposeCurrent());
    unawaited(BattleWorkerPool.disposeTag(kTeamRecommendWorkerTag));
    super.dispose();
  }

  void _changed(VoidCallback change) {
    setState(() {
      change();
      state.result = null;
    });
    _save();
  }

  void _editNumber({
    required String title,
    required int initial,
    required int min,
    required void Function(int) update,
    String? hintText,
  }) {
    InputCancelOkDialog.number(
      title: title,
      initValue: initial,
      validate: (v) => v >= min,
      onSubmit: (v) => _changed(() => update(v)),
      hintText: hintText,
    ).showDialog(context);
  }

  /// Lists recommended teams on the right half of the screen (a full page on narrow screens): candidates from
  /// the roster, checked with the solver as they come in.
  void _recommendTeams() {
    final quest = state.quest;
    if (quest == null) {
      EasyLoading.showError('Select a quest first');
      return;
    }
    final run = TeamRecommendRun(
      quest: quest,
      mysticCode: state.formation.mysticCodeData.copy(),
      settings: state.settings.copy(),
      // the manual team's CEs, front line first
      ces: [for (final svt in state.formation.svts) svt.equip1],
    );
    router.pushPage(TeamRecommendPage(run: run, onSelect: _selectTeam), detail: true, popDetail: true);
    unawaited(run.start());
  }

  /// Fills [team] into the six slots (its own levels, skills, support flag and CEs).
  void _selectTeam(RecommendedTeam team) {
    final svts = [for (int index = 0; index < 6; index++) team.svts.getOrNull(index)?.copy() ?? PlayerSvtData.base()];
    if (mounted) {
      _changed(() => state.formation.updateSvts(svts));
    } else {
      state.formation.updateSvts(svts); // the page was closed: the setup is still kept for next time
      state.result = null;
    }
    EasyLoading.showToast('Team selected');
  }

  Future<void> _solve() async {
    final quest = state.quest;
    if (quest == null) {
      EasyLoading.showError('Select a quest first');
      return;
    }
    final formation = state.formation.copy();
    final settings = state.settings.copy();
    void onProgress(int simulations, int elapsed) {
      if (mounted) {
        setState(() {
          _simulations = simulations;
          _elapsedMs = elapsed;
        });
      }
    }

    void onPaused(int simulations, int elapsed) {
      if (mounted) {
        setState(() {
          _paused = true;
          _simulations = simulations;
          _elapsedMs = elapsed;
        });
      }
    }

    TeamGeneratorRun singleThread() => TeamGeneratorSolver(
      quest: quest,
      formation: formation,
      settings: settings,
      onProgress: onProgress,
      onPaused: onPaused,
    );
    final useWorkers = !kIsWeb && settings.workers > 0;
    final TeamGeneratorRun run = useWorkers
        ? ParallelTeamGeneratorRun(
            quest: quest,
            formation: formation,
            settings: settings,
            onProgress: onProgress,
            onPaused: onPaused,
            onWorkersReady: () {
              if (mounted) setState(() => _startingWorkers = false);
            },
          )
        : singleThread();
    setState(() {
      _solver = run;
      _paused = false;
      _startingWorkers = useWorkers;
      _simulations = 0;
      _elapsedMs = 0;
      state.result = null;
    });
    // let the progress view draw before the game data copy (first parallel solve) blocks the UI thread
    await Future.delayed(const Duration(milliseconds: 50));
    TeamGeneratorResult result;
    try {
      result = await run.solve();
    } catch (e, s) {
      if (useWorkers && !(_solver?.isPaused ?? false) && mounted && identical(_solver, run)) {
        // workers could not start: search on the UI thread instead
        logger.e('team generator workers failed, falling back to the UI thread', e, s);
        EasyLoading.showToast('Worker threads unavailable, searching on the main thread');
        final fallback = singleThread();
        setState(() {
          _solver = fallback;
          _startingWorkers = false;
        });
        try {
          result = await fallback.solve();
        } catch (e, s) {
          logger.e('team generator failed', e, s);
          result = TeamGeneratorResult(success: false, message: 'Error: $e', simulations: 0, elapsedMilliseconds: 0);
        }
      } else {
        logger.e('team generator failed', e, s);
        result = TeamGeneratorResult(success: false, message: 'Error: $e', simulations: 0, elapsedMilliseconds: 0);
      }
    }
    if (!mounted) return;
    setState(() {
      _solver = null;
      _paused = false;
      _startingWorkers = false;
      state
        ..result = result
        ..resultQuest = quest
        ..resultFormation = formation;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Team Generator')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_restoring) const LinearProgressIndicator(),
          TileGroup(header: S.current.quest, children: [_questPicker()]),
          TileGroup(
            header: S.current.team,
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            children: [
              TeamSetupCard(
                formation: state.formation,
                quest: state.quest,
                playerRegion: db.settings.battleSim.playerRegion,
                onChanged: () => _changed(() {}),
              ),
            ],
          ),
          TileGroup(header: S.current.mystic_code, children: [_mysticCodeTile()]),
          TileGroup(
            header: S.current.settings_tab_name,
            children: [
              _numberTile(
                'Maximum Command Spells',
                state.settings.maxCommandSpells,
                0,
                (v) => state.settings.maxCommandSpells = v,
              ),
              _numberTile(
                'Time Limit (seconds)',
                state.settings.timeLimitSeconds,
                1,
                (v) => state.settings.timeLimitSeconds = v,
                enabled: !solving || _paused, // also sets how much "Add more time" adds
              ),
              if (!kIsWeb)
                _numberTile(
                  'Worker Threads',
                  state.settings.workers,
                  0,
                  (v) => state.settings.workers = v,
                  subtitle: '0 = main thread. Each worker keeps its own copy of the game data in memory.',
                  prefix: '',
                ),
              // recommended teams, same as Team Bond's setting
              ListTile(
                dense: true,
                title: Text(S.current.bond),
                trailing: TextButton(
                  onPressed: () => _editNumber(
                    title: '${S.current.bond}≤',
                    initial: state.settings.maxBond,
                    min: 0,
                    update: (v) => state.settings.maxBond = v,
                    hintText: '0 = ${S.current.general_any}',
                  ),
                  child: Text(
                    state.settings.maxBond <= 0 ? S.current.general_any : '≤${state.settings.maxBond}',
                  ),
                ),
              ),
              CheckboxListTile(
                dense: true,
                title: const Text('Support Ignores Bond Cap'),
                value: state.settings.supportIgnoresBondCap,
                onChanged: (v) => _changed(() => state.settings.supportIgnoresBondCap = v ?? false),
              ),
            ],
          ),
          // recommended teams never use these servants, same as Team Bond's list
          BondExcludedCards(
            title: '${S.current.exclude} - ${S.current.servant}',
            ids: state.settings.excludedSvts,
            servant: true,
            onAdd: () {
              router.pushPage(
                ServantListPage(
                  filterData: SvtFilterData(useGrid: true),
                  onSelected: (svt) {
                    if (mounted) _changed(() => state.settings.excludedSvts.add(svt.id));
                  },
                ),
              );
            },
            onRemove: (id) => _changed(() => state.settings.excludedSvts.remove(id)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: solving && _paused
                ? Column(
                    children: [
                      Text(
                        'No plan found within ${_solver?.timeLimitSeconds}s '
                        '($_simulations turns simulated). The search is paused where it stopped.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: () {
                              setState(() => _paused = false);
                              _solver?.addTime(state.settings.timeLimitSeconds);
                            },
                            icon: const Icon(Icons.more_time),
                            label: Text('Add more time (+${state.settings.timeLimitSeconds}s)'),
                          ),
                          TextButton(onPressed: () => _solver?.cancel(), child: const Text('Stop')),
                        ],
                      ),
                    ],
                  )
                : solving
                ? Column(
                    children: [
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(
                        _startingWorkers
                            ? 'Starting ${state.settings.workers} worker thread(s)… '
                                  'The first solve copies the game data, the app may pause briefly.'
                            : 'Simulated $_simulations turns · ${(_elapsedMs / 1000).toStringAsFixed(1)}s',
                        textAlign: TextAlign.center,
                      ),
                      TextButton(onPressed: () => _solver?.cancel(), child: Text(S.current.cancel)),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _recommendTeams,
                        icon: const Icon(Icons.groups),
                        label: const Text('Recommend Teams'),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _solve,
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Solve'),
                      ),
                    ],
                  ),
          ),
          if (state.result != null) _resultView(state.result!),
        ],
      ),
    );
  }

  Widget _numberTile(
    String title,
    int value,
    int min,
    void Function(int) update, {
    bool? enabled,
    String? subtitle,
    String prefix = '≤',
  }) {
    return ListTile(
      dense: true,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: TextButton(
        onPressed: (enabled ?? !solving)
            ? () => _editNumber(title: title, initial: value, min: min, update: update)
            : null,
        child: Text('$prefix$value'),
      ),
    );
  }

  Widget _mysticCodeTile() {
    final mcData = state.formation.mysticCodeData;
    final mc = mcData.mysticCode;
    return ListTile(
      dense: true,
      leading: mc?.iconBuilder(context: context, width: 36, jumpToDetail: false) ?? const Icon(Icons.block),
      title: Text(mc?.lName.l ?? S.current.select),
      onTap: () {
        router.pushPage(
          MysticCodeListPage(
            onSelected: (selected) => _changed(() {
              mcData
                ..mysticCode = selected
                ..level = db.curUser.mysticCodes[selected.id] ?? 10;
            }),
          ),
        );
      },
      trailing: mc == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => _editNumber(
                    title: '${S.current.mystic_code} Lv.',
                    initial: mcData.level,
                    min: 1,
                    update: (v) => mcData.level = v.clamp(1, 10),
                  ),
                  child: Text('Lv.${mcData.level}'),
                ),
                IconButton(
                  onPressed: () => _changed(() => mcData.mysticCode = null),
                  icon: const Icon(Icons.clear),
                  tooltip: S.current.clear,
                ),
              ],
            ),
    );
  }

  Widget _questPicker() {
    final quest = state.quest;
    return ListTile(
      dense: true,
      title: Text('${S.current.quest} ID'),
      subtitle: Text(quest?.lNameWithChapter ?? '—'),
      onTap: quest?.routeTo,
      trailing: TextButton(
        onPressed: solving
            ? null
            : () {
                InputCancelOkDialog.number(
                  title: 'Quest ID',
                  initValue: quest?.id,
                  validate: (v) => v > 0,
                  onSubmit: (v) => _loadQuest(v),
                ).showDialog(context);
              },
        child: Text(quest == null ? '0' : (quest.phases.length > 1 ? '${quest.id}/${quest.phase}' : '${quest.id}')),
      ),
    );
  }

  Future<void> _loadQuest(int questId) async {
    final quest = db.gameData.quests[questId] ?? await showEasyLoading(() => AtlasApi.quest(questId));
    if (!mounted) return;
    if (quest == null) {
      EasyLoading.showError(S.current.not_found);
      return;
    }
    int? phase;
    if (quest.phases.length == 1) {
      phase = quest.phases.single;
    } else {
      phase = await router.showDialog<int>(
        builder: (context) => SimpleDialog(
          title: const Text('Quest Phase'),
          children: [
            for (final phase in quest.phases)
              ListTile(
                enabled: !quest.phasesNoBattle.contains(phase),
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                onTap: () => Navigator.pop(context, phase),
                title: Text('phase $phase'),
              ),
          ],
        ),
      );
    }
    if (phase == null || !quest.phases.contains(phase)) return;
    final questPhase =
        db.gameData.getQuestPhase(quest.id, phase) ??
        await showEasyLoading(() => AtlasApi.questPhase(quest.id, phase!));
    if (!mounted) return;
    if (questPhase == null) {
      EasyLoading.showError(S.current.not_found);
      return;
    }
    _changed(() => state.quest = questPhase);
  }

  Widget _resultView(TeamGeneratorResult result) {
    final theme = Theme.of(context);
    final command = result.fgaCommand;

    return TileGroup(
      header: 'Plan',
      children: [
        ListTile(
          dense: true,
          leading: Icon(
            result.success ? Icons.check_circle : Icons.error_outline,
            color: result.success ? theme.colorScheme.primary : theme.colorScheme.error,
          ),
          title: Text(result.message),
          subtitle: Text(
            '${result.simulations} turns simulated · ${(result.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
            '${result.success ? ' · ${result.commandSpellsUsed} ${S.current.command_spell}' : ''}',
          ),
        ),
        for (final (index, turn) in result.turns.indexed)
          ListTile(
            dense: true,
            title: Text('${S.current.battle_turn} ${index + 1} · ${S.current.quest_wave} ${turn.wave}'),
            subtitle: Text(turn.steps.join('\n')),
          ),
        if (result.success && result.shareData != null) ...[
          ListTile(
            dense: true,
            title: const Text('FGA Command'),
            subtitle: SelectableText(command.isEmpty ? '(empty)' : command, style: kMonoStyle),
            trailing: IconButton(
              tooltip: S.current.copy,
              onPressed: command.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: command));
                      EasyLoading.showToast(S.current.copied);
                    },
              icon: const Icon(Icons.copy),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: FilledButton.tonalIcon(
                onPressed: () => _openInBattleSim(result),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Open in Battle Simulation'),
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _openInBattleSim(TeamGeneratorResult result) {
    final quest = state.resultQuest;
    final formation = state.resultFormation;
    final shareData = result.shareData;
    if (quest == null || formation == null || shareData == null) return;
    router.push(
      url: Routes.laplaceBattle,
      child: BattleSimulationPage(
        questPhase: quest,
        region: null,
        options: BattleOptions()..formation = formation.copy(),
        replayActions: shareData,
      ),
    );
  }
}
