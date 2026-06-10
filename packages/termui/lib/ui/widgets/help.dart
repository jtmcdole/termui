import 'package:characters/characters.dart';
import '../buffer.dart';
import '../style.dart';
import '../layout.dart';

/// A widget that formats and displays keybindings, auto-wrapping them to fit.
///
/// It aligns a dictionary of key-to-description bindings horizontally. If
/// the bindings exceed the available width, it wraps them down to subsequent
/// lines within the layout's constraints.
///
/// ### Example Usage
///
/// ```dart
/// Help(
///   bindings: const {
///     'Ctrl+Q': 'Quit',
///     'Tab': 'Next Field',
///     'Enter': 'Submit',
///   },
///   separator: ' | ',
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `bindings` | [Map]<[String], [String]> | Key-value pairs of keybind names and description. |
/// | `keyStyle` | [Style] | Style applied to key labels (defaults to bold). |
/// | `descStyle` | [Style] | Style applied to description labels (defaults to dim). |
/// | `separatorStyle` | [Style] | Style applied to the separator between bindings. |
/// | `separator` | [String] | Separator character or string. Defaults to ` • `. |
class Help extends Widget {
  /// A dictionary mapping key bindings to their descriptions.
  final Map<String, String> bindings;

  /// The style applied to the key bindings text.
  final Style keyStyle;

  /// The style applied to the descriptions text.
  final Style descStyle;

  /// The style applied to the separator text.
  final Style separatorStyle;

  /// The string used to separate key bindings.
  final String separator;

  /// Creates a [Help] widget to display a horizontal list of key bindings.
  const Help({
    required this.bindings,
    this.keyStyle = const Style(modifiers: Modifier.bold),
    this.descStyle = const Style(modifiers: Modifier.dim),
    this.separatorStyle = const Style(modifiers: Modifier.dim),
    this.separator = ' • ',
  });

  @override
  void render(Buffer buffer, Rect area) {
    if (bindings.isEmpty || area.width <= 0 || area.height <= 0) return;

    final items = <_HelpItem>[];
    for (final entry in bindings.entries) {
      items.add(_HelpItem(entry.key, entry.value));
    }

    var currentLineY = 0;
    var currentLineX = 0;

    final separatorChars = separator.characters;

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final keyPart = item.key;
      final keyPartChars = keyPart.characters;
      final descPart = item.desc;
      final descPartChars = descPart.characters;
      final isLast = i == items.length - 1;

      // Calculate the length of "key desc" + separator (if not last)
      final itemLength = keyPartChars.length + 1 + descPartChars.length;

      // Wrap to next line if it doesn't fit on the current line
      if (currentLineX + itemLength > area.width && currentLineX > 0) {
        currentLineY++;
        currentLineX = 0;
      }

      if (currentLineY >= area.height) break;

      // Render key
      buffer.writeString(currentLineX, currentLineY, keyPart, keyStyle);
      currentLineX += keyPartChars.length;

      // Render space
      buffer.writeString(currentLineX, currentLineY, ' ', Style.empty);
      currentLineX += 1;

      // Render description
      buffer.writeString(currentLineX, currentLineY, descPart, descStyle);
      currentLineX += descPartChars.length;

      // Render separator
      if (!isLast) {
        if (currentLineX + separatorChars.length <= area.width) {
          buffer.writeString(
            currentLineX,
            currentLineY,
            separator,
            separatorStyle,
          );
          currentLineX += separatorChars.length;
        } else {
          currentLineY++;
          currentLineX = 0;
        }
      }
    }
  }
}

class _HelpItem {
  final String key;
  final String desc;
  const _HelpItem(this.key, this.desc);
}
