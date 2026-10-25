import 'package:flutter/services.dart';

import 'package:flutter_easyloading/flutter_easyloading.dart';

import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/app/app.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/logger.dart';
import 'package:chaldea/utils/utils.dart';
import 'package:chaldea/widgets/widgets.dart';

import '../../mystic_code/mystic_code_list.dart';
import '../battle_simulation.dart';
import '../formation/team.dart';
import '../simulation/fga_export.dart';
import 'solver.dart';

/// Kept while the app runs, so leaving and reopening the page keeps the setup and last result.
class _TeamGeneratorState {
  QuestPhase? quest;
  final BattleTeamSetup formation = BattleTeamSetup(mysticCodeData: MysticCodeData()..mysticCode = null);
  final TeamGeneratorSettings settings = TeamGeneratorSettings();
  TeamGeneratorResult? result;
  QuestPhase? resultQuest;
  BattleTeamSetup? resultFormation;
}

class TeamGeneratorPage extends StatefulWidget {
  const TeamGeneratorPage({super.key});

  static final _state = _TeamGeneratorState();

  @override
  State<TeamGeneratorPage> createState() => _TeamGeneratorPageState();
}

class _TeamGeneratorPageState extends State<TeamGeneratorPage> {
  _TeamGeneratorState get state => TeamGeneratorPage._state;
  TeamGeneratorSolver? _solver;
  int _simulations = 0;
  int _elapsedMs = 0;

  bool get solving => _solver != null;

  @override
  void dispose() {
    _solver?.cancel();
    super.dispose();
  }

  void _changed(VoidCallback change) {
    setState(() {
      change();
      state.result = null;
    });
  }

  void _editNumber({required String title, required int initial, required int min, required void Function(int) update}) {
    InputCancelOkDialog.number(
      title: title,
      initValue: initial,
      validate: (v) => v >= min,
      onSubmit: (v) => _changed(() => update(v)),
    ).showDialog(context);
  }

  Future<void> _solve() async {
    final quest = state.quest;
    if (quest == null) {
      EasyLoading.showError('Select a quest first');
      return;
    }
    final formation = state.formation.copy();
    final solver = TeamGeneratorSolver(
      quest: quest,
      formation: formation,
      settings: state.settings,
      onProgress: (simulations, elapsed) {
        if (mounted) {
          setState(() {
            _simulations = simulations;
            _elapsedMs = elapsed;
          });
        }
      },
    );
    setState(() {
      _solver = solver;
      _simulations = 0;
      _elapsedMs = 0;
      state.result = null;
    });
    TeamGeneratorResult result;
    try {
      result = await solver.solve();
    } catch (e, s) {
      logger.e('team generator failed', e, s);
      result = TeamGeneratorResult(success: false, message: 'Error: $e', simulations: 0, elapsedMilliseconds: 0);
    }
    if (!mounted) return;
    setState(() {
      _solver = null;
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
              _numberTile('Maximum Turns', state.settings.maxTurns, 1, (v) => state.settings.maxTurns = v),
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
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: solving
                ? Column(
                    children: [
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text('Simulated $_simulations turns · ${(_elapsedMs / 1000).toStringAsFixed(1)}s'),
                      TextButton(onPressed: () => _solver?.cancel(), child: Text(S.current.cancel)),
                    ],
                  )
                : FilledButton.icon(
                    onPressed: _solve,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Solve'),
                  ),
          ),
          if (state.result != null) _resultView(state.result!),
        ],
      ),
    );
  }

  Widget _numberTile(String title, int value, int min, void Function(int) update) {
    return ListTile(
      dense: true,
      title: Text(title),
      trailing: TextButton(
        onPressed: solving ? null : () => _editNumber(title: title, initial: value, min: min, update: update),
        child: Text('≤$value'),
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
      subtitle: mc == null ? null : const Text('Order Change skills are not used yet'),
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
        db.gameData.getQuestPhase(quest.id, phase) ?? await showEasyLoading(() => AtlasApi.questPhase(quest.id, phase!));
    if (!mounted) return;
    if (questPhase == null) {
      EasyLoading.showError(S.current.not_found);
      return;
    }
    _changed(() => state.quest = questPhase);
  }

  Widget _resultView(TeamGeneratorResult result) {
    final theme = Theme.of(context);
    final battle = result.battle;
    final command = battle == null ? '' : FgaCommandExporter(battle.recorder.records).export();
    final formation = state.resultFormation;
    String svtName(int slot) => formation?.svts.getOrNull(slot)?.svt?.lName.l ?? 'Slot ${slot + 1}';

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
            subtitle: Text(
              [
                for (final (skill, target) in turn.skills)
                  '${skill.isMysticCode ? skill.name : '${svtName(skill.slot!)} S${skill.skillIndex + 1}'}'
                      '${target == null ? '' : ' → ${svtName(target)}'}',
                for (final target in turn.commandSpellTargets) '${S.current.command_spell} → ${svtName(target)}',
                turn.npSlots.isEmpty
                    ? 'No NP (charge turn)'
                    : 'NP: ${turn.npSlots.map(svtName).join(', ')}',
              ].join('\n'),
            ),
          ),
        if (result.success && battle != null) ...[
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
    final battle = result.battle;
    if (quest == null || formation == null || battle == null) return;
    router.push(
      url: Routes.laplaceBattle,
      child: BattleSimulationPage(
        questPhase: quest,
        region: null,
        options: BattleOptions()..formation = formation.copy(),
        replayActions: TeamGeneratorSolver.toShareData(quest, formation, battle),
      ),
    );
  }
}
