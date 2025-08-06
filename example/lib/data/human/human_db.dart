import 'package:example/data/human/human.dart';
import 'package:tunai_db/tunai_db.dart';

class HumanDb extends TunaiDB<Human> {
  @override
  DBDataConverter<Human> get dbTableDataConverter => _HumanDataConverter();

  @override
  DBTable get table => DBTable(
    tableName: 'human',
    fields: [
      DBField(
        fieldName: 'humanID',
        fieldType: DBFieldType.integer,
        isPrimaryKey: true,
      ),
      DBField(fieldName: 'name', fieldType: DBFieldType.text),
      DBField(fieldName: 'age', fieldType: DBFieldType.integer),
      DBField(fieldName: 'email', fieldType: DBFieldType.text),
    ],
  );
}

class _HumanDataConverter extends DBDataConverter<Human> {
  @override
  Human fromMap(Map<String, Object?> map) {
    return Human(
      humanID: map['humanID'] as int,
      name: map['name'] as String,
      age: map['age'] as int,
      email: map['email'] as String,
    );
  }

  @override
  Map<String, Object?> toMap(Human data) {
    return {
      'humanID': data.humanID,
      'name': data.name,
      'age': data.age,
      'email': data.email,
    };
  }
}
