import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// An example showcasing data display widgets like Tables and Paginators.
class DataDisplaysExample extends WidgetBookExample {
  /// The table widget used to display task data.
  final table = Table(
    headers: const ['ID', 'Task Name', 'Status'],
    rows: const [
      ['1', 'Extract Widgets', 'Done'],
      ['2', 'Create Padding', 'Done'],
      ['3', 'Add Table/Help', 'Done'],
      ['4', 'Add Inline Mode', 'Done'],
      ['5', 'Write Tests', 'Done'],
    ],
    columnWidths: const [4, 18, 8],
    selectedRowIndex: 0,
    selectedRowStyle: const Style(
      foreground: CharmColors.pepper,
      background: CharmColors.charple,
    ),
  );

  /// The current active page index in the paginator widget.
  int paginatorPage = 0;

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return Column([
      Expanded(child: table),
      SizedBox(
        height: 1,
        child: Row([
          const SizedBox(width: 11, child: Text('Paginator: ')),
          Expanded(
            child: Paginator(
              totalPages: 5,
              currentPage: paginatorPage,
              activeStyle: const Style(
                foreground: CharmColors.charple,
                modifiers: Modifier.bold,
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.type == ui.KeyType.up) {
      table.selectedRowIndex = (table.selectedRowIndex - 1).clamp(
        0,
        table.rows.length - 1,
      );
      return true;
    } else if (event.type == ui.KeyType.down) {
      table.selectedRowIndex = (table.selectedRowIndex + 1).clamp(
        0,
        table.rows.length - 1,
      );
      return true;
    } else if (event.type == ui.KeyType.left) {
      paginatorPage = (paginatorPage - 1).clamp(0, 4);
      return true;
    } else if (event.type == ui.KeyType.right) {
      paginatorPage = (paginatorPage + 1).clamp(0, 4);
      return true;
    }
    return false;
  }

  @override
  Map<String, String> get helpBindings => {
    'Up/Down': 'Select row',
    'Left/Right': 'Page dots',
  };
}
