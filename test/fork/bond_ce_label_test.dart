// Fork feature test:
//  10. Team Bond Results: CE label shows the extra bond it adds and how many party members it affects
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/user.dart';
import 'package:chaldea/app/modules/bond/bond_rules.dart';
import 'package:chaldea/app/modules/bond/formation_bond_calc.dart';
import 'package:chaldea/app/modules/bond/solver/bond_effect.dart';
import 'package:chaldea/app/modules/bond/solver/results.dart';
import 'package:chaldea/app/modules/bond/solver/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() {
  setUpAll(initiateForTest);

  test('party bond CE counts every member, self bond CE counts its wearer, supports excluded', () {
    final quest = QuestPhase(bond: 1000);

    /// a CE whose bond effects are all unconditional and of [scope]
    CraftEssence findCe(BondEffectScope scope) => db.gameData.craftEssencesById.values.firstWhere((ce) {
      if (ce.collectionNo <= 0 || ce.id == kHeroicSpiritPortraitDariusCeId) return false;
      final effects = CeBondEffect.extractAll(ce, true, quest, support: false);
      return effects.isNotEmpty && effects.every((e) => e.isFlat && e.scope == scope);
    });
    final partyCe = findCe(BondEffectScope.team);
    final selfCe = findCe(BondEffectScope.self);

    final servants = db.gameData.servantsById.values
        .where((svt) => svt.collectionNo > 0 && svt.isUserSvt)
        .take(4)
        .toList();
    final source = BattleTeamSetup();
    for (var p = 0; p < 4; p++) {
      source.svts[p] = PlayerSvtData.svt(servants[p]);
    }
    source.svts[2].supportType = SupportSvtType.friend;

    BondSolvedSlot slot(int position, {CraftEssence? ce, bool support = false}) => BondSolvedSlot(
      position: position,
      servantId: support ? null : servants[position].id,
      limitCount: 4,
      equip1: ce == null ? null : BondSolvedCe(ce.id, true),
      equip3: null,
      isSupport: support,
      fixedServant: true,
      bond: 0,
      cost: 0,
      servantCandidates: const [],
      equip1Candidates: const [],
      equip3Candidates: const [],
    );
    final team = BondSolvedTeam(0, 0, [
      slot(0, ce: partyCe),
      slot(1, ce: selfCe),
      slot(2, support: true),
      slot(3),
    ]);

    final option = FormationBondOption(
      maxServants: 6,
      enableEvent: false,
      searchFixedAscensions: false,
      maxCost: 999,
      maxCandidateTeams: 5,
    )..validate(quest);
    final tab = BondSolverResultsTab(
      solved: null,
      formation: source,
      option: option,
      quest: quest,
      runState: BondSolverRunState.idle,
      error: null,
      onCancel: null,
    );

    final contributions = tab.ceBondContributions(team);
    expect(contributions.keys.toSet(), {(0, SvtEquipTarget.normal), (1, SvtEquipTarget.normal)});

    final (partyBond, partyCount) = contributions[(0, SvtEquipTarget.normal)]!;
    expect(partyCount, 3, reason: 'positions 0, 1, 3; the support at 2 earns no bond');
    expect(partyBond, greaterThan(0));

    final (selfBond, selfCount) = contributions[(1, SvtEquipTarget.normal)]!;
    expect(selfCount, 1);
    expect(selfBond, greaterThan(0));

    // the label's numbers add up to the team total minus a team without CEs
    final applied = team.applyTo(source, FormationBondOption.fromJson(option.toJson()));
    int teamTotal(BattleTeamSetup setup) => option
        .calcResults(quest, setup)
        .indexed
        .where((e) => const [0, 1, 3].contains(e.$1))
        .fold(0, (sum, e) => sum + e.$2.totalBond);
    final withCes = teamTotal(applied);
    applied.svts[0].equip1.ce = null;
    applied.svts[1].equip1.ce = null;
    final withoutCes = teamTotal(applied);
    // each CE is measured alone, so floor() rounding may differ by a point or two from removing both at once
    expect(partyBond + selfBond, closeTo(withCes - withoutCes, 3));
  });
}
