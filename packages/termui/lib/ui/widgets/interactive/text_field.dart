import 'dart:async';
import 'dart:math';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/event.dart' as ev;

/// Actions supported by the [TextField] widget.
enum TextFieldAction {
  /// Move cursor left.
  moveLeft,

  /// Move cursor right.
  moveRight,

  /// Move cursor up.
  moveUp,

  /// Move cursor down.
  moveDown,

  /// Move cursor one word to the left.
  moveWordLeft,

  /// Move cursor one word to the right.
  moveWordRight,

  /// Move cursor to the start of the line.
  moveToLineStart,

  /// Move cursor to the end of the line.
  moveToLineEnd,

  /// Delete character to the left.
  deleteLeft,

  /// Delete character to the right.
  deleteRight,

  /// Delete word to the left.
  deleteWordLeft,

  /// Delete word to the right.
  deleteWordRight,

  /// Delete to the start of the line.
  deleteToLineStart,

  /// Delete to the end of the line.
  deleteToLineEnd,

  /// Undo last change.
  undo,

  /// Redo last undone change.
  redo,
}

/// A keyboard shortcut representation for assigning to [TextFieldAction]s.
class TextFieldShortcut {
  /// The key type.
  final KeyType? type;

  /// The character key.
  final String? key;

  /// Required modifiers.
  final Set<ev.Modifier> modifiers;

  /// Creates a [TextFieldShortcut].
  const TextFieldShortcut({
    this.type,
    this.key,
    this.modifiers = const <ev.Modifier>{},
  });

  /// Returns true if this shortcut matches the given [KeyEvent].
  bool matches(KeyEvent event) {
    if (type != null && event.type != type) return false;
    if (key != null && event.key.toLowerCase() != key!.toLowerCase()) {
      return false;
    }
    if (event.modifiers.length != modifiers.length) return false;
    return event.modifiers.containsAll(modifiers);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TextFieldShortcut &&
        other.type == type &&
        other.key == key &&
        _setEquals(other.modifiers, modifiers);
  }

  @override
  int get hashCode => Object.hash(type, key, Object.hashAll(modifiers));

  bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
}

/// Represents the visual cursor selection offset in terminal cells.
class TextSelection {
  /// Base offset.
  final int baseOffset;

  /// Extent offset.
  final int extentOffset;

  /// Line index.
  final int cursorLine;

  /// Column index.
  final int cursorColumn;

  /// Creates a [TextSelection].
  const TextSelection({
    required this.baseOffset,
    required this.extentOffset,
    this.cursorLine = 0,
    this.cursorColumn = 0,
  });

  /// Creates a collapsed [TextSelection] at the given offset.
  const TextSelection.collapsed({
    required int offset,
    int line = 0,
    int column = 0,
  }) : baseOffset = offset,
       extentOffset = offset,
       cursorLine = line,
       cursorColumn = column;

  /// Whether the selection is collapsed.
  bool get isCollapsed => baseOffset == extentOffset;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextSelection &&
          other.baseOffset == baseOffset &&
          other.extentOffset == extentOffset &&
          other.cursorLine == cursorLine &&
          other.cursorColumn == cursorColumn;

  @override
  int get hashCode =>
      Object.hash(baseOffset, extentOffset, cursorLine, cursorColumn);
}

/// Holds the configuration state of a TextField value.
class TextEditingValue {
  /// The text content.
  final String text;

  /// The current text selection state.
  final TextSelection selection;

  /// Creates a [TextEditingValue].
  const TextEditingValue({
    this.text = '',
    this.selection = const TextSelection.collapsed(offset: 0),
  });

  /// Text split into separate lines.
  List<String> get lines => text.split('\n');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextEditingValue &&
          other.text == text &&
          other.selection == selection;

  @override
  int get hashCode => Object.hash(text, selection);
}

/// A controller that notifies listeners when editing value changes.
class TextEditingController {
  TextEditingValue _value;
  final List<void Function()> _listeners = [];
  final List<TextEditingValue> _undoStack = [];
  final List<TextEditingValue> _redoStack = [];

  /// Creates a [TextEditingController].
  TextEditingController({String? text})
    : _value = TextEditingValue(
        text: text ?? '',
        selection: TextSelection.collapsed(
          offset: (text ?? '').characters.length,
          line: (text ?? '').split('\n').length - 1,
          column: (text ?? '').split('\n').last.characters.length,
        ),
      );

  /// Gets the current editing value.
  TextEditingValue get value => _value;

  /// Sets the editing value.
  set value(TextEditingValue newValue) {
    if (_value != newValue) {
      _value = newValue;
      _notify();
    }
  }

  /// Gets the current text string.
  String get text => _value.text;

  /// Sets the current text string.
  set text(String newText) {
    final lines = newText.split('\n');
    value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: newText.characters.length,
        line: lines.length - 1,
        column: lines.last.characters.length,
      ),
    );
  }

  /// Adds a listener.
  void addListener(void Function() listener) => _listeners.add(listener);

  /// Removes a listener.
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  /// Pushes current state to undo history.
  void saveStateToHistory() {
    _undoStack.add(_value);
    if (_undoStack.length > 100) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  /// Undoes the last change.
  void undo() {
    if (_undoStack.isNotEmpty) {
      _redoStack.add(_value);
      value = _undoStack.removeLast();
    }
  }

  /// Redoes the last undone change.
  void redo() {
    if (_redoStack.isNotEmpty) {
      _undoStack.add(_value);
      value = _redoStack.removeLast();
    }
  }

  /// Clears the text.
  void clear() {
    value = const TextEditingValue();
  }
}

/// An interactive single-line or multi-line text input field.
///
/// It coordinates keyboard inputs to mutate text values, maintains cursor state
/// and scroll offsets, and supports undo/redo history.
///
/// ### Keyboard Hotkey Reference Table
///
/// | Keyboard Shortcut | Action | Description |
/// | :--- | :--- | :--- |
/// | `Ctrl + W` | `deleteWordLeft` | Delete the word behind the cursor. |
/// | `Ctrl + D` / `Ctrl + Del` | `deleteWordRight`| Delete the word in front of the cursor. |
/// | `Ctrl + Z` / `Alt + Z` | `undo` | Revert the last text mutation. |
/// | `Ctrl + Y` / `Alt + Y` | `redo` | Reapply a previously reverted mutation. |
/// | `Ctrl + Left` | `moveWordLeft` | Move cursor one word backward. |
/// | `Ctrl + Right` | `moveWordRight` | Move cursor one word forward. |
/// | `Home` / `Ctrl + Shift + Left` | `moveToLineStart`| Move cursor to the beginning of the line. |
/// | `End` / `Ctrl + Shift + Right` | `moveToLineEnd` | Move cursor to the end of the line. |
///
/// ### Example Usage
///
/// ```dart
/// final controller = TextEditingController(text: 'Edit me');
/// TextField(
///   controller: controller,
///   multiline: false,
///   placeholder: 'Type here...',
///   focused: true,
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `controller` | [TextEditingController] | Holds the text value and selection state. |
/// | `multiline` | [bool] | Enable multi-line input and wraps lines. |
/// | `style` | [Style] | Formatting attributes for the input text. |
/// | `cursorStyle` | [Style] | Highlighting style for the cursor cell. |
/// | `placeholder` | [String] | Ghost hint text displayed when field is empty. |
/// | `placeholderStyle`| [Style] | Style of the placeholder hint text. |
/// | `obscureText` | [bool] | Masks text characters for passwords/secrets. |
/// | `obscuringCharacter` | [String] | Single grapheme character used for masking. |
/// | `focused` | [bool] | Determines if cursor is drawn and keys are processed. |
/// | `customShortcuts` | [Map]? | Custom key mappings for input actions. |
class TextField extends StatefulWidget implements Focusable {
  /// The text editing controller.
  final TextEditingController controller;

  /// Whether the field supports multiple lines.
  final bool multiline;

  /// Whether to obscure text input (e.g. for passwords).
  final bool obscureText;

  /// Single grapheme cluster character used to obscure text.
  final String obscuringCharacter;

  /// Formatting attributes for the input text.
  Style style;

  /// Highlighting style for the cursor cell.
  Style cursorStyle;

  /// Style of the placeholder hint text.
  Style placeholderStyle;

  /// Ghost hint text displayed when field is empty.
  final String placeholder;

  /// Determines if cursor is drawn and keys are processed.
  @override
  bool focused;

  /// Custom key mappings for input actions.
  final Map<TextFieldShortcut, TextFieldAction>? customShortcuts;

  /// Optional custom FocusNode to manage this text field's focus.
  final FocusNode? focusNode;

  /// Optional callback executed when focus status transitions.
  final void Function(bool hasFocus)? onFocusChange;

  /// Vertical scroll offset.
  int scrollOffset = 0;

  /// Creates a [TextField].
  TextField({
    super.key,
    String initialText = '',
    String? value,
    int? cursorPosition,
    TextEditingController? controller,
    this.multiline = false,
    this.obscureText = false,
    this.obscuringCharacter = '*',
    this.style = Style.empty,
    this.cursorStyle = const Style(modifiers: Modifier.underline),
    this.placeholder = '',
    this.placeholderStyle = const Style(foreground: Color(128, 128, 128)),
    this.focused = true,
    this.customShortcuts,
    this.focusNode,
    this.onFocusChange,
  }) : controller =
           controller ?? TextEditingController(text: value ?? initialText) {
    if (obscureText && multiline) {
      throw ArgumentError(
        'obscureText cannot be enabled on a multiline TextField.',
      );
    }
    _validateObscuredText(this.controller.text);
    if (obscuringCharacter.characters.length != 1) {
      throw ArgumentError(
        'obscuringCharacter must be a single grapheme cluster.',
      );
    }
    if (obscuringCharacter.contains('\n') ||
        obscuringCharacter.contains('\r')) {
      throw ArgumentError(
        'obscuringCharacter cannot be a newline or carriage return.',
      );
    }
    if (graphemeWidth(obscuringCharacter) != 1) {
      throw ArgumentError(
        'obscuringCharacter must have a terminal column display width of exactly 1.',
      );
    }
    if (cursorPosition != null && controller == null) {
      final text = value ?? initialText;
      final clampedPos = cursorPosition.clamp(0, text.characters.length);
      this.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: clampedPos,
          column: clampedPos,
        ),
      );
    }
  }

  /// The default key bindings mapping shortcuts to actions.
  static final Map<TextFieldShortcut, TextFieldAction> defaultShortcuts = {
    // Navigation
    const TextFieldShortcut(type: KeyType.left): TextFieldAction.moveLeft,
    const TextFieldShortcut(type: KeyType.right): TextFieldAction.moveRight,
    const TextFieldShortcut(type: KeyType.up): TextFieldAction.moveUp,
    const TextFieldShortcut(type: KeyType.down): TextFieldAction.moveDown,
    const TextFieldShortcut(
      type: KeyType.left,
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.moveWordLeft,
    const TextFieldShortcut(
      type: KeyType.right,
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.moveWordRight,
    const TextFieldShortcut(
      type: KeyType.left,
      modifiers: {ev.Modifier.control, ev.Modifier.shift},
    ): TextFieldAction.moveToLineStart,
    const TextFieldShortcut(
      type: KeyType.right,
      modifiers: {ev.Modifier.control, ev.Modifier.shift},
    ): TextFieldAction.moveToLineEnd,
    const TextFieldShortcut(type: KeyType.home):
        TextFieldAction.moveToLineStart,
    const TextFieldShortcut(type: KeyType.end): TextFieldAction.moveToLineEnd,

    // Deletion
    const TextFieldShortcut(type: KeyType.backspace):
        TextFieldAction.deleteLeft,
    const TextFieldShortcut(type: KeyType.delete): TextFieldAction.deleteRight,
    const TextFieldShortcut(
      type: KeyType.character,
      key: 'w',
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.deleteWordLeft,
    const TextFieldShortcut(
      type: KeyType.character,
      key: 'd',
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.deleteWordRight,
    const TextFieldShortcut(
      type: KeyType.delete,
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.deleteWordRight,
    const TextFieldShortcut(
      type: KeyType.backspace,
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.deleteToLineStart,
    const TextFieldShortcut(
      type: KeyType.character,
      key: 'k',
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.deleteToLineEnd,

    // Undo / Redo
    const TextFieldShortcut(
      type: KeyType.character,
      key: 'z',
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.undo,
    const TextFieldShortcut(
      type: KeyType.character,
      key: 'z',
      modifiers: {ev.Modifier.alt},
    ): TextFieldAction.undo,
    const TextFieldShortcut(
      type: KeyType.character,
      key: 'y',
      modifiers: {ev.Modifier.control},
    ): TextFieldAction.redo,
    const TextFieldShortcut(
      type: KeyType.character,
      key: 'y',
      modifiers: {ev.Modifier.alt},
    ): TextFieldAction.redo,
  };

  /// Gets the complete value of the text field.
  String get value => controller.text;

  /// Sets the complete value of the text field.
  set value(String text) {
    _validateObscuredText(text);
    controller.text = text;
  }

  void _validateObscuredText(String text) {
    if (obscureText && (text.contains('\n') || text.contains('\r'))) {
      throw ArgumentError(
        'obscureText TextField cannot contain newline or carriage return characters.',
      );
    }
  }

  /// Gets the cursor column.
  int get cursorPosition => cursorColumn;

  /// Sets the cursor column.
  set cursorPosition(int val) => cursorColumn = val;

  /// Gets the cursor column.
  int get cursorColumn => controller.value.selection.cursorColumn;

  /// Sets the cursor column.
  set cursorColumn(int val) {
    final text = controller.value.text;
    final lines = controller.value.lines;
    final currentLine = cursorLine.clamp(0, lines.length - 1);
    final clampedCol = val.clamp(0, lines[currentLine].characters.length);
    final nextOffset = _getOffsetFromLineColumn(text, currentLine, clampedCol);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: nextOffset,
        extentOffset: nextOffset,
        cursorLine: currentLine,
        cursorColumn: clampedCol,
      ),
    );
  }

  /// Gets the cursor line.
  int get cursorLine => controller.value.selection.cursorLine;

  /// Sets the cursor line.
  set cursorLine(int val) {
    final text = controller.value.text;
    final lines = controller.value.lines;
    final nextLine = val.clamp(0, lines.length - 1);
    final clampedCol = cursorColumn.clamp(0, lines[nextLine].characters.length);
    final nextOffset = _getOffsetFromLineColumn(text, nextLine, clampedCol);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: nextOffset,
        extentOffset: nextOffset,
        cursorLine: nextLine,
        cursorColumn: clampedCol,
      ),
    );
  }

  int _findWordBoundaryBackward(String line, int colIdx) {
    if (obscureText) return 0;
    final charsList = line.characters.toList();
    int i = colIdx - 1;
    while (i >= 0 && charsList[i] == ' ') {
      i--;
    }
    while (i >= 0 && charsList[i] != ' ') {
      i--;
    }
    return i + 1;
  }

  int _findWordBoundaryForward(String line, int colIdx) {
    if (obscureText) return line.characters.length;
    final charsList = line.characters.toList();
    int i = colIdx;
    while (i < charsList.length && charsList[i] == ' ') {
      i++;
    }
    while (i < charsList.length && charsList[i] != ' ') {
      i++;
    }
    return i;
  }

  int _getOffsetFromLineColumn(String text, int line, int column) {
    final lines = text.split('\n');
    if (line < 0) return 0;
    if (line >= lines.length) return text.characters.length;
    var offset = 0;
    for (var i = 0; i < line; i++) {
      offset += lines[i].characters.length + 1;
    }
    return offset + column;
  }

  TextFieldAction? _matchShortcutAction(KeyEvent event) {
    final shortcuts = customShortcuts ?? defaultShortcuts;
    for (final entry in shortcuts.entries) {
      if (entry.key.matches(event)) return entry.value;
    }
    return null;
  }

  bool _canExecuteVerticalMove(TextFieldAction action) {
    if (action == TextFieldAction.moveUp) {
      return multiline && cursorLine > 0;
    }
    if (action == TextFieldAction.moveDown) {
      return multiline && cursorLine < controller.value.lines.length - 1;
    }
    return true;
  }

  void _insertNewline() {
    controller.saveStateToHistory();
    final lines = [...controller.value.lines];
    final lineIdx = cursorLine;
    final colIdx = cursorColumn;
    final current = lines[lineIdx].characters;
    final prefix = current.take(colIdx).string;
    final suffix = current.skip(colIdx).string;
    lines[lineIdx] = prefix;
    lines.insert(lineIdx + 1, suffix);

    final nextLine = lineIdx + 1;
    const nextCol = 0;
    final nextText = lines.join('\n');
    final nextOffset = _getOffsetFromLineColumn(nextText, nextLine, nextCol);

    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection(
        baseOffset: nextOffset,
        extentOffset: nextOffset,
        cursorLine: nextLine,
        cursorColumn: nextCol,
      ),
    );
  }

  void _insertCharacterKey(String key) {
    if (key == '\n' || key == '\r' || key == '\r\n') {
      if (multiline) _insertNewline();
      return;
    }
    final sanitized = multiline
        ? key
        : key.replaceAll('\r', '').replaceAll('\n', '');
    if (sanitized.isEmpty) return;

    controller.saveStateToHistory();
    final lines = [...controller.value.lines];
    final lineIdx = cursorLine;
    final colIdx = cursorColumn;
    final current = lines[lineIdx].characters;
    lines[lineIdx] =
        '${current.take(colIdx).string}$sanitized${current.skip(colIdx).string}';

    final nextCol = colIdx + sanitized.characters.length;
    final nextText = lines.join('\n');
    final nextOffset = _getOffsetFromLineColumn(nextText, lineIdx, nextCol);

    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection(
        baseOffset: nextOffset,
        extentOffset: nextOffset,
        cursorLine: lineIdx,
        cursorColumn: nextCol,
      ),
    );
  }

  /// Handles key events to update the text area value and cursor position.
  bool handleKeyEvent(KeyEvent event) {
    if (event.type == KeyType.tab) return false;

    if (_matchShortcutAction(event) case final action?) {
      if (!_canExecuteVerticalMove(action)) return false;
      _executeAction(action);
      return true;
    }

    if (event.type == KeyType.enter) {
      if (!multiline) return false;
      _insertNewline();
      return true;
    }

    final hasControlOrAltOrMeta =
        event.modifiers.contains(ev.Modifier.control) ||
        event.modifiers.contains(ev.Modifier.alt) ||
        event.modifiers.contains(ev.Modifier.meta);
    if (event.type != KeyType.character || hasControlOrAltOrMeta) {
      return false;
    }

    _insertCharacterKey(event.key);
    return true;
  }

  void _executeAction(TextFieldAction action) {
    final lines = List<String>.from(controller.value.lines);
    var lineIdx = cursorLine;
    var colIdx = cursorColumn;
    final chars = lines[lineIdx].characters;

    switch (action) {
      case TextFieldAction.moveLeft:
        if (colIdx > 0) {
          colIdx--;
        } else if (lineIdx > 0 && multiline) {
          lineIdx--;
          colIdx = lines[lineIdx].characters.length;
        }
        break;

      case TextFieldAction.moveRight:
        if (colIdx < chars.length) {
          colIdx++;
        } else if (lineIdx < lines.length - 1 && multiline) {
          lineIdx++;
          colIdx = 0;
        }
        break;

      case TextFieldAction.moveUp:
        if (lineIdx > 0 && multiline) {
          lineIdx--;
          colIdx = min(colIdx, lines[lineIdx].characters.length);
        }
        break;

      case TextFieldAction.moveDown:
        if (lineIdx < lines.length - 1 && multiline) {
          lineIdx++;
          colIdx = min(colIdx, lines[lineIdx].characters.length);
        }
        break;

      case TextFieldAction.moveWordLeft:
        if (colIdx > 0) {
          colIdx = _findWordBoundaryBackward(lines[lineIdx], colIdx);
        } else if (lineIdx > 0 && multiline) {
          lineIdx--;
          colIdx = lines[lineIdx].characters.length;
        }
        break;

      case TextFieldAction.moveWordRight:
        if (colIdx < chars.length) {
          colIdx = _findWordBoundaryForward(lines[lineIdx], colIdx);
        } else if (lineIdx < lines.length - 1 && multiline) {
          lineIdx++;
          colIdx = 0;
        }
        break;

      case TextFieldAction.moveToLineStart:
        colIdx = 0;
        break;

      case TextFieldAction.moveToLineEnd:
        colIdx = chars.length;
        break;

      case TextFieldAction.deleteLeft:
        if (colIdx > 0) {
          controller.saveStateToHistory();
          lines[lineIdx] =
              '${chars.take(colIdx - 1).string}${chars.skip(colIdx).string}';
          colIdx--;
        } else if (lineIdx > 0 && multiline) {
          controller.saveStateToHistory();
          final prevLine = lines[lineIdx - 1];
          final currentLine = lines[lineIdx];
          lines[lineIdx - 1] = prevLine + currentLine;
          colIdx = prevLine.characters.length;
          lines.removeAt(lineIdx);
          lineIdx--;
        }
        break;

      case TextFieldAction.deleteRight:
        if (colIdx < chars.length) {
          controller.saveStateToHistory();
          lines[lineIdx] =
              '${chars.take(colIdx).string}${chars.skip(colIdx + 1).string}';
        } else if (lineIdx < lines.length - 1 && multiline) {
          controller.saveStateToHistory();
          final currentLine = lines[lineIdx];
          final nextLine = lines[lineIdx + 1];
          lines[lineIdx] = currentLine + nextLine;
          lines.removeAt(lineIdx + 1);
        }
        break;

      case TextFieldAction.deleteWordLeft:
        if (colIdx > 0) {
          final start = _findWordBoundaryBackward(lines[lineIdx], colIdx);
          if (start < colIdx) {
            controller.saveStateToHistory();
            lines[lineIdx] =
                '${chars.take(start).string}${chars.skip(colIdx).string}';
            colIdx = start;
          }
        } else if (lineIdx > 0 && multiline) {
          controller.saveStateToHistory();
          final prevLine = lines[lineIdx - 1];
          final currentLine = lines[lineIdx];
          lines[lineIdx - 1] = prevLine + currentLine;
          colIdx = prevLine.characters.length;
          lines.removeAt(lineIdx);
          lineIdx--;
        }
        break;

      case TextFieldAction.deleteWordRight:
        if (colIdx < chars.length) {
          final end = _findWordBoundaryForward(lines[lineIdx], colIdx);
          if (end > colIdx) {
            controller.saveStateToHistory();
            final prefix = chars.take(colIdx).toString();
            final suffix = chars.skip(end).toString();
            lines[lineIdx] = prefix + suffix;
          }
        } else if (lineIdx < lines.length - 1 && multiline) {
          controller.saveStateToHistory();
          final currentLine = lines[lineIdx];
          final nextLine = lines[lineIdx + 1];
          lines[lineIdx] = currentLine + nextLine;
          lines.removeAt(lineIdx + 1);
        }
        break;

      case TextFieldAction.deleteToLineStart:
        if (colIdx > 0) {
          controller.saveStateToHistory();
          lines[lineIdx] = chars.skip(colIdx).toString();
          colIdx = 0;
        }
        break;

      case TextFieldAction.deleteToLineEnd:
        if (colIdx < chars.length) {
          controller.saveStateToHistory();
          lines[lineIdx] = chars.take(colIdx).toString();
        } else if (lineIdx < lines.length - 1 && multiline) {
          controller.saveStateToHistory();
          final currentLine = lines[lineIdx];
          final nextLine = lines[lineIdx + 1];
          lines[lineIdx] = currentLine + nextLine;
          lines.removeAt(lineIdx + 1);
        }
        break;

      case TextFieldAction.undo:
        controller.undo();
        return;

      case TextFieldAction.redo:
        controller.redo();
        return;
    }

    final nextText = lines.join('\n');
    final nextOffset = _getOffsetFromLineColumn(nextText, lineIdx, colIdx);
    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection(
        baseOffset: nextOffset,
        extentOffset: nextOffset,
        cursorLine: lineIdx,
        cursorColumn: colIdx,
      ),
    );
  }

  /// Adjusts the scroll offset based on the viewport height.
  void adjustScroll(int viewportHeight) {
    final lines = controller.value.lines;
    if (lines.isEmpty || viewportHeight <= 0) return;
    final currentCursorLine = cursorLine.clamp(0, lines.length - 1);
    if (currentCursorLine < scrollOffset) {
      scrollOffset = currentCursorLine;
    } else if (currentCursorLine >= scrollOffset + viewportHeight) {
      scrollOffset = currentCursorLine - viewportHeight + 1;
    }
  }

  @override
  State createState() => TextFieldState();

  @override
  int getIntrinsicHeight(int width) {
    if (!multiline) return 1;
    final lines = value.split('\n');
    return max(1, lines.length);
  }
}

/// The state for a [TextField] widget.
class TextFieldState extends State<TextField> implements KeyEventHandler {
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return widget.handleKeyEvent(event);
  }

  TextEditingController? _listenedController;
  late FocusNode _focusNode;

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _updateListener() {
    if (_listenedController != widget.controller) {
      _listenedController?.removeListener(_onControllerChanged);
      _listenedController = widget.controller;
      _listenedController?.addListener(_onControllerChanged);
    }
  }

  @override
  void initState() {
    super.initState();
    _focusNode =
        widget.focusNode ?? FocusNode(id: 'textfield_${widget.hashCode}');
    _updateListener();
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(TextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateListener();
    if (widget.focusNode != oldWidget.focusNode) {
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode =
          widget.focusNode ?? FocusNode(id: 'textfield_${widget.hashCode}');
    }
    if (widget.focused != oldWidget.focused) {
      if (widget.focused) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    _listenedController?.removeListener(_onControllerChanged);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _updateListener();
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        widget.focused = hasFocus;
        widget.onFocusChange?.call(hasFocus);
        if (mounted) {
          setState(() {}); // Redraw cursor highlight
        }
      },
      onKeyEvent: (event) {
        return widget.handleKeyEvent(event);
      },
      child: _TextFieldRenderWidget(widget),
    );
  }
}

class _TextFieldRenderWidget extends Widget {
  /// The parent TextField widget configuration.
  final TextField textFieldWidget;

  /// Creates a render proxy for a TextField.
  const _TextFieldRenderWidget(this.textFieldWidget);

  @override
  Element createElement() => _TextFieldRenderWidgetElement(this);
}

/// Element that performs layout and paint for [_TextFieldRenderWidget].
class _TextFieldRenderWidgetElement extends Element {
  /// Instantiates the rendering element for the given [_TextFieldRenderWidget].
  _TextFieldRenderWidgetElement(_TextFieldRenderWidget super.widget);

  Style? _cachedMergedStyle;
  TextField? _cachedTextField;

  Style _getMergedStyle(TextField textField) {
    if (_cachedTextField != textField) {
      _cachedMergedStyle = textField.style.merge(textField.cursorStyle);
      _cachedTextField = textField;
    }
    return _cachedMergedStyle!;
  }

  @override
  Map<String, String>? get paintTraceMetadata {
    final renderWidget = widget as _TextFieldRenderWidget;
    final textField = renderWidget.textFieldWidget;
    if (textField.obscureText) {
      return null;
    }
    return {'length': '${textField.value.characters.length}'};
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final renderWidget = widget as _TextFieldRenderWidget;
    final textField = renderWidget.textFieldWidget;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : textField.controller.value.lines.length;

    textField.adjustScroll(height);

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final renderWidget = widget as _TextFieldRenderWidget;
    final textField = renderWidget.textFieldWidget;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    if (textField.value.isEmpty && textField.placeholder.isNotEmpty) {
      buffer.writeString(
        offset.dx,
        offset.dy,
        textField.placeholder,
        textField.placeholderStyle,
      );
      if (textField.focused) {
        buffer.setAttributes(
          offset.dx,
          offset.dy,
          fg: textField.cursorStyle.foreground?.argb ?? 0,
          bg: textField.cursorStyle.background?.argb ?? 0,
          modifiers: textField.cursorStyle.modifiers,
        );
      }
      return;
    }

    final lines = textField.controller.value.lines;
    final cursorLine = textField.cursorLine;
    final mergedCursorStyle = textField.focused
        ? _getMergedStyle(textField)
        : textField.style;

    for (var y = 0; y < h; y++) {
      final lineIdx = textField.scrollOffset + y;
      if (lineIdx >= lines.length) break;
      _paintLine(
        buffer,
        Offset(offset.dx, offset.dy + y),
        w,
        lines[lineIdx],
        textField,
        mergedCursorStyle,
        isCursorLine: textField.focused && lineIdx == cursorLine,
      );
    }
  }

  void _paintLine(
    Buffer buffer,
    Offset rowOffset,
    int width,
    String line,
    TextField textField,
    Style mergedCursorStyle, {
    required bool isCursorLine,
  }) {
    final charIter = line.characters.iterator;
    var lineLen = 0;

    for (var x = 0; x < width; x++) {
      var char = ' ';
      if (charIter.moveNext()) {
        lineLen++;
        char = textField.obscureText
            ? textField.obscuringCharacter
            : charIter.current;
      }

      final isCursor = isCursorLine && x == textField.cursorColumn;
      final cellStyle = isCursor ? mergedCursorStyle : textField.style;
      buffer.setAttributes(
        rowOffset.dx + x,
        rowOffset.dy,
        char: char,
        fg: cellStyle.foreground?.argb ?? 0,
        bg: cellStyle.background?.argb ?? 0,
        modifiers: cellStyle.modifiers,
      );
    }

    // Render cursor at end of line if needed
    if (isCursorLine && textField.cursorColumn >= lineLen && lineLen < width) {
      buffer.setAttributes(
        rowOffset.dx + lineLen,
        rowOffset.dy,
        fg: mergedCursorStyle.foreground?.argb ?? 0,
        bg: mergedCursorStyle.background?.argb ?? 0,
        modifiers: mergedCursorStyle.modifiers,
      );
    }
  }
}
