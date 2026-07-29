import 'package:test/test.dart';
import 'package:termui_audio/termui_audio.dart';

void main() {
  test(
    'TermuiAudioEngine exports the Codefu-designed opinionated API surface',
    () {
      // This should compile fine if the API is exported correctly.
      final AudioBuffer? buffer = null;
      final AudioBus? bus = null;
      final TermuiAudioEngine? engine = null;

      expect(buffer, isNull);
      expect(bus, isNull);
      expect(engine, isNull);
    },
  );
}
