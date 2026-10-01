import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

// The transport adapter is deliberately tied to the exact dependency pins.
// ignore: implementation_imports
import 'package:sqflite_common/src/mixin/factory.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: implementation_imports
import 'package:sqflite_common_ffi/src/method_call.dart';

/// The optional background refresh lost ownership. Never retry it on another
/// connection: the foreground may already be using the database.
class DatabaseOwnershipRevoked implements Exception {
  const DatabaseOwnershipRevoked();
  @override
  String toString() => 'Background database ownership was revoked';
}

/// Coordinates foreground access with optional background work across engines.
///
/// Foreground ownership is process-lifetime, including minimized/logged-out
/// states. Background connections live in the coordinator isolate itself, so
/// killing a WorkManager engine cannot orphan a separate SQLite driver. A
/// foreground claim closes those handles before it acknowledges the handover.
/// Native close rolls back an unfinished transaction; committed work is retained.
/// Foreground connections keep their existing backend and are not proxied.
class TunaiDBOwnership {
  TunaiDBOwnership({this.name = 'tunai_db.background_owner.v1'});
  final String name;
  Future<SendPort>? _port;
  Future<void>? _foreground;

  Future<void> claimForeground() => _foreground ??= _claimForeground();

  Future<void> _claimForeground() async {
    await _request(await _server(), 'foreground');
  }

  Future<TunaiDBBackgroundLease?> tryBackground() async {
    final server = await _server();
    final notifications = ReceivePort();
    final token = notifications.sendPort;
    // Register before requesting ownership, so cancellation cannot leave an
    // acquired lease without an exit notification.
    Isolate.current.addOnExitListener(server, response: ['exited', token]);
    final lease = TunaiDBBackgroundLease._(server, notifications);
    try {
      final accepted = await _request(server, 'background', token);
      if (accepted == true) return lease;
      lease._dispose();
      return null;
    } catch (_) {
      lease._dispose();
      rethrow;
    }
  }

  Future<SendPort> _server() => _port ??= _findOrStart();

  Future<SendPort> _findOrStart() async {
    final existing = IsolateNameServer.lookupPortByName(name);
    if (existing != null) return existing;
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serve, ready.sendPort,
        debugName: 'TunaiDBBackgroundOwner');
    final server = await ready.first as SendPort;
    ready.close();
    if (IsolateNameServer.registerPortWithName(server, name)) return server;
    // This losing candidate has received no database requests.
    isolate.kill(priority: Isolate.immediate);
    final winner = IsolateNameServer.lookupPortByName(name);
    if (winner == null) throw StateError('Database owner registration lost');
    return winner;
  }
}

class TunaiDBBackgroundLease {
  TunaiDBBackgroundLease._(this._server, this._notifications) {
    _notifications.listen((_) => _revoked = true);
    factory = buildDatabaseFactory(
      tag: 'tunai_owned_background',
      invokeMethod: (method, [arguments]) async {
        if (_revoked) throw const DatabaseOwnershipRevoked();
        try {
          return await _request(
              _server, 'database', [_token, method, arguments]);
        } on DatabaseOwnershipRevoked {
          _revoked = true;
          rethrow;
        }
      },
    );
  }

  final SendPort _server;
  final ReceivePort _notifications;
  SendPort get _token => _notifications.sendPort;
  late final DatabaseFactory factory;
  bool _revoked = false;
  bool get isRevoked => _revoked;
  Future<void>? _closing;

  /// Idempotent. Acknowledged only after all this lease's native handles close.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await _request(_server, 'release', _token);
    } finally {
      _dispose();
    }
  }

  void _dispose() {
    _revoked = true;
    Isolate.current.removeOnExitListener(_server);
    _notifications.close();
  }
}

Future<Object?> _request(SendPort server, String command,
    [Object? args]) async {
  final reply = ReceivePort();
  try {
    server.send([command, args, reply.sendPort]);
    final value = await reply.first;
    if (value is Map && value['revoked'] == true) {
      throw const DatabaseOwnershipRevoked();
    }
    return responseToResultOrThrow(value);
  } finally {
    reply.close();
  }
}

void _serve(SendPort ready) {
  final inbox = ReceivePort();
  final coordinator = _Coordinator();
  ready.send(inbox.sendPort);
  inbox.listen((dynamic message) {
    // Each handler contains its errors. SQL requests must remain asynchronous:
    // sqflite can defer another request until a later COMMIT message arrives.
    unawaited(coordinator.handle(message as List));
  });
}

class _Pending {
  _Pending(this.reply);
  final SendPort reply;
  bool completed = false;
  void complete(Object response) {
    if (completed) return;
    completed = true;
    reply.send(response);
  }
}

class _Owner {
  _Owner(this.token);
  final SendPort token;
  bool active = true;
  final ids = <int>{};
  final pending = <_Pending>{};
  final lifecycle = <Future<void>>{};
  Future<void>? cleanup;
}

class _Coordinator {
  // This isolate performs the synchronous native SQLite calls itself. There
  // is no driver child that can outlive our resource tracking.
  final SqfliteInvokeHandler driver =
      createDatabaseFactoryFfi(noIsolate: true) as SqfliteInvokeHandler;
  _Owner? owner;
  bool foreground = false;

  Future<void> handle(List message) async {
    final command = message[0] as String;
    final args = message[1];
    final reply = message.length > 2 ? message[2] as SendPort : null;
    try {
      switch (command) {
        case 'foreground':
          // Reserve priority before awaiting cleanup; reject subsequent claims.
          foreground = true;
          final old = owner;
          if (old != null) await closeOwner(old);
          reply!.send({'result': true});
        case 'background':
          if (foreground || owner != null) {
            reply!.send({'result': false});
          } else {
            owner = _Owner(args as SendPort);
            reply!.send({'result': true});
          }
        case 'release':
        case 'exited':
          final old = owner;
          if (old != null && old.token == args) await closeOwner(old);
          reply?.send({'result': true});
        case 'database':
          await database(args as List, reply!);
        default:
          throw StateError('Unknown database ownership command');
      }
    } catch (error, stack) {
      // Cleanup failure deliberately retains owner: never acknowledge an unsafe
      // handover. A later foreground request sees that same cleanup failure.
      reply?.send(FfiMethodResponse.fromException(error, stack).toDataMap());
    }
  }

  Future<void> database(List args, SendPort reply) async {
    final current = owner;
    if (current == null || !current.active || current.token != args[0]) {
      reply.send({'revoked': true});
      return;
    }
    final method = args[1] as String;
    final arguments = args[2];
    final pending = _Pending(reply);
    current.pending.add(pending);
    Future<void> invoke() async {
      try {
        final result = await driver.invokeMethod<Object?>(method, arguments);
        if (method == 'openDatabase') {
          current.ids.add((result as Map)['id'] as int);
        } else if (method == 'closeDatabase') {
          current.ids.remove((arguments as Map)['id']);
        }
        pending.complete(FfiMethodResponse(result: result).toDataMap());
      } catch (error, stack) {
        pending.complete(
            FfiMethodResponse.fromException(error, stack).toDataMap());
      } finally {
        current.pending.remove(pending);
      }
    }

    final operation = invoke();
    // Await filesystem/open/close work before cleanup. SQL requests deferred
    // behind an unfinished transaction must instead fail with revocation.
    if (!const {
      'execute',
      'insert',
      'update',
      'query',
      'queryCursorNext',
      'batch'
    }.contains(method)) {
      current.lifecycle.add(operation);
      try {
        await operation;
      } finally {
        current.lifecycle.remove(operation);
      }
    } else {
      await operation;
    }
  }

  Future<void> closeOwner(_Owner old) => old.cleanup ??= _closeOwner(old);

  Future<void> _closeOwner(_Owner old) async {
    old.active = false;
    old.token.send('revoked');
    for (final request in old.pending.toList()) {
      request.complete({'revoked': true});
    }
    // No new requests can enter. Late opens are tracked before this completes.
    await Future.wait(old.lifecycle.toList());
    for (final id in old.ids.toList()) {
      await driver.invokeMethod<void>('closeDatabase', {'id': id});
      old.ids.remove(id);
    }
    if (identical(owner, old)) owner = null;
  }
}
