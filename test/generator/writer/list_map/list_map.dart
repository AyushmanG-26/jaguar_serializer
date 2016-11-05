library serializer.test.list_map;

import 'package:test/test.dart';

import 'package:jaguar_serializer/generator/parser/import.dart';
import 'package:jaguar_serializer/generator/writer/writer.dart';

const PropertyTo prop1 = const ListPropertyTo(
    const ListPropertyTo(const BuiltinLeafPropertyTo(), 'String'),
    'List<String>');

void main() {
  group('Gen.Write.ListMap', () {
    setUp(() {});

    test('test1', () {
      ToItemWriter item = new ToItemWriter(prop1);
      String str = item.generate('model.tags');
      expect(str,
          'model.tags.map((List<String> val) => val.map((String val) => val).toList()).toList()');
    });
  });
}
