enum DBFieldType {
  integer,
  text,
  real,
  ;

  String get query => switch (this) {
        DBFieldType.integer => 'INTEGER',
        DBFieldType.text => 'TEXT',
        DBFieldType.real => 'REAL',
      };
}
