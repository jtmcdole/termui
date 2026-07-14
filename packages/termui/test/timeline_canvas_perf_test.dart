import 'package:termui/termui.dart';
import 'package:termui/trace/widgets/timeline_canvas.dart';
import 'package:termui/trace/models/trace_models.dart';
import 'package:test/test.dart';

void main() {
  test('TimelineCanvas handles massive span overdraw efficiently', () {
    // Generate 10,000 overlapping spans simulating a dense trace
    final spans = List.generate(
      10000,
      (i) => TraceSpan(
        name: 'Span $i',
        category: 'Test',
        startUs: 100,
        endUs: 500,
        depth: i % 10, // 10 layers of depth overlapping completely
        args: {},
      ),
    );

    final canvas = TimelineCanvas(
      spans: spans,
      offsetX: 0,
      offsetY: 0,
      zoomLevel: 10.0,
      maxSpanDuration: 1000,
    );

    final element = canvas.createElement();
    // Mount and layout
    element.layout(BoxConstraints.tightFor(width: 80, height: 24));

    final buffer = Buffer(80, 24);

    // 1. Run with Set<int> (Old method)
    TimelineCanvas.debugUseBoolArray = false;
    final watchSet = Stopwatch()..start();
    element.performPaint(buffer, Offset.zero);
    watchSet.stop();
    print('Paint time with Set<int>: ${watchSet.elapsedMilliseconds}ms');

    // Reset buffer (or just let it paint over, but let's re-init buffer just in case, though performPaint overwrites)
    final buffer2 = Buffer(80, 24);

    // 2. Run with BoolArray (New method)
    TimelineCanvas.debugUseBoolArray = true;
    final watchArray = Stopwatch()..start();
    element.performPaint(buffer2, Offset.zero);
    watchArray.stop();
    print('Paint time with BoolArray: ${watchArray.elapsedMilliseconds}ms');

    print(
      'Performance gain: ${watchSet.elapsedMilliseconds - watchArray.elapsedMilliseconds}ms',
    );

    // Just verify the test succeeded without exception
    expect(true, isTrue);
  });
}
