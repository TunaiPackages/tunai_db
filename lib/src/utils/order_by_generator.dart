import 'query_generator.dart';

class OrderByGenerator extends QueryGenerator {
  final String? orderBy;

  const OrderByGenerator({this.orderBy});

  @override
  String generate() {
    if (orderBy == null || orderBy!.isEmpty) {
      return '';
    }
    return ' ORDER BY $orderBy';
  }
}
