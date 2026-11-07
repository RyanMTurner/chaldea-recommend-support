// Fork feature test:
//  Team Bond page: "Runs To Bond 10" and "Apples" rows
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/bond/formation_bond_calc.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

void main() async {
  await initiateForTest();

  // cumulative bond table: bond 1 = 1000, bond 2 = 3000, ... bond 10 = 55000
  final growth = [for (int lv = 1; lv <= 15; lv++) 1000 * lv * (lv + 1) ~/ 2];

  group('bond points to bond 10', () {
    test('uses the saved bond points when known', () {
      expect(bondPointsToLv(growth, bondLv: 5, bondPoints: 20000), 55000 - 20000);
    });

    test('falls back to the lowest total for the bond level when bond points are blank', () {
      expect(bondPointsToLv(growth, bondLv: 5), 55000 - 15000);
      expect(bondPointsToLv(growth, bondLv: 0), 55000);
    });

    test('is 0 at or past bond 10', () {
      expect(bondPointsToLv(growth, bondLv: 10), 0);
      expect(bondPointsToLv(growth, bondLv: 12, bondPoints: 90000), 0);
    });
  });

  group('runs to bond 10', () {
    test('divides by the bond per run, rounding up', () {
      expect(runsToBond(40000, 3290), 13); // 12.16 -> 13
      expect(runsToBond(32900, 3290), 10); // exact
      expect(runsToBond(1, 3290), 1);
    });

    test('is 0 when nothing is left and null when the quest gives no bond', () {
      expect(runsToBond(0, 3290), 0);
      expect(runsToBond(0, 0), 0);
      expect(runsToBond(100, 0), isNull);
    });
  });

  group('apples', () {
    test('multiplies runs by the AP cost and divides by max AP', () {
      expect(applesForRuns(13, 40, 152), closeTo(13 * 40 / 152, 1e-9));
      expect(applesForRuns(19, 40, 152), closeTo(5.0, 1e-9));
      expect(applesForRuns(0, 40, 152), 0);
      expect(applesForRuns(10, 40, 0), isNull);
    });

    test('MAX AP defaults to 152 and survives serialization', () {
      final option = FormationBondOption();
      expect(option.maxAp, 152);
      expect(FormationBondOption.fromJson({}).maxAp, 152);
      option.maxAp = 140;
      expect(FormationBondOption.fromJson(option.toJson()).maxAp, 140);
      expect(option.copy().maxAp, 140);
    });
  });

  test('end to end with a real servant and an AP quest', () {
    final svt = db.gameData.servantsById[800100]!; // Mash
    final quest = db.gameData.questPhases.values.firstWhere(
      (q) => q.bond > 0 && q.consumeType == ConsumeType.ap && q.consume > 0,
    );
    final ap = questApCost(quest)!;
    expect(ap, greaterThan(0));

    const bondPerRun = 3290;
    final status = SvtStatus(bond: 6); // bond points blank
    final remaining = bondPointsToLv(svt.bondGrowth, bondLv: status.bond, bondPoints: status.bondPoints);
    expect(remaining, svt.bondGrowth[9] - svt.bondGrowth[5]);

    final runs = runsToBond(remaining, bondPerRun)!;
    expect(runs, (remaining / bondPerRun).ceil());
    expect(applesForRuns(runs, ap, 152), closeTo(runs * ap / 152, 1e-9));

    status.bondPoints = svt.bondGrowth[5] + 1234;
    expect(
      bondPointsToLv(svt.bondGrowth, bondLv: status.bond, bondPoints: status.bondPoints),
      svt.bondGrowth[9] - svt.bondGrowth[5] - 1234,
    );
  });
}
