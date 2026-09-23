import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('Issue #119 - Wide Emojis in U+2300..U+27BF Detection', () {
    test(
      'isWideGrapheme identifies Miscellaneous Technical emojis as wide',
      () {
        expect(
          isWideGrapheme('⏳'),
          isTrue,
          reason: 'U+23F3 Hourglass should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⌛'),
          isTrue,
          reason: 'U+231B Hourglass Done should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏭️'),
          isTrue,
          reason: 'U+23ED + VS16 Next Track should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⏭'),
          isFalse,
          reason: 'U+23ED Next Track without VS16 should be narrow (1 cell)',
        );
        expect(
          isWideGrapheme('⏩'),
          isTrue,
          reason: 'U+23E9 Fast-Forward should be wide (2 cells)',
        );
        expect(
          isWideGrapheme('⌚'),
          isTrue,
          reason: 'U+231A Watch should be wide (2 cells)',
        );
      },
    );

    test('isWideGrapheme identifies Miscellaneous Symbols emojis as wide', () {
      expect(
        isWideGrapheme('⚡'),
        isTrue,
        reason: 'U+26A1 High Voltage should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('⚪'),
        isTrue,
        reason: 'U+26AA White Circle should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('⚫'),
        isTrue,
        reason: 'U+26AB Black Circle should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('☕'),
        isTrue,
        reason: 'U+2615 Hot Beverage should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('⚽'),
        isTrue,
        reason: 'U+26BD Soccer Ball should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('⛔'),
        isTrue,
        reason: 'U+26D4 No Entry should be wide (2 cells)',
      );
    });

    test('isWideGrapheme identifies Dingbats emojis as wide', () {
      expect(
        isWideGrapheme('✅'),
        isTrue,
        reason: 'U+2705 Check Mark should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('✨'),
        isTrue,
        reason: 'U+2728 Sparkles should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('❌'),
        isTrue,
        reason: 'U+274C Cross Mark should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('❓'),
        isTrue,
        reason: 'U+2753 Question Mark should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('❗'),
        isTrue,
        reason: 'U+2757 Exclamation Mark should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('➕'),
        isTrue,
        reason: 'U+2795 Plus should be wide (2 cells)',
      );
    });

    test(
      'isWideGrapheme identifies Variation Selector-16 (U+FE0F) sequences as wide',
      () {
        // Gears with emoji variation selector
        expect(
          isWideGrapheme('⚙️'),
          isTrue,
          reason: 'U+2699 + U+FE0F should be wide (2 cells)',
        );
        // Warning with emoji variation selector
        expect(
          isWideGrapheme('⚠️'),
          isTrue,
          reason: 'U+26A0 + U+FE0F should be wide (2 cells)',
        );
        // Play button with emoji variation selector
        expect(
          isWideGrapheme('▶️'),
          isTrue,
          reason: 'U+25B6 + U+FE0F should be wide (2 cells)',
        );
      },
    );

    test('isWideGrapheme identifies Keycap sequences (U+20E3) as wide', () {
      expect(
        isWideGrapheme('#️⃣'),
        isTrue,
        reason: '# + U+FE0F + U+20E3 should be wide (2 cells)',
      );
      expect(
        isWideGrapheme('1️⃣'),
        isTrue,
        reason: '1 + U+FE0F + U+20E3 should be wide (2 cells)',
      );
    });
  });

  group('Issue #119 - Buffer writeString and Continuation Cells', () {
    test(
      'writeString for BMP wide emoji allocates continuation cell and advances 2 columns',
      () {
        final buffer = Buffer(5, 1);
        buffer.writeString(0, 0, '⏳A', Style.empty);

        expect(buffer.getCharacter(0, 0), '⏳');
        expect(
          buffer.getCharacter(1, 0),
          '',
          reason: 'Cell 1 must be an empty continuation cell',
        );
        expect(
          buffer.getCharacter(2, 0),
          'A',
          reason: "'A' must be written at column 2",
        );
      },
    );

    test(
      'writeString for VS16 emoji allocates continuation cell and advances 2 columns',
      () {
        final buffer = Buffer(5, 1);
        buffer.writeString(0, 0, '⚙️A', Style.empty);

        expect(buffer.getCharacter(0, 0), '⚙️');
        expect(
          buffer.getCharacter(1, 0),
          '',
          reason: 'Cell 1 must be an empty continuation cell',
        );
        expect(
          buffer.getCharacter(2, 0),
          'A',
          reason: "'A' must be written at column 2",
        );
      },
    );

    test(
      'measureStringWidth returns 2 for BMP wide emojis and VS16 sequences',
      () {
        expect(measureStringWidth('⏳'), 2);
        expect(measureStringWidth('⚡'), 2);
        expect(measureStringWidth('⚙️'), 2);
        expect(
          measureStringWidth('Status: ⏳'),
          10,
        ); // 8 ASCII chars + 2 for emoji = 10
      },
    );

    test(
      'padOrTruncate accounts for wide emojis and variation selectors correctly',
      () {
        // Width 5 with emoji taking 2 cells -> 3 padding spaces
        expect(padOrTruncate('⏳', 5), '⏳   ');
        expect(measureStringWidth(padOrTruncate('⏳', 5)), 5);

        expect(padOrTruncate('⚙️', 5), '⚙️   ');
        expect(measureStringWidth(padOrTruncate('⚙️', 5)), 5);
      },
    );
  });

  group('Issue #119 - Border and Table Alignment', () {
    test(
      'DecoratedBox child with wide emoji maintains right border alignment',
      () {
        final buffer = Buffer.blank(8, 3);
        final widget = DecoratedBox(
          decoration: const BoxDecoration(border: Border.single),
          child: const Text('⏳ OK', wrap: false),
        );

        final wrapper = ElementWidget(widget);
        wrapper.layout(BoxConstraints.tight(const Size(8, 3)));
        wrapper.paint(buffer, Offset.zero);

        // Row 0: ┌──────┐
        expect(buffer.getCharacter(0, 0), '┌');
        expect(buffer.getCharacter(7, 0), '┐');

        // Row 1: │⏳ OK │ -> │ at 0, ⏳ at 1, '' at 2, ' ' at 3, 'O' at 4, 'K' at 5, ' ' at 6, │ at 7
        expect(buffer.getCharacter(0, 1), '│');
        expect(buffer.getCharacter(1, 1), '⏳');
        expect(
          buffer.getCharacter(2, 1),
          '',
          reason: 'Continuation cell prevents right border shift',
        );
        expect(buffer.getCharacter(3, 1), ' ');
        expect(buffer.getCharacter(4, 1), 'O');
        expect(buffer.getCharacter(5, 1), 'K');
        expect(
          buffer.getCharacter(7, 1),
          '│',
          reason: 'Right border remains at column 7',
        );

        // Row 2: └──────┘
        expect(buffer.getCharacter(0, 2), '└');
        expect(buffer.getCharacter(7, 2), '┘');
      },
    );

    test('Table row containing wide emoji does not shift adjacent columns', () {
      final buffer = Buffer.blank(12, 3);
      final table = Table(
        headers: const ['Status', 'Info'],
        columnWidths: const [5, 6],
        rows: const [
          ['⏳', 'Wait'],
        ],
      );

      final element = ElementWidget(table);
      element.layout(BoxConstraints.tight(const Size(12, 3)));
      element.paint(buffer, Offset.zero);

      // Header row
      expect(buffer.getCharacter(0, 0), 'S');
      // Column separator at col 5
      expect(buffer.getCharacter(5, 0), ' ');
      // Second header starts at col 6
      expect(buffer.getCharacter(6, 0), 'I');

      // Row 0 (Y=2): cell 0 has '⏳', padded to col width 5 -> '⏳   '
      // col 0: '⏳', col 1: '', col 2: ' ', col 3: ' ', col 4: ' '
      expect(buffer.getCharacter(0, 2), '⏳');
      expect(buffer.getCharacter(1, 2), '');
      // Column separator at col 5
      expect(buffer.getCharacter(5, 2), ' ');
      // Second column starts strictly at col 6: 'W'
      expect(buffer.getCharacter(6, 2), 'W');
      expect(buffer.getCharacter(7, 2), 'a');
      expect(buffer.getCharacter(8, 2), 'i');
      expect(buffer.getCharacter(9, 2), 't');
    });
  });

  group('Issue #119 - Edge Cases & Boundary Conditions', () {
    test('Writing wide BMP emoji at last column falls back to space', () {
      final buffer = Buffer(5, 1);
      buffer.writeString(4, 0, '⏳', Style.empty);
      expect(buffer.getCharacter(4, 0), ' ');
    });

    test(
      'Overwriting first cell of wide BMP emoji clears continuation cell',
      () {
        final buffer = Buffer(5, 1);
        buffer.writeString(0, 0, '⏳', Style.empty);
        expect(buffer.getCharacter(0, 0), '⏳');
        expect(buffer.getCharacter(1, 0), '');

        buffer.writeString(0, 0, 'A', Style.empty);
        expect(buffer.getCharacter(0, 0), 'A');
        expect(buffer.getCharacter(1, 0), ' ');
      },
    );

    test(
      'Overwriting continuation cell of wide BMP emoji clears lead cell',
      () {
        final buffer = Buffer(5, 1);
        buffer.writeString(0, 0, '⏳', Style.empty);
        expect(buffer.getCharacter(0, 0), '⏳');
        expect(buffer.getCharacter(1, 0), '');

        buffer.writeString(1, 0, 'A', Style.empty);
        expect(buffer.getCharacter(0, 0), ' ');
        expect(buffer.getCharacter(1, 0), 'A');
      },
    );

    test('setAttributes sets continuation cell for wide BMP emoji', () {
      final buffer = Buffer(5, 1);
      buffer.setAttributes(0, 0, char: '⏳');
      expect(buffer.getCharacter(0, 0), '⏳');
      expect(buffer.getCharacter(1, 0), '');
    });

    test('padOrTruncate truncates wide emoji when target width is 1', () {
      // Wide emoji requires 2 cells; if target width is 1, it cannot fit and pads with space
      expect(padOrTruncate('⏳', 1), ' ');
      expect(measureStringWidth(padOrTruncate('⏳', 1)), 1);
    });
  });

  group('Issue #119 - Golden Tests', () {
    test('DecoratedBox with wide BMP emoji maintains golden alignment', () {
      final buffer = Buffer.blank(16, 5);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.rounded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Column(const [
            Text('⏳ Wait'),
            Text('⚙️ Gear'),
            Text('✅ Done'),
          ], crossAxisAlignment: CrossAxisAlignment.stretch),
        ),
      );

      final element = ElementWidget(widget);
      element.layout(BoxConstraints.tight(const Size(16, 5)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/wide_emoji_decorated_box.ansi'),
      );
    });

    test(
      'Table with wide BMP emojis and variation selectors maintains golden alignment',
      () {
        final buffer = Buffer.blank(22, 6);
        final table = Table(
          headers: const ['Icon', 'Label', 'Value'],
          columnWidths: const [6, 8, 6],
          rows: const [
            ['⏳', 'Build', 'Wait'],
            ['⚙️', 'Config', 'Active'],
            ['⚡', 'Power', 'Fast'],
            ['#️⃣', 'Index', '42'],
          ],
          selectedRowIndex: 0,
        );

        final element = ElementWidget(table);
        element.layout(BoxConstraints.tight(const Size(22, 6)));
        element.paint(buffer, Offset.zero);

        expect(buffer, matchesAnsiGolden('test/goldens/wide_emoji_table.ansi'));
      },
    );
  });
}
