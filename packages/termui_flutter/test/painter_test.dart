import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';

void main() {
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
}
