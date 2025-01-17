import 'package:flutter/foundation.dart';

abstract class TunaiDBLogger {
  void logInit(String message);

  void logFetch(String message);

  void logAction(String message);

  void logError(String message);

  void logRaw(String message);
}

class TunaiDBLoggerImpl implements TunaiDBLogger {
  @override
  void logInit(String message) {
    debugPrint('TunaiDB: $message');
  }

  @override
  void logFetch(String message) {
    // debugPrint('TunaiDB: $message');
  }

  @override
  void logAction(String message) {
    // debugPrint('TunaiDB: $message');
  }

  @override
  void logError(String message) {
    // debugPrint('TunaiDB: $message');
  }

  @override
  void logRaw(String message) {
    // TODO: implement logRaw
  }
}
