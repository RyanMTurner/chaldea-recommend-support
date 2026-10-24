import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/battle/utils/battle_logger.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/utils.dart';
import 'package:chaldea/widgets/widgets.dart';

/// Converts battle records into a Fate Grand Automata (FGA) auto skill command.
///
/// Syntax (from FGA's AutoSkillCommand parser):
/// - servant skills: `a b c` (field slot 1), `d e f` (slot 2), `g h i` (slot 3)
/// - master skills: `j k l`
/// - single ally target: `1 2 3` directly after the skill
/// - skill choices (e.g. Kukulkan): `[Ch2A]`/`[Ch2B]` or `[Ch3A]`/`[Ch3B]`/`[Ch3C]`;
///   combined with an ally target as a multi-target group, choice first: `b([Ch2A]1)`
/// - NP: `4 5 6` for field slot 1/2/3
/// - order change: `x` + starting member (1-3) + sub member (1-3), replaces the mystic code skill itself
/// - command spell (NP charge): `o` + target
/// - next turn: `,`  next wave: `,#,`
class FgaCommandExporter {
  final List<BattleRecord> records;
  final List<String> warnings = [];

  FgaCommandExporter(this.records);

  static const _servantSkillCodes = 'abcdefghi';
  static const _masterSkillCodes = 'jkl';

  static const _singleAllyTargetTypes = {
    FuncTargetType.ptOne,
    FuncTargetType.ptOneOther,
    FuncTargetType.playerAttackPreselectTargetPtOne,
  };

  String export() {
    warnings.clear();
    final buffer = StringBuffer();
    bool waveStarted = false;
    bool firstTurnInWave = true;
    final Set<int> skipIndices = {};

    for (int index = 0; index < records.length; index++) {
      if (skipIndices.contains(index)) continue;
      final record = records[index];

      if (record is BattleProgressWaveRecord) {
        if (waveStarted) buffer.write(',#,');
        waveStarted = true;
        firstTurnInWave = true;
      } else if (record is BattleSkipWaveRecord) {
        warnings.add('Wave ${record.wave} was skipped in the simulator. FGA cannot skip waves.');
      } else if (record is BattleProgressTurnRecord) {
        if (firstTurnInWave) {
          firstTurnInWave = false;
        } else {
          buffer.write(',');
        }
      } else if (record is BattleOrderChangeRecord) {
        // the order change record is added before the skill record that caused it
        final sourceIndex = _findNextSkillRecord(index);
        final source = sourceIndex == null ? null : records[sourceIndex] as BattleSkillRecord;
        if (source != null && source.skill.type == SkillInfoType.masterEquip) {
          // FGA's `x` uses the mystic code skill itself, so don't output the skill letter too
          skipIndices.add(sourceIndex!);
          final starting = record.onField.fieldIndex + 1;
          final sub = record.backup.fieldIndex - 3 + 1;
          if (starting < 1 || starting > 3 || sub < 1 || sub > 3) {
            warnings.add('Order Change: unexpected positions ($starting ⇄ ${record.backup.fieldIndex + 1}), skipped.');
          } else {
            buffer.write('x$starting$sub');
          }
        } else {
          warnings.add(
            'Order Change caused by a servant skill (${record.onField.lBattleName} ⇄ ${record.backup.lBattleName}). '
            'FGA can only order change through the mystic code, so the swap selection is not included.',
          );
        }
      } else if (record is BattleSkillRecord) {
        buffer.write(_convertSkill(record));
      } else if (record is BattleAttacksInitiationRecord) {
        buffer.write(_convertAttacks(record));
      }
    }

    // trailing separators carry no actions
    return buffer.toString().replaceFirst(RegExp(r'[,#]+$'), '');
  }

  String _convertAttacks(BattleAttacksInitiationRecord record) {
    final buffer = StringBuffer();
    int cardsBeforeFirstNp = 0;
    bool npFound = false;
    for (final attack in record.attacks) {
      if (attack.actor.isEnemy) continue;
      if (!attack.cardData.isTD) {
        if (!npFound) cardsBeforeFirstNp += 1;
        continue;
      }
      npFound = true;
      final pos = attack.actor.fieldIndex;
      if (pos < 0 || pos > 2) {
        warnings.add('${attack.actor.lBattleName} NP: unexpected position ${pos + 1}, skipped.');
        continue;
      }
      buffer.write('${pos + 4}');
    }
    if (npFound && cardsBeforeFirstNp > 0) {
      warnings.add(
        '$cardsBeforeFirstNp face card(s) were played before an NP. Cards are not exported, '
        'so FGA will play the NP first unless you add n$cardsBeforeFirstNp before it.',
      );
    }
    return buffer.toString();
  }

  int? _findNextSkillRecord(int start) {
    for (int index = start + 1; index < records.length; index++) {
      final record = records[index];
      if (record is BattleSkillRecord) return index;
      if (record is BattleProgressTurnRecord || record is BattleProgressWaveRecord) return null;
    }
    return null;
  }

  String _convertSkill(BattleSkillRecord record) {
    if (!record.fromPlayer) return '';
    final skillInfo = record.skill;
    final skill = skillInfo.skill;
    switch (skillInfo.type) {
      case SkillInfoType.svtSelf:
        final actor = record.activator;
        if (actor == null || actor.isEnemy) return '';
        final pos = actor.fieldIndex;
        final num = skillInfo.skillNum;
        if (pos < 0 || pos > 2 || num < 1 || num > 3) {
          warnings.add('${actor.lBattleName} Skill $num: unexpected position ${pos + 1}, skipped.');
          return '';
        }
        return _servantSkillCodes[pos * 3 + num - 1] + _targets(record, skill);
      case SkillInfoType.masterEquip:
        final num = skillInfo.skillNum;
        if (num < 1 || num > 3) return '';
        return _masterSkillCodes[num - 1] + _targets(record, skill);
      case SkillInfoType.commandSpell:
        if (skill?.id == CommonCustomSkills.csRepairNp.id) {
          final target = record.targetPlayerSvt?.fieldIndex;
          if (target == null || target < 0 || target > 2) {
            warnings.add('${S.current.command_spell}: unknown target, skipped.');
            return '';
          }
          return 'o${target + 1}';
        }
        warnings.add(
          '${S.current.command_spell} "${skillInfo.lName}" is not supported by FGA (only NP charge), skipped.',
        );
        return '';
      default:
        return '';
    }
  }

  /// Target suffix after the skill letter: choice option and/or single ally target.
  String _targets(BattleSkillRecord record, BaseSkill? skill) {
    final choice = _choice(record, skill);
    final ally = _allyTarget(record, skill);
    if (choice.isNotEmpty && ally.isNotEmpty) return '($choice$ally)';
    return choice + ally;
  }

  /// FGA special target for skills with options (Kukulkan, UKD-Barghest, etc.)
  String _choice(BattleSkillRecord record, BaseSkill? skill) {
    final index = record.param.selectAddIndex;
    if (index == null) return '';
    int? count = skill?.script?.SelectAddInfo?.getOrNull(record.skill.skillLv - 1)?.btn.length;
    count ??= index < 2 ? 2 : 3;
    const letters = 'ABC';
    if ((count != 2 && count != 3) || index < 0 || index >= count) {
      warnings.add('${skillInfo(record)}: option ${index + 1} of $count is not supported by FGA, skipped.');
      return '';
    }
    return '[Ch$count${letters[index]}]';
  }

  /// Target number, only when the skill targets a single ally.
  String _allyTarget(BattleSkillRecord record, BaseSkill? skill) {
    if (skill == null) return '';
    bool singleAlly = skill.script?.condBranchSkillInfo?.isNotEmpty == true;
    if (!singleAlly) {
      for (final func in skill.functions) {
        if (func.funcTargetTeam == FuncApplyTarget.enemy) continue;
        if (_singleAllyTargetTypes.contains(func.funcTargetType)) {
          singleAlly = true;
          break;
        }
      }
    }
    if (!singleAlly) return '';
    final target = record.targetPlayerSvt?.fieldIndex;
    if (target == null || target < 0 || target > 2) {
      warnings.add('${skillInfo(record)}: unknown ally target.');
      return '';
    }
    return '${target + 1}';
  }

  String skillInfo(BattleSkillRecord record) {
    return '${record.activator?.lBattleName ?? S.current.mystic_code} ${S.current.skill} ${record.skill.skillNum}';
  }
}

class FgaCommandDialog extends StatelessWidget {
  final List<BattleRecord> records;
  const FgaCommandDialog({super.key, required this.records});

  @override
  Widget build(BuildContext context) {
    final exporter = FgaCommandExporter(records);
    final command = exporter.export();
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('FGA Command'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(command.isEmpty ? '(empty)' : command, style: kMonoStyle),
          ),
          if (exporter.warnings.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final warning in exporter.warnings)
              Text('• $warning', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(S.current.cancel)),
        FilledButton.icon(
          onPressed: command.isEmpty
              ? null
              : () {
                  copyToClipboard(command, toast: true);
                  Navigator.pop(context);
                },
          icon: const Icon(Icons.copy),
          label: Text(S.current.copy),
        ),
      ],
    );
  }
}
