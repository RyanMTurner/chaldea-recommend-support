import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/language.dart';
import 'package:chaldea/packages/logger.dart';

/// A task run on a worker isolate: a top-level or static function (functions are sendable between
/// isolates of the app) with a payload. [report] sends progress back to the caller.
typedef BattleWorkerTask = Future<Object?> Function(Object? payload, void Function(Object? progress) report);

/// Worker isolates that can run the battle engine.
///
/// The battle engine reads the global game data, which a new isolate doesn't have, so every worker gets a
/// copy of the main isolate's GameData object (same isolate group: copied, not parsed again). The sender
/// makes the copy, so the main isolate starts only the first worker and that worker starts the others.
/// Pools are kept by [tag] and reused while the worker count and game data are unchanged.
class BattleWorkerPool {
  static final Map<String, BattleWorkerPool> _pools = {};

  /// CPU cores - 1, at least 1 and at most 4 (each worker holds a copy of the game data). 0 on web.
  static int get defaultWorkers => kIsWeb ? 0 : max(1, min(4, Platform.numberOfProcessors - 1));

  final String tag;
  final int count;
  final GameData gameData;
  final ReceivePort _inbox = ReceivePort();
  final Map<int, SendPort> _ports = {};
  final Completer<void> _ready = Completer();
  final Map<int, _PendingTask> _pending = {};
  Isolate? _first;
  bool _disposed = false;
  int _nextTaskId = 1;

  BattleWorkerPool._(this.tag, this.count, this.gameData);

  static Future<BattleWorkerPool> obtain(String tag, int count) async {
    final current = _pools[tag];
    if (current != null && !current._disposed && current.count == count && identical(current.gameData, db.gameData)) {
      await current._ready.future;
      return current;
    }
    await current?.dispose();
    final pool = _pools[tag] = BattleWorkerPool._(tag, count, db.gameData);
    try {
      await pool._start();
    } catch (e) {
      await pool.dispose();
      rethrow;
    }
    return pool;
  }

  static Future<void> disposeTag(String tag) async {
    await _pools[tag]?.dispose();
  }

  Future<void> _start() async {
    _inbox.listen((message) {
      if (message is _WorkerReady) {
        _ports[message.index] = message.port;
        if (_ports.length == count && !_ready.isCompleted) _ready.complete();
      } else if (message is _WorkerFailed) {
        logger.e('battle worker ${message.index} failed: ${message.error}');
        if (!_ready.isCompleted) _ready.completeError(StateError('worker ${message.index}: ${message.error}'));
      } else if (message is _TaskProgress) {
        _pending[message.taskId]?.onProgress?.call(message.worker, message.progress);
      } else if (message is _TaskDone) {
        final pending = _pending[message.taskId];
        if (pending == null) return;
        if (message.error != null) {
          pending.errors.add('worker ${message.worker}: ${message.error}');
        } else {
          pending.results[message.worker] = message.result;
        }
        pending.remaining--;
        if (pending.remaining <= 0) {
          _pending.remove(message.taskId);
          if (pending.errors.isNotEmpty) {
            pending.completer.completeError(StateError(pending.errors.join('\n')));
          } else {
            pending.completer.complete(pending.results);
          }
        }
      }
    });
    _first = await Isolate.spawn(
      _battleWorkerMain,
      _WorkerBoot(
        mainPort: _inbox.sendPort,
        gameData: gameData,
        languageCode: Language.current.code,
        index: 0,
        count: count,
        tag: tag,
      ),
      errorsAreFatal: false,
      debugName: '${tag}_worker_0',
    );
    await _ready.future.timeout(const Duration(minutes: 3));
  }

  /// Runs one task per entry of [jobs] (entry i on worker i, at most [count]) and returns their results in order.
  /// Throws if any worker fails.
  Future<List<Object?>> runAll(
    List<(BattleWorkerTask task, Object? payload)> jobs, {
    void Function(int worker, Object? progress)? onProgress,
  }) async {
    if (_disposed) throw StateError('worker pool disposed');
    if (jobs.length > count) throw ArgumentError('${jobs.length} jobs for $count workers');
    if (jobs.isEmpty) return [];
    final taskId = _nextTaskId++;
    final pending = _pending[taskId] = _PendingTask(jobs.length, onProgress);
    for (final (index, (task, payload)) in jobs.indexed) {
      _ports[index]!.send(_TaskRequest(taskId, task, payload));
    }
    return pending.completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final port in _ports.values) {
      port.send(const _WorkerExit());
    }
    _first?.kill(priority: Isolate.beforeNextEvent);
    _inbox.close();
    for (final pending in _pending.values) {
      if (!pending.completer.isCompleted) pending.completer.completeError(StateError('worker pool disposed'));
    }
    _pending.clear();
    if (identical(_pools[tag], this)) _pools.remove(tag);
  }
}

class _PendingTask {
  int remaining;
  final void Function(int worker, Object? progress)? onProgress;
  final List<Object?> results;
  final List<String> errors = [];
  final Completer<List<Object?>> completer = Completer();

  _PendingTask(this.remaining, this.onProgress) : results = List.filled(remaining, null);
}

class _WorkerBoot {
  final SendPort mainPort;
  final GameData gameData;
  final String languageCode;
  final int index;
  final int count;
  final String tag;

  const _WorkerBoot({
    required this.mainPort,
    required this.gameData,
    required this.languageCode,
    required this.index,
    required this.count,
    required this.tag,
  });

  _WorkerBoot forIndex(int index) => _WorkerBoot(
    mainPort: mainPort,
    gameData: gameData,
    languageCode: languageCode,
    index: index,
    count: count,
    tag: tag,
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

class _WorkerExit {
  const _WorkerExit();
}

class _TaskRequest {
  final int taskId;
  final BattleWorkerTask task;
  final Object? payload;
  const _TaskRequest(this.taskId, this.task, this.payload);
}

class _TaskProgress {
  final int taskId;
  final int worker;
  final Object? progress;
  const _TaskProgress(this.taskId, this.worker, this.progress);
}

class _TaskDone {
  final int taskId;
  final int worker;
  final Object? result;
  final String? error;
  const _TaskDone(this.taskId, this.worker, this.result, this.error);
}

@pragma('vm:entry-point')
Future<void> _battleWorkerMain(_WorkerBoot boot) async {
  try {
    // Language.current would fall back to the system locale (needs WidgetsBinding), so set it explicitly
    await db.settings.setLanguage(Language.getLanguage(boot.languageCode) ?? Language.en);
    db.gameData = boot.gameData;
  } catch (e) {
    boot.mainPort.send(_WorkerFailed(boot.index, '$e'));
    return;
  }

  // copies of the game data for the other workers are made here, not on the UI thread
  if (boot.index == 0) {
    for (int index = 1; index < boot.count; index++) {
      try {
        await Isolate.spawn(
          _battleWorkerMain,
          boot.forIndex(index),
          errorsAreFatal: false,
          debugName: '${boot.tag}_worker_$index',
        );
      } catch (e) {
        boot.mainPort.send(_WorkerFailed(index, '$e'));
      }
    }
  }

  final inbox = ReceivePort();
  boot.mainPort.send(_WorkerReady(boot.index, inbox.sendPort));
  await for (final message in inbox) {
    if (message is _WorkerExit) {
      inbox.close();
      break;
    }
    if (message is _TaskRequest) {
      try {
        final result = await message.task(
          message.payload,
          (progress) => boot.mainPort.send(_TaskProgress(message.taskId, boot.index, progress)),
        );
        boot.mainPort.send(_TaskDone(message.taskId, boot.index, result, null));
      } catch (e, s) {
        logger.e('battle worker task failed', e, s);
        boot.mainPort.send(_TaskDone(message.taskId, boot.index, null, '$e'));
      }
    }
  }
}
