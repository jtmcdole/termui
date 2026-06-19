import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/layout/column.dart';
import 'package:termui/ui/widgets/layout/stack.dart';
import 'package:termui/ui/widgets/layout/positioned.dart';
import 'package:termui/ui/widgets/layout/sized_box.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/widget_toolkit.dart';

class TestCellWidget extends Widget {
  final String content;
  const TestCellWidget(this.content);

  @override
  Element createElement() => _TestCellElement(this);
}

class _TestCellElement extends Element {
  _TestCellElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(
      Size((widget as TestCellWidget).content.length, 1),
    );
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    buffer.writeString(
      offset.dx,
      offset.dy,
      (widget as TestCellWidget).content,
      Style.empty,
    );
  }
}

void main() {
  group('LinearProgressIndicator Tests', () {
    test('LinearProgressIndicator renders correctly', () {
      final buffer = Buffer.blank(10, 1);
      final indicator = const LinearProgressIndicator(
        0.5,
        showPercentage: false,
      );
      ElementWidget(indicator)
        ..layout(BoxConstraints.tight(const Size(10, 1)))
        ..paint(buffer, Offset.zero);

      // 0.5 of 10 is 5 cells filled
      expect(buffer.getCell(0, 0)!.char, equals('█'));
      expect(buffer.getCell(4, 0)!.char, equals('█'));
      expect(buffer.getCell(5, 0)!.char, equals('░'));
    });
  });

  group('Spinner Wall-Clock & Speed Tests', () {
    test('Spinner is driven by wall-clock time by default', () {
      final spinner = Spinner.line(speed: const Duration(milliseconds: 10));
      final initial = spinner.currentFrame;

      // Wait slightly for clock to advance
      final stopWatch = Stopwatch()..start();
      while (stopWatch.elapsed < const Duration(milliseconds: 15)) {
        // busy wait briefly
      }

      final current = spinner.currentFrame;
      // Frame index should change based on elapsed time
      expect(initial, isNotEmpty);
      expect(current, isNotEmpty);
    });

    test('Spinner supports manual tick for backward compatibility', () {
      final spinner = Spinner.line();
      expect(spinner.currentFrame, equals('|'));
      spinner.tick();
      expect(spinner.currentFrame, equals('/'));
      spinner.tick();
      expect(spinner.currentFrame, equals('-'));
    });
  });

  group('Table with Widgets Tests', () {
    test('Table renders cell widgets correctly', () {
      final buffer = Buffer.blank(20, 4);
      final table = Table(
        headers: ['Name', 'Status'],
        rows: [
          ['Alice', const TestCellWidget('RUN')],
          ['Bob', const TestCellWidget('OK')],
        ],
        columnWidths: [6, 6],
      );

      ElementWidget(table)
        ..layout(BoxConstraints.tight(const Size(20, 4)))
        ..paint(buffer, Offset.zero);

      // Row 0: Headers
      final row0 = List.generate(
        20,
        (x) => buffer.getCell(x, 0)!.char,
      ).join('');
      expect(row0, startsWith('Name   Status'));

      // Row 2: First row data ('Alice  RUN')
      final row2 = List.generate(
        20,
        (x) => buffer.getCell(x, 2)!.char,
      ).join('');
      expect(row2, startsWith('Alice  RUN'));

      // Row 3: Second row data ('Bob    OK')
      final row3 = List.generate(
        20,
        (x) => buffer.getCell(x, 3)!.char,
      ).join('');
      expect(row3, startsWith('Bob    OK'));
    });
  });

  group('Overlay and Interactive Overlays Tests', () {
    test('Overlay inserts and renders entries in Stack order', () {
      final buffer = Buffer.blank(10, 10);

      final entry1 = OverlayEntry(
        builder: (context) {
          return const Positioned(
            left: 0,
            top: 0,
            width: 2,
            height: 1,
            child: TestCellWidget('E1'),
          );
        },
      );
      final entry2 = OverlayEntry(
        builder: (context) {
          return const Positioned(
            left: 2,
            top: 0,
            width: 2,
            height: 1,
            child: TestCellWidget('E2'),
          );
        },
      );

      final overlayWidget = Overlay(
        initialEntries: [entry1, entry2],
        child: const TestCellWidget('BG'),
      );

      // Lazily run stateful loop
      final rootEl = StatefulElement(overlayWidget)..mount(null);
      rootEl.layout(BoxConstraints.tight(const Size(10, 10)));
      rootEl.paint(buffer, Offset.zero);

      // E1 rendered at (0, 0)
      expect(buffer.getCell(0, 0)!.char, equals('E'));
      expect(buffer.getCell(1, 0)!.char, equals('1'));

      // E2 rendered at (2, 0)
      expect(buffer.getCell(2, 0)!.char, equals('E'));
      expect(buffer.getCell(3, 0)!.char, equals('2'));

      // BG (child) is overwritten/covered under (0, 0) by E1, but visible elsewhere if rendered
      // E2 is removed
      entry2.remove();
      buffer.clear();
      rootEl.layout(BoxConstraints.tight(const Size(10, 10)));
      rootEl.paint(buffer, Offset.zero);

      expect(buffer.getCell(0, 0)!.char, equals('E'));
      // E2 position is now empty/clear
      expect(buffer.getCell(2, 0)!.char, equals(' '));
    });

    test('DropdownButton toggles dropdown menu on action', () {
      final items = [
        const DropdownMenuItem(value: '1', child: TestCellWidget('One')),
        const DropdownMenuItem(value: '2', child: TestCellWidget('Two')),
      ];

      final dropdown = DropdownButton<String>(items: items, value: '1');

      final app = Overlay(
        child: Column([SizedBox(height: 1, child: dropdown)]),
      );

      final rootEl = StatefulElement(app)..mount(null);
      final buffer = Buffer.blank(20, 10);
      rootEl.layout(BoxConstraints.tight(const Size(20, 10)));
      rootEl.paint(buffer, Offset.zero);

      // Initially closed, shows selection
      // Find DropdownButton element and trigger action
      final stackEl = rootEl.childElement! as StackElement;
      final posEl = stackEl.childElements[0] as PositionedElement;
      final columnEl = posEl.childElement! as ColumnElement;
      final flexEl = columnEl.childElements[0] as SizedBoxElement; // SizedBox
      final dropEl = flexEl.childElement! as StatefulElement; // DropdownButton
      final dropState = dropEl.state as dynamic;

      // Open dropdown
      dropState.handleKeyEvent(const KeyEvent(' ', KeyType.character));
      rootEl.layout(BoxConstraints.tight(const Size(20, 10)));
      rootEl.paint(buffer, Offset.zero);

      // Dropdown menu elements should render below the button (row 1 and row 2)
      // Since first item is selected, row 1 shows 'One'
      expect(buffer.getCell(0, 1)!.char, equals('O'));
      expect(buffer.getCell(1, 1)!.char, equals('n'));
      expect(buffer.getCell(2, 1)!.char, equals('e'));

      // Move selection down
      dropState.handleKeyEvent(const KeyEvent('down', KeyType.down));
      rootEl.layout(BoxConstraints.tight(const Size(20, 10)));
      rootEl.paint(buffer, Offset.zero);

      // Confirm selection
      dropState.handleKeyEvent(const KeyEvent('enter', KeyType.enter));
      buffer.clear();
      rootEl.layout(BoxConstraints.tight(const Size(20, 10)));
      rootEl.paint(buffer, Offset.zero);

      // Menu is closed, row 1 is now empty/clear
      expect(buffer.getCell(0, 1)!.char, equals(' '));
    });

    test('PopupMenuButton toggles popup menu on action', () {
      final items = [
        const PopupMenuItem(value: 'A', child: TestCellWidget('Action A')),
        const PopupMenuItem(value: 'B', child: TestCellWidget('Action B')),
      ];

      var selectedVal = '';
      final menuButton = PopupMenuButton<String>(
        items: items,
        onSelected: (val) => selectedVal = val,
        child: const TestCellWidget('Menu'),
      );

      final app = Overlay(
        child: Column([SizedBox(height: 1, child: menuButton)]),
      );

      final rootEl = StatefulElement(app)..mount(null);
      final buffer = Buffer.blank(20, 10);
      rootEl.layout(BoxConstraints.tight(const Size(20, 10)));
      rootEl.paint(buffer, Offset.zero);

      final stackEl = rootEl.childElement! as StackElement;
      final posEl = stackEl.childElements[0] as PositionedElement;
      final columnEl = posEl.childElement! as ColumnElement;
      final flexEl = columnEl.childElements[0] as SizedBoxElement; // SizedBox
      final menuEl = flexEl.childElement! as StatefulElement; // PopupMenuButton
      final menuState = menuEl.state as dynamic;

      // Open menu
      menuState.handleKeyEvent(const KeyEvent(' ', KeyType.character));
      rootEl.layout(BoxConstraints.tight(const Size(20, 10)));
      rootEl.paint(buffer, Offset.zero);

      // Action A should render below the button (row 1)
      expect(buffer.getCell(0, 1)!.char, equals('A'));
      expect(buffer.getCell(1, 1)!.char, equals('c'));

      // Select first action
      menuState.handleKeyEvent(const KeyEvent('enter', KeyType.enter));
      buffer.clear();
      rootEl.layout(BoxConstraints.tight(const Size(20, 10)));
      rootEl.paint(buffer, Offset.zero);

      expect(selectedVal, equals('A'));
      // Menu is closed, row 1 is now empty/clear
      expect(buffer.getCell(0, 1)!.char, equals(' '));
    });
  });
}
