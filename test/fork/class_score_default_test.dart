// Fork feature test:
//   4. Battle Simulation team setup: Class Score defaults to the user's current progress when selecting a servant
//
// Run: flutter test test/fork --dart-define=APP_PATH=/path/to/app/data
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/models/models.dart';

import '../test_init.dart';

const int kAltria = 100100; // Saber
const int kMerlin = 500800; // Caster

void main() async {
  await initiateForTest();

  final altria = db.gameData.servantsById[kAltria]!;
  final merlin = db.gameData.servantsById[kMerlin]!;
  final saberBoard = ClassBoard.getClassBoard(altria.classId)!;
  final casterBoard = ClassBoard.getClassBoard(merlin.classId)!;

  /// a few real square ids of a board, used as the user's "current" progress
  Set<int> someSquares(ClassBoard board, int count) => board.squares.map((e) => e.id).take(count).toSet();

  late Set<int> savedSaber, savedCaster;
  setUp(() {
    savedSaber = saberBoard.status.enhancedSquares.toSet();
    savedCaster = casterBoard.status.enhancedSquares.toSet();
  });
  tearDown(() {
    saberBoard.status.enhancedSquares = savedSaber;
    casterBoard.status.enhancedSquares = savedCaster;
  });

  test('selecting a servant fills Class Score from current progress', () {
    final current = someSquares(saberBoard, 3);
    saberBoard.status.enhancedSquares = current.toSet();

    final data = PlayerSvtData.base()..onSelectServant(altria);
    expect(data.classBoardData.classBoardSquares.toSet(), current);
  });

  test('re-selecting a same-class servant resets manual edits back to current', () {
    final current = someSquares(saberBoard, 2);
    saberBoard.status.enhancedSquares = current.toSet();

    final data = PlayerSvtData.base()..onSelectServant(altria);
    data.classBoardData.classBoardSquares = []; // manual edit in the editor
    final otherSaber = db.gameData.servantsNoDup.values.firstWhere(
      (svt) => svt.isUserSvt && svt.classId == altria.classId && svt.id != altria.id,
    );
    data.onSelectServant(otherSaber);
    expect(data.classBoardData.classBoardSquares.toSet(), current);
  });

  test('switching class uses the new class board, empty if no progress', () {
    saberBoard.status.enhancedSquares = someSquares(saberBoard, 2);
    casterBoard.status.enhancedSquares = {};

    final data = PlayerSvtData.base()..onSelectServant(altria);
    expect(data.classBoardData.classBoardSquares, isNotEmpty);
    data.onSelectServant(merlin);
    expect(data.classBoardData.classBoardSquares, isEmpty);

    final casterCurrent = someSquares(casterBoard, 4);
    casterBoard.status.enhancedSquares = casterCurrent.toSet();
    data.onSelectServant(merlin);
    expect(data.classBoardData.classBoardSquares.toSet(), casterCurrent);
  });
}
