import 'package:termui/termui_trace.dart';
import 'package:test/test.dart';

void main() {
  test('SearchOverlay renders successfully when spawned', () {
    final spans = <TraceSpan>[
      TraceSpan(
        name: 'test',
        category: 'cat',
        startUs: 0,
        endUs: 1000,
        depth: 0,
        args: {},
      ),
    ];

    final overlay = SearchOverlay(
      spans: spans,
      onMatchSelected: (_) {},
      onQueryChanged: (_) {},
      onClose: () {},
      initialQuery: '',
    );

    final element = overlay.createElement();
    element.mount(null);
    element.rebuild();

    // If we reach here without exception, it builds fine.
    expect(true, isTrue);
  });
}
