// Fork feature test:
//  Team Bond results: "Unique Candidates" = servants on the score group's teams that the manual team input lacks
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/user.dart';
import 'package:chaldea/app/modules/bond/solver/results.dart';
import 'package:chaldea/app/modules/bond/solver/solver.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('candidates come from the clicked score group only, minus the manual team and supports', () {
    final svts = db.gameData.servantsById.values.where((svt) => svt.collectionNo > 0 && svt.isUserSvt).take(8).toList();
    final [a, b, c, d, e, f, g, h] = svts;

    BondSolvedSlot slot(int position, Servant? svt, {bool support = false, List<Servant> alts = const []}) =>
        BondSolvedSlot(
      position: position,
      servantId: svt?.id,
      limitCount: 4,
      equip1: null,
      equip3: null,
      isSupport: support,
      fixedServant: false,
      bond: 0,
      cost: 0,
      servantCandidates: [for (final alt in alts) alt.id],
      equip1Candidates: const [],
      equip3Candidates: const [],
    );

    // manual input: a, plus a support slot that holds f
    final manual = BattleTeamSetup();
    manual.svts[0] = PlayerSvtData.svt(a);
    manual.svts[2] = PlayerSvtData.svt(f)..supportType = SupportSvtType.friend;

    final teams = [
      // score group 1000
      // b's slot could equally hold g (or a, already in the manual team); the support's alternative h is ignored
      BondSolvedTeam(1000, 0, [slot(0, a), slot(1, b, alts: [b, g, a]), slot(2, e, support: true, alts: [h])]),
      BondSolvedTeam(1000, 0, [slot(0, a), slot(1, c), slot(2, null)]),
      // score group 900
      BondSolvedTeam(900, 0, [slot(0, a), slot(1, d)]),
      BondSolvedTeam(900, 0, [slot(0, f), slot(1, b)]),
    ];

    final tab = BondSolverResultsTab(
      solved: null,
      formation: manual,
      option: FormationBondOption(),
      quest: null,
      runState: BondSolverRunState.idle,
      error: null,
      onCancel: null,
    );

    // a is in the manual team, e and h are only ever supports, d is in another group; g is an equal alternative
    expect(tab.uniqueCandidateIds(teams, 0), {b.id, c.id, g.id});
    // f is already in the manual input (even as a support slot), so only d and b remain
    expect(tab.uniqueCandidateIds(teams, 2), {d.id, b.id});
  });

  test('a group whose servants are all already in the manual team has no candidates', () {
    final svt = db.gameData.servantsById.values.firstWhere((svt) => svt.collectionNo > 0 && svt.isUserSvt);
    final manual = BattleTeamSetup()..svts[0] = PlayerSvtData.svt(svt);
    final team = BondSolvedTeam(500, 0, [
      BondSolvedSlot(
        position: 0,
        servantId: svt.id,
        limitCount: 4,
        equip1: null,
        equip3: null,
        isSupport: false,
        fixedServant: true,
        bond: 0,
        cost: 0,
        servantCandidates: const [],
        equip1Candidates: const [],
        equip3Candidates: const [],
      ),
    ]);
    final tab = BondSolverResultsTab(
      solved: null,
      formation: manual,
      option: FormationBondOption(),
      quest: null,
      runState: BondSolverRunState.idle,
      error: null,
      onCancel: null,
    );
    expect(tab.uniqueCandidateIds([team], 0), isEmpty);
  });
}
