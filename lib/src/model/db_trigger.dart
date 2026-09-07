class DBTrigger {
  final String name;
  final String table;
  final TriggerTiming timing;
  final TriggerEvent event;
  final String body;

  const DBTrigger({
    required this.name,
    required this.table,
    required this.timing,
    required this.event,
    required this.body,
  });

  String toSQL() {
    return '''
    CREATE TRIGGER IF NOT EXISTS $name
    ${timing.sql} ${event.sql} ON $table
    BEGIN
      $body
    END;
    ''';
  }
}

enum TriggerTiming { before, after, insteadOf }

extension TriggerTimingSQL on TriggerTiming {
  String get sql {
    switch (this) {
      case TriggerTiming.before:
        return "BEFORE";
      case TriggerTiming.after:
        return "AFTER";
      case TriggerTiming.insteadOf:
        return "INSTEAD OF";
    }
  }
}

enum TriggerEvent { insert, update, delete }

extension TriggerEventSQL on TriggerEvent {
  String get sql {
    switch (this) {
      case TriggerEvent.insert:
        return "INSERT";
      case TriggerEvent.update:
        return "UPDATE";
      case TriggerEvent.delete:
        return "DELETE";
    }
  }
}
