// Fork feature test:
//  NP Damage: "Propose NP Up" (NP levels below 5 raised by 1, gain per servant, sorted by gain)
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/app/modules/battle/td_damage/model.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  test('NP up raises NP levels below 5 by 1, NP5 stays', () {
    final options = db.settings.battleSim.tdDmgOptions;
    final saved = (options.usePlayerSvt, options.tdR5, options.tdR3);
    try {
      options
        ..usePlayerSvt = PreferPlayerSvtDataSource.none
        ..tdR5 = 1
        ..tdR3 = 5;
      final solver = TdDmgSolver();
      final ssr = db.gameData.servantsById[100100]!; // Altria, 5*
      final low = db.gameData.servantsNoDup.values.firstWhere((s) => s.isUserSvt && s.rarity == 3);
      expect(solver.getSvtData(ssr, 4)!.tdLv, 1);
      solver.npUp = true;
      expect(solver.getSvtData(ssr, 4)!.tdLv, 2);
      expect(solver.getSvtData(low, 4)!.tdLv, 5, reason: 'already NP5');
    } finally {
      options
        ..usePlayerSvt = saved.$1
        ..tdR5 = saved.$2
        ..tdR3 = saved.$3;
    }
  });

  test('gain is the raised damage minus the damage, 0 without an NP up result', () {
    final svt = db.gameData.servantsById[100100]!;
    final result = TdDmgResult(PlayerSvtData.svt(svt), BattleData())..totalDamage = 100000;
    expect(result.npUpGain, 0);
    result.npUpDamage = 125000;
    expect(result.npUpGain, 25000);
    result.npUpDamage = 90000;
    expect(result.npUpGain, 0, reason: 'never negative');
    final raised = TdDmgResult(PlayerSvtData.svt(svt)..tdLv = 5, BattleData());
    expect(TdDmgSolver.npUpKey(result), TdDmgSolver.npUpKey(raised), reason: 'matched across NP levels');
  });
}
