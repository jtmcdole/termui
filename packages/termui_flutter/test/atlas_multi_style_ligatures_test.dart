import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' as tui_color;
import 'package:termui/ui/style.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/service/terminal_service.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/terminal.dart';
import 'package:termui_flutter/termui_flutter.dart';

final class _CapturingTerminalService implements TerminalService {
  final Map<String, Uint8List> savedFiles = {};

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) async {
    savedFiles[basename] = Uint8List.fromList(bytes);
    return basename;
  }

  @override
  Future<void> setClipboard(String text) async {}

  @override
  Future<String?> getClipboard() async => null;

  @override
  Future<bool> openUrl(String url) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Multi-Style GlyphAtlas', () {
    test(
      'generate uses numCols = 64 and stores all 4 style variants in single image',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.image.dispose);

        expect(atlas.numCols, equals(64));
        expect(atlas.image, isNotNull);

        // Verify regular variant
        final regularA = atlas.lookup('A', bold: false, italic: false);
        expect(regularA, isNotNull);
        expect(atlas.charRects['A'], equals(regularA));

        // Verify bold variant
        final boldA = atlas.lookup('A', bold: true, italic: false);
        expect(boldA, isNotNull);
        expect(boldA, isNot(equals(regularA)));

        // Verify italic variant
        final italicA = atlas.lookup('A', bold: false, italic: true);
        expect(italicA, isNotNull);
        expect(italicA, isNot(equals(regularA)));
        expect(italicA, isNot(equals(boldA)));

        // Verify bold-italic variant
        final boldItalicA = atlas.lookup('A', bold: true, italic: true);
        expect(boldItalicA, isNotNull);
        expect(boldItalicA, isNot(equals(regularA)));
        expect(boldItalicA, isNot(equals(boldA)));
        expect(boldItalicA, isNot(equals(italicA)));

        // Verify procedural box drawing character lookup falls back cleanly
        final regularLine = atlas.lookup('─', bold: false, italic: false);
        expect(regularLine, isNotNull);
        final boldLine = atlas.lookup('─', bold: true, italic: false);
        expect(boldLine, equals(regularLine));

        // Unknown character lookup returns null
        expect(atlas.lookup('Ж'), isNull);
      },
    );

    test('addGlyphs appends style variants dynamically to atlas', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 14.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.image.dispose);

      expect(atlas.lookup('Ψ'), isNull);

      final expandedAtlas = await atlas.addGlyphs(['Ψ']);
      addTearDown(expandedAtlas.image.dispose);

      expect(expandedAtlas.numCols, equals(64));
      final regularPsi = expandedAtlas.lookup('Ψ', bold: false, italic: false);
      final boldPsi = expandedAtlas.lookup('Ψ', bold: true, italic: false);
      final italicPsi = expandedAtlas.lookup('Ψ', bold: false, italic: true);
      final boldItalicPsi = expandedAtlas.lookup('Ψ', bold: true, italic: true);

      expect(regularPsi, isNotNull);
      expect(boldPsi, isNotNull);
      expect(italicPsi, isNotNull);
      expect(boldItalicPsi, isNotNull);
    });
  });

  group('FlutterTerminal & Terminal ligatures configuration', () {
    test(
      'FlutterTerminal defaults enableLigatures to false and supports toggling',
      () async {
        final terminal = FlutterTerminal();
        expect(terminal.enableLigatures, isFalse);

        final emitted = <bool>[];
        final sub = terminal.watchEnableLigatures().listen(emitted.add);

        terminal.setEnableLigatures(true);
        expect(terminal.enableLigatures, isTrue);

        terminal.setEnableLigatures(false);
        expect(terminal.enableLigatures, isFalse);

        await Future<void>.delayed(Duration.zero);
        expect(emitted, equals([true, false]));

        await sub.cancel();
        terminal.dispose();
      },
    );

    testWidgets('Terminal widget initializes with enableLigatures', (
      tester,
    ) async {
      final terminal = FlutterTerminal(enableLigatures: true);
      addTearDown(terminal.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Terminal(
              terminal: terminal,
              enableLigatures: true,
              fontSize: 14.0,
              fontFamily: 'Roboto Mono',
              onRun: (term, drawFrame) async {
                final buf = Buffer(10, 2);
                drawFrame(buf);
              },
            ),
          ),
        ),
      );

      expect(terminal.enableLigatures, isTrue);
    });
  });

  group('TuiAtlasPainter multi-style and dynamic ligatures', () {
    test(
      'TuiAtlasPainter queries styled glyphs and renders bold and italic cells cleanly',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.image.dispose);

        final buffer = Buffer(8, 2)
          ..writeString(
            0,
            0,
            'A',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              modifiers: Modifier.bold,
            ),
          )
          ..writeString(
            1,
            0,
            'B',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              modifiers: Modifier.italic,
            ),
          )
          ..writeString(
            2,
            0,
            'C',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              modifiers: Modifier.bold | Modifier.italic,
            ),
          );

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
            Size(8 * atlas.cellWidth, 2 * atlas.cellHeight),
          ),
          returnsNormally,
        );
        recorder.endRecording().dispose();
      },
    );

    test(
      'when enableLigatures is false, adjacent ligature chars use fast atlas rendering',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.image.dispose);

        final buffer = Buffer(8, 1)
          ..writeString(
            0,
            0,
            '->',
            const Style(foreground: tui_color.Color(255, 255, 255)),
          );

        final ligaturePainters =
            <(String, bool, bool, ui.Color), TextPainter>{};
        final painter = TuiAtlasPainter(
          buffer: buffer,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          ligaturePainters: ligaturePainters,
          enableLigatures: false,
          onMissingGlyphs: null,
        );

        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        painter.paint(canvas, Size(8 * atlas.cellWidth, atlas.cellHeight));
        recorder.endRecording().dispose();

        // No ligature TextPainters should be generated or used when enableLigatures is false
        expect(ligaturePainters.isEmpty, isTrue);
      },
    );

    test(
      'when enableLigatures is true, stages pre-baked ligatures via atlas and falls back to ligaturePainters for others',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.image.dispose);

        final buffer = Buffer(16, 1)
          ..writeString(
            0,
            0,
            '->',
            const Style(foreground: tui_color.Color(255, 255, 255)),
          )
          ..writeString(
            3,
            0,
            '===',
            const Style(
              foreground: tui_color.Color(0, 255, 0),
              modifiers: Modifier.bold,
            ),
          )
          ..writeString(
            7,
            0,
            '!=',
            const Style(foreground: tui_color.Color(255, 128, 0)),
          )
          ..writeString(
            10,
            0,
            '<!--',
            const Style(
              foreground: tui_color.Color(128, 200, 255),
              modifiers: Modifier.bold,
            ),
          );

        final ligaturePainters =
            <(String, bool, bool, ui.Color), TextPainter>{};
        final painter = TuiAtlasPainter(
          buffer: buffer,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          ligaturePainters: ligaturePainters,
          enableLigatures: true,
          onMissingGlyphs: null,
        );

        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        expect(
          () => painter.paint(
            canvas,
            Size(16 * atlas.cellWidth, atlas.cellHeight),
          ),
          returnsNormally,
        );
        recorder.endRecording().dispose();

        // Pre-baked ligatures ('->', '===', '!=') stage directly into drawRawAtlas without TextPainters!
        expect(atlas.rectFor('->'), isNotNull);
        expect(atlas.rectFor('===', isBold: true), isNotNull);
        expect(atlas.rectFor('!='), isNotNull);
        expect(ligaturePainters.keys.any((k) => k.$1 == '->'), isFalse);
        expect(ligaturePainters.keys.any((k) => k.$1 == '==='), isFalse);
        expect(ligaturePainters.keys.any((k) => k.$1 == '!='), isFalse);

        // Non-prebaked 4-char ligature '<!--' falls back to ligaturePainters
        expect(
          ligaturePainters.keys.any((k) => k.$1 == '<!--' && k.$2 == true),
          isTrue,
          reason: '<!-- should be shaped via fallback ligaturePainters',
        );

        for (final p in ligaturePainters.values) {
          p.dispose();
        }
      },
    );

    test(
      'cells with different fg/bg/style do not form ligatures even if adjacent',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.image.dispose);

        final buffer = Buffer(6, 1)
          ..writeString(
            0,
            0,
            '-',
            const Style(foreground: tui_color.Color(255, 0, 0)),
          )
          ..writeString(
            1,
            0,
            '>',
            const Style(
              foreground: tui_color.Color(0, 255, 0),
            ), // different fg color
          );

        final ligaturePainters =
            <(String, bool, bool, ui.Color), TextPainter>{};
        final painter = TuiAtlasPainter(
          buffer: buffer,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          ligaturePainters: ligaturePainters,
          enableLigatures: true,
          onMissingGlyphs: null,
        );

        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        painter.paint(canvas, Size(6 * atlas.cellWidth, atlas.cellHeight));
        recorder.endRecording().dispose();

        expect(
          ligaturePainters.containsKey((
            '->',
            false,
            false,
            const ui.Color(0xFFFF0000),
          )),
          isFalse,
        );
        expect(ligaturePainters.isEmpty, isTrue);
      },
    );

    test(
      'cells with different underlineColor or OSC 8 uri do not coalesce into ligatures',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.image.dispose);

        // Split by different SGR 58 underlineColor at cell 1 ('!') and cell 3 ('-')
        final ulSplitBuf = Buffer(6, 1)
          ..writeString(
            0,
            0,
            '<',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              modifiers: Modifier.underline,
              underlineColor: tui_color.Color(255, 0, 0),
            ),
          )
          ..writeString(
            1,
            0,
            '!',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              modifiers: Modifier.underline,
              underlineColor: tui_color.Color(0, 255, 0),
            ),
          )
          ..writeString(
            2,
            0,
            '-',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              modifiers: Modifier.underline,
              underlineColor: tui_color.Color(255, 0, 0),
            ),
          )
          ..writeString(
            3,
            0,
            '-',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              modifiers: Modifier.underline,
              underlineColor: tui_color.Color(0, 0, 255),
            ),
          );

        final ulPainters = <(String, bool, bool, ui.Color), TextPainter>{};
        final ulPainter = TuiAtlasPainter(
          buffer: ulSplitBuf,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          ligaturePainters: ulPainters,
          enableLigatures: true,
          onMissingGlyphs: null,
        );
        final ulRec = ui.PictureRecorder();
        ulPainter.paint(
          Canvas(ulRec),
          Size(6 * atlas.cellWidth, atlas.cellHeight),
        );
        ulRec.endRecording().dispose();
        expect(ulPainters.keys.any((k) => k.$1 == '<!--'), isFalse);

        // Split by different OSC 8 URI across '<!--'
        final uriSplitBuf = Buffer(6, 1)
          ..writeString(
            0,
            0,
            '<!',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              uri: 'https://a.example',
            ),
          )
          ..writeString(
            2,
            0,
            '--',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              uri: 'https://b.example',
            ),
          );

        final uriPainters = <(String, bool, bool, ui.Color), TextPainter>{};
        final uriPainter = TuiAtlasPainter(
          buffer: uriSplitBuf,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          ligaturePainters: uriPainters,
          enableLigatures: true,
          onMissingGlyphs: null,
        );
        final uriRec = ui.PictureRecorder();
        uriPainter.paint(
          Canvas(uriRec),
          Size(6 * atlas.cellWidth, atlas.cellHeight),
        );
        uriRec.endRecording().dispose();
        expect(uriPainters.keys.any((k) => k.$1 == '<!--'), isFalse);
      },
    );
  });

  group(
    'Terminal runtime regressions (cell metrics, F12 screenshot, fallback cache)',
    () {
      testWidgets(
        'FlutterTerminal.watchCellPixelSize emits atlas metrics on init and font resize (R3-HIGH-2)',
        (tester) async {
          final terminal = FlutterTerminal(initialFontSize: 12.0);
          addTearDown(terminal.dispose);

          final emittedSizes = <(int, int)>[];
          final sub = terminal.watchCellPixelSize().listen(emittedSizes.add);
          addTearDown(sub.cancel);

          await tester.runAsync(() async {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: SizedBox(
                    width: 400,
                    height: 300,
                    child: Terminal(
                      terminal: terminal,
                      fontSize: 12.0,
                      fontFamily: 'Roboto Mono',
                      onRun: (term, drawFrame) async {
                        drawFrame(Buffer(10, 4));
                      },
                    ),
                  ),
                ),
              ),
            );
            for (var i = 0; i < 20 && emittedSizes.isEmpty; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
          });
          await tester.pump();

          expect(emittedSizes, isNotEmpty);
          final initialMetrics = terminal.cellPixelSize;
          expect(initialMetrics.$1, greaterThan(0));
          expect(initialMetrics.$2, greaterThan(0));

          await tester.runAsync(() async {
            terminal.setFontSize(28.0);
            for (
              var i = 0;
              i < 30 && terminal.cellPixelSize.$2 <= initialMetrics.$2;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
          });
          await tester.pump();

          expect(terminal.cellPixelSize.$2, greaterThan(initialMetrics.$2));
          expect(emittedSizes.last, equals(terminal.cellPixelSize));
        },
      );

      testWidgets(
        'F12 screenshot saves PNG and coordinates JSON with underlineColor and uri cleanly (R3-MED-5)',
        (tester) async {
          final terminal = FlutterTerminal(initialFontSize: 14.0);
          addTearDown(terminal.dispose);
          final service = _CapturingTerminalService();
          void Function(Buffer)? draw;

          await tester.runAsync(() async {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: SizedBox(
                    width: 320,
                    height: 200,
                    child: Terminal(
                      terminal: terminal,
                      service: service,
                      fontSize: 14.0,
                      fontFamily: 'Roboto Mono',
                      onRun: (term, drawFrame) async {
                        draw = drawFrame;
                        final buf = Buffer(8, 2)
                          ..writeString(
                            0,
                            0,
                            'L',
                            const Style(
                              foreground: tui_color.Color(255, 255, 255),
                              modifiers: Modifier.underline,
                              underlineColor: tui_color.Color(255, 64, 128),
                              uri: 'https://termui.dev',
                            ),
                          );
                        drawFrame(buf);
                      },
                    ),
                  ),
                ),
              ),
            );
            final state = tester.state<PrivateTuiViewState>(
              find.byType(PrivateTuiView),
            );
            for (var i = 0; i < 30 && state.debugAtlas == null; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
            expect(draw, isNotNull);
            await tester.pump();
            await state.debugTakeScreenshot();
          });
          await tester.pump();

          final screenshotEntry = service.savedFiles.entries.firstWhere(
            (e) => e.key.startsWith('screenshot_') && e.key.endsWith('.png'),
          );
          // Verify PNG magic signature (0x89 0x50 0x4E 0x47)
          expect(
            screenshotEntry.value.sublist(0, 4),
            equals([0x89, 0x50, 0x4E, 0x47]),
          );

          final coordsEntry = service.savedFiles.entries.firstWhere(
            (e) => e.key.startsWith('coordinates_') && e.key.endsWith('.json'),
          );
          final decoded =
              jsonDecode(utf8.decode(coordsEntry.value))
                  as Map<String, Object?>;
          final cells = decoded['cells']! as List<Object?>;
          final cell0 = cells.first! as Map<String, Object?>;
          expect(cell0['char'], equals('L'));
          expect(cell0['underlineColor'], equals('0xFFFF4080'));
          expect(cell0['uri'], equals('https://termui.dev'));
        },
      );

      testWidgets(
        'fallback TextPainter cache isolates italic key, caps at 256 entries, and evicts after atlas bake (R3-LOW-8)',
        (tester) async {
          final terminal = FlutterTerminal(initialFontSize: 14.0);
          addTearDown(terminal.dispose);
          void Function(Buffer)? draw;

          await tester.runAsync(() async {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: SizedBox(
                    width: 600,
                    height: 400,
                    child: Terminal(
                      terminal: terminal,
                      fontSize: 14.0,
                      fontFamily: 'Roboto Mono',
                      onRun: (term, drawFrame) async {
                        draw = drawFrame;
                        drawFrame(Buffer(20, 16));
                      },
                    ),
                  ),
                ),
              ),
            );
            final state = tester.state<PrivateTuiViewState>(
              find.byType(PrivateTuiView),
            );
            for (
              var i = 0;
              i < 30 && (state.debugAtlas == null || draw == null);
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
          });

          final state = tester.state<PrivateTuiViewState>(
            find.byType(PrivateTuiView),
          );

          // 1. Upright and italic unbaked 'Ж' must produce distinct cache keys
          final italicVsUprightBuf = Buffer(20, 16)
            ..writeString(
              0,
              0,
              'Ж',
              const Style(foreground: tui_color.Color(255, 255, 255)),
            )
            ..writeString(
              1,
              0,
              'Ж',
              const Style(
                foreground: tui_color.Color(255, 255, 255),
                modifiers: Modifier.italic,
              ),
            );
          draw!(italicVsUprightBuf);
          await Future<void>.microtask(() {});
          expect(
            state.debugFallbackPainterKeys.any((k) => k.$1 == 'Ж' && !k.$3),
            isTrue,
          );
          expect(
            state.debugFallbackPainterKeys.any((k) => k.$1 == 'Ж' && k.$3),
            isTrue,
          );

          // 2. Drawing 300 distinct unbaked Cyrillic glyphs caps _fallbackPainters at 256
          final overflowBuf = Buffer(300, 1);
          for (var i = 0; i < 300; i++) {
            overflowBuf.writeString(
              i,
              0,
              String.fromCharCode(0x0400 + i),
              const Style(foreground: tui_color.Color(255, 255, 255)),
            );
          }
          draw!(overflowBuf);
          await Future<void>.microtask(() {});
          expect(state.debugFallbackPainterKeys.length, equals(256));

          // 3. Pumping paints missing glyphs, triggers async atlas bake, and evicts baked fallback painters
          await tester.runAsync(() async {
            await tester.pump();
            for (
              var i = 0;
              i < 40 && state.debugFallbackPainterKeys.isNotEmpty;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 15));
              await tester.pump();
            }
          });
          await tester.pump();

          expect(state.debugFallbackPainterKeys, isEmpty);
        },
      );
    },
  );
}
