import 'package:termui/trace/models/trace_models.dart';
import 'package:test/test.dart';

TraceEvent _event(
  String name,
  String phase,
  int timestamp, {
  int tid = 1,
  int? dur,
  String category = 'tui',
}) => TraceEvent(
  name: name,
  phase: phase,
  category: category,
  timestamp: timestamp,
  dur: dur,
  tid: tid,
  args: const {},
);

void main() {
  group('computeSpans', () {
    test('returns empty list for empty input', () {
      expect(computeSpans(const []), isEmpty);
    });

    test('tracks independent stacks per tid', () {
      final spans = computeSpans([
        _event('T1Outer', 'B', 10, tid: 1),
        _event('T2Outer', 'B', 20, tid: 2),
        _event('T1Inner', 'B', 30, tid: 1),
        _event('T2Outer', 'E', 40, tid: 2),
        _event('T1Inner', 'E', 50, tid: 1),
        _event('T1Outer', 'E', 60, tid: 1),
      ]);

      final byName = {for (final s in spans) s.name: s};
      expect(byName['T1Outer']!.depth, 0);
      expect(byName['T1Outer']!.startUs, 10);
      expect(byName['T1Outer']!.endUs, 60);

      expect(byName['T1Inner']!.depth, 1);
      expect(byName['T1Inner']!.startUs, 30);
      expect(byName['T1Inner']!.endUs, 50);

      expect(byName['T2Outer']!.depth, 0);
      expect(byName['T2Outer']!.startUs, 20);
      expect(byName['T2Outer']!.endUs, 40);
    });

    test(
      'handles instant (i) and complete (X) events with and without dur',
      () {
        final spans = computeSpans([
          _event('Outer', 'B', 100),
          _event('Instant', 'i', 120),
          _event('CompleteNoDur', 'X', 140),
          _event('CompleteWithDur', 'X', 160, dur: 25),
          _event('Outer', 'E', 200),
        ]);

        final byName = {for (final s in spans) s.name: s};
        expect(byName['Instant']!.startUs, 120);
        expect(byName['Instant']!.endUs, 121);
        expect(byName['Instant']!.depth, 1);

        expect(byName['CompleteNoDur']!.startUs, 140);
        expect(byName['CompleteNoDur']!.endUs, 141);
        expect(byName['CompleteNoDur']!.depth, 1);

        expect(byName['CompleteWithDur']!.startUs, 160);
        expect(byName['CompleteWithDur']!.endUs, 185);
        expect(byName['CompleteWithDur']!.depth, 1);
      },
    );

    test('clamps unclosed B spans to absolute max timestamp', () {
      final spans = computeSpans([
        _event('Unclosed', 'B', 50, tid: 1),
        _event('LaterInstant', 'i', 300, tid: 2),
      ]);

      final byName = {for (final s in spans) s.name: s};
      expect(byName['Unclosed']!.startUs, 50);
      expect(byName['Unclosed']!.endUs, 300);
      expect(byName['Unclosed']!.depth, 0);
    });

    test('ignores stray E events without matching B', () {
      final spans = computeSpans([
        _event('StrayEmpty', 'E', 5),
        _event('Active', 'B', 10),
        _event('StrayMismatch', 'E', 20),
        _event('Active', 'E', 40),
      ]);

      expect(spans, hasLength(1));
      expect(spans.single.name, 'Active');
      expect(spans.single.startUs, 10);
      expect(spans.single.endUs, 40);
    });

    test('unwinds nested orphan spans when an enclosing span closes', () {
      final spans = computeSpans([
        _event('Outer', 'B', 10),
        _event('OrphanInner', 'B', 20),
        _event('OrphanDeep', 'B', 30),
        _event('Outer', 'E', 100),
      ]);

      final byName = {for (final s in spans) s.name: s};
      expect(spans, hasLength(3));

      expect(byName['OrphanDeep']!.startUs, 30);
      expect(byName['OrphanDeep']!.endUs, 100);
      expect(byName['OrphanDeep']!.depth, 2);

      expect(byName['OrphanInner']!.startUs, 20);
      expect(byName['OrphanInner']!.endUs, 100);
      expect(byName['OrphanInner']!.depth, 1);

      expect(byName['Outer']!.startUs, 10);
      expect(byName['Outer']!.endUs, 100);
      expect(byName['Outer']!.depth, 0);
    });
  });
}
