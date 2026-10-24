// Fork feature tests: Laplace NP Damage
//   1. Best Supports list
//   2. Best CE list
//   3. Best MC list
//   5. Command Spell calculator option
//   8. Grand Servant option: Disabled / Current / Max
//   9. "Battle Sim" button: send attacker + supports + MC to the Battle Simulation team
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/modules/battle/td_damage/model.dart';
import 'package:chaldea/app/modules/battle/td_damage/ranking_tab.dart' show buildBattleSimFormation;
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int kAltria = 100100; // Saber, Buster NP
const int kMerlin = 500800; // party ATK/Buster support
const int kKaleidoscopeId = 9400340; // CE, also used by test_init.dart

TdDamageOptions get options => db.settings.battleSim.tdDmgOptions;

/// Baseline NP damage result of [svtId] with the current TD options, same as one row of the ranking.
Future<TdDmgResult> calcAttacker(TdDmgSolver solver, int svtId) async {
  final svt = db.gameData.servantsById[svtId]!;
  final data = solver.getSvtData(svt, 4)!;
  final result = await solver.calcOneSvt(data, solver.getQuest(), solver.getMysticCodeData(), solver.getDelegate());
  expect(result, isNotNull, reason: 'attacker $svtId should produce an NP damage result');
  return result!;
}

/// Shared assertions for any "Best X" ranking.
void expectSortedByDamage(List<int> damages) {
  for (int i = 1; i < damages.length; i++) {
    expect(damages[i - 1] >= damages[i], isTrue, reason: 'ranking must be sorted by damage (index $i)');
  }
}

void main() async {
  await initiateForTest();

  setUp(() {
    db.settings.battleSim.tdDmgOptions = TdDamageOptions()..initBuffs();
  });

  group('Best Supports', () {
    test('ranks candidates by damage gain against a fresh baseline', () async {
      final solver = TdDmgSolver();
      final target = await calcAttacker(solver, kAltria);
      final candidates = [kMerlin, kAltria].map((id) => db.gameData.servantsById[id]!).toList();

      await solver.calcBestSupports(target, candidates: candidates);

      final gains = target.supportGains;
      expect(gains, isNotNull);
      expect(target.supportErrors, isEmpty);
      expect(gains!.map((e) => e.support.id).toSet(), {kMerlin, kAltria});
      expect(target.supportBaseDamage, target.totalDamage, reason: 'baseline = same options, no extra support');
      for (final gain in gains) {
        expect(gain.gain, gain.damage - target.supportBaseDamage!);
      }
      final merlin = gains.firstWhere((e) => e.support.id == kMerlin);
      expect(merlin.gain, greaterThan(0), reason: 'Merlin buffs a Buster attacker');
      for (int i = 1; i < gains.length; i++) {
        expect(gains[i - 1].gain >= gains[i].gain, isTrue, reason: 'sorted by gain');
      }
    });

    test('candidate support is added on top of supports already in options', () async {
      final solver = TdDmgSolver();
      final noSupport = await calcAttacker(solver, kAltria);
      options.supports.add(kMerlin);
      final withMerlin = await calcAttacker(solver, kAltria);
      expect(withMerlin.totalDamage, greaterThan(noSupport.totalDamage));

      await solver.calcBestSupports(withMerlin, candidates: [db.gameData.servantsById[kMerlin]!]);
      expect(withMerlin.supportBaseDamage, withMerlin.totalDamage, reason: 'baseline keeps the existing support');
      expect(withMerlin.supportGains!.single.damage, greaterThan(withMerlin.totalDamage), reason: 'second Merlin');
    });
  });

  group('Best CE', () {
    late Map<int, CraftStatus> savedStatus;
    late CraftEssence kaleido, blackGrail, notOwned;

    setUp(() {
      kaleido = db.gameData.craftEssencesById[kKaleidoscopeId]!;
      blackGrail = db.gameData.craftEssences[48]!; // The Black Grail, NP damage up
      notOwned = db.gameData.craftEssences[1]!;
      savedStatus = {
        for (final ce in [kaleido, blackGrail, notOwned])
          ce.collectionNo: CraftStatus(status: ce.status.status, lv: ce.status.lv, limitCount: ce.status.limitCount),
      };
      kaleido.status
        ..status = CraftStatus.owned
        ..lv = 100
        ..limitCount = 4;
      blackGrail.status
        ..status = CraftStatus.owned
        ..lv = 1
        ..limitCount = 0;
      notOwned.status.status = CraftStatus.notMet;
    });

    tearDown(() {
      savedStatus.forEach((no, saved) {
        db.curUser.ceStatusOf(no)
          ..status = saved.status
          ..lv = saved.lv
          ..limitCount = saved.limitCount;
      });
    });

    test('only owned CEs, at owned level and limit break, compared to no CE', () async {
      final solver = TdDmgSolver();
      final target = await calcAttacker(solver, kAltria);
      await solver.calcBestCEs(target, candidates: [kaleido, blackGrail, notOwned]);

      final gains = target.ceGains!;
      expect(target.ceErrors, isEmpty);
      expect(gains.map((e) => e.ce?.id).toSet(), {kaleido.id, blackGrail.id}, reason: 'not-owned CE excluded');
      expect(gains.any((e) => e.ce == null), isFalse, reason: 'no "No CE" row when nothing is selected');
      expect(target.ceBaseCeId, isNull);

      final k = gains.firstWhere((e) => e.ce?.id == kaleido.id);
      expect(k.lv, 100);
      expect(k.limitBreak, isTrue);
      final g = gains.firstWhere((e) => e.ce?.id == blackGrail.id);
      expect(g.lv, 1);
      expect(g.limitBreak, isFalse);
      expect(g.gain, greaterThan(0), reason: 'NP damage up CE beats no CE');

      for (final gain in gains) {
        expect(gain.gain, gain.damage - target.ceBaseDamage!);
      }
      expectSortedByDamage(gains.map((e) => e.damage).toList());
    });

    test('with a CE selected: shows replacement numbers, current marker and a "No CE" row', () async {
      options
        ..ceId = kaleido.id
        ..ceLv = 100
        ..ceMLB = true;
      final solver = TdDmgSolver();
      final target = await calcAttacker(solver, kAltria);
      await solver.calcBestCEs(target, candidates: [kaleido, blackGrail]);

      final gains = target.ceGains!;
      expect(target.ceBaseCeId, kaleido.id);
      expect(target.ceBaseLv, 100);
      expect(target.ceBaseMLB, isTrue);

      final none = gains.singleWhere((e) => e.ce == null);
      expect(none.gain, lessThan(0), reason: 'removing a lv100 CE loses ATK');
      final current = gains.singleWhere((e) => e.isCurrent);
      expect(current.ce?.id, kaleido.id);
      expect(current.gain, 0, reason: 'same CE, level and limit break as the baseline');
      expectSortedByDamage(gains.map((e) => e.damage).toList());
    });
  });

  group('Best MC', () {
    late Map<int, int> savedMcLevels;
    setUp(() => savedMcLevels = Map.of(db.curUser.mysticCodes));
    tearDown(() {
      db.curUser.mysticCodes
        ..clear()
        ..addAll(savedMcLevels);
    });

    test('every MC at the user level (default 10), compared to no MC', () async {
      options.mcId = null;
      db.curUser.mysticCodes[20] = 6;
      final solver = TdDmgSolver();
      final target = await calcAttacker(solver, kAltria);
      await solver.calcBestMCs(target);

      final gains = target.mcGains!;
      expect(target.mcErrors, isEmpty);
      expect(target.mcBaseMcId, isNull);
      expect(gains.any((e) => e.mc == null), isFalse);
      expect(gains.length, db.gameData.mysticCodes.length);
      for (final gain in gains) {
        expect(gain.lv, TdDmgSolver.userMcLevel(gain.mc!));
        expect(gain.gain, gain.damage - target.mcBaseDamage!);
      }
      expect(gains.firstWhere((e) => e.mc!.id == 20).lv, 6);
      expect(gains.any((e) => e.gain > 0), isTrue, reason: 'some MC buffs ATK/NP damage');
      expectSortedByDamage(gains.map((e) => e.damage).toList());
    });

    test('with an MC selected: current marker and a "No MC" row', () async {
      db.curUser.mysticCodes[20] = 10;
      options
        ..mcId = 20
        ..mcLv = 10;
      final solver = TdDmgSolver();
      final target = await calcAttacker(solver, kAltria);
      final candidates = [db.gameData.mysticCodes[20]!, db.gameData.mysticCodes[130]!];
      await solver.calcBestMCs(target, candidates: candidates);

      final gains = target.mcGains!;
      expect(target.mcBaseMcId, 20);
      expect(target.mcBaseLv, 10);
      expect(gains.where((e) => e.mc == null).length, 1);
      final current = gains.singleWhere((e) => e.isCurrent);
      expect(current.mc!.id, 20);
      expect(current.gain, 0);
      expectSortedByDamage(gains.map((e) => e.damage).toList());
    });
  });

  group('Command Spell option', () {
    test('triggers Class Score "Command Spell Excitation" when the board is enhanced', () async {
      options.classBoard = PreferClassBoardDataSource.full;
      final solver = TdDmgSolver();
      options.commandSpell = false;
      final without = await calcAttacker(solver, kAltria);
      options.commandSpell = true;
      final withCs = await calcAttacker(solver, kAltria);
      expect(withCs.totalDamage, greaterThan(without.totalDamage));
    });

    test('no effect without Class Score, and NP gain from the Command Spell is discarded', () async {
      options.classBoard = PreferClassBoardDataSource.none;
      final solver = TdDmgSolver();
      options.commandSpell = false;
      final without = await calcAttacker(solver, kAltria);
      options.commandSpell = true;
      final withCs = await calcAttacker(solver, kAltria);
      expect(withCs.totalDamage, without.totalDamage);
      expect(withCs.attackNp, without.attackNp);
      expect(withCs.totalNp, without.totalNp, reason: 'gauge is reset to 100% before the NP');
    });

    test('option is saved with the other NP damage settings', () {
      TdDamageOptions roundTrip(TdDamageOptions o) => TdDamageOptions.fromJson(jsonDecode(jsonEncode(o.toJson())));
      expect(roundTrip(TdDamageOptions()..commandSpell = true).commandSpell, isTrue);
      expect(roundTrip(TdDamageOptions()).commandSpell, isFalse);
      // settings saved before this option existed
      final legacy = jsonDecode(jsonEncode(TdDamageOptions().toJson())) as Map<String, dynamic>;
      legacy.remove('commandSpell');
      expect(TdDamageOptions.fromJson(legacy).commandSpell, isFalse);
    });
  });

  group('Grand Servant option', () {
    final altria = db.gameData.servantsById[kAltria]!;
    late bool savedGrand;
    setUp(() => savedGrand = altria.status.grandSvt);
    tearDown(() => altria.status.grandSvt = savedGrand);

    test('Disabled / Max apply to every servant, Current follows the Grand flag in user data', () {
      final solver = TdDmgSolver();
      bool grandOf(GrandSvtSource source) {
        options.grandSvt = source;
        return solver.getSvtData(altria, 4)!.grandSvt;
      }

      altria.status.grandSvt = false;
      expect(grandOf(GrandSvtSource.disabled), isFalse);
      expect(grandOf(GrandSvtSource.max), isTrue);
      expect(grandOf(GrandSvtSource.current), isFalse);
      altria.status.grandSvt = true;
      expect(grandOf(GrandSvtSource.current), isTrue);
      expect(grandOf(GrandSvtSource.disabled), isFalse);
    });

    test('Grand Board only applies to servants treated as Grand', () {
      final solver = TdDmgSolver();
      options
        ..grandBoard = PreferClassBoardDataSource.full
        ..grandSvt = GrandSvtSource.current;
      altria.status.grandSvt = false;
      expect(solver.getSvtData(altria, 4)!.classBoardData.grandClassBoardSquares, isEmpty);
      altria.status.grandSvt = true;
      if (ClassBoard.getGrandClassBoard(altria.classId) != null) {
        expect(solver.getSvtData(altria, 4)!.classBoardData.grandClassBoardSquares, isNotEmpty);
      }
    });

    test('saved settings: old on/off values load as Max/Disabled', () {
      Map<String, dynamic> json(Object? grandSvt) =>
          (jsonDecode(jsonEncode(TdDamageOptions().toJson())) as Map<String, dynamic>)..['grandSvt'] = grandSvt;
      expect(TdDamageOptions.fromJson(json(true)).grandSvt, GrandSvtSource.max);
      expect(TdDamageOptions.fromJson(json(false)).grandSvt, GrandSvtSource.disabled);
      expect(TdDamageOptions.fromJson(json(null)).grandSvt, GrandSvtSource.disabled);
      for (final source in GrandSvtSource.values) {
        final roundTrip = TdDamageOptions.fromJson(
          jsonDecode(jsonEncode((TdDamageOptions()..grandSvt = source).toJson())),
        );
        expect(roundTrip.grandSvt, source);
      }
    });
  });

  group('Battle Sim button', () {
    test('slot 1 = attacker with the calc CE, slots 2-6 = supports, MC from calc', () async {
      final kaleido = db.gameData.craftEssencesById[kKaleidoscopeId]!;
      options
        ..ceId = kaleido.id
        ..ceLv = 100
        ..ceMLB = true
        ..supports.addAll([kMerlin, kAltria])
        ..mcId = 20
        ..mcLv = 7;
      final solver = TdDmgSolver();
      final target = await calcAttacker(solver, kAltria);

      final formation = buildBattleSimFormation(
        solver,
        target,
        BattleTeamFormation()..mysticCode = MysticCodeSaveData(mysticCodeId: 130, level: 10),
      );
      expect(formation.svts, hasLength(6));
      expect(formation.svts[0]?.svtId, kAltria);
      expect(formation.svts[0]?.equip1.id, kaleido.id);
      expect(formation.svts[0]?.equip1.lv, 100);
      expect(formation.svts[0]?.equip1.limitBreak, isTrue);
      expect(formation.svts[0]?.customPassives, isEmpty, reason: 'calc buffs are not copied');
      expect(formation.svts[1]?.svtId, kMerlin);
      expect(formation.svts[2]?.svtId, kAltria);
      expect(formation.svts.skip(3).every((e) => e == null), isTrue, reason: 'previous team is cleared');
      expect(formation.mysticCode.mysticCodeId, 20);
      expect(formation.mysticCode.level, 7);
    });

    test('no MC in the calc keeps the team MC', () async {
      options.mcId = null;
      final solver = TdDmgSolver();
      final target = await calcAttacker(solver, kAltria);
      final formation = buildBattleSimFormation(
        solver,
        target,
        BattleTeamFormation()..mysticCode = MysticCodeSaveData(mysticCodeId: 130, level: 9),
      );
      expect(formation.svts[0]?.svtId, kAltria);
      expect(formation.svts.skip(1).every((e) => e == null), isTrue);
      expect(formation.mysticCode.mysticCodeId, 130);
      expect(formation.mysticCode.level, 9);
    });
  });
}
