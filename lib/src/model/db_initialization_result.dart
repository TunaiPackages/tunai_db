/// Result of opening and preparing a database for application use.
enum DBInitializationResult {
  /// Initialization completed without discarding the database contents.
  ready,

  /// Irreconcilable schema required replacing all contents with empty schema.
  /// The consuming app must handle repopulation.
  rebuilt,

  /// The caller explicitly requested resetDB, rather than automatic recovery.
  reset,
}
