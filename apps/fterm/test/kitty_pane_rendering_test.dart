import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_pty/termui_pty.dart';

final class _TestRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast(sync: true);
  final Completer<int> _exitCode = Completer<int>();

  void emitString(String ansi) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(ansi)));
    }
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }

  @override
  Future<void> dispose() async {
    if (!_output.isClosed) await _output.close();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

String _buildUnpaddedCompressedRgb(int width, int height) {
  final rgb = Uint8List(width * height * 3);
  for (var seed = 1; seed < 256; seed++) {
    final rng = Random(seed);
    for (var i = 0; i < rgb.length; i++) {
      rgb[i] = rng.nextInt(256);
    }
    final compressed = zlib.encode(rgb);
    if (compressed.length % 3 != 0) {
      final unpadded = base64Encode(compressed).replaceAll('=', '');
      assert(unpadded.length % 4 != 0);
      return unpadded;
    }
  }
  throw StateError('Failed to find unpadded zlib RGB stream');
}

void main() {
  group('FtermPaneController Kitty graphics end-to-end regressions (#366)', () {
    test(
      'Renders multi-row kitten icat stream at bottom row, preserves IDs across scrollback, and keeps cursor/indexed-fg Kitty IDs intact under SolarizedDark contrast',
      () async {
        final backend = _TestRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(
          backend: backend,
          initialCols: 12,
          initialRows: 6,
          maxScrollbackLines: 50,
          emitIndexedColors: true,
        );
        final port = session.openPort(initialCols: 12, initialRows: 6);
        final resolver = TerminalColorResolver(
          theme: tui.TerminalColorTheme.solarizedDark,
          settings: const TerminalThemeSettings(
            darkThemeId: 'solarized_dark',
            minimumContrast: 4.5,
          ),
        );
        final pane = FtermPaneController(
          paneId: 'kitty-pane',
          port: port,
          colorResolver: resolver,
          resizeDebounce: Duration.zero,
        )..setFocused(true);

        addTearDown(() async {
          await pane.dispose(disposePort: false);
          await port.dispose();
          await router.dispose();
        });

        pane.updateViewportSize(12, 6, 10.0, 20.0);
        backend.emitString('r0\r\nr1\r\nr2\r\nr3\r\nr4\r\n');

        final streamB64 = _buildUnpaddedCompressedRgb(30, 60);
        final mid = streamB64.length ~/ 2;
        backend.emitString(
          '\r\x1b_Ga=T,q=2,f=24,o=z,m=1,s=30,v=60;${streamB64.substring(0, mid)}\x1b\\',
        );
        backend.emitString(
          '\x1b_Ga=T,q=2;${streamB64.substring(mid)}\x1b\\\r\n❯ ',
        );

        final buf = pane.readDisplayBuffer();
        expect(buf.hasKittyImages, isTrue);

        // Expect 30x60 image placed across rows y=2,3,4 (3 cols x 3 rows) with prompt at y=5.
        for (var r = 0; r < 3; r++) {
          for (var c = 0; c < 3; c++) {
            final y = 2 + r;
            final ch = buf.getCharacter(c, y);
            final id = tui.extractKittyCellImageId(ch, buf.getForeground(c, y));
            expect(id, equals(0x80000001));
            expect(
              tui.parseKittyPlaceholderCell(ch),
              equals((row: r, col: c, imageIdMsb: 0x80)),
            );
            final resolved = buf.lookupKittyImage(c, y, id);
            expect(resolved, isNotNull);
            expect(resolved!.pixelWidth, equals(30));
            expect(resolved.pixelHeight, equals(60));
          }
        }
        expect(buf.getCharacter(0, 5), equals('❯'));

        // Pushing into scrollback + scrolling back up preserves Kitty lookup metadata.
        backend.emitString('\r\n\r\n');
        pane.scrollLines(2);
        final scrolledBuf = pane.readDisplayBuffer();
        expect(scrolledBuf.hasKittyImages, isTrue);
        for (var r = 0; r < 3; r++) {
          final y = 2 + r;
          final ch = scrolledBuf.getCharacter(0, y);
          final id = tui.extractKittyCellImageId(
            ch,
            scrolledBuf.getForeground(0, y),
          );
          expect(id, equals(0x80000001));
          expect(scrolledBuf.lookupKittyImage(0, y, id), isNotNull);
        }

        // Scroll back to bottom and verify SGR 38;5;42 and C=1 cursor overlap preserve imageId 42.
        pane.jumpToBottom();
        final pxB64 = base64Encode(Uint8List.fromList([0, 255, 0, 255]));
        backend.emitString(
          '\x1b[2J\x1b[1;1H'
          '\x1b_Ga=t,U=1,i=42,s=1,v=1,f=32,c=2,r=1;$pxB64\x1b\\'
          '\x1b[38;5;42m${tui.kittyPlaceholderCell(0, 0)}${tui.kittyPlaceholderCell(0, 1)}\x1b[39m'
          '\x1b[2;1H\x1b_Ga=T,i=42,s=1,v=1,f=32,c=1,r=1,C=1;$pxB64\x1b\\',
        );

        final afterBuf = pane.readDisplayBuffer();
        // U=1 indexed cell (0, 0) must keep ID 42, not SolarizedDark ANSI-42 contrast color.
        expect(
          tui.extractKittyCellImageId(
            afterBuf.getCharacter(0, 0),
            afterBuf.getForeground(0, 0),
          ),
          equals(42),
        );
        // C=1 cell (0, 1) sits directly under the focused SolarizedDark cursor; must keep ID 42.
        expect(
          afterBuf.getBackground(0, 1),
          equals(tui.TerminalColorTheme.solarizedDark.cursorColor.argb),
        );
        expect(
          tui.extractKittyCellImageId(
            afterBuf.getCharacter(0, 1),
            afterBuf.getForeground(0, 1),
          ),
          equals(42),
        );
      },
    );

    test(
      'Default termui_dark cursor over C=1 Kitty placeholder avoids Modifier.reverse, paints cursor background, and preserves imageId',
      () async {
        final backend = _TestRoutedPtyBackend();
        final router = PtyRouter();
        final session = router.createSession(
          backend: backend,
          initialCols: 8,
          initialRows: 4,
          emitIndexedColors: true,
        );
        final port = session.openPort(initialCols: 8, initialRows: 4);
        final resolver = TerminalColorResolver(
          theme: tui.TerminalColorTheme.termuiDark,
          settings: const TerminalThemeSettings(darkThemeId: 'termui_dark'),
        );
        final pane = FtermPaneController(
          paneId: 'kitty-dark-pane',
          port: port,
          colorResolver: resolver,
          resizeDebounce: Duration.zero,
        )..setFocused(true);

        addTearDown(() async {
          await pane.dispose(disposePort: false);
          await port.dispose();
          await router.dispose();
        });

        pane.updateViewportSize(8, 4, 10.0, 20.0);
        final pxB64 = base64Encode(Uint8List.fromList([0, 255, 0, 255]));
        backend.emitString(
          '\x1b[2;1H\x1b_Ga=T,i=42,s=1,v=1,f=32,c=1,r=1,C=1;$pxB64\x1b\\',
        );

        final termuiBuf = pane.readDisplayBuffer();
        expect(
          tui.Modifier.has(
            termuiBuf.getModifiers(0, 1),
            tui.Modifier.kittyPlaceholder,
          ),
          isTrue,
        );
        expect(
          tui.Modifier.has(termuiBuf.getModifiers(0, 1), tui.Modifier.reverse),
          isFalse,
        );
        expect(
          termuiBuf.getBackground(0, 1),
          equals(tui.TerminalColorTheme.termuiDark.cursorColor.argb),
        );
        expect(
          tui.extractKittyCellImageId(
            termuiBuf.getCharacter(0, 1),
            termuiBuf.getForeground(0, 1),
          ),
          equals(42),
        );
      },
    );
  });
}
