import 'package:example/data/dog/dog.dart';
import 'package:tunai_db/tunai_db.dart';

class DogDb extends TunaiDB<Dog> {
  @override
  DBDataConverter<Dog> get dbTableDataConverter => _DogDataConverter();

  @override
  DBTable get table => DBTable(
    tableName: 'dog',
    fields: [
      DBField(
        fieldName: 'dogID',
        fieldType: DBFieldType.integer,
        isPrimaryKey: true,
      ),
      DBField(fieldName: 'name', fieldType: DBFieldType.text),
      DBField(fieldName: 'age', fieldType: DBFieldType.integer),
      DBField(fieldName: 'breed', fieldType: DBFieldType.text),
      DBField(fieldName: 'humanID', fieldType: DBFieldType.integer),
    ],
  );
}

class _DogDataConverter extends DBDataConverter<Dog> {
  @override
  Dog fromMap(Map<String, Object?> map) {
    return Dog(
      dogID: map['dogID'] as int,
      name: map['name'] as String,
      age: map['age'] as int,
      breed: map['breed'] as String,
      humanID: map['humanID'] as int,
    );
  }

  @override
  Map<String, Object?> toMap(Dog data) {
    return {
      'dogID': data.dogID,
      'name': data.name,
      'age': data.age,
      'breed': data.breed,
      'humanID': data.humanID,
    };
  }
}
