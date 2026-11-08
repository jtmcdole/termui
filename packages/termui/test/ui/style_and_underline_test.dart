import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('Style, UnderlineStyle, Overline, and UnderlineColor', () {
    test('Modifier encodes and decodes UnderlineStyle variants', () {
      expect(Modifier.getUnderlineStyle(Modifier.none), UnderlineStyle.none);
      expect(
        Modifier.getUnderlineStyle(Modifier.underline),
        UnderlineStyle.single,
      );

      for (final variant in UnderlineStyle.values) {
        final mask = Modifier.withUnderlineStyle(Modifier.bold, variant);
        expect(Modifier.has(mask, Modifier.bold), isTrue);
        expect(Modifier.getUnderlineStyle(mask), equals(variant));
        expect(
          Modifier.has(mask, Modifier.underline),
          equals(variant != UnderlineStyle.none),
        );
      }
    });

    test(
      'Style constructor and merge preserve underlineStyle and underlineColor',
      () {
        const base = Style(
          foreground: Colors.white,
          underlineStyle: UnderlineStyle.curly,
          underlineColor: Colors.red,
          modifiers: Modifier.overline,
        );
        expect(base.underlineStyle, UnderlineStyle.curly);
        expect(base.underlineColor, Colors.red);
        expect(Modifier.has(base.modifiers, Modifier.overline), isTrue);

        const override = Style(
          underlineStyle: UnderlineStyle.dashed,
          underlineColor: Colors.green,
        );
        final merged = base.merge(override);
        expect(merged.foreground, Colors.white);
        expect(merged.underlineStyle, UnderlineStyle.dashed);
        expect(merged.underlineColor, Colors.green);
        expect(Modifier.has(merged.modifiers, Modifier.overline), isTrue);
      },
    );

    test(
      'Buffer lazily stores underlineColor and Renderer emits SGR 4:x, 53, 58',
      () {
        final buffer = Buffer.blank(10, 2);
        expect(buffer.hasUnderlineColors, isFalse);

        buffer.writeString(
          0,
          0,
          'A',
          const Style(
            foreground: Color(255, 255, 255),
            underlineStyle: UnderlineStyle.curly,
            underlineColor: Color(255, 0, 128),
            modifiers: Modifier.overline,
          ),
        );
        expect(buffer.hasUnderlineColors, isTrue);
        expect(buffer.getUnderlineColor(0, 0), const Color(255, 0, 128).argb);
        expect(
          Modifier.getUnderlineStyle(buffer.getModifiers(0, 0)),
          UnderlineStyle.curly,
        );
        expect(
          Modifier.has(buffer.getModifiers(0, 0), Modifier.overline),
          isTrue,
        );

        final renderer = Renderer(10, 2);
        final out = StringBuffer();
        renderer.render(buffer, out);
        final ansi = out.toString();

        expect(ansi, contains('58;2;255;0;128'));
        expect(ansi, contains('4:3'));
        expect(ansi, contains('53'));
      },
    );

    test(
      'RichText and Compositor preserve underlineStyle and underlineColor',
      () {
        const widget = RichText(
          text: TextSpan(
            text: 'Wave',
            style: Style(
              foreground: Color(255, 255, 255),
              underlineStyle: UnderlineStyle.curly,
              underlineColor: Color(255, 64, 128),
            ),
          ),
        );
        final element = widget.createElement()..mount(null);
        element.layout(const BoxConstraints(maxWidth: 10, maxHeight: 2));

        final layerBuf = Buffer(10, 2);
        element.paint(layerBuf, Offset.zero);
        expect(
          layerBuf.getUnderlineColor(0, 0),
          equals(const Color(255, 64, 128).argb),
        );

        final target = Buffer.blank(10, 2);
        Compositor().composite(
          target: target,
          layers: [LayeredBuffer(buffer: layerBuf, x: 0, y: 0, zIndex: 0)],
        );
        expect(
          target.getUnderlineColor(0, 0),
          equals(const Color(255, 64, 128).argb),
        );
        expect(
          Modifier.getUnderlineStyle(target.getModifiers(0, 0)),
          equals(UnderlineStyle.curly),
        );
      },
    );
  });
}
