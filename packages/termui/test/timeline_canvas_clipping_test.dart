import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui/termui_trace.dart';

void main() {
  test('TimelineCanvas visual clipping for long spans', () {
    final span = TraceSpan(
      name: 'PromptScope:paint',
      category: 'TUI',
      startUs: 1591010,
      endUs: 1805760,
      depth: 0,
      args: {},
    );

    final canvas = TimelineCanvas(
      spans: [span],
      offsetX: 1600000,
      offsetY: 0,
      zoomLevel: 1000.0,
      maxSpanDuration: 300000,
    );

    final element = canvas.createElement();
    element.mount(null);
    element.layout(BoxConstraints.tight(Size(40, 5)));

    final buffer = Buffer(40, 5);
    element.paint(buffer, Offset.zero);

    bool hasLeftIndicator = false;
    bool hasRightIndicator = false;
    for (int x = 1; x < 39; x++) {
      final char = buffer.getCharacter(x, 0);
      if (char == '◀' || char == '«') hasLeftIndicator = true;
      if (char == '▶' || char == '»') hasRightIndicator = true;
    }

    expect(
      hasLeftIndicator,
      isTrue,
      reason: 'Missing left off-screen indicator',
    );
    expect(
      hasRightIndicator,
      isTrue,
      reason: 'Missing right off-screen indicator',
    );
  });
}
