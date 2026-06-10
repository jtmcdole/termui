// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  testWidgets('Inspect GlyphAtlas coordinates', (WidgetTester tester) async {
    final atlas = await GlyphAtlasGenerator.generate(
      fontSize: 13,
      fontFamily: 'Cascadia Mono',
    );

    print(
      'Atlas cellWidth: ${atlas.cellWidth}, cellHeight: ${atlas.cellHeight}',
    );
    print('Atlas colWidth: ${atlas.colWidth}, rowHeight: ${atlas.rowHeight}');

    // Print coordinates of some standard characters
    final charsToPrint = ['A', 'B', 'a', 'b', ' ', '1', '│', '█'];
    for (final char in charsToPrint) {
      final rect = atlas.charRects[char];
      print("Character '$char' rect: $rect");
    }

    // Check if any character rect is null
    for (final char in charsToPrint) {
      expect(atlas.charRects[char], isNotNull);
    }
  });
}
