abstract class DBDataConverter<T> {
  const DBDataConverter();
  Map<String, Object?> toMap(T data);

  T fromMap(Map<String, Object?> map);
}
