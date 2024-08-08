import 'package:flutter/foundation.dart';

class TunaiDBLogger {
  static void logInit(String message) {
    debugPrint('TunaiDB: $message');
  }

  static void logAction(String message) {
    debugPrint('TunaiDB: $message');
  }
}
