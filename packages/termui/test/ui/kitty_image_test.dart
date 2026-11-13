import 'dart:typed_data';

import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/terminal/input_parser.dart';
import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('KittyImage and U+10EEEE Unicode Placeholders', () {
    tearDown(KittyImageRegistry.clear);

    test('kittyPlaceholderCell and parseKittyPlaceholderCell round-trip', () {
      for (var r = 0; r < 10; r++) {
        for (var c = 0; c < 20; c++) {
          final cell = kittyPlaceholderCell(r, c);
          expect(graphemeWidth(cell), equals(1));
          final parsed = parseKittyPlaceholderCell(cell);
          expect(parsed, equals((row: r, col: c, imageIdMsb: null)));
        }
      }
      expect(parseKittyPlaceholderCell('A'), isNull);
    });

    test(
      'KittyImage populates U+10EEEE cells, survives DimmerEffect, and emits APC G in Renderer',
      () {
        final rgba = Uint8List.fromList(List.filled(4 * 4 * 4, 200));
        final widget = KittyImage(
          imageId: 0x123456,
          pixelWidth: 4,
          pixelHeight: 4,
          rgbaPixels: rgba,
          columns: 3,
          rows: 2,
        );

        final element = widget.createElement()..mount(null);
        element.layout(const BoxConstraints(maxWidth: 10, maxHeight: 5));

        final buffer = Buffer.blank(6, 4);
        element.paint(buffer, const Offset(1, 1));

        expect(
          parseKittyPlaceholderCell(buffer.getCharacter(1, 1)),
          equals((row: 0, col: 0, imageIdMsb: null)),
        );
        expect(buffer.getForeground(1, 1) & 0xFFFFFF, equals(0x123456));
        expect(
          Modifier.has(buffer.getModifiers(1, 1), Modifier.kittyPlaceholder),
          isTrue,
        );

        const DimmerEffect(
          scalar: 0.5,
        ).applyEffect(buffer, const Rect(0, 0, 6, 4));
        expect(buffer.getForeground(1, 1) & 0xFFFFFF, equals(0x123456));

        final renderer = Renderer(6, 4);
        final out = StringBuffer();
        renderer.render(buffer, out);
        final ansi = out.toString();

        expect(ansi, contains('\x1b_Ga=t,f=32,s=4,v=4,i=1193046,q=2;'));
        expect(ansi, contains('\x1b_Ga=p,U=1,i=1193046,c=3,r=2,q=2\x1b\\'));
        expect(ansi, contains('38;2;18;52;86'));
      },
    );

    test(
      'chunked APC includes q=2, KittyImageRegistry.unregister removes entry, and performLayout clamps to kittyDiacritics',
      () {
        final largeRgba = Uint8List.fromList(List.filled(32 * 32 * 4, 128));
        final data = KittyImageData(
          imageId: 0x00BEEF,
          pixelWidth: 32,
          pixelHeight: 32,
          rgbaPixels: largeRgba,
          gridCols: 4,
          gridRows: 2,
        );
        final apc = data.toApcSequence();
        expect(apc, contains('q=2,m=1;'));
        expect(apc, contains('\x1b_Gm=0,q=2;'));

        KittyImageRegistry.register(data);
        expect(KittyImageRegistry.lookup(0x00BEEF), isNotNull);
        KittyImageRegistry.unregister(0x00BEEF);
        expect(KittyImageRegistry.lookup(0x00BEEF), isNull);

        final hugeWidget = KittyImage(
          imageId: 0x00BEEF,
          pixelWidth: 32,
          pixelHeight: 32,
          rgbaPixels: largeRgba,
          columns: 999,
          rows: 999,
        );
        final element = hugeWidget.createElement()..mount(null);
        element.layout(const BoxConstraints(maxWidth: 999, maxHeight: 999));
        expect(element.size.width, equals(kittyDiacritics.length));
        expect(element.size.height, equals(kittyDiacritics.length));
      },
    );

    test(
      'toApcSequence validates chunkSize and copyWith updates grid dimensions',
      () {
        final rgba = Uint8List.fromList(List.filled(16, 255));
        final data = KittyImageData(
          imageId: 7,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: rgba,
          gridCols: 2,
          gridRows: 1,
        );

        expect(() => data.toApcSequence(chunkSize: 0), throwsArgumentError);
        expect(() => data.toApcSequence(chunkSize: -8), throwsArgumentError);
        expect(() => data.toApcSequence(chunkSize: 10), throwsArgumentError);
        expect(() => data.toApcSequence(chunkSize: 4095), throwsArgumentError);

        final resized = data.copyWith(gridCols: 5, gridRows: 3);
        expect(resized.gridCols, equals(5));
        expect(resized.gridRows, equals(3));
        expect(resized.imageId, equals(7));
        expect(resized.pixelWidth, equals(2));
      },
    );

    test(
      '32-bit imageIds do not collide in KittyImageRegistry and encode MSB diacritic in KittyImageElement',
      () {
        final rgbaA = Uint8List.fromList(List.filled(16, 10));
        final rgbaB = Uint8List.fromList(List.filled(16, 200));

        const idA = 0x01000005;
        const idB = 0x02000005;

        final buffer = Buffer.blank(4, 2);
        final elA = KittyImage(
          imageId: idA,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: rgbaA,
          columns: 2,
          rows: 1,
        ).createElement()..mount(null);
        elA.layout(const BoxConstraints(maxWidth: 2, maxHeight: 1));
        elA.paint(buffer, Offset.zero);

        final elB = KittyImage(
          imageId: idB,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: rgbaB,
          columns: 2,
          rows: 1,
        ).createElement()..mount(null);
        elB.layout(const BoxConstraints(maxWidth: 2, maxHeight: 1));
        elB.paint(buffer, const Offset(2, 0));

        expect(KittyImageRegistry.lookup(idA)?.rgbaPixels, same(rgbaA));
        expect(KittyImageRegistry.lookup(idB)?.rgbaPixels, same(rgbaB));

        expect(
          parseKittyPlaceholderCell(buffer.getCharacter(0, 0)),
          equals((row: 0, col: 0, imageIdMsb: 1)),
        );
        expect(
          parseKittyPlaceholderCell(buffer.getCharacter(2, 0)),
          equals((row: 0, col: 0, imageIdMsb: 2)),
        );

        final renderer = Renderer(4, 2);
        final out = StringBuffer();
        renderer.render(buffer, out);
        final ansi = out.toString();
        expect(ansi, contains('i=$idA,q=2'));
        expect(ansi, contains('i=$idB,q=2'));
      },
    );

    test(
      'instance-scoped KittyImageRegistry and Buffer.lookupKittyImage isolate panes',
      () {
        final globalPixels = Uint8List.fromList(List.filled(16, 1));
        final pane1Pixels = Uint8List.fromList(List.filled(16, 2));
        final pane2Pixels = Uint8List.fromList(List.filled(16, 3));

        final globalData = KittyImageData(
          imageId: 42,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: globalPixels,
          gridCols: 2,
          gridRows: 1,
        );
        final pane1Data = KittyImageData(
          imageId: 42,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: pane1Pixels,
          gridCols: 2,
          gridRows: 1,
        );
        final pane2Data = KittyImageData(
          imageId: 42,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: pane2Pixels,
          gridCols: 2,
          gridRows: 1,
        );

        KittyImageRegistry.register(globalData);
        final reg1 = KittyImageRegistry()..registerImage(pane1Data);
        final reg2 = KittyImageRegistry()..registerImage(pane2Data);

        expect(reg1.registeredImageIds, contains(42));

        final buf = Buffer.blank(20, 10);
        buf.registerKittyRegistry(const Rect(0, 0, 10, 10), reg1);
        final vp2 = Viewport(buf, const Rect(10, 0, 10, 10));
        vp2.registerKittyRegistry(const Rect(0, 0, 10, 5), reg2);

        // Pane 1 resolves reg1; missing ID inside Pane 1 does NOT leak global!
        expect(buf.lookupKittyImage(2, 2, 42)?.rgbaPixels, same(pane1Pixels));
        expect(buf.lookupKittyImage(2, 2, 999), isNull);

        // Registering an ID in global must NOT bleed into scoped Pane 1!
        KittyImageRegistry.register(
          KittyImageData(
            imageId: 77,
            pixelWidth: 1,
            pixelHeight: 1,
            rgbaPixels: globalPixels,
            gridCols: 1,
            gridRows: 1,
          ),
        );
        expect(buf.lookupKittyImage(2, 2, 77), isNull);

        // Pane 2 top half resolves reg2; bottom half (outside reg2) falls back to global.
        expect(buf.lookupKittyImage(12, 2, 42)?.rgbaPixels, same(pane2Pixels));
        expect(vp2.lookupKittyImage(2, 2, 42)?.rgbaPixels, same(pane2Pixels));
        expect(buf.lookupKittyImage(12, 7, 42)?.rgbaPixels, same(globalPixels));
        expect(buf.lookupKittyImage(12, 7, 77)?.rgbaPixels, same(globalPixels));

        reg1.unregisterImage(42);
        expect(reg1.lookupImage(42), isNull);
        reg2.clearImages();
        expect(reg2.registeredImageIds, isEmpty);

        // Buffer.clear clears scoped registries.
        buf.clear();
        expect(buf.lookupKittyImage(2, 2, 42)?.rgbaPixels, same(globalPixels));
      },
    );

    test(
      'hasImages, Buffer.hasKittyImages, and Viewport.hasKittyImages track empty, scoped, global, and cleared registries',
      () {
        final emptyScoped = KittyImageRegistry();
        expect(emptyScoped.hasImages, isFalse);
        expect(KittyImageRegistry.global.hasImages, isFalse);

        final buf = Buffer.blank(10, 4);
        final vp = Viewport(buf, const Rect(0, 0, 5, 2));
        expect(buf.hasKittyImages, isFalse);
        expect(vp.hasKittyImages, isFalse);

        // Attaching an empty scoped registry must keep hasKittyImages false.
        buf.registerKittyRegistry(const Rect(0, 0, 10, 4), emptyScoped);
        expect(buf.hasKittyImages, isFalse);
        expect(vp.hasKittyImages, isFalse);

        final data = KittyImageData(
          imageId: 91,
          pixelWidth: 1,
          pixelHeight: 1,
          rgbaPixels: Uint8List.fromList([1, 2, 3, 255]),
          gridCols: 1,
          gridRows: 1,
        );

        // Populating the attached scoped registry flips hasKittyImages true.
        emptyScoped.registerImage(data);
        expect(emptyScoped.hasImages, isTrue);
        expect(buf.hasKittyImages, isTrue);
        expect(vp.hasKittyImages, isTrue);

        // Clearing the scoped registry restores false.
        emptyScoped.clearImages();
        expect(emptyScoped.hasImages, isFalse);
        expect(buf.hasKittyImages, isFalse);
        expect(vp.hasKittyImages, isFalse);

        // Global registry flips hasKittyImages true even with empty scoped registries.
        KittyImageRegistry.register(data);
        expect(KittyImageRegistry.global.hasImages, isTrue);
        expect(buf.hasKittyImages, isTrue);
        expect(vp.hasKittyImages, isTrue);

        KittyImageRegistry.clear();
        expect(KittyImageRegistry.global.hasImages, isFalse);
        expect(buf.hasKittyImages, isFalse);
        expect(vp.hasKittyImages, isFalse);
      },
    );

    test(
      'Compositor upper text with default fg occludes lower KittyImage without inheriting imageId or kittyPlaceholder',
      () {
        final rgba = Uint8List.fromList(List.filled(2 * 2 * 4, 255));
        final lower = Buffer.blank(2, 1);
        final imgEl = KittyImage(
          imageId: 0xABCDEF,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: rgba,
          columns: 2,
          rows: 1,
        ).createElement()..mount(null);
        imgEl.layout(const BoxConstraints(maxWidth: 2, maxHeight: 1));
        imgEl.paint(lower, Offset.zero);

        final upper = Buffer(2, 1);
        upper.setAttributes(
          0,
          0,
          char: 'X',
          fg: 0,
          bg: 0,
          modifiers: Modifier.bold,
        );

        final target = Buffer.blank(2, 1);
        Compositor().composite(
          target: target,
          layers: [
            LayeredBuffer(buffer: lower, x: 0, y: 0, zIndex: 0),
            LayeredBuffer(buffer: upper, x: 0, y: 0, zIndex: 1),
          ],
        );

        expect(target.getCharacter(0, 0), equals('X'));
        expect(
          Modifier.has(target.getModifiers(0, 0), Modifier.kittyPlaceholder),
          isFalse,
        );
        expect(target.getForeground(0, 0), equals(0));
        expect(
          Modifier.has(target.getModifiers(1, 0), Modifier.kittyPlaceholder),
          isTrue,
        );
      },
    );

    test(
      'Renderer re-emits APC when rgbaPixels buffer changes under same imageId and version',
      () {
        final rgba1 = Uint8List.fromList(List.filled(2 * 2 * 4, 10));
        final rgba2 = Uint8List.fromList(List.filled(2 * 2 * 4, 200));
        final buf = Buffer.blank(2, 1);
        final el1 = KittyImage(
          imageId: 0x000042,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaPixels: rgba1,
          columns: 2,
          rows: 1,
        ).createElement()..mount(null);
        el1.layout(const BoxConstraints(maxWidth: 2, maxHeight: 1));
        el1.paint(buf, Offset.zero);

        final renderer = Renderer(2, 1);
        final out1 = StringBuffer();
        renderer.render(buf, out1);
        expect(out1.toString(), contains('\x1b_Ga=t,f=32'));

        final out2 = StringBuffer();
        renderer.render(buf, out2);
        expect(out2.toString(), isNot(contains('\x1b_Ga=t,f=32')));

        KittyImageRegistry.register(
          KittyImageData(
            imageId: 0x000042,
            pixelWidth: 2,
            pixelHeight: 2,
            rgbaPixels: rgba2,
            gridCols: 2,
            gridRows: 1,
          ),
        );
        final out3 = StringBuffer();
        renderer.render(buf, out3);
        expect(out3.toString(), contains('\x1b_Ga=t,f=32'));
      },
    );

    test(
      '32-bit imageId and 4th diacritic round-trip across all 0..255 MSBs',
      () {
        expect(kittyDiacritics.length, equals(297));
        expect(kittyDiacritics.toSet().length, equals(297));
        for (var msb = 1; msb <= 255; msb++) {
          final cell = kittyPlaceholderCell(3, 7, imageIdMsb: msb);
          expect(graphemeWidth(cell), equals(1));
          final parsed = parseKittyPlaceholderCell(cell);
          expect(parsed, equals((row: 3, col: 7, imageIdMsb: msb)));
        }
      },
    );

    test(
      'KittyImageData supports zlib compression (o=z) and PNG format (f=100)',
      () {
        final rgba = Uint8List.fromList(List.filled(16 * 16 * 4, 100));
        final data = KittyImageData(
          imageId: 0x010203,
          pixelWidth: 16,
          pixelHeight: 16,
          rgbaPixels: rgba,
          gridCols: 2,
          gridRows: 2,
        );
        final seqUncompressed = data.toApcSequence(compress: false);
        expect(seqUncompressed, contains('f=32'));
        expect(seqUncompressed, isNot(contains('o=z')));

        final seqCompressed = data.toApcSequence(compress: true);
        expect(seqCompressed, contains('f=32,o=z'));

        final fakePng = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
        final pngData = KittyImageData.fromPng(
          imageId: 0x050607,
          pixelWidth: 8,
          pixelHeight: 8,
          pngBytes: fakePng,
          gridCols: 1,
          gridRows: 1,
        );
        final seqPng = pngData.toApcSequence();
        expect(seqPng, contains('f=100'));
        expect(seqPng, isNot(contains('o=z')));
      },
    );

    test(
      'KittyImageRegistry preserves KittyImageData identity across unchanged repaints and updates on mutation',
      () {
        final rgba = Uint8List.fromList(List.filled(4 * 4 * 4, 128));
        final buf = Buffer.blank(4, 2);
        final el = KittyImage(
          imageId: 0x123456,
          pixelWidth: 4,
          pixelHeight: 4,
          rgbaPixels: rgba,
          columns: 4,
          rows: 2,
        ).createElement()..mount(null);
        el.layout(const BoxConstraints(maxWidth: 4, maxHeight: 2));
        el.paint(buf, Offset.zero);

        final firstData = KittyImageRegistry.lookup(0x123456);
        expect(firstData, isNotNull);
        expect(
          extractKittyCellImageId(
            buf.getCharacter(1, 1),
            buf.getForeground(1, 1),
          ),
          equals(0x123456),
        );

        // Re-painting with unchanged pixels/dimensions retains exact object identity.
        buf.clear();
        el.paint(buf, Offset.zero);
        expect(KittyImageRegistry.lookup(0x123456), same(firstData));

        // Updating version replaces the descriptor.
        el.update(
          KittyImage(
            imageId: 0x123456,
            pixelWidth: 4,
            pixelHeight: 4,
            rgbaPixels: rgba,
            columns: 4,
            rows: 2,
            version: 1,
          ),
        );
        el.paint(buf, Offset.zero);
        final updatedData = KittyImageRegistry.lookup(0x123456);
        expect(updatedData, isNot(same(firstData)));
        expect(updatedData?.version, equals(1));
      },
    );

    test(
      'Compositor propagates scoped KittyImageRegistry entries with layer offsets and Z-order',
      () {
        final pxLower = Uint8List.fromList([10, 20, 30, 255]);
        final pxUpper = Uint8List.fromList([200, 210, 220, 255]);
        final regLower = KittyImageRegistry()
          ..registerImage(
            KittyImageData(
              imageId: 0x42000007,
              pixelWidth: 1,
              pixelHeight: 1,
              rgbaPixels: pxLower,
              gridCols: 2,
              gridRows: 2,
            ),
          );
        final regUpper = KittyImageRegistry()
          ..registerImage(
            KittyImageData(
              imageId: 0x42000007,
              pixelWidth: 1,
              pixelHeight: 1,
              rgbaPixels: pxUpper,
              gridCols: 2,
              gridRows: 2,
            ),
          );

        final lowerBuf = Buffer.blank(6, 4)
          ..registerKittyRegistry(const Rect(0, 0, 6, 4), regLower);
        final upperBuf = Buffer.blank(3, 2)
          ..registerKittyRegistry(const Rect(0, 0, 3, 2), regUpper);

        final target = Buffer.blank(10, 8);
        Compositor().composite(
          target: target,
          layers: [
            LayeredBuffer(buffer: lowerBuf, x: 2, y: 3, zIndex: 5),
            LayeredBuffer(buffer: upperBuf, x: 4, y: 4, zIndex: 10),
          ],
        );

        // Unoccluded lower region resolves regLower.
        expect(
          target.lookupKittyImage(2, 3, 0x42000007)?.rgbaPixels,
          same(pxLower),
        );
        // Overlapping upper region resolves regUpper (higher zIndex).
        expect(
          target.lookupKittyImage(5, 4, 0x42000007)?.rgbaPixels,
          same(pxUpper),
        );
        expect(
          extractKittyCellImageId(
            kittyPlaceholderCell(0, 0, imageIdMsb: 0x42),
            0xFF000007,
          ),
          equals(0x42000007),
        );

        // Higher-zIndex global KittyImage widget overrides fullscreen lower scoped registry.
        final pxGlobal = Uint8List.fromList([77, 88, 99, 255]);
        final modalLayer = Buffer(3, 2);
        final modalEl = KittyImage(
          imageId: 0x000099,
          pixelWidth: 1,
          pixelHeight: 1,
          rgbaPixels: pxGlobal,
          columns: 3,
          rows: 2,
        ).createElement()..mount(null);
        modalEl.layout(const BoxConstraints(maxWidth: 3, maxHeight: 2));
        modalEl.paint(modalLayer, Offset.zero);

        final fullscreenTarget = Buffer.blank(6, 4);
        Compositor().composite(
          target: fullscreenTarget,
          layers: [
            LayeredBuffer(buffer: lowerBuf, x: 0, y: 0, zIndex: 1),
            LayeredBuffer(buffer: modalLayer, x: 1, y: 1, zIndex: 20),
          ],
        );
        expect(
          fullscreenTarget.lookupKittyRegistry(2, 1),
          same(KittyImageRegistry.global),
        );
        expect(
          fullscreenTarget.lookupKittyImage(2, 1, 0x000099)?.rgbaPixels,
          same(pxGlobal),
        );
      },
    );

    test(
      'InputParser handles Alt+_ without stalling, streaming APC bounds, CAN/SUB abort, and ESC recovery',
      () {
        final query = KittyImageData.buildCapabilityQuery(queryId: 99);
        expect(
          query,
          equals('\x1b_Gi=99,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c'),
        );

        final parser = InputParser();

        // 1. Bare ESC _ -> Alt+_ immediately without stalling!
        final bareAltUnderscore = parser.parse('\x1b_'.codeUnits);
        expect(
          bareAltUnderscore,
          equals([
            const KeyEvent(
              '_',
              KeyType.character,
              modifiers: {ev.Modifier.alt},
            ),
          ]),
        );

        // 2. ESC _ followed by non-'G' -> Alt+_ plus trailing char!
        final altUnderscorePlusKey = parser.parse('\x1b_z'.codeUnits);
        expect(
          altUnderscorePlusKey,
          equals([
            const KeyEvent(
              '_',
              KeyType.character,
              modifiers: {ev.Modifier.alt},
            ),
            const KeyEvent('z', KeyType.character),
          ]),
        );

        // 3. Chunked valid Kitty APC response (split across chunks including split ST)
        expect(parser.parse('\x1b_Gi=9'.codeUnits), isEmpty);
        expect(parser.parse('9;OK\x1b'.codeUnits), isEmpty);
        final events = parser.parse('\\'.codeUnits);
        expect(
          events,
          equals([
            const KittyGraphicsEvent(
              imageId: 99,
              supported: true,
              message: 'OK',
            ),
          ]),
        );

        // 4. CAN (0x18) and SUB (0x1A) abort malformed APC cleanly
        final afterCan = parser.parse('\x1b_Gi=1;BROKEN\x18k'.codeUnits);
        expect(afterCan, equals([const KeyEvent('k', KeyType.character)]));

        final afterSub = parser.parse('\x1b_Gi=1;BROKEN\x1am'.codeUnits);
        expect(afterSub, equals([const KeyEvent('m', KeyType.character)]));

        // 5. ESC followed by non-'\' aborts APC and re-processes from that ESC!
        final escRecovery = parser.parse('\x1b_Gi=1;UNCLOSED\x1b[A'.codeUnits);
        expect(escRecovery, equals([const KeyEvent('up', KeyType.up)]));

        // 6. > 1.4MB APC overflow is discarded without OOM or keystroke leak
        expect(parser.parse('\x1b_Gi=7;'.codeUnits), isEmpty);
        final bigChunk = List<int>.filled(800000, 0x41);
        expect(parser.parse(bigChunk), isEmpty);
        expect(parser.parse(bigChunk), isEmpty);
        final postOverflow = parser.parse('\x1b\\q'.codeUnits);
        expect(postOverflow, equals([const KeyEvent('q', KeyType.character)]));
      },
    );
  });
}
