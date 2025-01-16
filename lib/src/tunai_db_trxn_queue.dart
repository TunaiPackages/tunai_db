import 'dart:async';
import 'dart:collection';

class TunaiDBTrxnQueue {
  static final TunaiDBTrxnQueue _instance = TunaiDBTrxnQueue._internal();
  factory TunaiDBTrxnQueue() => _instance;
  TunaiDBTrxnQueue._internal();

  final Queue<_QueueItem> _writeQueue = Queue<_QueueItem>();
  Future? _currentWrite;
  bool _processing = false;

  /// Adds an operation to the queue and returns a Future that completes
  /// when the operation is done
  Future<T> add<T>(Future<T> Function() operation) async {
    final completer = Completer<T>();

    _writeQueue.add(_QueueItem(
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

    return completer.future;
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
