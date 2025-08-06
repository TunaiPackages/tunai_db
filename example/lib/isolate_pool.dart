import 'dart:async';
import 'dart:isolate';
import 'dart:developer' as developer;

import 'package:collection/collection.dart';

enum TaskPriority { high, normal, low }

class Task<T> {
  final dynamic args;
  final FutureOr<T> Function(dynamic args) task;
  final TaskPriority priority;
  final String? taskName;
  final Completer<T> completer;

  Task({
    required this.args,
    required this.task,
    required this.priority,
    this.taskName,
    required this.completer,
  });
}

class IsolatePool {
  static IsolatePool? _instance;
  static IsolatePool get instance => _instance ??= IsolatePool._();

  final List<_IsolateWorker> _workers = [];
  int get workerCount => _workers.length;
  final PriorityQueue<Task> _taskQueue = PriorityQueue<Task>((a, b) {
    return a.priority.index.compareTo(b.priority.index);
  });

  bool _isInitialized = false;
  final int _defaultPoolSize = 3; // Default number of isolates in the pool

  IsolatePool._();

  /// Initialize the isolate pool with the specified number of worker isolates
  Future<void> init({int? poolSize}) async {
    if (_isInitialized) return;

    final size = poolSize ?? _defaultPoolSize;

    for (int i = 0; i < size; i++) {
      final worker = _IsolateWorker(id: i);
      await worker.spawn();

      _workers.add(worker);
    }

    _isInitialized = true;
  }

  /// Execute a task with arguments in an available isolate with the specified priority
  Future<T> execute<T>({
    dynamic args,
    required FutureOr<T> Function(dynamic args) task,
    TaskPriority priority = TaskPriority.normal,
    String? taskName,
  }) async {
    if (!_isInitialized) {
      await init();
    }

    final completer = Completer<T>();
    final taskObj = Task<T>(
      args: args,
      task: task,
      priority: priority,
      taskName: taskName,
      completer: completer,
    );

    // Find an available worker or queue the task
    final availableWorker = _findAvailableWorker();
    if (availableWorker != null) {
      _executeTask(availableWorker, taskObj);
    } else {
      _taskQueue.add(taskObj);
    }

    return completer.future;
  }

  _IsolateWorker? _findAvailableWorker() {
    for (final worker in _workers) {
      if (!worker.isBusy) {
        return worker;
      }
    }
    return null;
  }

  void _executeTask(_IsolateWorker worker, Task task) {
    worker.execute(task).then((_) {
      // Check if there are more tasks in the queue
      if (_taskQueue.isNotEmpty) {
        final nextTask = _taskQueue.removeFirst();
        _executeTask(worker, nextTask);
      }
    });
  }

  /// Dispose all isolates in the pool
  Future<void> dispose() async {
    for (final worker in _workers) {
      await worker.dispose();
    }
    _workers.clear();
    _isInitialized = false;
  }
}

class _IsolateWorker {
  final int id;
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  bool isBusy = false;

  _IsolateWorker({required this.id});

  Future<void> spawn() async {
    _receivePort = ReceivePort();

    _isolate = await Isolate.spawn(_isolateEntryPoint, _receivePort!.sendPort);

    _sendPort = await _receivePort!.first as SendPort;
  }

  Future<void> execute(Task task) async {
    if (_sendPort == null) {
      throw Exception('Worker isolate not initialized');
    }

    isBusy = true;
    final stopwatch = Stopwatch()..start();

    try {
      final responsePort = ReceivePort();

      _sendPort!.send({
        'args': task.args,
        'task': task.task,
        'sendPort': responsePort.sendPort,
      });

      final response = await responsePort.first;

      if (response is Exception || response is Error) {
        task.completer.completeError(response);
      } else {
        task.completer.complete(response);
      }

      if (task.taskName != null) {
        stopwatch.stop();
        developer.log(
          'Task ${task.taskName} completed in ${stopwatch.elapsedMilliseconds}ms on worker $id',
          name: 'TunaiIsolatePool',
        );
      }
    } catch (e) {
      task.completer.completeError(e);
    } finally {
      isBusy = false;
    }
  }

  Future<void> dispose() async {
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    _isolate = null;
    _sendPort = null;
    _receivePort = null;
  }

  static void _isolateEntryPoint(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      final dynamic args = message['args'];
      final dynamic Function(dynamic args) task = message['task'];
      final SendPort sendPort = message['sendPort'];

      try {
        final result = await task(args);
        sendPort.send(result);
      } catch (e) {
        sendPort.send(e);
      }
    });
  }
}
