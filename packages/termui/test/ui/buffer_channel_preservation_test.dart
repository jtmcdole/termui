import 'dart:typed_data';
import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  const richLinkStyle = Style(
    foreground: Color(240, 220, 120),
    background: Color(20, 30, 50),
    underlineStyle: UnderlineStyle.curly,
    underlineColor: Color(255, 64, 128),
    uri: 'https://example.dev/spec',
    modifiers: Modifier.bold | Modifier.overline,
  );

  group('All-channel Buffer & container preservation contract', () {
    test(
      'Buffer wide-char overwrite and drawCautionTape clear stale underlineColor and OSC 8 uri',
      () {
        final buf = Buffer.blank(10, 2);
        buf.writeString(0, 0, '漢字', richLinkStyle);
        expect(buf.getUri(0, 0), equals('https://example.dev/spec'));
        expect(buf.getUri(1, 0), equals('https://example.dev/spec'));
        expect(buf.getUnderlineColor(1, 0), const Color(255, 64, 128).argb);

        // Overwrite left cell of first wide char with narrow ASCII: right continuation cell (1,0) must reset cleanly!
        buf.writeString(0, 0, 'X', const Style());
        expect(buf.getCharacter(0, 0), equals('X'));
        expect(buf.getCharacter(1, 0), equals(' '));
        expect(buf.getUri(1, 0), isNull);
        expect(buf.getUnderlineColor(1, 0), equals(0));
        expect(buf.getModifiers(1, 0), equals(Modifier.none));

        // Caution tape over second wide char clears stale link/underline metadata.
        buf.drawCautionTape(const Rect(2, 0, 2, 1), 0, 0);
        expect(buf.getUri(2, 0), isNull);
        expect(buf.getUnderlineColor(2, 0), equals(0));
        expect(buf.getModifiers(2, 0), equals(Modifier.none));
      },
    );

    test(
      'BufferWidget preserves SGR 58, OSC 8, effects, and scoped KittyImageRegistry on Buffer and Viewport',
      () {
        final scopedReg = KittyImageRegistry()
          ..registerImage(
            KittyImageData(
              imageId: 7,
              pixelWidth: 1,
              pixelHeight: 1,
              rgbaPixels: Uint8List.fromList([1, 2, 3, 255]),
              gridCols: 2,
              gridRows: 1,
            ),
          );
        final src = Buffer.blank(6, 2)
          ..writeString(0, 0, 'LINK', richLinkStyle)
          ..registerKittyRegistry(const Rect(0, 0, 6, 2), scopedReg);

        final dst = Buffer.blank(12, 4);
        final el = BufferWidget(buffer: src).createElement()
          ..mount(null)
          ..layout(const BoxConstraints(maxWidth: 6, maxHeight: 2))
          ..paint(dst, const Offset(3, 1));
        addTearDown(el.unmount);

        expect(dst.cellsEqual(3, 1, src, 0, 0), isTrue);
        expect(dst.getUnderlineColor(3, 1), const Color(255, 64, 128).argb);
        expect(dst.getUri(3, 1), equals('https://example.dev/spec'));
        expect(dst.lookupKittyRegistry(4, 1), same(scopedReg));

        // Also verify painting BufferWidget into a Viewport never throws and preserves all channels.
        final vpParent = Buffer.blank(12, 4);
        final vp = Viewport(vpParent, const Rect(2, 1, 8, 2));
        el.paint(vp, const Offset(1, 0));
        expect(vpParent.cellsEqual(3, 1, src, 0, 0), isTrue);
        expect(vpParent.lookupKittyRegistry(4, 1), same(scopedReg));
      },
    );

    test(
      'SingleChildScrollView (vertical and horizontal) preserves SGR 58, OSC 8, UnderlineStyle, and scoped KittyImageRegistry',
      () {
        final scopedReg = KittyImageRegistry();
        final childBuf = Buffer.blank(8, 2)
          ..writeString(0, 0, 'Row 0', const Style())
          ..writeString(0, 1, 'CURLYLNK', richLinkStyle)
          ..registerKittyRegistry(const Rect(0, 1, 8, 1), scopedReg);

        final vController = DiscreteScrollController(initialScrollOffset: 1);
        final vScroll = SingleChildScrollView(
          controller: vController,
          childLength: 2,
          scrollDirection: LayoutDirection.vertical,
          child: BufferWidget(buffer: childBuf),
        );

        final vBuf = Buffer.blank(10, 1);
        final vEl = vScroll.createElement()
          ..mount(null)
          ..layout(BoxConstraints.tight(const Size(10, 1)))
          ..paint(vBuf, Offset.zero);
        addTearDown(vEl.unmount);

        expect(vBuf.getCharacter(0, 0), equals('C'));
        expect(
          Modifier.getUnderlineStyle(vBuf.getModifiers(0, 0)),
          equals(UnderlineStyle.curly),
        );
        expect(vBuf.getUnderlineColor(0, 0), const Color(255, 64, 128).argb);
        expect(vBuf.getUri(0, 0), equals('https://example.dev/spec'));
        expect(vBuf.lookupKittyRegistry(2, 0), same(scopedReg));

        // Horizontal scroll
        final hController = DiscreteScrollController(initialScrollOffset: 2);
        final hScroll = SingleChildScrollView(
          controller: hController,
          childLength: 6,
          scrollDirection: LayoutDirection.horizontal,
          child: const Text('>>LINK', style: richLinkStyle),
        );
        final hBuf = Buffer.blank(4, 1);
        final hEl = hScroll.createElement()
          ..mount(null)
          ..layout(BoxConstraints.tight(const Size(4, 1)))
          ..paint(hBuf, Offset.zero);
        addTearDown(hEl.unmount);

        expect(hBuf.getCharacter(0, 0), equals('L'));
        expect(hBuf.getUnderlineColor(0, 0), const Color(255, 64, 128).argb);
        expect(hBuf.getUri(0, 0), equals('https://example.dev/spec'));
      },
    );

    test(
      'FittedBox(clipBehavior: Clip.hardEdge) and ListView preserve SGR 58, OSC 8, and scoped KittyImageRegistry',
      () {
        final scopedReg = KittyImageRegistry();
        final srcBuf = Buffer.blank(8, 1)
          ..writeString(0, 0, 'HARDCLIP', richLinkStyle)
          ..registerKittyRegistry(const Rect(0, 0, 8, 1), scopedReg);
        final fitted = FittedBox(
          clipBehavior: Clip.hardEdge,
          child: BufferWidget(buffer: srcBuf),
        );

        final fBuf = Buffer.blank(6, 1);
        final fEl = fitted.createElement()
          ..mount(null)
          ..layout(BoxConstraints.tight(const Size(6, 1)))
          ..paint(fBuf, Offset.zero);
        addTearDown(fEl.unmount);

        expect(fBuf.getUnderlineColor(0, 0), const Color(255, 64, 128).argb);
        expect(fBuf.getUri(0, 0), equals('https://example.dev/spec'));
        expect(
          Modifier.getUnderlineStyle(fBuf.getModifiers(0, 0)),
          equals(UnderlineStyle.curly),
        );
        expect(fBuf.lookupKittyRegistry(2, 0), same(scopedReg));

        // ListView with selectedStyle carrying underlineColor & uri preserves/merges them cleanly.
        final lv = ListView(
          selectedIndex: 0,
          selectedStyle: const Style(
            background: Color(40, 50, 70),
            underlineColor: Color(11, 22, 33),
          ),
          children: const [
            Text('Item0', style: Style(uri: 'https://item.dev')),
          ],
        );
        final lvBuf = Buffer.blank(8, 1);
        final lvEl = lv.createElement()
          ..mount(null)
          ..layout(BoxConstraints.tight(const Size(8, 1)))
          ..paint(lvBuf, Offset.zero);
        addTearDown(lvEl.unmount);

        expect(lvBuf.getUnderlineColor(0, 0), const Color(11, 22, 33).argb);
        expect(lvBuf.getUri(0, 0), equals('https://item.dev'));
      },
    );
  });
}
