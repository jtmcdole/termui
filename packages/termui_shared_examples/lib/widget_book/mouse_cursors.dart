import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/terminal/terminal.dart' as core;
import 'example_base.dart';

/// An interactive grid that displays available OSC 22 mouse pointers.
/// Hovering over different cells sets the terminal mouse cursor shape accordingly.
class MouseCursorsExample extends WidgetBookExample {
  int? _hoveredIndex;

  static const List<core.MousePointer> _pointers = [
    core.MousePointer.defaultCursor,
    core.MousePointer.text,
    core.MousePointer.pointer,
    core.MousePointer.crosshair,
    core.MousePointer.help,
    core.MousePointer.progress,
    core.MousePointer.wait,
    core.MousePointer.move,
    core.MousePointer.notAllowed,
    core.MousePointer.grab,
    core.MousePointer.grabbing,
    core.MousePointer.none,
    core.MousePointer.alias,
    core.MousePointer.copy,
    core.MousePointer.cell,
    core.MousePointer.noDrop,
    core.MousePointer.zoomIn,
    core.MousePointer.zoomOut,
    core.MousePointer.resizeUpDown,
    core.MousePointer.resizeLeftRight,
    core.MousePointer.allScroll,
  ];

  static const Map<core.MousePointer, String> _pointerDescriptions = {
    core.MousePointer.defaultCursor: 'Default Arrow',
    core.MousePointer.text: 'I-Beam (Text Selection)',
    core.MousePointer.pointer: 'Pointing Hand (Link)',
    core.MousePointer.crosshair: 'Crosshair (Precision)',
    core.MousePointer.help: 'Question Mark (Help)',
    core.MousePointer.progress: 'Bg Progress Indicator',
    core.MousePointer.wait: 'Hourglass / Wait Spinner',
    core.MousePointer.move: 'Four-Way Move Cursor',
    core.MousePointer.notAllowed: 'Forbidden Action',
    core.MousePointer.grab: 'Open Hand (Grab)',
    core.MousePointer.grabbing: 'Closed Fist (Grabbing)',
    core.MousePointer.none: 'Hidden / No Cursor',
    core.MousePointer.alias: 'Link / Alias Shortcut',
    core.MousePointer.copy: 'Copy Element',
    core.MousePointer.cell: 'Cell Selection',
    core.MousePointer.noDrop: 'Forbidden Drop Target',
    core.MousePointer.zoomIn: 'Zoom In (+)',
    core.MousePointer.zoomOut: 'Zoom Out (-)',
    core.MousePointer.resizeUpDown: 'Vertical Resize',
    core.MousePointer.resizeLeftRight: 'Horizontal Resize',
    core.MousePointer.allScroll: 'All Scroll / Pan',
  };

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    // 3 columns, 7 rows grid (21 cells total)
    final colWidth = width ~/ 3;
    final rowHeight = height ~/ 7;
    if (colWidth == 0 || rowHeight == 0) return;

    if (localX < 0 || localY < 0 || localX >= width || localY >= height) {
      if (_hoveredIndex != null) {
        _hoveredIndex = null;
        terminal?.resetMousePointer();
      }
      return;
    }

    final col = localX ~/ colWidth;
    final row = localY ~/ rowHeight;

    if (col >= 0 && col < 3 && row >= 0 && row < 7) {
      final index = row * 3 + col;
      if (index >= 0 && index < _pointers.length) {
        if (_hoveredIndex != index) {
          _hoveredIndex = index;
          final pointer = _pointers[index];
          terminal?.setMousePointer(pointer);
        }
        return;
      }
    }

    // Reset area or outside valid pointers
    if (_hoveredIndex != null) {
      _hoveredIndex = null;
      terminal?.resetMousePointer();
    }
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    final rows = <Widget>[];

    for (var r = 0; r < 7; r++) {
      final rowChildren = <Widget>[];
      for (var c = 0; c < 3; c++) {
        final index = r * 3 + c;
        if (index < _pointers.length) {
          final pointer = _pointers[index];
          final isHovered = _hoveredIndex == index;

          rowChildren.add(
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.rounded,
                  backgroundStyle: Style(
                    background: isHovered
                        ? CharmColors.charple
                        : CharmColors.bbq,
                  ),
                ),
                child: Center(
                  child: Column([
                    Text(
                      ' [ ${pointer.value.toUpperCase()} ] ',
                      style: Style(
                        foreground: isHovered
                            ? CharmColors.salt
                            : CharmColors.dolly,
                        modifiers: Modifier.bold,
                      ),
                      wrap: false,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      ' ${_pointerDescriptions[pointer]} ',
                      style: Style(
                        foreground: isHovered
                            ? CharmColors.steam
                            : CharmColors.iron,
                        modifiers: Modifier.dim,
                      ),
                      wrap: false,
                    ),
                  ]),
                ),
              ),
            ),
          );
        } else {
          // Empty slot placeholder (acts as a reset cursor button or simple reset area)
          final isHovered = _hoveredIndex == index;
          rowChildren.add(
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.rounded,
                  backgroundStyle: Style(
                    background: isHovered
                        ? CharmColors.charple
                        : CharmColors.bbq,
                  ),
                ),
                child: Center(
                  child: Text(
                    ' [ RESET DEFAULT ] ',
                    style: Style(
                      foreground: isHovered
                          ? CharmColors.salt
                          : CharmColors.char,
                      modifiers: Modifier.dim,
                    ),
                  ),
                ),
              ),
            ),
          );
        }
      }
      rows.add(Expanded(child: Row(rowChildren)));
    }

    return Column(rows);
  }
}
