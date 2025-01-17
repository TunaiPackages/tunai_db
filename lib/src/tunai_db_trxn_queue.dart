import 'dart:async';
import 'dart:collection';

import 'package:sqflite/sqflite.dart';
import 'package:tunai_db/tunai_db.dart';

class TunaiDBTrxnQueue {
  static final TunaiDBTrxnQueue _instance = TunaiDBTrxnQueue._internal();
  factory TunaiDBTrxnQueue() => _instance;
  TunaiDBTrxnQueue._internal();

  Database get _db => TunaiDBInitializer().database;

  final Queue<_QueueItem> _writeQueue = Queue<_QueueItem>();
  Future? _currentWrite;
  bool _processing = false;
  bool _isTransaction = false;
  Transaction? _currentTransaction;

  /// Adds an operation to the queue and returns a Future that completes
  /// when the operation is done
  Future<T> add<T>({
    required Future<T> Function(DatabaseExecutor executor) operation,
    bool requiredTransaction = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final completer = Completer<T>();

    _writeQueue.add(_QueueItem(
      operation: () async {
        try {
          if (requiredTransaction && _currentTransaction == null) {
            await _db.transaction((txn) async {
              _currentTransaction = txn;
              final result = await operation(txn);
              completer.complete(result);
              return result;
            });
            _currentTransaction = null;
          } else if (requiredTransaction && _currentTransaction != null) {
            final result = await operation(_currentTransaction!);
            completer.complete(result);
            return result;
          } else {
            final result = await operation(_db);
            completer.complete(result);
            return result;
          }
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
        throw TimeoutException('Database Operation timed out');
      },
    );
  }

  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;

    try {
      while (_writeQueue.isNotEmpty) {
        final item = _writeQueue.first;
        _currentWrite = item.operation();

        try {
          await _currentWrite;
        } finally {
          _writeQueue.removeFirst();
        }
      }
    } finally {
      _currentWrite = null;
      _processing = false;
    }
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
  final Future Function() operation;

  _QueueItem({required this.operation});
}
