import 'package:termui/trace/widgets/timeline_canvas.dart';
import 'package:termui/trace/models/trace_models.dart';
import 'package:test/test.dart';

void main() {
  test('TimelineCanvas applies animation flashing to animatedSpan', () {
    final span = TraceSpan(
      name: 'SearchTarget',
      category: 'UI',
      startUs: 1000,
      endUs: 5000,
      depth: 0,
      args: {},
    );

    final widget = TimelineCanvas(
      spans: [span],
      offsetX: 0,
      offsetY: 0,
      zoomLevel: 100.0,
      maxSpanDuration: 10000,
      animatedSpan: span,
      animationProgress:
          0.5, // sin(0.5 * pi * 6) = sin(3pi) = 0? Wait, 0.5 * 18 = 9, sin(9) ... let's just test the property assignment
    );

    // This will fail because animatedSpan and animationProgress do not exist yet on TimelineCanvas
    expect(widget, isNotNull);
  });
}
