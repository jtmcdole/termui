import 'package:flutter_test/flutter_test.dart';
import 'package:example_flutter/src/viewmodel.dart';

void main() {
  group('AsciicastPlayerViewModel', () {
    test('loads cast data and parses header and events correctly', () async {
      final castContent =
          '{"version": 2, "width": 80, "height": 24, "timestamp": 1234567890}\n'
          '[0.1, "o", "Hello"]\n'
          '[0.2, "o", " World!"]\n';

      final vm = AsciicastPlayerViewModel();
      await vm.loadCastData('test.cast', castContent);

      expect(vm.header.width, equals(80));
      expect(vm.header.height, equals(24));
      expect(vm.events.length, equals(2));
      expect(vm.totalDuration, equals(0.2));
    });

    test('plays back events in chronological order', () async {
      final castContent =
          '{"version": 2, "width": 80, "height": 24}\n'
          '[0.1, "o", "A"]\n'
          '[0.2, "o", "B"]\n';

      final vm = AsciicastPlayerViewModel();
      await vm.loadCastData('test.cast', castContent);

      // Start playing and manually tick or set play state
      expect(vm.isPlaying, isFalse);
      vm.togglePlay();
      expect(vm.isPlaying, isTrue);

      // Verify that seeking to 0.15 updates current time and terminal buffer
      vm.seek(0.15);
      expect(vm.currentTime, equals(0.15));
      expect(vm.virtualTerminal.buffer.characters[0], equals('A'));

      // Seeking to 0.25 should render B
      vm.seek(0.25);
      expect(vm.currentTime, equals(0.2));
      expect(vm.virtualTerminal.buffer.characters[0], equals('A'));
      expect(vm.virtualTerminal.buffer.characters[1], equals('B'));
    });
  });
}
