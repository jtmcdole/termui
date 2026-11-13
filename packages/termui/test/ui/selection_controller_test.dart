import 'package:termui/termui.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart'
    as legacy_sel;
import 'package:termui/ui/widgets/interactive/terminal_selection_controller.dart'
    as term_sel;
import 'package:test/test.dart';

Buffer _buildSplitBuffer() {
  final splitBuf = Buffer(40, 10);
  for (var y = 0; y < 10; y++) {
    splitBuf.setCharacter(15, y, '│');
  }
  for (var x = 16; x < 40; x++) {
    splitBuf.setCharacter(x, 5, '─');
  }
  return splitBuf;
}

void main() {
  group('TerminalSelectionController', () {
    late TerminalSelectionController controller;

    setUp(() {
      controller = TerminalSelectionController();
    });

    tearDown(() {
      controller.dispose();
    });

    test(
      'exports match across termui, selection_controller, and terminal_selection_controller',
      () {
        expect(SelectionMode.normal, same(SelectionMode.character));
        expect(SelectionMode.stream, same(SelectionMode.character));
        expect(SelectionMode.box, same(SelectionMode.block));
        expect(
          legacy_sel.SelectionMode.character,
          same(term_sel.SelectionMode.character),
        );
        expect(const SelectionPoint(2, 3), equals(const SelectionPoint(2, 3)));
        expect(
          const SelectionRegion(minCol: 1, maxCol: 5, minRow: 2, maxRow: 6),
          equals(
            const SelectionRegion(minCol: 1, maxCol: 5, minRow: 2, maxRow: 6),
          ),
        );
      },
    );

    test('initial state has no selection', () {
      expect(controller.hasSelection, isFalse);
      expect(controller.isSelecting, isFalse);
      expect(controller.anchor, isNull);
      expect(controller.focus, isNull);
      expect(controller.region, isNull);
      expect(controller.isCellSelected(0, 0), isFalse);
      expect(controller.containsCell(0, 0), isFalse);
    });

    group('Stream / character selection mode', () {
      test('single row selection', () {
        controller.startSelection(2, 1, mode: SelectionMode.stream);
        expect(controller.isSelecting, isTrue);
        expect(controller.hasSelection, isFalse);

        controller.updateSelection(5, 1);
        expect(controller.hasSelection, isTrue);

        expect(controller.isCellSelected(1, 1), isFalse);
        expect(controller.isCellSelected(2, 1), isTrue);
        expect(controller.containsCell(3, 1), isTrue);
        expect(controller.isCellSelected(5, 1), isTrue);
        expect(controller.isCellSelected(6, 1), isFalse);
        expect(controller.isCellSelected(3, 0), isFalse);
        expect(controller.isCellSelected(3, 2), isFalse);
      });

      test('multi-row forward and backward selection', () {
        controller.startSelection(5, 1, mode: SelectionMode.character);
        controller.updateSelection(3, 3);

        expect(controller.isCellSelected(4, 1), isFalse);
        expect(controller.isCellSelected(5, 1), isTrue);
        expect(controller.isCellSelected(10, 1), isTrue);
        expect(controller.isCellSelected(0, 2), isTrue);
        expect(controller.isCellSelected(3, 3), isTrue);
        expect(controller.isCellSelected(4, 3), isFalse);

        controller.startSelection(3, 3, mode: SelectionMode.stream);
        controller.updateSelection(5, 1);
        expect(controller.isCellSelected(5, 1), isTrue);
        expect(controller.isCellSelected(3, 3), isTrue);
        expect(controller.isCellSelected(4, 3), isFalse);
      });

      test('line and word selection modes', () {
        final buf = Buffer(20, 4);
        buf.writeString(0, 0, 'alpha beta gamma    ', const Style());
        buf.writeString(0, 1, 'second line text    ', const Style());

        controller.startSelection(3, 0, mode: SelectionMode.line);
        controller.updateSelection(2, 1);
        expect(controller.containsCell(0, 0), isTrue);
        expect(controller.containsCell(19, 1), isTrue);
        expect(
          controller.extractSelectedText(buf),
          equals('alpha beta gamma\nsecond line text'),
        );

        controller.selectWord(buf, 7, 0);
        expect(controller.mode, equals(SelectionMode.word));
        expect(controller.extractSelectedText(buf), equals('beta'));
      });

      test(
        'selectWord and updateWordSelection handle wide CJK words, forward/backward drags, and direction reversal',
        () {
          final buf = Buffer(24, 3);
          buf.writeString(0, 0, 'alpha beta gamma', const Style());
          // Row 1: 'hi 日本語 ok' -> cols: 0='h',1='i',2=' ',3='日',4='',5='本',6='',7='語',8='',9=' ',10='o',11='k'
          buf.writeString(0, 1, 'hi 日本語 ok', const Style());
          buf.writeString(0, 2, 'tail word', const Style());

          // 1. Wide CJK word selection hitting both lead and continuation columns.
          controller.selectWord(buf, 5, 1); // lead of '本'
          expect(controller.anchor, equals(const SelectionPoint(3, 1)));
          expect(controller.focus, equals(const SelectionPoint(8, 1)));
          expect(controller.extractSelectedText(buf), equals('日本語'));

          controller.selectWord(buf, 6, 1); // continuation '' of '本'
          expect(controller.anchor, equals(const SelectionPoint(3, 1)));
          expect(controller.focus, equals(const SelectionPoint(8, 1)));
          expect(controller.extractSelectedText(buf), equals('日本語'));

          // 2. Same-row forward drag, backward drag, and reversal back over anchor word.
          var notifications = 0;
          void listener() => notifications++;
          controller.addListener(listener);

          controller.selectWord(buf, 7, 0); // 'beta' (6..9)
          expect(notifications, equals(1));
          expect(controller.extractSelectedText(buf), equals('beta'));

          // Drag forward to 'gamma' (11..15).
          controller.updateWordSelection(buf, 12, 0);
          expect(notifications, equals(2));
          expect(controller.anchor, equals(const SelectionPoint(6, 0)));
          expect(controller.focus, equals(const SelectionPoint(15, 0)));
          expect(controller.extractSelectedText(buf), equals('beta gamma'));

          // Redundant update on same word skips listener notification.
          controller.updateWordSelection(buf, 14, 0);
          expect(notifications, equals(2));

          // Reverse backward onto initial word 'beta' (6..9).
          controller.updateWordSelection(buf, 8, 0);
          expect(notifications, equals(3));
          expect(controller.anchor, equals(const SelectionPoint(6, 0)));
          expect(controller.focus, equals(const SelectionPoint(9, 0)));
          expect(controller.extractSelectedText(buf), equals('beta'));

          // Continue dragging backward to 'alpha' (0..4).
          controller.updateWordSelection(buf, 2, 0);
          expect(notifications, equals(4));
          expect(controller.anchor, equals(const SelectionPoint(9, 0)));
          expect(controller.focus, equals(const SelectionPoint(0, 0)));
          expect(controller.extractSelectedText(buf), equals('alpha beta'));

          // Drag forward into row 1 onto CJK continuation col 6 ('本').
          controller.updateWordSelection(buf, 6, 1);
          expect(controller.anchor, equals(const SelectionPoint(6, 0)));
          expect(controller.focus, equals(const SelectionPoint(8, 1)));
          expect(
            controller.extractSelectedText(buf),
            equals('beta gamma\nhi 日本語'),
          );

          // Anchor on row 1 CJK word ('日本語', 3..8) and drag backward to row 0 'gamma' (11..15).
          controller.selectWord(buf, 4, 1);
          controller.updateWordSelection(buf, 13, 0);
          expect(controller.anchor, equals(const SelectionPoint(8, 1)));
          expect(controller.focus, equals(const SelectionPoint(11, 0)));
          expect(controller.extractSelectedText(buf), equals('gamma\nhi 日本語'));

          // Region clamping confines word drag bounds.
          const region = SelectionRegion(
            minCol: 3,
            maxCol: 10,
            minRow: 1,
            maxRow: 2,
          );
          controller.selectWord(buf, 4, 1, region: region);
          expect(controller.extractSelectedText(buf), equals('日本語'));
          controller.updateWordSelection(buf, 20, 2);
          expect(controller.focus, equals(const SelectionPoint(10, 2)));

          // startSelection clears _wordAnchor so subsequent updateWordSelection
          // uses the new anchor instead of the stale word span.
          controller.startSelection(0, 0);
          controller.updateWordSelection(buf, 13, 0);
          expect(controller.anchor, equals(const SelectionPoint(0, 0)));
          expect(controller.focus, equals(const SelectionPoint(15, 0)));
          expect(
            controller.extractSelectedText(buf),
            equals('alpha beta gamma'),
          );

          controller.removeListener(listener);
        },
      );
    });

    group('Block / box selection mode', () {
      test('rectangular box selection forward and backward', () {
        controller.startSelection(2, 1, mode: SelectionMode.box);
        controller.updateSelection(5, 3);

        expect(controller.isCellSelected(2, 1), isTrue);
        expect(controller.isCellSelected(5, 3), isTrue);
        expect(controller.isCellSelected(3, 2), isTrue);
        expect(controller.isCellSelected(1, 2), isFalse);
        expect(controller.isCellSelected(6, 2), isFalse);
        expect(controller.isCellSelected(3, 0), isFalse);
        expect(controller.isCellSelected(3, 4), isFalse);

        controller.startSelection(5, 3, mode: SelectionMode.block);
        controller.updateSelection(2, 1);
        expect(controller.isCellSelected(2, 1), isTrue);
        expect(controller.isCellSelected(5, 3), isTrue);
      });
    });

    group('Region clipping', () {
      const region = SelectionRegion(
        minCol: 10,
        maxCol: 20,
        minRow: 5,
        maxRow: 15,
      );

      test('clamps start and update coordinates within region', () {
        controller.startSelection(
          5,
          2,
          mode: SelectionMode.stream,
          region: region,
        );
        expect(controller.anchor, equals(const SelectionPoint(10, 5)));

        controller.updateSelection(25, 18);
        expect(controller.focus, equals(const SelectionPoint(20, 15)));
      });

      test('confines stream and block selection to region', () {
        controller.startSelection(
          12,
          6,
          mode: SelectionMode.stream,
          region: region,
        );
        controller.updateSelection(18, 8);

        expect(controller.isCellSelected(9, 7), isFalse);
        expect(controller.isCellSelected(21, 7), isFalse);
        expect(controller.isCellSelected(10, 7), isTrue);
        expect(controller.isCellSelected(20, 7), isTrue);
        expect(controller.isCellSelected(18, 8), isTrue);
        expect(controller.isCellSelected(19, 8), isFalse);

        controller.startSelection(
          12,
          6,
          mode: SelectionMode.block,
          region: region,
        );
        controller.updateSelection(25, 9);
        expect(controller.isCellSelected(20, 9), isTrue);
        expect(controller.isCellSelected(21, 9), isFalse);
      });
    });

    group('Selectable regions, Viewports, and resolveRegionForCell', () {
      test(
        'Viewport and nested Viewport register accurate root selectableRegions and clear resets them',
        () {
          final root = Buffer(80, 24);
          root.registerSelectableRegion(const Rect(0, 0, 0, 10)); // ignored
          expect(root.selectableRegions, isEmpty);

          final outer = Viewport(root, const Rect(10, 4, 50, 16));
          final inner = Viewport(outer, const Rect(5, 2, 20, 8));
          inner.writeString(0, 0, 'Nested', const Style());

          expect(
            root.selectableRegions,
            equals([const Rect(10, 4, 50, 16), const Rect(15, 6, 20, 8)]),
          );

          // Smallest-area matching sub-region wins for (18, 8).
          final resolvedInner =
              TerminalSelectionController.resolveRegionForCell(root, 18, 8);
          expect(
            resolvedInner,
            equals(
              const SelectionRegion(
                minCol: 15,
                maxCol: 34,
                minRow: 6,
                maxRow: 13,
              ),
            ),
          );

          // In outer but outside inner -> resolves to outer.
          final resolvedOuter =
              TerminalSelectionController.resolveRegionForCell(root, 12, 5);
          expect(
            resolvedOuter,
            equals(
              const SelectionRegion(
                minCol: 10,
                maxCol: 59,
                minRow: 4,
                maxRow: 19,
              ),
            ),
          );

          // Block/box mode returns null so Alt+Drag is never clamped automatically.
          expect(
            TerminalSelectionController.resolveRegionForCell(
              root,
              18,
              8,
              mode: SelectionMode.block,
            ),
            isNull,
          );

          root.clear();
          expect(root.selectableRegions, isEmpty);
        },
      );

      test(
        'Compositor propagates selectableRegions across layers and prioritizes higher-zIndex modals over occluded background panes',
        () {
          final bgLayer = Buffer.blank(80, 24);
          Viewport(bgLayer, const Rect(0, 0, 30, 24)); // area 720, zIndex 0
          Viewport(bgLayer, const Rect(31, 0, 49, 24)); // zIndex 0

          // Larger modal (50x18 = area 900 > 720) floating at zIndex 10 over both panes.
          final modalLayer = Buffer(50, 18);
          Viewport(modalLayer, const Rect(1, 1, 48, 16)); // area 768 > 720!

          final target = Buffer.blank(80, 24);
          Compositor().composite(
            target: target,
            layers: [
              LayeredBuffer(buffer: bgLayer, x: 0, y: 0, zIndex: 0),
              LayeredBuffer(buffer: modalLayer, x: 10, y: 3, zIndex: 10),
            ],
          );

          // Unoccluded left pane cell (5, 5) resolves to left pane (0..29).
          expect(
            TerminalSelectionController.resolveRegionForCell(target, 5, 5),
            equals(
              const SelectionRegion(
                minCol: 0,
                maxCol: 29,
                minRow: 0,
                maxRow: 23,
              ),
            ),
          );

          // Cell (20, 8) inside the modal resolves to modal content (11..58, 4..19)
          // rather than getting sliced at col 29 by the occluded smaller-area background pane!
          expect(
            TerminalSelectionController.resolveRegionForCell(target, 20, 8),
            equals(
              const SelectionRegion(
                minCol: 11,
                maxCol: 58,
                minRow: 4,
                maxRow: 19,
              ),
            ),
          );
        },
      );

      test(
        'resolveRegionForCell clamps vertical/box dividers but NEVER clamps plain shell horizontal rules',
        () {
          // 1. Plain shell output with a full-width horizontal rule (no vertical dividers):
          final shellBuf = Buffer(40, 10);
          shellBuf.writeString(0, 2, 'commit 12345', const Style());
          shellBuf.writeString(0, 4, '─' * 40, const Style());
          shellBuf.writeString(0, 6, 'diff --git a/foo b/foo', const Style());

          expect(
            TerminalSelectionController.resolveRegionForCell(shellBuf, 5, 2),
            isNull,
          );

          // 2. Split panes with vertical divider at col 15 and horizontal split in right pane at row 5:
          final splitBuf = _buildSplitBuffer();

          final leftPane = TerminalSelectionController.resolveRegionForCell(
            splitBuf,
            5,
            3,
          );
          expect(
            leftPane,
            equals(
              const SelectionRegion(
                minCol: 0,
                maxCol: 14,
                minRow: 0,
                maxRow: 9,
              ),
            ),
          );

          final rightTopPane = TerminalSelectionController.resolveRegionForCell(
            splitBuf,
            20,
            2,
          );
          expect(
            rightTopPane,
            equals(
              const SelectionRegion(
                minCol: 16,
                maxCol: 39,
                minRow: 0,
                maxRow: 4,
              ),
            ),
          );

          // Block mode ignores dividers.
          expect(
            TerminalSelectionController.resolveRegionForCell(
              splitBuf,
              20,
              2,
              mode: SelectionMode.box,
            ),
            isNull,
          );
        },
      );
    });

    group('extractSelectedText / extractText', () {
      late Buffer buffer;

      setUp(() {
        buffer = Buffer(20, 10);
        buffer.writeString(0, 0, 'Hello World         ', const Style());
        buffer.writeString(0, 1, 'Secret Code: 1234   ', const Style());
        buffer.writeString(0, 2, 'Line Three Here     ', const Style());

        for (var x = 13; x <= 16; x++) {
          buffer.setModifiers(x, 1, Modifier.hidden);
        }
      });

      test('extracts stream, hidden, block, and skips kitty placeholders', () {
        controller.startSelection(6, 0, mode: SelectionMode.stream);
        controller.updateSelection(10, 1);
        expect(
          controller.extractSelectedText(buffer),
          equals('World\nSecret Code'),
        );

        controller.startSelection(0, 1, mode: SelectionMode.stream);
        controller.updateSelection(16, 1);
        expect(
          controller.extractText(buffer, includeHidden: true),
          equals('Secret Code: 1234'),
        );
        expect(
          controller.extractSelectedText(buffer, includeHidden: false),
          equals('Secret Code: '),
        );

        controller.startSelection(0, 0, mode: SelectionMode.block);
        controller.updateSelection(4, 2);
        expect(controller.extractText(buffer), equals('Hello\nSecre\nLine '));

        buffer.writeString(0, 3, 'AB[IMAGE]CD         ', const Style());
        for (var x = 2; x <= 8; x++) {
          buffer.setModifiers(x, 3, Modifier.kittyPlaceholder);
        }
        controller.startSelection(0, 3, mode: SelectionMode.stream);
        controller.updateSelection(10, 3);
        expect(controller.extractText(buffer), equals('ABCD'));
      });
    });

    group('Listeners and notifications', () {
      test('notifies listeners on start, update, and clear', () {
        var notifyCount = 0;
        void listener() => notifyCount++;

        controller.addListener(listener);
        controller.startSelection(1, 1);
        expect(notifyCount, equals(1));

        controller.updateSelection(2, 2);
        expect(notifyCount, equals(2));

        controller.updateSelection(2, 2);
        expect(notifyCount, equals(2));

        controller.clearSelection();
        expect(notifyCount, equals(3));

        controller.clearSelection();
        expect(notifyCount, equals(3));

        controller.removeListener(listener);
        controller.startSelection(3, 3);
        expect(notifyCount, equals(3));
      });
    });

    group('Virtual offsets, wide snapping, and resolveLinkSpanAt', () {
      test(
        'visibleRowSpans and extractVirtualText handle scrollback offsets, soft wraps, and wide graphemes',
        () {
          final lines = <VirtualLineSlice>[
            (
              isWrapped: false,
              characters: ['A', '🔥', '', 'B', 'Z'],
              uris: null,
            ),
            (
              isWrapped: true,
              characters: ['C', 'D', ' ', ' ', ' '],
              uris: null,
            ),
            (
              isWrapped: false,
              characters: ['E', 'F', ' ', ' ', ' '],
              uris: null,
            ),
          ];
          VirtualLineSlice? lookup(int y) =>
              y >= 0 && y < lines.length ? lines[y] : null;

          // Select from right-half continuation of '🔥' (col 2, row 0) through (col 1, row 2).
          controller.startSelection(2, 0, mode: SelectionMode.normal);
          controller.updateSelection(1, 2);
          expect(controller.extractVirtualText(lookup, cols: 5), '🔥BZCD\nEF');

          // Viewport showing virtual rows 0..1:
          final viewport = Buffer.blank(5, 2)
            ..writeString(0, 0, 'A🔥BZ', const Style())
            ..writeString(0, 1, 'CD', const Style());
          expect(
            controller.visibleRowSpans(viewport, topVirtualRow: 0),
            equals([(0, 1, 4), (1, 0, 4)]),
          );
          expect(controller.containsCell(2, 0, topVirtualRow: 0), isTrue);
          expect(controller.containsCell(0, 0, topVirtualRow: 1), isTrue);
        },
      );

      test(
        'resolveLinkSpanAt resolves contiguous OSC 8 spans across wraps before plain-text https and mailto',
        () {
          final lines = <VirtualLineSlice>[
            (
              isWrapped: false,
              characters: 'See Click'.split(''),
              uris: [
                null,
                null,
                null,
                null,
                ...List<String?>.filled(5, 'https://dart.dev/docs'),
              ],
            ),
            (
              isWrapped: true,
              characters: ' Here mailto:dev@dart.dev!'.split(''),
              uris: [
                ...List<String?>.filled(5, 'https://dart.dev/docs'),
                ...List<String?>.filled(21, null),
              ],
            ),
            (
              isWrapped: false,
              characters: 'Evil https://safe.example/ok'.split(''),
              uris: [
                ...List<String?>.filled(4, 'javascript:alert(1)'),
                ...List<String?>.filled(24, null),
              ],
            ),
          ];
          VirtualLineSlice? lookup(int y) =>
              y >= 0 && y < lines.length ? lines[y] : null;

          // 1. Multi-row wrapped OSC 8 span resolves full start..end across rows 0..1.
          final osc8Span = TerminalSelectionController.resolveLinkSpanAt(
            lookup: lookup,
            col: 2,
            virtualRow: 1,
          );
          expect(
            osc8Span,
            equals((
              uri: 'https://dart.dev/docs',
              startCol: 4,
              startRow: 0,
              endCol: 4,
              endRow: 1,
            )),
          );

          // 2. Plain-text mailto: fallback strips trailing '!'.
          final mailtoSpan = TerminalSelectionController.resolveLinkSpanAt(
            lookup: lookup,
            col: 12,
            virtualRow: 1,
          );
          expect(
            mailtoSpan,
            equals((
              uri: 'mailto:dev@dart.dev',
              startCol: 6,
              startRow: 1,
              endCol: 24,
              endRow: 1,
            )),
          );

          // 3. Hostile javascript: OSC 8 URI is rejected, while plain https:// works.
          expect(
            TerminalSelectionController.resolveLinkSpanAt(
              lookup: lookup,
              col: 1,
              virtualRow: 2,
            ),
            isNull,
          );
          expect(
            TerminalSelectionController.resolveLinkSpanAt(
              lookup: lookup,
              col: 10,
              virtualRow: 2,
            )?.uri,
            equals('https://safe.example/ok'),
          );
        },
      );

      test(
        'extractVirtualText preserves newlines across split-pane rows even when line.isWrapped is true',
        () {
          final lines = <VirtualLineSlice>[
            (
              isWrapped: false,
              characters: 'Left0│Right0'.split(''),
              uris: null,
            ),
            (isWrapped: true, characters: 'Left1│Right1'.split(''), uris: null),
            (isWrapped: true, characters: 'Left2│Right2'.split(''), uris: null),
          ];
          VirtualLineSlice? lookup(int y) =>
              y >= 0 && y < lines.length ? lines[y] : null;

          controller
            ..startSelection(
              0,
              0,
              mode: SelectionMode.normal,
              region: const SelectionRegion(
                minCol: 0,
                maxCol: 4,
                minRow: 0,
                maxRow: 2,
              ),
            )
            ..updateSelection(4, 2);

          expect(
            controller.extractVirtualText(lookup, cols: 12),
            equals('Left0\nLeft1\nLeft2'),
          );
        },
      );
    });
  });
}
