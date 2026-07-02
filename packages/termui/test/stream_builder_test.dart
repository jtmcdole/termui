import 'dart:async';
import 'package:test/test.dart';
import 'package:termui/termui.dart';

String getBufferText(Buffer buffer) {
  final sb = StringBuffer();
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      sb.write(buffer.getCharacter(x, y));
    }
  }
  return sb.toString();
}

void main() {
  group('StreamBuilder', () {
    test('renders initial data when stream is null', () {
      final widget = StreamBuilder<int>(
        stream: null,
        initialData: 42,
        builder: (context, snapshot) {
          return Text('Value: ${snapshot.data}');
        },
      );
      final element = widget.createElement();
      element.mount(null);

      element.layout(BoxConstraints.loose(const Size(50, 5)));
      final buffer = Buffer(50, 5);
      element.paint(buffer, Offset.zero);

      expect(getBufferText(buffer), contains('Value: 42'));
    });

    test('updates when stream emits new data', () async {
      final controller = StreamController<int>();

      final widget = StreamBuilder<int>(
        stream: controller.stream,
        initialData: 0,
        builder: (context, snapshot) {
          return Text('Value: ${snapshot.data}');
        },
      );
      final element = widget.createElement();
      element.mount(null);

      element.layout(BoxConstraints.loose(const Size(50, 5)));
      var buffer = Buffer(50, 5);
      element.paint(buffer, Offset.zero);
      expect(getBufferText(buffer), contains('Value: 0'));

      // Emit new value
      controller.add(42);
      await Future.delayed(Duration.zero); // yield for stream to process

      element.rebuild();
      element.layout(BoxConstraints.loose(const Size(50, 5)));
      buffer = Buffer(50, 5);
      element.paint(buffer, Offset.zero);
      expect(getBufferText(buffer), contains('Value: 42'));

      await controller.close();
    });

    test('handles errors correctly', () async {
      final controller = StreamController<int>();

      final widget = StreamBuilder<int>(
        stream: controller.stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Text('Error: ${snapshot.error}');
          }
          return Text('Value: ${snapshot.data}');
        },
      );
      final element = widget.createElement();
      element.mount(null);

      element.layout(BoxConstraints.loose(const Size(50, 5)));
      var buffer = Buffer(50, 5);
      element.paint(buffer, Offset.zero);
      expect(getBufferText(buffer), contains('Value: null'));

      // Emit error
      controller.addError('Something went wrong');
      await Future.delayed(Duration.zero); // yield for stream to process

      element.rebuild();
      element.layout(BoxConstraints.loose(const Size(50, 5)));
      buffer = Buffer(50, 5);
      element.paint(buffer, Offset.zero);
      expect(getBufferText(buffer), contains('Error: Something went wrong'));

      await controller.close();
    });
  });
}
