import 'dart:async';
import 'dart:collection';

import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';
import 'package:tunai_db/tunai_db.dart';

class TunaiDBTrxnQueue {
  final _mutex = Lock();
  static final TunaiDBTrxnQueue _instance = TunaiDBTrxnQueue._internal();
  factory TunaiDBTrxnQueue() => _instance;
  TunaiDBTrxnQueue._internal();

  Database get _db => TunaiDBInitializer().database;

  void logAction(String message) {
    TunaiDBInitializer.logger.logAction(message);
  }

  final Queue<_QueueItem> _writeQueue = Queue<_QueueItem>();
  Future? _currentWrite;
  bool _processing = false;

  /// Adds an operation to the queue and returns a Future that completes
  /// when the operation is done
  Future<T> add<T>({
    String? operationName,
    required Future<T> Function() operation,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final completer = Completer<T>();

    _writeQueue.add(_QueueItem(
      operationName: operationName,
      operation: () async {
        try {
          final result = await operation();
          completer.complete(result);
          return result;
        } catch (e) {
          completer.completeError(e);
          rethrow;
        }
      },
    ));

    _processQueue();

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _writeQueue.removeFirst();
        throw TimeoutException('Database Operation timed out');
      },
    );
  }

  Future<void> _processQueue() async {
    await _mutex.synchronized(() async {
      if (_processing) return;
      _processing = true;

      try {
        while (_writeQueue.isNotEmpty) {
          final item = _writeQueue.first;
          _currentWrite = item.operation();
          if (item.operationName != null) {
            logAction('TunaiDBQueue Running : ${item.operationName}');
          }
          try {
            await _currentWrite;
          } catch (e) {
            logAction('TunaiDBQueue Error : ${item.operationName}');
          } finally {
            _writeQueue.removeFirst();
          }
        }
      } finally {
        _currentWrite = null;
        _processing = false;
      }
    });
  }

  /// Clears all pending operations in the queue
  void clear() {
    _writeQueue.clear();
  }

  /// Returns true if the queue is currently processing operations
  bool get isProcessing => _processing;

  /// Returns the number of pending operations in the queue
  int get pendingOperations => _writeQueue.length;
}

class _QueueItem {
  final String? operationName;
  final Future Function() operation;

  _QueueItem({required this.operation, this.operationName});
}
