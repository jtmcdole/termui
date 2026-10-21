import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/atlas.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isColorEmoji properly distinguishes emoji variations', () {
    // Should be color emojis
    expect(isColorEmoji('🚀'), isTrue, reason: 'Modern emoji should be color');
    expect(
      isColorEmoji('♠\uFE0F'),
      isTrue,
      reason: 'Emoji variation selector makes it color',
    );

    // Should be monochrome (should NOT be color emojis)
    expect(
      isColorEmoji('♠'),
      isFalse,
      reason: 'Naked card suit should be monochrome',
    );
    expect(
      isColorEmoji('♥'),
      isFalse,
      reason: 'Naked card suit should be monochrome',
    );
    expect(
      isColorEmoji('🚀\uFE0E'),
      isFalse,
      reason: 'Text variation selector forces monochrome',
    );
    expect(isColorEmoji('A'), isFalse, reason: 'Normal text is monochrome');
  });

  test(
    'GlyphAtlasGenerator.generateEmpty includes \\uFFFF and paints cleanly',
    () async {
      final atlas = await GlyphAtlasGenerator.generateEmpty(
        fontSize: 13.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(() => atlas.image.dispose());

      expect(atlas.charRects.containsKey('\uFFFF'), isTrue);
      expect(atlas.nextGridIndex, equals(1));

      final buffer = Buffer(4, 2)..writeString(0, 0, 'Hi', Style.empty);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = TuiAtlasPainter(
        buffer: buffer,
        atlas: atlas,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
      );

      expect(
        () => painter.paint(
          canvas,
          Size(4 * atlas.cellWidth, 2 * atlas.cellHeight),
        ),
        returnsNormally,
      );
      recorder.endRecording().dispose();
    },
  );
}
