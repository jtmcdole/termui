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

        expect(ansi, contains('\x1b[58:2::255:0:128m'));
        expect(ansi, contains('\x1b[4:3m'));
        expect(ansi, contains('53'));
      },
    );

    test(
      'RichText, Compositor, and Renderer preserve and emit OSC 8 hyperlinks',
      () {
        const widget = RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: 'Docs',
                style: Style(
                  foreground: Color(0, 200, 255),
                  underlineStyle: UnderlineStyle.single,
                  uri: 'https://github.com/ termui',
                ),
              ),
              TextSpan(text: '!'),
            ],
          ),
        );
        final element = widget.createElement()..mount(null);
        element.layout(const BoxConstraints(maxWidth: 10, maxHeight: 1));

        final layerBuf = Buffer(10, 1);
        element.paint(layerBuf, Offset.zero);
        expect(layerBuf.hasUris, isTrue);
        expect(layerBuf.getUri(0, 0), equals('https://github.com/ termui'));
        expect(layerBuf.getUri(4, 0), isNull);

        final target = Buffer.blank(10, 1);
        Compositor().composite(
          target: target,
          layers: [LayeredBuffer(buffer: layerBuf, x: 0, y: 0, zIndex: 0)],
        );
        expect(target.getUri(0, 0), equals('https://github.com/ termui'));
        expect(target.getUri(3, 0), equals('https://github.com/ termui'));
        expect(target.getUri(4, 0), isNull);

        final renderer = Renderer(10, 1);
        final out = StringBuffer();
        renderer.render(target, out);
        final ansi = out.toString();

        expect(ansi, contains('\x1b]8;;https://github.com/ termui\x1b\\'));
        expect(ansi, contains('\x1b]8;;\x1b\\'));
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

    test(
      'sanitizeOsc8Uri strips control characters in Renderer and toAnsiString',
      () {
        final buffer = Buffer.blank(5, 1);
        buffer.writeString(
          0,
          0,
          'Link',
          const Style(uri: 'https://example.com\x1b\\INJECTED\x07'),
        );

        final renderer = Renderer(5, 1);
        final out = StringBuffer();
        renderer.render(buffer, out);
        expect(
          out.toString(),
          contains('\x1b]8;;https://example.com\\INJECTED\x1b\\'),
        );
        expect(out.toString(), isNot(contains('example.com\x1b\\INJECTED')));

        final serialized = buffer.toAnsiString();
        expect(
          serialized,
          contains('\x1b]8;;https://example.com\\INJECTED\x1b\\'),
        );
      },
    );

    test(
      'setAttributes preserves existing URI on color-only updates and clears on empty string',
      () {
        final buffer = Buffer.blank(5, 1);
        buffer.writeString(
          0,
          0,
          'Click',
          const Style(uri: 'https://flutter.dev'),
        );
        expect(buffer.getUri(0, 0), equals('https://flutter.dev'));

        buffer.setAttributes(0, 0, bg: const Color(20, 40, 60).argb);
        expect(buffer.getUri(0, 0), equals('https://flutter.dev'));

        buffer.setAttributes(0, 0, uri: '');
        expect(buffer.getUri(0, 0), isNull);
      },
    );

    test(
      'BufferAnsiSerialization.fromAnsi round-trips 4:x, 53, 58:2, and OSC 8',
      () {
        final original = Buffer.blank(6, 1);
        original.writeString(
          0,
          0,
          'Styled',
          const Style(
            foreground: Color(10, 20, 30),
            underlineStyle: UnderlineStyle.curly,
            underlineColor: Color(200, 100, 50),
            modifiers: Modifier.overline,
            uri: 'https://dart.dev',
          ),
        );

        final ansi = original.toAnsiString();
        final parsed = BufferAnsiSerialization.fromAnsi(
          ansi,
          width: 6,
          height: 1,
        );

        for (var x = 0; x < 6; x++) {
          expect(
            Modifier.getUnderlineStyle(parsed.getModifiers(x, 0)),
            equals(UnderlineStyle.curly),
          );
          expect(
            Modifier.has(parsed.getModifiers(x, 0), Modifier.overline),
            isTrue,
          );
          expect(
            parsed.getUnderlineColor(x, 0),
            equals(const Color(200, 100, 50).argb),
          );
          expect(parsed.getUri(x, 0), equals('https://dart.dev'));
        }
      },
    );

    test(
      'Modifier.mergeLayered preserves upper UnderlineStyle and Viewport resets underlineColor',
      () {
        final upper = Modifier.withUnderlineStyle(
          Modifier.bold,
          UnderlineStyle.single,
        );
        final lower = Modifier.withUnderlineStyle(
          Modifier.italic,
          UnderlineStyle.dotted,
        );
        final merged = Modifier.mergeLayered(upper, lower);
        expect(Modifier.has(merged, Modifier.bold), isTrue);
        expect(Modifier.has(merged, Modifier.italic), isTrue);
        expect(
          Modifier.getUnderlineStyle(merged),
          equals(UnderlineStyle.single),
        );

        final buf = Buffer.blank(4, 1);
        final vp = Viewport(buf, const Rect(0, 0, 4, 1));
        vp.writeString(
          0,
          0,
          'ABCD',
          const Style(
            underlineStyle: UnderlineStyle.single,
            underlineColor: Color(255, 0, 0),
            uri: 'https://a.example',
          ),
        );
        vp.writeString(0, 0, 'XY', const Style(foreground: Colors.white));
        expect(buf.getUnderlineColor(0, 0), equals(0));
        expect(buf.getUri(0, 0), isNull);
        expect(
          buf.getUnderlineColor(2, 0),
          equals(const Color(255, 0, 0).argb),
        );
        expect(buf.getUri(2, 0), equals('https://a.example'));
      },
    );
  });
}
