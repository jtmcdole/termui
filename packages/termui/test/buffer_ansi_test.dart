import 'package:test/test.dart';
import 'package:termui/termui.dart';

final class _ThrowingEffect extends TerminalEffect {
  @override
  void applyEffect(Buffer buffer, Rect bounds) {
    throw StateError('boom during effect');
  }
}

final class _TintEffect extends TerminalEffect {
  @override
  void applyEffect(Buffer buffer, Rect bounds) {
    buffer.setCharacter(bounds.x, bounds.y, 'E');
  }
}

void main() {
  group('BufferAnsiSerialization', () {
    test(
      'round-trips Buffer toAnsiString and BufferAnsiSerialization.fromAnsi',
      () {
        final buffer = Buffer(10, 5);
        buffer.setCharacter(2, 2, 'A');
        buffer.setForeground(2, 2, 0xFFFF0000); // Red
        buffer.setBackground(2, 2, 0xFF0000FF); // Blue

        final ansiStr = buffer.toAnsiString();
        expect(ansiStr, contains('\x1b[38;2;255;0;0;48;2;0;0;255mA'));

        final restored = BufferAnsiSerialization.fromAnsi(ansiStr);
        expect(restored.width, equals(10));
        expect(restored.height, equals(5));
        expect(restored.getCharacter(2, 2), equals('A'));
        expect(restored.getForeground(2, 2), equals(0xFFFF0000));
        expect(restored.getBackground(2, 2), equals(0xFF0000FF));
      },
    );

    test('parses non-ASCII block art in O(N) without corruption', () {
      const artRow = '╔══════╗░░▒▒▓▓██';
      final ansi = '\x1B[38;2;0;255;128m$artRow\x1B[0m\n$artRow\n';
      final restored = BufferAnsiSerialization.fromAnsi(ansi);

      expect(restored.width, equals(16));
      expect(restored.height, equals(2));
      expect(restored.getCharacter(0, 0), equals('╔'));
      expect(restored.getCharacter(15, 0), equals('█'));
      expect(restored.getForeground(0, 0), equals(0xFF00FF80));
      expect(restored.getCharacter(15, 1), equals('█'));
    });

    test(
      'round-trips wide emojis and CJK graphemes with continuation cells',
      () {
        final buffer = Buffer.blank(8, 1);
        buffer.writeString(
          0,
          0,
          '🚀漢!',
          const Style(foreground: Color(10, 20, 30), modifiers: Modifier.bold),
        );

        expect(buffer.getCharacter(0, 0), equals('🚀'));
        expect(buffer.getCharacter(1, 0), equals(''));
        expect(buffer.getCharacter(2, 0), equals('漢'));
        expect(buffer.getCharacter(3, 0), equals(''));
        expect(buffer.getCharacter(4, 0), equals('!'));

        final untrimmed = buffer.toAnsiString(trimTrailingSpaces: false);
        final restored = BufferAnsiSerialization.fromAnsi(untrimmed);

        expect(restored.width, equals(8));
        expect(restored.height, equals(1));
        expect(restored.getCharacter(0, 0), equals('🚀'));
        expect(restored.getCharacter(1, 0), equals(''));
        expect(restored.getCharacter(2, 0), equals('漢'));
        expect(restored.getCharacter(3, 0), equals(''));
        expect(restored.getCharacter(4, 0), equals('!'));
        expect(restored.getModifiers(0, 0), equals(Modifier.bold));
        expect(restored.getModifiers(4, 0), equals(Modifier.bold));

        final trimmed = buffer.toAnsiString(
          trimTrailingSpaces: true,
          resetLineEndings: true,
        );
        final restoredTrimmed = BufferAnsiSerialization.fromAnsi(
          trimmed,
          width: 8,
          height: 1,
        );
        expect(restoredTrimmed.width, equals(8));
        expect(restoredTrimmed.getCharacter(0, 0), equals('🚀'));
        expect(restoredTrimmed.getCharacter(4, 0), equals('!'));
      },
    );

    test('supports SGR modifiers and individual reset codes', () {
      final buffer = Buffer.blank(5, 1);
      buffer.setCell(
        0,
        0,
        'B',
        0xFFFFFFFF,
        0xFF000000,
        Modifier.bold |
            Modifier.italic |
            Modifier.underline |
            Modifier.crossedOut,
      );
      buffer.setCell(
        1,
        0,
        'D',
        0xFFFFFFFF,
        0xFF000000,
        Modifier.dim | Modifier.blink | Modifier.reverse | Modifier.hidden,
      );
      buffer.setCell(2, 0, 'P', 0xFFFFFFFF, 0xFF000000, Modifier.none);

      final ansiStr = buffer.toAnsiString(trimTrailingSpaces: false);
      final restored = BufferAnsiSerialization.fromAnsi(ansiStr);

      expect(
        restored.getModifiers(0, 0),
        equals(
          Modifier.bold |
              Modifier.italic |
              Modifier.underline |
              Modifier.crossedOut,
        ),
      );
      expect(
        restored.getModifiers(1, 0),
        equals(
          Modifier.dim | Modifier.blink | Modifier.reverse | Modifier.hidden,
        ),
      );
      expect(restored.getModifiers(2, 0), equals(Modifier.none));

      // Verify explicit SGR reset codes (22..29, 39, 49) from raw ANSI input.
      final manual = BufferAnsiSerialization.fromAnsi(
        '\x1B[1;2;3;4;5;7;8;9;38;2;1;2;3;48;2;4;5;6mX'
        '\x1B[22;23;24;25;27;28;29;39;49mY\n',
      );
      expect(
        manual.getModifiers(0, 0),
        equals(
          Modifier.bold |
              Modifier.dim |
              Modifier.italic |
              Modifier.underline |
              Modifier.blink |
              Modifier.reverse |
              Modifier.hidden |
              Modifier.crossedOut,
        ),
      );
      expect(manual.getModifiers(1, 0), equals(Modifier.none));
      expect(manual.getForeground(1, 0), equals(0));
      expect(manual.getBackground(1, 0), equals(0));
    });

    test(
      'supports width/height clipping, carriage returns, and resetLineEndings',
      () {
        const ansi = '\x1b[38;2;255;0;0mABCD\rXY\r\nSECOND\nTHIRD\n';
        final clipped = BufferAnsiSerialization.fromAnsi(
          ansi,
          width: 4,
          height: 2,
        );
        expect(clipped.width, equals(4));
        expect(clipped.height, equals(2));
        expect(clipped.getCharacter(0, 0), equals('X'));
        expect(clipped.getCharacter(1, 0), equals('Y'));
        expect(clipped.getCharacter(2, 0), equals('C'));
        expect(clipped.getCharacter(3, 0), equals('D'));
        expect(clipped.getCharacter(0, 1), equals('S'));
        expect(clipped.getCharacter(3, 1), equals('O'));

        final styled = Buffer.blank(3, 2);
        styled.writeString(
          0,
          0,
          'Hi',
          const Style(foreground: Color(255, 0, 0)),
        );
        styled.writeString(
          0,
          1,
          'Ok',
          const Style(foreground: Color(255, 0, 0)),
        );
        expect(
          styled.toAnsiString(resetLineEndings: true),
          equals('\x1b[38;2;255;0;0mHi\x1b[0m\n\x1b[38;2;255;0;0mOk\x1b[0m\n'),
        );
        expect(
          styled.toAnsiString(resetLineEndings: false),
          equals('\x1b[38;2;255;0;0mHi\nOk\n\x1b[0m'),
        );
      },
    );
  });

  group('Compositor pool safety', () {
    test('releases rented pool buffer when an effect throws', () {
      final compositor = Compositor();
      final badLayerBuf = Buffer(4, 2)
        ..writeString(0, 0, 'X', const Style(foreground: Color(255, 0, 0)))
        ..addEffect(
          RegisteredEffect(_ThrowingEffect(), const Rect(0, 0, 4, 2), 0, 0),
        );

      expect(
        () => compositor.composite(
          target: Buffer(4, 2),
          layers: [LayeredBuffer(buffer: badLayerBuf, x: 0, y: 0, zIndex: 1)],
        ),
        throwsStateError,
      );

      final goodLayerBuf = Buffer(4, 2)
        ..writeString(0, 0, 'A', const Style(foreground: Color(0, 255, 0)))
        ..addEffect(
          RegisteredEffect(_TintEffect(), const Rect(0, 0, 4, 2), 0, 0),
        );
      final target = Buffer(4, 2);
      compositor.composite(
        target: target,
        layers: [LayeredBuffer(buffer: goodLayerBuf, x: 0, y: 0, zIndex: 1)],
      );
      expect(target.getCharacter(0, 0), equals('E'));
    });
  });
}
