import 'query_generator.dart';

class LimitOffsetGenerator extends QueryGenerator {
  final int? limit;
  final int? offset;

  const LimitOffsetGenerator({
    this.limit,
    this.offset,
  });

  @override
  String generate() {
    String query = '';

    if (limit != null) {
      query += ' LIMIT $limit';
    }
    if (offset != null) {
      query += ' OFFSET $offset';
    }

    return query;
  }
}
