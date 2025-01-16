import 'package:flutter/foundation.dart';

abstract class TunaiDBLogger {
  void logInit(String message);

  void logAction(String message);

  void logError(String message);
}

class TunaiDBLoggerImpl implements TunaiDBLogger {
  @override
  void logInit(String message) {
    debugPrint('TunaiDB: $message');
  }

  @override
  void logAction(String message) {
    // debugPrint('TunaiDB: $message');
  }

  @override
  void logError(String message) {
    // debugPrint('TunaiDB: $message');
  }
}
