import 'package:flutter_easyloading/flutter_easyloading.dart';

import 'package:chaldea/app/app.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/app/modules/common/filter_page_base.dart';
import 'package:chaldea/app/modules/common/filter_group.dart';
import 'package:chaldea/app/modules/common/misc.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';
import 'package:chaldea/widgets/widgets.dart';

import '../../craft_essence/filter.dart';
import '../../servant/filter.dart';
import '../simulation/battle_log.dart';
import '../simulation/recorder.dart';
import 'model.dart';

class TdDmgRankingTab extends StatefulWidget {
  final TdDmgSolver solver;
  final SvtFilterData svtFilterData;
  final VoidCallback? onOptionsChanged; // e.g. CE applied from Best CE, to refresh the options tab

  const TdDmgRankingTab({super.key, required this.solver, required this.svtFilterData, this.onOptionsChanged});

  @override
  State<TdDmgRankingTab> createState() => _TdDmgRankingTabState();
}

class _TdDmgRankingTabState extends State<TdDmgRankingTab> {
  _SortType _sortType = _SortType.damage;
  // filter for the Best Supports lists, independent of the damage dealer filter
  final supportFilterData = SvtFilterData();
  // filter for the Best CE lists
  final ceFilterData = CraftFilterData();

  final scrollController = ScrollController();

  @override
  void dispose() {
    super.dispose();
    scrollController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: listView),
        kDefaultDivider,
        SafeArea(
          child: OverflowBar(
            alignment: MainAxisAlignment.center,
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${S.current.sort_order}: '),
                  DropdownButton<_SortType>(
                    // https://github.com/flutter/flutter/issues/101575
                    // isDense: true,
                    value: _sortType,
                    items: [
                      for (final type in _SortType.values) DropdownMenuItem(value: type, child: Text(type.shownName)),
                    ],
                    onChanged: (v) {
                      setState(() {
                        if (v != null) _sortType = v;
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool filter(TdDmgResult result) {
    final filterData = widget.svtFilterData;
    if (!ServantFilterPage.filter(filterData, result.svt)) {
      return false;
    }

    final td = result.actor.playerSvtData?.td;
    if (filterData.tdCardType.isNotEmpty || filterData.tdType.isNotEmpty) {
      if (td == null) return false;
      if (!filterData.tdCardType.matchOne(td.svt.card)) {
        return false;
      }
      if (!filterData.tdType.matchOne(td.damageType)) {
        return false;
      }
    }

    return true;
  }

  Widget get listView {
    List<TdDmgResult> results = widget.solver.results.where(filter).toList();
    switch (_sortType) {
      case _SortType.damage:
        results.sortByList((e) => [e.hasInstantDeathSuccess ? 0 : 1, -e.totalDamage, -e.attackNp, -e.totalNp]);
        break;
      case _SortType.attackNp:
        results.sortByList((e) => [-e.attackNp, -e.totalNp, -e.totalDamage]);
        break;
      case _SortType.totalNp:
        results.sortByList((e) => [-e.totalNp, -e.attackNp, -e.totalDamage]);
        break;
      case _SortType.id:
        results.sort2((e) => e.svt.collectionNo);
        break;
    }
    return ListView.separated(
      controller: scrollController,
      itemCount: results.length + 1,
      separatorBuilder: (context, index) => kDefaultDivider,
      itemBuilder: (context, index) {
        if (index == 0) {
          final errors = widget.solver.errors;
          if (errors.isEmpty) return const SizedBox.shrink();
          return SimpleAccordion(
            headerBuilder: (context, _) => ListTile(
              dense: true,
              title: Text(
                '${errors.length} ${S.current.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            contentBuilder: (context) {
              return Card(
                child: Padding(padding: const EdgeInsets.all(8), child: Text(errors.join('\n\n'))),
              );
            },
          );
        }
        final rank = index;
        final result = results[index - 1];
        return SimpleAccordion(
          key: Key('Ranking_${index}_${result.svt.id}'),
          headerBuilder: (context, _) => headerBuilder(rank, result),
          contentBuilder: (context) => _ResultDetail(
            key: Key('ResultDetail_${index}_${_sortType}_${result.svt.id}'),
            solver: widget.solver,
            supportFilterData: supportFilterData,
            ceFilterData: ceFilterData,
            onOptionsChanged: widget.onOptionsChanged,
            result: result,
            tab: result.hasInstantDeathSuccess
                ? _ParamType.instantDeath
                : _sortType.isNp
                ? _ParamType.refund
                : _ParamType.damage,
          ),
        );
      },
    );
  }

  Widget headerBuilder(int rank, TdDmgResult result) {
    final dmgStr = result.totalDamage.format(groupSeparator: ",", compact: false);
    String npStr = '${S.current.np_refund_short} ${result.attackNp / 100}';
    if (result.attackNp != result.totalNp) {
      npStr += ' → ${result.totalNp / 100}';
    }
    String prefix = (_sortType == _SortType.id ? result.svt.collectionNo : rank).toString().padRight(2);
    List<Widget> cardIcons = [];
    int tdLv = result.originalSvtData.tdLv;
    int? oc;
    for (final record in result.attacks) {
      if (record is BattleAttackRecord && record.card != null) {
        cardIcons.add(CommandCardWidget(card: record.card!.cardType, width: 28));
        oc ??= record.card!.oc;
      } else if (record is BattleInstantDeathRecord) {
        cardIcons.add(db.getIconImage(AssetURL.i.buffIcon(record.hasSuccess ? 337 : 532), width: 20, height: 20));
        oc ??= record.card?.oc;
      }
    }
    cardIcons.add(
      Text(
        [' NP$tdLv', if (oc != null) ' OC$oc'].join('\n'),
        style: Theme.of(context).textTheme.bodySmall,
        textScaler: const TextScaler.linear(0.9),
      ),
    );
    return ListTile(
      dense: true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('$prefix ', style: kMonoStyle, textScaler: const TextScaler.linear(0.8)),
          result.svt.iconBuilder(
            context: context,
            width: 36,
            overrideIcon: result.svt.ascendIcon(result.originalSvtData.limitCount),
          ),
        ],
      ),
      // title: Text('${S.current.damage} $dmgStr'),
      title: Text(dmgStr),
      subtitle: Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(npStr)),
      contentPadding: const EdgeInsetsDirectional.only(start: 12),
      trailing: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: cardIcons,
      ),
    );
  }
}

class _ResultDetail extends StatefulWidget {
  final TdDmgSolver solver;
  final SvtFilterData supportFilterData;
  final CraftFilterData ceFilterData;
  final VoidCallback? onOptionsChanged;
  final TdDmgResult result;
  final _ParamType? tab;
  const _ResultDetail({
    super.key,
    required this.solver,
    required this.supportFilterData,
    required this.ceFilterData,
    this.onOptionsChanged,
    required this.result,
    this.tab,
  });

  @override
  State<_ResultDetail> createState() => _ResultDetailState();
}

class _ResultDetailState extends State<_ResultDetail> {
  _ParamType? _tab;

  @override
  Widget build(BuildContext context) {
    final tab = _tab ?? widget.tab ?? _ParamType.damage;

    List<Widget> children = [
      FilterGroup<_ParamType>(
        combined: true,
        options: widget.result.hasInstantDeath
            ? _ParamType.values
            : (_ParamType.values.toList()..remove(_ParamType.instantDeath)),
        values: FilterRadioData.nonnull(tab),
        optionBuilder: (v) => Text(v.shownName),
        onFilterChanged: (v, _) {
          setState(() {
            _tab = v.radioValue;
          });
        },
      ),
    ];

    if (tab == _ParamType.bestSupports) {
      children.add(
        _BestSupportsView(
          key: Key('BestSupports_${widget.result.hashCode}'),
          solver: widget.solver,
          filterData: widget.supportFilterData,
          onOptionsChanged: widget.onOptionsChanged,
          result: widget.result,
        ),
      );
      return Column(mainAxisSize: MainAxisSize.min, children: children);
    }
    if (tab == _ParamType.bestCE) {
      children.add(
        _BestCeView(
          key: Key('BestCE_${widget.result.hashCode}'),
          solver: widget.solver,
          filterData: widget.ceFilterData,
          onOptionsChanged: widget.onOptionsChanged,
          result: widget.result,
        ),
      );
      return Column(mainAxisSize: MainAxisSize.min, children: children);
    }
    if (tab == _ParamType.bestMC) {
      children.add(
        _BestMcView(
          key: Key('BestMC_${widget.result.hashCode}'),
          solver: widget.solver,
          onOptionsChanged: widget.onOptionsChanged,
          result: widget.result,
        ),
      );
      return Column(mainAxisSize: MainAxisSize.min, children: children);
    }

    for (final attack in widget.result.attacks) {
      Widget? paramsCard;
      if (attack is BattleAttackRecord) {
        final target = attack.targets.first;
        final baseInfo = AttackBaseInfo(actor: attack.attacker, target: target.target, card: attack.card);
        switch (tab) {
          case _ParamType.damage:
            paramsCard = DamageParamDialog(
              baseInfo,
              target.damageParams,
              target.result,
              wrapDialog: false,
              minResult: target.minResult,
              maxResult: target.maxResult,
            );
            break;
          case _ParamType.refund:
            paramsCard = AttackerNpParamDialog(
              baseInfo,
              target.attackNpParams,
              target.result,
              wrapDialog: false,
              minResult: target.minResult,
              maxResult: target.maxResult,
            );
            break;
          case _ParamType.star:
            paramsCard = StarParamDialog(
              baseInfo,
              target.starParams,
              target.result,
              wrapDialog: false,
              minResult: target.minResult,
              maxResult: target.maxResult,
            );
            break;
          case _ParamType.instantDeath:
          case _ParamType.bestSupports:
          case _ParamType.bestCE:
          case _ParamType.bestMC:
            break;
        }
      } else if (attack is BattleInstantDeathRecord) {
        if (tab == _ParamType.instantDeath) {
          paramsCard = InstantDeathParamDialog(
            AttackBaseInfo(actor: attack.activator, target: attack.targets.first.target, card: attack.card),
            attack.targets.first.params,
            wrapDialog: false,
          );
        }
      }
      if (paramsCard == null) continue;
      children.add(
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: paramsCard),
        ),
      );
    }
    children.add(
      TextButton(
        onPressed: () {
          router.pushPage(_BattleLogDetails(title: widget.result.svt.lName.l, battleData: widget.result.battleData));
        },
        child: Text(S.current.details),
      ),
    );
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _BestSupportsView extends StatefulWidget {
  final TdDmgSolver solver;
  final SvtFilterData filterData;
  final VoidCallback? onOptionsChanged;
  final TdDmgResult result;
  const _BestSupportsView({
    super.key,
    required this.solver,
    required this.filterData,
    this.onOptionsChanged,
    required this.result,
  });

  @override
  State<_BestSupportsView> createState() => _BestSupportsViewState();
}

class _BestSupportsViewState extends State<_BestSupportsView> {
  static const _kCollapsedCount = 20;
  bool _showAll = false;
  bool _calculating = false;

  @override
  void initState() {
    super.initState();
    if (widget.result.supportGains == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _calculate());
    }
  }

  Future<void> _calculate() async {
    if (_calculating || widget.solver.running.value) return;
    setState(() => _calculating = true);
    await widget.solver.calcBestSupports(widget.result);
    if (mounted) setState(() => _calculating = false);
  }

  String _fmt(int v) => v.format(groupSeparator: ",", compact: false);

  static const _kMaxSupports = 5; // same limit as the options tab

  void _addSupport(Servant svt) {
    final supports = widget.solver.options.supports;
    if (supports.length >= _kMaxSupports) {
      EasyLoading.showToast('Max $_kMaxSupports supports');
      return;
    }
    supports.add(svt.id);
    setState(() {});
    widget.onOptionsChanged?.call();
    EasyLoading.showToast(
      'Support added: ${svt.lName.l} (${supports.length}/$_kMaxSupports)'
      '\nPress ${S.current.calculate} to update the rankings.',
    );
  }

  void _showFilter() {
    FilterPage.show(
      context: context,
      builder: (context) => ServantFilterPage(
        filterData: widget.filterData,
        onChanged: (_) {
          if (mounted) setState(() {});
        },
        planMode: false,
        showSort: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gains = widget.result.supportGains;
    if (_calculating) {
      return const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator());
    }
    if (gains == null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: FilledButton(onPressed: _calculate, child: const Text('Calculate Best Supports')),
      );
    }
    final theme = Theme.of(context);
    final baseDamage = widget.result.supportBaseDamage ?? widget.result.totalDamage;
    final filterData = widget.filterData;
    final filterActive = filterData.groups.any((g) => !g.isEmpty);
    final filtered = gains.where((e) => ServantFilterPage.filter(filterData, e.support)).toList();
    final positive = filtered.where((e) => e.gain > 0).toList();
    final shown = _showAll ? positive : positive.take(_kCollapsedCount).toList();

    List<Widget> children = [
      ListTile(
        dense: true,
        title: Text('Baseline ${S.current.damage}: ${_fmt(baseDamage)}'),
        subtitle: Text(
          'Each servant added as an extra support (skills used in order 1→2→3) on top of current options. '
          '${filtered.length - positive.length} servants gave no increase.'
          '${filterActive ? '\nFiltered: ${filtered.length} / ${gains.length} servants shown.' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: S.current.filter,
              onPressed: _showFilter,
              icon: Icon(Icons.filter_alt, color: filterActive ? theme.colorScheme.primary : null),
            ),
            IconButton(tooltip: 'Recalculate', onPressed: _calculate, icon: const Icon(Icons.refresh)),
          ],
        ),
      ),
    ];
    if (positive.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(filterActive ? 'No filtered support increases damage.' : 'No support increases damage.'),
        ),
      );
    }
    for (final (index, gain) in shown.indexed) {
      final percent = baseDamage > 0 ? gain.gain / baseDamage * 100 : 0.0;
      children.add(
        ListTile(
          dense: true,
          contentPadding: const EdgeInsetsDirectional.only(start: 12, end: 12),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${(index + 1).toString().padRight(2)} ', style: kMonoStyle, textScaler: const TextScaler.linear(0.8)),
              gain.support.iconBuilder(context: context, width: 32),
            ],
          ),
          title: Text(gain.support.lName.l, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${S.current.damage} ${_fmt(gain.damage)}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '+${_fmt(gain.gain)}\n+${percent.toStringAsFixed(1)}%',
                textAlign: TextAlign.end,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
              ),
              Builder(
                builder: (context) {
                  final supports = widget.solver.options.supports;
                  final count = supports.where((id) => id == gain.support.id).length;
                  final full = supports.length >= _kMaxSupports;
                  return IconButton(
                    tooltip: full
                        ? 'Max $_kMaxSupports supports'
                        : count > 0
                        ? 'Already added ($count). Add another'
                        : 'Add as support',
                    onPressed: full ? null : () => _addSupport(gain.support),
                    icon: Icon(count > 0 ? Icons.add_circle : Icons.add_circle_outline),
                    color: theme.colorScheme.primary,
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ],
          ),
        ),
      );
    }
    if (positive.length > _kCollapsedCount) {
      children.add(
        TextButton(
          onPressed: () => setState(() => _showAll = !_showAll),
          child: Text(_showAll ? 'Show top $_kCollapsedCount' : 'Show all (${positive.length})'),
        ),
      );
    }
    final errors = widget.result.supportErrors;
    if (errors.isNotEmpty) {
      children.add(
        SimpleAccordion(
          headerBuilder: (context, _) => ListTile(
            dense: true,
            title: Text('${errors.length} ${S.current.error}', style: TextStyle(color: theme.colorScheme.error)),
          ),
          contentBuilder: (context) => Padding(padding: const EdgeInsets.all(8), child: Text(errors.join('\n\n'))),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _BestCeView extends StatefulWidget {
  final TdDmgSolver solver;
  final CraftFilterData filterData;
  final VoidCallback? onOptionsChanged;
  final TdDmgResult result;
  const _BestCeView({
    super.key,
    required this.solver,
    required this.filterData,
    this.onOptionsChanged,
    required this.result,
  });

  @override
  State<_BestCeView> createState() => _BestCeViewState();
}

class _BestCeViewState extends State<_BestCeView> {
  static const _kCollapsedCount = 20;
  bool _showAll = false;
  bool _calculating = false;

  @override
  void initState() {
    super.initState();
    if (widget.result.ceGains == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _calculate());
    }
  }

  Future<void> _calculate() async {
    if (_calculating || widget.solver.running.value) return;
    setState(() => _calculating = true);
    await widget.solver.calcBestCEs(widget.result);
    if (mounted) setState(() => _calculating = false);
  }

  String _fmt(int v) => v.format(groupSeparator: ",", compact: false);

  bool _isSelectedInOptions(TdCeGain gain) {
    final options = widget.solver.options;
    if (gain.ce == null) return options.ceId == null || db.gameData.craftEssencesById[options.ceId] == null;
    return options.ceId == gain.ce!.id && options.ceLv == gain.lv && options.ceMLB == gain.limitBreak;
  }

  void _applyCe(TdCeGain gain) {
    final options = widget.solver.options;
    final ce = gain.ce;
    if (ce == null) {
      options.ceId = null;
    } else {
      options
        ..ceId = ce.id
        ..ceLv = gain.lv.clamp(0, ce.lvMax)
        ..ceMLB = gain.limitBreak;
    }
    setState(() {});
    widget.onOptionsChanged?.call();
    EasyLoading.showToast(
      '${S.current.craft_essence}: ${ce == null ? 'None' : '${ce.lName.l} Lv.${gain.lv}${gain.limitBreak ? ' MLB' : ''}'}'
      '\nPress ${S.current.calculate} to update the rankings.',
    );
  }

  void _showFilter() {
    FilterPage.show(
      context: context,
      builder: (context) => CraftFilterPage(
        filterData: widget.filterData,
        onChanged: (_) {
          if (mounted) setState(() {});
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gains = widget.result.ceGains;
    if (_calculating) {
      return const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator());
    }
    if (gains == null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: FilledButton(onPressed: _calculate, child: const Text('Calculate Best CE')),
      );
    }
    final theme = Theme.of(context);
    final result = widget.result;
    final currentCe = db.gameData.craftEssencesById[result.ceBaseCeId];
    final baseDamage = result.ceBaseDamage ?? result.totalDamage;
    final filterData = widget.filterData;
    final filterActive = filterData.groups.any((g) => !g.isEmpty);
    // "No CE" row is always kept
    final filtered = gains.where((e) => e.ce == null || CraftFilterPage.filter(filterData, e.ce!)).toList();
    final shown = _showAll ? filtered : filtered.take(_kCollapsedCount).toList();
    final ownedCount = gains.where((e) => e.ce != null).length;
    final filteredCount = filtered.where((e) => e.ce != null).length;

    List<Widget> children = [
      ListTile(
        dense: true,
        title: Text('Baseline ${S.current.damage}: ${_fmt(baseDamage)}'),
        subtitle: Text(
          (currentCe == null
                  ? 'No CE selected. Each owned CE ($ownedCount) equipped at your level and limit break.'
                  : 'Current CE: ${currentCe.lName.l} (Lv.${result.ceBaseLv}${result.ceBaseMLB ? ' MLB' : ''}). '
                        'Numbers show replacing it with each owned CE ($ownedCount) at your level and limit break.') +
              (filterActive ? '\nFiltered: $filteredCount / $ownedCount CEs shown.' : ''),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: S.current.filter,
              onPressed: _showFilter,
              icon: Icon(Icons.filter_alt, color: filterActive ? theme.colorScheme.primary : null),
            ),
            IconButton(tooltip: 'Recalculate', onPressed: _calculate, icon: const Icon(Icons.refresh)),
          ],
        ),
      ),
    ];
    if (ownedCount == 0) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('No owned craft essences. Mark CEs as owned (with level and limit break) in the CE pages.'),
        ),
      );
    } else if (filteredCount == 0) {
      children.add(const Padding(padding: EdgeInsets.all(8), child: Text('No owned CE matches the filter.')));
    }
    for (final (index, gain) in shown.indexed) {
      final ce = gain.ce;
      final percent = baseDamage > 0 ? gain.gain / baseDamage * 100 : 0.0;
      final sign = gain.gain >= 0 ? '+' : '';
      final color = gain.gain > 0
          ? theme.colorScheme.primary
          : gain.gain < 0
          ? theme.colorScheme.error
          : theme.disabledColor;
      children.add(
        ListTile(
          dense: true,
          selected: gain.isCurrent,
          contentPadding: const EdgeInsetsDirectional.only(start: 12, end: 12),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${(index + 1).toString().padRight(2)} ', style: kMonoStyle, textScaler: const TextScaler.linear(0.8)),
              ce == null
                  ? const SizedBox(width: 32, height: 32, child: Icon(Icons.block))
                  : ce.iconBuilder(context: context, width: 32),
            ],
          ),
          title: Text(
            ce == null ? 'No CE' : ce.lName.l + (gain.isCurrent ? ' (current)' : ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              if (ce != null) 'Lv.${gain.lv}${gain.limitBreak ? ' MLB' : ''}',
              '${S.current.damage} ${_fmt(gain.damage)}',
            ].join('  '),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$sign${_fmt(gain.gain)}\n$sign${percent.toStringAsFixed(1)}%',
                textAlign: TextAlign.end,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
              Builder(
                builder: (context) {
                  final selected = _isSelectedInOptions(gain);
                  return IconButton(
                    tooltip: selected ? 'Selected in options' : 'Use this CE',
                    onPressed: selected ? null : () => _applyCe(gain),
                    icon: Icon(selected ? Icons.check_circle : Icons.add_circle_outline),
                    color: theme.colorScheme.primary,
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ],
          ),
        ),
      );
    }
    if (filtered.length > _kCollapsedCount) {
      children.add(
        TextButton(
          onPressed: () => setState(() => _showAll = !_showAll),
          child: Text(_showAll ? 'Show top $_kCollapsedCount' : 'Show all (${filtered.length})'),
        ),
      );
    }
    final errors = widget.result.ceErrors;
    if (errors.isNotEmpty) {
      children.add(
        SimpleAccordion(
          headerBuilder: (context, _) => ListTile(
            dense: true,
            title: Text('${errors.length} ${S.current.error}', style: TextStyle(color: theme.colorScheme.error)),
          ),
          contentBuilder: (context) => Padding(padding: const EdgeInsets.all(8), child: Text(errors.join('\n\n'))),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _BestMcView extends StatefulWidget {
  final TdDmgSolver solver;
  final VoidCallback? onOptionsChanged;
  final TdDmgResult result;
  const _BestMcView({super.key, required this.solver, this.onOptionsChanged, required this.result});

  @override
  State<_BestMcView> createState() => _BestMcViewState();
}

class _BestMcViewState extends State<_BestMcView> {
  static const _kCollapsedCount = 20;
  bool _showAll = false;
  bool _calculating = false;

  @override
  void initState() {
    super.initState();
    if (widget.result.mcGains == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _calculate());
    }
  }

  Future<void> _calculate() async {
    if (_calculating || widget.solver.running.value) return;
    setState(() => _calculating = true);
    await widget.solver.calcBestMCs(widget.result);
    if (mounted) setState(() => _calculating = false);
  }

  String _fmt(int v) => v.format(groupSeparator: ",", compact: false);

  bool _isSelectedInOptions(TdMcGain gain) {
    final options = widget.solver.options;
    if (gain.mc == null) return db.gameData.mysticCodes[options.mcId] == null;
    return options.mcId == gain.mc!.id && options.mcLv == gain.lv;
  }

  void _applyMc(TdMcGain gain) {
    final options = widget.solver.options;
    final mc = gain.mc;
    if (mc == null) {
      options.mcId = null;
    } else {
      options
        ..mcId = mc.id
        ..mcLv = gain.lv;
    }
    setState(() {});
    widget.onOptionsChanged?.call();
    EasyLoading.showToast(
      '${S.current.mystic_code}: ${mc == null ? 'None' : '${mc.lName.l} Lv.${gain.lv}'}'
      '\nPress ${S.current.calculate} to update the rankings.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final gains = widget.result.mcGains;
    if (_calculating) {
      return const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator());
    }
    if (gains == null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: FilledButton(onPressed: _calculate, child: const Text('Calculate Best MC')),
      );
    }
    final theme = Theme.of(context);
    final result = widget.result;
    final currentMc = db.gameData.mysticCodes[result.mcBaseMcId];
    final baseDamage = result.mcBaseDamage ?? result.totalDamage;
    final shown = _showAll ? gains : gains.take(_kCollapsedCount).toList();
    final mcCount = gains.where((e) => e.mc != null).length;

    List<Widget> children = [
      ListTile(
        dense: true,
        title: Text('Baseline ${S.current.damage}: ${_fmt(baseDamage)}'),
        subtitle: Text(
          currentMc == null
              ? 'No Mystic Code selected. Each Mystic Code ($mcCount) used at your level (Lv.10 if not recorded).'
              : 'Current: ${currentMc.lName.l} (Lv.${result.mcBaseLv}). Numbers show replacing it with each '
                    'Mystic Code ($mcCount) at your level (Lv.10 if not recorded).',
        ),
        trailing: IconButton(tooltip: 'Recalculate', onPressed: _calculate, icon: const Icon(Icons.refresh)),
      ),
    ];
    for (final (index, gain) in shown.indexed) {
      final mc = gain.mc;
      final percent = baseDamage > 0 ? gain.gain / baseDamage * 100 : 0.0;
      final sign = gain.gain >= 0 ? '+' : '';
      final color = gain.gain > 0
          ? theme.colorScheme.primary
          : gain.gain < 0
          ? theme.colorScheme.error
          : theme.disabledColor;
      final selected = _isSelectedInOptions(gain);
      children.add(
        ListTile(
          dense: true,
          selected: gain.isCurrent,
          contentPadding: const EdgeInsetsDirectional.only(start: 12, end: 4),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${(index + 1).toString().padRight(2)} ', style: kMonoStyle, textScaler: const TextScaler.linear(0.8)),
              mc == null
                  ? const SizedBox(width: 32, height: 32, child: Icon(Icons.block))
                  : mc.iconBuilder(context: context, width: 32),
            ],
          ),
          title: Text(
            mc == null ? 'No Mystic Code' : mc.lName.l + (gain.isCurrent ? ' (current)' : ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [if (mc != null) 'Lv.${gain.lv}', '${S.current.damage} ${_fmt(gain.damage)}'].join('  '),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$sign${_fmt(gain.gain)}\n$sign${percent.toStringAsFixed(1)}%',
                textAlign: TextAlign.end,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
              IconButton(
                tooltip: selected ? 'Selected in options' : 'Use this Mystic Code',
                onPressed: selected ? null : () => _applyMc(gain),
                icon: Icon(selected ? Icons.check_circle : Icons.add_circle_outline),
                color: theme.colorScheme.primary,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      );
    }
    if (gains.length > _kCollapsedCount) {
      children.add(
        TextButton(
          onPressed: () => setState(() => _showAll = !_showAll),
          child: Text(_showAll ? 'Show top $_kCollapsedCount' : 'Show all (${gains.length})'),
        ),
      );
    }
    final errors = result.mcErrors;
    if (errors.isNotEmpty) {
      children.add(
        SimpleAccordion(
          headerBuilder: (context, _) => ListTile(
            dense: true,
            title: Text('${errors.length} ${S.current.error}', style: TextStyle(color: theme.colorScheme.error)),
          ),
          contentBuilder: (context) => Padding(padding: const EdgeInsets.all(8), child: Text(errors.join('\n\n'))),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _BattleLogDetails extends StatelessWidget {
  final String title;
  final BattleData battleData;
  const _BattleLogDetails({required this.title, required this.battleData});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            onPressed: () {
              router.pushPage(BattleLogPage(logger: battleData.battleLogger));
            },
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: SingleChildScrollView(child: BattleRecorderPanel(records: battleData.recorder.records.toList())),
    );
  }
}

enum _SortType {
  damage,
  attackNp,
  totalNp,
  id;

  bool get isNp => this == _SortType.attackNp || this == _SortType.totalNp;

  String get shownName {
    switch (this) {
      case _SortType.damage:
        return S.current.damage;
      case _SortType.attackNp:
        return S.current.np_refund;
      case _SortType.totalNp:
        return S.current.total_np;
      case _SortType.id:
        return 'ID';
    }
  }
}

enum _ParamType {
  damage,
  refund,
  star,
  bestSupports,
  bestCE,
  bestMC,
  instantDeath;

  String get shownName {
    switch (this) {
      case _ParamType.damage:
        return S.current.damage;
      case _ParamType.refund:
        return S.current.np_refund_short;
      case _ParamType.star:
        return S.current.critical_star;
      case _ParamType.bestSupports:
        return 'Best Supports';
      case _ParamType.bestCE:
        return 'Best CE';
      case _ParamType.bestMC:
        return 'Best MC';
      case _ParamType.instantDeath:
        return S.current.instant_death;
    }
  }
}
