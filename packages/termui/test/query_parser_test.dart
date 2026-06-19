import 'package:test/test.dart';

import '../bin/termui_trace.dart';

void main() {
  group('QueryToken Logic', () {
    test('parses -dur:<0.5s correctly', () {
      final token = QueryToken(
        isExclusion: true,
        field: 'dur',
        operator: '<',
        value: '0.5s',
      );

      expect(token.isExclusion, isTrue);
      expect(token.field, 'dur');
      expect(token.operator, '<');
      expect(token.durationUs, 500000.0); // 0.5s in micros

      final span = TraceSpan(
        name: 'test',
        category: 'cat',
        startUs: 0,
        endUs: 400000, // 0.4s
        depth: 0,
        args: {},
      );

      // 0.4s < 0.5s is true, but isExclusion makes it false
      expect(token.matches(span), isFalse);
    });

    test('matches name with Smart Case', () {
      final token = QueryToken(
        isExclusion: false,
        field: 'name',
        operator: null,
        value: 'Build',
      );

      expect(token.isSmartCase, isTrue);

      final span1 = TraceSpan(
        name: 'Builder',
        category: 'cat',
        startUs: 0,
        endUs: 10,
        depth: 0,
        args: {},
      );
      expect(token.matches(span1), isTrue);

      final span2 = TraceSpan(
        name: 'build',
        category: 'cat',
        startUs: 0,
        endUs: 10,
        depth: 0,
        args: {},
      );
      // Smart case requires exact case match if query has upper case
      expect(token.matches(span2), isFalse);
    });

    test('matches regex', () {
      final token = QueryToken(
        isExclusion: false,
        field: null,
        operator: null,
        value: '/^test_\\d+/',
      );

      expect(token.regex, isNotNull);

      final span1 = TraceSpan(
        name: 'test_123',
        category: 'cat',
        startUs: 0,
        endUs: 10,
        depth: 0,
        args: {},
      );
      expect(token.matches(span1), isTrue);

      final span2 = TraceSpan(
        name: 'foo_test_123',
        category: 'cat',
        startUs: 0,
        endUs: 10,
        depth: 0,
        args: {},
      );
      expect(token.matches(span2), isFalse);
    });
  });

  group('SearchOverlayState Query Parser', () {
    test('extracts multiple tokens correctly', () {
      final parser = QueryToken.parseQuery;

      final tokens = parser('-dur:<0.5s name:foo "exact match"');
      expect(tokens.length, 3);

      expect(tokens[0].isExclusion, isTrue);
      expect(tokens[0].field, 'dur');
      expect(tokens[0].operator, '<');
      expect(tokens[0].value, '0.5s');

      expect(tokens[1].isExclusion, isFalse);
      expect(tokens[1].field, 'name');
      expect(tokens[1].operator, null);
      expect(tokens[1].value, 'foo');

      expect(tokens[2].isExclusion, isFalse);
      expect(tokens[2].field, null);
      expect(tokens[2].operator, null);
      expect(tokens[2].value, 'exact match');
    });
  });
}
