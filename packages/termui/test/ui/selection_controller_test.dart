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
  });
}
