import 'package:flutter/foundation.dart';

interface class TunaiDBLogger {
  void logInit(String message) {
    debugPrint('TunaiDB: $message');
  }

  void logAction(String message) {
    debugPrint('TunaiDB: $message');
  }
}
