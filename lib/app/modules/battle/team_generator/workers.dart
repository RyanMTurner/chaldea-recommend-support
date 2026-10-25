import 'dart:async';
import 'dart:isolate';

import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/language.dart';
import 'package:chaldea/packages/logger.dart';

import 'solver.dart';

// Parallel Team Generator search.
//
// The battle engine reads the global game data, which a new isolate doesn't have. Each worker gets a
// copy of the main isolate's GameData object (same isolate group, so it is copied, not re-parsed).
// The copy is made by the sender, so the main isolate starts only the first worker and that worker
// starts the others. Workers live while the Team Generator page is open and are reused between solves.
//
// Each worker runs the normal solver on its share of the first-turn options (round-robin), the first
// plan found wins and the others are cancelled. One clock for all: the page pauses / resumes every worker.

class _WorkerBoot {
  final SendPort mainPort;
  final GameData gameData;
  final String languageCode;
  final bool isGirl;
  final int index;
  final int count;

  const _WorkerBoot({
    required this.mainPort,
    required this.gameData,
    required this.languageCode,
    required this.isGirl,
    required this.index,
    required this.count,
  });

  _WorkerBoot forIndex(int index) => _WorkerBoot(
    mainPort: mainPort,
    gameData: gameData,
    languageCode: languageCode,
    isGirl: isGirl,
    index: index,
    count: count,
  );
}

class _WorkerReady {
  final int index;
  final SendPort port;
  const _WorkerReady(this.index, this.port);
}

class _WorkerFailed {
  final int index;
  final String error;
  const _WorkerFailed(this.index, this.error);
}

class _SolveRequest {
  final int id;
  final QuestPhase quest;
  final BattleTeamFormation formation;
  final int maxTurns;
  final int maxCommandSpells;
  final int maxHeldSkills;

  const _SolveRequest({
    required this.id,
    required this.quest,
    required this.formation,
    required this.maxTurns,
    required this.maxCommandSpells,
    required this.maxHeldSkills,
  });
}

class _Progress {
  final int id;
  final int index;
  final int simulations;
  const _Progress(this.id, this.index, this.simulations);
}

class _Done {
  final int id;
  final int index;
  final TeamGeneratorResult result;
  const _Done(this.id, this.index, this.result);
}

enum _Control { pause, resume, cancel, exit }

class _ControlMessage {
  final int id;
  final _Control control;
  const _ControlMessage(this.id, this.control);
}

@pragma('vm:entry-point')
Future<void> _workerMain(_WorkerBoot boot) async {
  try {
    // Language.current would fall back to the system locale (needs WidgetsBinding), so set it explicitly
    await db.settings.setLanguage(Language.getLanguage(boot.languageCode) ?? Language.en);
    db.gameData = boot.gameData;
    db.curUser.isGirl = boot.isGirl; // gender-specific mystic code / Command Spell effects
  } catch (e) {
    boot.mainPort.send(_WorkerFailed(boot.index, '$e'));
    return;
  }

  // copies of the game data for the other workers are made here, not on the UI thread
  if (boot.index == 0) {
    for (int index = 1; index < boot.count; index++) {
      try {
        await Isolate.spawn(
          _workerMain,
          boot.forIndex(index),
          errorsAreFatal: false,
          debugName: 'team_generator_$index',
        );
      } catch (e) {
        boot.mainPort.send(_WorkerFailed(index, '$e'));
      }
    }
  }

  final inbox = ReceivePort();
  boot.mainPort.send(_WorkerReady(boot.index, inbox.sendPort));

  TeamGeneratorSolver? solver;
  int? solveId;
  await for (final message in inbox) {
    if (message is _SolveRequest) {
      solver?.cancel();
      solveId = message.id;
      solver = await _startSolve(boot, message);
    } else if (message is _ControlMessage) {
      if (message.control == _Control.exit) {
        solver?.cancel();
        inbox.close();
        break;
      }
      if (message.id != solveId) continue;
      switch (message.control) {
        case _Control.pause:
          solver?.pause();
        case _Control.resume:
          solver?.resume();
        case _Control.cancel:
          solver?.cancel();
        case _Control.exit:
          break;
      }
    }
  }
}

Future<TeamGeneratorSolver?> _startSolve(_WorkerBoot boot, _SolveRequest request) async {
  try {
    final svts = <PlayerSvtData>[
      for (final stored in request.formation.svts) await PlayerSvtData.fromStoredData(stored),
    ];
    final mysticCode = MysticCodeData()..loadStoredData(request.formation.mysticCode);
    final team = BattleTeamSetup(svts: svts, mysticCodeData: mysticCode);
    int lastProgress = 0;
    final watch = Stopwatch()..start();
    final solver = TeamGeneratorSolver(
      quest: request.quest,
      formation: team,
      settings: TeamGeneratorSettings(
        maxTurns: request.maxTurns,
        maxCommandSpells: request.maxCommandSpells,
        maxHeldSkills: request.maxHeldSkills,
        timeLimitSeconds: 1 << 30, // the page owns the clock
        workers: 0,
      ),
      partitionIndex: boot.index,
      partitionCount: boot.count,
      onProgress: (simulations, _) {
        if (watch.elapsedMilliseconds - lastProgress < 250) return;
        lastProgress = watch.elapsedMilliseconds;
        boot.mainPort.send(_Progress(request.id, boot.index, simulations));
      },
    );
    unawaited(
      solver
          .solve()
          .then(
            (result) => boot.mainPort.send(
              _Done(
                request.id,
                boot.index,
                // the battle object stays here; the page uses the FGA command and replay data
                TeamGeneratorResult(
                  success: result.success,
                  message: result.message,
                  turns: result.turns,
                  fgaCommand: result.fgaCommand,
                  shareData: result.shareData,
                  simulations: result.simulations,
                  elapsedMilliseconds: result.elapsedMilliseconds,
                ),
              ),
            ),
          )
          .catchError((Object e) {
            boot.mainPort.send(
              _Done(
                request.id,
                boot.index,
                TeamGeneratorResult(success: false, message: 'Error: $e', simulations: 0, elapsedMilliseconds: 0),
              ),
            );
          }),
    );
    return solver;
  } catch (e) {
    boot.mainPort.send(
      _Done(
        request.id,
        boot.index,
        TeamGeneratorResult(success: false, message: 'Error: $e', simulations: 0, elapsedMilliseconds: 0),
      ),
    );
    return null;
  }
}

/// Worker isolates holding a copy of the game data. One pool at a time, reused while it matches.
class TeamGeneratorWorkerPool {
  static TeamGeneratorWorkerPool? _current;

  final int count;
  final GameData gameData;
  final ReceivePort _inbox = ReceivePort();
  final StreamController<Object?> _messages = StreamController.broadcast();
  final Map<int, SendPort> _ports = {};
  final Completer<void> _ready = Completer();
  Isolate? _first;
  bool _disposed = false;

  TeamGeneratorWorkerPool._(this.count, this.gameData);

  Stream<Object?> get messages => _messages.stream;
  Iterable<SendPort> get ports => _ports.values;

  /// Reuses the current pool if the worker count and game data are unchanged, otherwise starts a new one.
  static Future<TeamGeneratorWorkerPool> obtain(int count) async {
    final current = _current;
    if (current != null && !current._disposed && current.count == count && identical(current.gameData, db.gameData)) {
      await current._ready.future;
      return current;
    }
    await current?.dispose();
    final pool = _current = TeamGeneratorWorkerPool._(count, db.gameData);
    try {
      await pool._start();
    } catch (e) {
      await pool.dispose();
      rethrow;
    }
    return pool;
  }

  static Future<void> disposeCurrent() async {
    await _current?.dispose();
  }

  Future<void> _start() async {
    _inbox.listen((message) {
      if (message is _WorkerReady) {
        _ports[message.index] = message.port;
        if (_ports.length == count && !_ready.isCompleted) _ready.complete();
      } else if (message is _WorkerFailed) {
        logger.e('Team Generator worker ${message.index} failed: ${message.error}');
        if (!_ready.isCompleted) _ready.completeError(StateError('worker ${message.index}: ${message.error}'));
      } else {
        _messages.add(message);
      }
    });
    _first = await Isolate.spawn(
      _workerMain,
      _WorkerBoot(
        mainPort: _inbox.sendPort,
        gameData: gameData,
        languageCode: Language.current.code,
        isGirl: db.curUser.isGirl,
        index: 0,
        count: count,
      ),
      errorsAreFatal: false,
      debugName: 'team_generator_0',
    );
    await _ready.future.timeout(const Duration(minutes: 3));
  }

  void broadcast(Object message) {
    for (final port in _ports.values) {
      port.send(message);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    broadcast(const _ControlMessage(0, _Control.exit));
    _first?.kill(priority: Isolate.beforeNextEvent);
    _inbox.close();
    await _messages.close();
    if (identical(_current, this)) _current = null;
  }
}

/// Runs the search on [TeamGeneratorSettings.workers] worker isolates with one shared clock.
class ParallelTeamGeneratorRun implements TeamGeneratorRun {
  final QuestPhase quest;
  final BattleTeamSetup formation;
  final TeamGeneratorSettings settings;
  final void Function(int simulations, int elapsedMilliseconds)? onProgress;
  final void Function(int simulations, int elapsedMilliseconds)? onPaused;

  /// Called once the workers are running (the first solve has to copy the game data first).
  final void Function()? onWorkersReady;

  ParallelTeamGeneratorRun({
    required this.quest,
    required this.formation,
    required this.settings,
    this.onProgress,
    this.onPaused,
    this.onWorkersReady,
  }) : _timeLimitSeconds = settings.timeLimitSeconds;

  static int _nextId = 1;
  final int _id = _nextId++;

  int _timeLimitSeconds;
  bool _paused = false;
  bool _cancelled = false;
  bool _reachedTimeLimit = false;
  final Stopwatch _watch = Stopwatch();
  final Map<int, int> _simulations = {};
  TeamGeneratorWorkerPool? _pool;

  int get _totalSimulations => _simulations.values.fold(0, (sum, value) => sum + value);

  @override
  int get timeLimitSeconds => _timeLimitSeconds;

  @override
  bool get isPaused => _paused;

  void _send(_Control control) => _pool?.broadcast(_ControlMessage(_id, control));

  @override
  void cancel() {
    _cancelled = true;
    _send(_Control.cancel);
  }

  @override
  void addTime(int seconds) {
    _timeLimitSeconds += seconds;
    if (_paused && !_cancelled) {
      _paused = false;
      _watch.start();
      _send(_Control.resume);
    }
  }

  TeamGeneratorResult _failure(String message) => TeamGeneratorResult(
    success: false,
    message: message,
    simulations: _totalSimulations,
    elapsedMilliseconds: _watch.elapsedMilliseconds,
  );

  /// Throws if the workers cannot start; the caller may fall back to [TeamGeneratorSolver].
  @override
  Future<TeamGeneratorResult> solve() async {
    final pool = _pool = await TeamGeneratorWorkerPool.obtain(settings.workers);
    if (_cancelled) return _failure('Cancelled.');
    onWorkersReady?.call();

    final done = Completer<TeamGeneratorResult>();
    final finished = <int>{};
    final subscription = pool.messages.listen((message) {
      if (message is _Progress && message.id == _id) {
        _simulations[message.index] = message.simulations;
        onProgress?.call(_totalSimulations, _watch.elapsedMilliseconds);
      } else if (message is _Done && message.id == _id) {
        _simulations[message.index] = message.result.simulations;
        finished.add(message.index);
        if (done.isCompleted) return;
        if (message.result.success) {
          _send(_Control.cancel); // the other workers can stop
          done.complete(
            message.result.copyWith(simulations: _totalSimulations, elapsedMilliseconds: _watch.elapsedMilliseconds),
          );
        } else if (finished.length >= pool.count) {
          if (_reachedTimeLimit && _cancelled) {
            done.complete(_failure('No plan found within ${_timeLimitSeconds}s.'));
          } else if (_cancelled) {
            done.complete(_failure('Cancelled.'));
          } else {
            final error = message.result.message.startsWith('Error') ? ' (${message.result.message})' : '';
            done.complete(_failure('No plan clears the quest within ${settings.maxTurns} turn(s).$error'));
          }
        }
      }
    });

    final request = _SolveRequest(
      id: _id,
      quest: quest,
      formation: formation.toFormationData(),
      maxTurns: settings.maxTurns,
      maxCommandSpells: settings.maxCommandSpells,
      maxHeldSkills: settings.maxHeldSkills,
    );
    for (final port in pool.ports) {
      port.send(request);
    }
    _watch.start();
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_paused || _cancelled || done.isCompleted) return;
      if (_watch.elapsed.inSeconds >= _timeLimitSeconds) {
        _paused = true;
        _reachedTimeLimit = true;
        _watch.stop();
        _send(_Control.pause);
        onPaused?.call(_totalSimulations, _watch.elapsedMilliseconds);
      }
    });

    try {
      return await done.future;
    } finally {
      timer.cancel();
      _watch.stop();
      await subscription.cancel();
    }
  }
}
