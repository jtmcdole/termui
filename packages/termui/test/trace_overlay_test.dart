import 'package:termui/termui.dart';
import 'package:termui/termui_trace.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => FocusManager.instance.setPrimaryFocus(null));

  test('SearchOverlay renders query and matching spans when spawned', () {
    final spans = <TraceSpan>[
      TraceSpan(
        name: 'layoutPass',
        category: 'layout',
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
      initialQuery: 'layoutPass',
    );

    final element = overlay.createElement();
    element.mount(null);
    element.rebuild();
    element.layout(BoxConstraints.tight(const Size(60, 20)));

    final buffer = Buffer.blank(60, 20);
    element.paint(buffer, Offset.zero);

    final rendered = [
      for (var y = 0; y < buffer.height; y++)
        [
          for (var x = 0; x < buffer.width; x++) buffer.getCharacter(x, y),
        ].join(),
    ].join('\n');

    expect(rendered, contains('layoutPass'));
  });
}
