import 'dart:async';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:clock/clock.dart';
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

  /// Move cursor up by one viewport page.
  pageUp,

  /// Move cursor down by one viewport page.
  pageDown,

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

/// A controller that notifies listeners when editing value or scroll state changes.
class TextEditingController {
  TextEditingValue _value;
  final List<void Function()> _listeners = [];
  final List<TextEditingValue> _undoStack = [];
  final List<TextEditingValue> _redoStack = [];

  /// Duration within which consecutive single-grapheme typing insertions
  /// coalesce into one undo history entry.
  final Duration undoCoalesceWindow;

  int _scrollOffset = 0;
  int _horizontalScrollOffset = 0;
  bool _manualScroll = false;
  bool _manualHorizontalScroll = false;
  DateTime? _lastBurstEditAt;
  bool _inInsertBurst = false;

  /// Creates a [TextEditingController].
  TextEditingController({
    String? text,
    this.undoCoalesceWindow = const Duration(milliseconds: 500),
  }) : _value = TextEditingValue(
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
      _manualScroll = false;
      _manualHorizontalScroll = false;
      _notify();
    }
  }

  /// Gets the current vertical scroll offset (0-based top visible line).
  int get scrollOffset => _scrollOffset;

  /// Sets the vertical scroll offset, clamped to `>= 0`.
  set scrollOffset(int newOffset) {
    final clamped = newOffset < 0 ? 0 : newOffset;
    _manualScroll = true;
    if (_scrollOffset != clamped) {
      _scrollOffset = clamped;
      _notify();
    }
  }

  /// Gets the current horizontal scroll offset (0-based leftmost visible column).
  int get horizontalScrollOffset => _horizontalScrollOffset;

  /// Sets the horizontal scroll offset, clamped to `>= 0`.
  set horizontalScrollOffset(int newOffset) {
    final clamped = newOffset < 0 ? 0 : newOffset;
    _manualHorizontalScroll = true;
    if (_horizontalScrollOffset != clamped) {
      _horizontalScrollOffset = clamped;
      _notify();
    }
  }

  void _setAutoScrollOffset(int newOffset) {
    final clamped = newOffset < 0 ? 0 : newOffset;
    if (_scrollOffset != clamped) {
      _scrollOffset = clamped;
      _notify();
    }
  }

  void _clampScrollOffset(int maxScroll) {
    final upper = maxScroll < 0 ? 0 : maxScroll;
    if (_scrollOffset > upper) {
      _scrollOffset = upper;
      _notify();
    }
  }

  void _setAutoHorizontalScrollOffset(int newOffset) {
    final clamped = newOffset < 0 ? 0 : newOffset;
    if (_horizontalScrollOffset != clamped) {
      _horizontalScrollOffset = clamped;
      _notify();
    }
  }

  /// Gets the current text string.
  String get text => _value.text;

  /// Sets the current text string.
  set text(String newText) {
    breakUndoBurst();
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

  /// Ends any active undo-coalescing typing burst so the next edit creates a
  /// distinct undo entry.
  void breakUndoBurst() {
    _inInsertBurst = false;
    _lastBurstEditAt = null;
  }

  /// Pushes current state to undo history.
  ///
  /// When [coalesce] is `true`, consecutive single-character typing edits
  /// occurring within [undoCoalesceWindow] share one undo entry until broken by
  /// a pause, newline, paste, deletion, cursor move, or an explicit
  /// `saveStateToHistory()` call.
  void saveStateToHistory({bool coalesce = false}) {
    final now = clock.now();
    if (coalesce &&
        _inInsertBurst &&
        _lastBurstEditAt != null &&
        now.difference(_lastBurstEditAt!) <= undoCoalesceWindow &&
        _undoStack.isNotEmpty) {
      _lastBurstEditAt = now;
      _redoStack.clear();
      return;
    }
    _undoStack.add(_value);
    if (_undoStack.length > 100) _undoStack.removeAt(0);
    _redoStack.clear();
    _inInsertBurst = coalesce;
    _lastBurstEditAt = coalesce ? now : null;
  }

  /// Inserts [inserted] at the current cursor position, normalizing `\r\n` and
  /// `\r` line endings.
  ///
  /// When [multiline] is `false`, line breaks in [inserted] are stripped.
  /// Always starts a dedicated undo step so multi-character pastes undo cleanly.
  void insertText(String inserted, {bool multiline = true}) {
    if (inserted.isEmpty) return;
    final normalized = inserted.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final effective = multiline ? normalized : normalized.replaceAll('\n', '');
    if (effective.isEmpty) return;

    saveStateToHistory();
    final lines = [..._value.lines];
    final lineIdx = _value.selection.cursorLine.clamp(0, lines.length - 1);
    final lineChars = lines[lineIdx].characters;
    final colIdx = _value.selection.cursorColumn.clamp(0, lineChars.length);
    final prefix = lineChars.take(colIdx).string;
    final suffix = lineChars.skip(colIdx).string;

    final insertedLines = effective.split('\n');
    final int nextLine;
    final int nextCol;
    if (insertedLines.length == 1) {
      lines[lineIdx] = '$prefix${insertedLines.first}$suffix';
      nextLine = lineIdx;
      nextCol = colIdx + insertedLines.first.characters.length;
    } else {
      lines[lineIdx] = '$prefix${insertedLines.first}';
      final trailing = <String>[
        ...insertedLines.sublist(1, insertedLines.length - 1),
        '${insertedLines.last}$suffix',
      ];
      lines.insertAll(lineIdx + 1, trailing);
      nextLine = lineIdx + insertedLines.length - 1;
      nextCol = insertedLines.last.characters.length;
    }

    final nextText = lines.join('\n');
    final nextOffset = _offsetFromLines(lines, nextLine, nextCol);
    value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(
        offset: nextOffset,
        line: nextLine,
        column: nextCol,
      ),
    );
  }

  static int _offsetFromLines(List<String> lines, int line, int column) {
    var offset = 0;
    for (var i = 0; i < line; i++) {
      offset += lines[i].characters.length + 1;
    }
    return offset + column;
  }

  /// Undoes the last change.
  void undo() {
    breakUndoBurst();
    if (_undoStack.isNotEmpty) {
      _redoStack.add(_value);
      value = _undoStack.removeLast();
    }
  }

  /// Redoes the last undone change.
  void redo() {
    breakUndoBurst();
    if (_redoStack.isNotEmpty) {
      _undoStack.add(_value);
      value = _redoStack.removeLast();
    }
  }

  /// Clears the text.
  void clear() {
    breakUndoBurst();
    value = const TextEditingValue();
  }

  /// Clears the undo and redo history stacks without modifying [value].
  void clearHistory() {
    _undoStack.clear();
    _redoStack.clear();
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
/// | `Ctrl + W` / `Alt + W` / `Alt + Backspace` | `deleteWordLeft` | Delete the word behind the cursor. |
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

  /// Optional fallback callback invoked when [handleKeyEvent] does not consume a key.
  final bool Function(KeyEvent event)? onKeyEvent;

  /// Optional number of spaces inserted when `Tab` (without modifiers) is pressed.
  ///
  /// Defaults to `null`, preserving standard `Tab` focus traversal.
  final int? tabSize;

  int _viewportHeight = 10;

  /// Vertical scroll offset, persisted on [controller].
  int get scrollOffset => controller.scrollOffset;
  set scrollOffset(int value) => controller.scrollOffset = value;

  /// Horizontal scroll offset, persisted on [controller].
  int get horizontalScrollOffset => controller.horizontalScrollOffset;
  set horizontalScrollOffset(int value) =>
      controller.horizontalScrollOffset = value;

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
    this.onKeyEvent,
    this.tabSize,
  }) : controller =
           controller ?? TextEditingController(text: value ?? initialText) {
    if (tabSize != null && tabSize! <= 0) {
      throw ArgumentError.value(tabSize, 'tabSize', 'Must be positive.');
    }
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
    const TextFieldShortcut(type: KeyType.pageUp): TextFieldAction.pageUp,
    const TextFieldShortcut(type: KeyType.pageDown): TextFieldAction.pageDown,
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
      key: 'w',
      modifiers: {ev.Modifier.alt},
    ): TextFieldAction.deleteWordLeft,
    const TextFieldShortcut(
      type: KeyType.backspace,
      modifiers: {ev.Modifier.alt},
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
      key: 'z',
      modifiers: {ev.Modifier.control, ev.Modifier.shift},
    ): TextFieldAction.redo,
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

  bool _canExecuteVerticalMove(TextFieldAction action) => switch (action) {
    TextFieldAction.moveUp => multiline && cursorLine > 0,
    TextFieldAction.moveDown =>
      multiline && cursorLine < controller.value.lines.length - 1,
    TextFieldAction.pageUp || TextFieldAction.pageDown => multiline,
    _ => true,
  };

  void _insertNewline() {
    controller.insertText('\n', multiline: true);
  }

  void _insertCharacterKey(String key) {
    if (key.contains('\n') || key.contains('\r') || key.characters.length > 1) {
      controller.insertText(key, multiline: multiline);
      return;
    }
    if (key.isEmpty) return;

    controller.saveStateToHistory(coalesce: true);
    if (key.trim().isEmpty) {
      controller.breakUndoBurst();
    }
    final lines = [...controller.value.lines];
    final lineIdx = cursorLine;
    final colIdx = cursorColumn;
    final current = lines[lineIdx].characters;
    lines[lineIdx] =
        '${current.take(colIdx).string}$key${current.skip(colIdx).string}';

    final nextCol = colIdx + 1;
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
    if (event.type == KeyType.tab) {
      final spaces = tabSize;
      if (spaces == null || event.modifiers.isNotEmpty) return false;
      controller.insertText(' ' * spaces, multiline: multiline);
      return true;
    }

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
    if (action == TextFieldAction.undo) {
      controller.undo();
      return;
    }
    if (action == TextFieldAction.redo) {
      controller.redo();
      return;
    }

    final lines = List<String>.from(controller.value.lines);
    final pos = _isNavigationAction(action)
        ? _executeNavigationAction(action, lines, cursorLine, cursorColumn)
        : _executeDeletionAction(action, lines, cursorLine, cursorColumn);

    final nextText = lines.join('\n');
    final nextOffset = _getOffsetFromLineColumn(nextText, pos.line, pos.col);
    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection(
        baseOffset: nextOffset,
        extentOffset: nextOffset,
        cursorLine: pos.line,
        cursorColumn: pos.col,
      ),
    );
  }

  static bool _isNavigationAction(TextFieldAction action) => switch (action) {
    TextFieldAction.moveLeft ||
    TextFieldAction.moveRight ||
    TextFieldAction.moveUp ||
    TextFieldAction.moveDown ||
    TextFieldAction.pageUp ||
    TextFieldAction.pageDown ||
    TextFieldAction.moveWordLeft ||
    TextFieldAction.moveWordRight ||
    TextFieldAction.moveToLineStart ||
    TextFieldAction.moveToLineEnd => true,
    _ => false,
  };

  ({int line, int col}) _executeNavigationAction(
    TextFieldAction action,
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    controller.breakUndoBurst();
    return switch (action) {
      TextFieldAction.moveLeft => _moveHorizontal(lines, lineIdx, colIdx, -1),
      TextFieldAction.moveRight => _moveHorizontal(lines, lineIdx, colIdx, 1),
      TextFieldAction.moveUp => _moveVertical(lines, lineIdx, colIdx, -1),
      TextFieldAction.moveDown => _moveVertical(lines, lineIdx, colIdx, 1),
      TextFieldAction.pageUp => _moveByPage(lines, lineIdx, colIdx, -1),
      TextFieldAction.pageDown => _moveByPage(lines, lineIdx, colIdx, 1),
      TextFieldAction.moveWordLeft => _moveWordLeft(lines, lineIdx, colIdx),
      TextFieldAction.moveWordRight => _moveWordRight(lines, lineIdx, colIdx),
      TextFieldAction.moveToLineStart => (line: lineIdx, col: 0),
      TextFieldAction.moveToLineEnd => (
        line: lineIdx,
        col: lines[lineIdx].characters.length,
      ),
      _ => (line: lineIdx, col: colIdx),
    };
  }

  ({int line, int col}) _moveHorizontal(
    List<String> lines,
    int lineIdx,
    int colIdx,
    int delta,
  ) {
    if (delta < 0) {
      if (colIdx > 0) return (line: lineIdx, col: colIdx - 1);
      if (lineIdx > 0 && multiline) {
        return (line: lineIdx - 1, col: lines[lineIdx - 1].characters.length);
      }
      return (line: lineIdx, col: colIdx);
    }
    if (colIdx < lines[lineIdx].characters.length) {
      return (line: lineIdx, col: colIdx + 1);
    }
    if (lineIdx < lines.length - 1 && multiline) {
      return (line: lineIdx + 1, col: 0);
    }
    return (line: lineIdx, col: colIdx);
  }

  ({int line, int col}) _moveVertical(
    List<String> lines,
    int lineIdx,
    int colIdx,
    int delta,
  ) {
    if (!multiline) return (line: lineIdx, col: colIdx);
    final nextLine = (lineIdx + delta).clamp(0, lines.length - 1);
    final nextCol = min(colIdx, lines[nextLine].characters.length);
    return (line: nextLine, col: nextCol);
  }

  ({int line, int col}) _moveByPage(
    List<String> lines,
    int lineIdx,
    int colIdx,
    int direction,
  ) {
    final step = max(1, _viewportHeight > 1 ? _viewportHeight - 1 : 1);
    final nextLine = (lineIdx + direction * step).clamp(0, lines.length - 1);
    final nextCol = min(colIdx, lines[nextLine].characters.length);
    if (nextLine == lineIdx && nextCol == colIdx) {
      final viewport = max<int>(1, _viewportHeight);
      final maxScroll = max<int>(0, lines.length - viewport);
      controller._setAutoScrollOffset(
        min<int>(maxScroll, max<int>(0, scrollOffset + direction * step)),
      );
    }
    return (line: nextLine, col: nextCol);
  }

  ({int line, int col}) _moveWordLeft(
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    if (colIdx > 0) {
      return (
        line: lineIdx,
        col: _findWordBoundaryBackward(lines[lineIdx], colIdx),
      );
    }
    if (lineIdx > 0 && multiline) {
      return (line: lineIdx - 1, col: lines[lineIdx - 1].characters.length);
    }
    return (line: lineIdx, col: colIdx);
  }

  ({int line, int col}) _moveWordRight(
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    if (colIdx < lines[lineIdx].characters.length) {
      return (
        line: lineIdx,
        col: _findWordBoundaryForward(lines[lineIdx], colIdx),
      );
    }
    if (lineIdx < lines.length - 1 && multiline) {
      return (line: lineIdx + 1, col: 0);
    }
    return (line: lineIdx, col: colIdx);
  }

  ({int line, int col}) _executeDeletionAction(
    TextFieldAction action,
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) => switch (action) {
    TextFieldAction.deleteLeft => _deleteLeft(lines, lineIdx, colIdx),
    TextFieldAction.deleteRight => _deleteRight(lines, lineIdx, colIdx),
    TextFieldAction.deleteWordLeft => _deleteWordLeft(lines, lineIdx, colIdx),
    TextFieldAction.deleteWordRight => _deleteWordRight(lines, lineIdx, colIdx),
    TextFieldAction.deleteToLineStart => _deleteToLineStart(
      lines,
      lineIdx,
      colIdx,
    ),
    TextFieldAction.deleteToLineEnd => _deleteToLineEnd(lines, lineIdx, colIdx),
    _ => (line: lineIdx, col: colIdx),
  };

  ({int line, int col}) _deleteLeft(
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    final chars = lines[lineIdx].characters;
    if (colIdx > 0) {
      controller.saveStateToHistory();
      lines[lineIdx] =
          '${chars.take(colIdx - 1).string}${chars.skip(colIdx).string}';
      return (line: lineIdx, col: colIdx - 1);
    }
    if (lineIdx > 0 && multiline) {
      return _mergeWithPreviousLine(lines, lineIdx);
    }
    return (line: lineIdx, col: colIdx);
  }

  ({int line, int col}) _deleteRight(
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    final chars = lines[lineIdx].characters;
    if (colIdx < chars.length) {
      controller.saveStateToHistory();
      lines[lineIdx] =
          '${chars.take(colIdx).string}${chars.skip(colIdx + 1).string}';
    } else if (lineIdx < lines.length - 1 && multiline) {
      _mergeWithNextLine(lines, lineIdx);
    }
    return (line: lineIdx, col: colIdx);
  }

  ({int line, int col}) _deleteWordLeft(
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    final chars = lines[lineIdx].characters;
    if (colIdx > 0) {
      final start = _findWordBoundaryBackward(lines[lineIdx], colIdx);
      if (start < colIdx) {
        controller.saveStateToHistory();
        lines[lineIdx] =
            '${chars.take(start).string}${chars.skip(colIdx).string}';
        return (line: lineIdx, col: start);
      }
      return (line: lineIdx, col: colIdx);
    }
    if (lineIdx > 0 && multiline) {
      return _mergeWithPreviousLine(lines, lineIdx);
    }
    return (line: lineIdx, col: colIdx);
  }

  ({int line, int col}) _deleteWordRight(
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    final chars = lines[lineIdx].characters;
    if (colIdx < chars.length) {
      final end = _findWordBoundaryForward(lines[lineIdx], colIdx);
      if (end > colIdx) {
        controller.saveStateToHistory();
        lines[lineIdx] =
            '${chars.take(colIdx).string}${chars.skip(end).string}';
      }
    } else if (lineIdx < lines.length - 1 && multiline) {
      _mergeWithNextLine(lines, lineIdx);
    }
    return (line: lineIdx, col: colIdx);
  }

  ({int line, int col}) _deleteToLineStart(
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    if (colIdx <= 0) return (line: lineIdx, col: colIdx);
    controller.saveStateToHistory();
    lines[lineIdx] = lines[lineIdx].characters.skip(colIdx).string;
    return (line: lineIdx, col: 0);
  }

  ({int line, int col}) _deleteToLineEnd(
    List<String> lines,
    int lineIdx,
    int colIdx,
  ) {
    final chars = lines[lineIdx].characters;
    if (colIdx < chars.length) {
      controller.saveStateToHistory();
      lines[lineIdx] = chars.take(colIdx).string;
    } else if (lineIdx < lines.length - 1 && multiline) {
      _mergeWithNextLine(lines, lineIdx);
    }
    return (line: lineIdx, col: colIdx);
  }

  ({int line, int col}) _mergeWithPreviousLine(
    List<String> lines,
    int lineIdx,
  ) {
    controller.saveStateToHistory();
    final prevLine = lines[lineIdx - 1];
    lines[lineIdx - 1] = prevLine + lines[lineIdx];
    lines.removeAt(lineIdx);
    return (line: lineIdx - 1, col: prevLine.characters.length);
  }

  void _mergeWithNextLine(List<String> lines, int lineIdx) {
    controller.saveStateToHistory();
    lines[lineIdx] = lines[lineIdx] + lines[lineIdx + 1];
    lines.removeAt(lineIdx + 1);
  }

  /// Adjusts the vertical scroll offset based on [viewportHeight] so the cursor
  /// line stays visible.
  void adjustScroll(int viewportHeight) {
    final lines = controller.value.lines;
    if (lines.isEmpty || viewportHeight <= 0) return;
    final currentCursorLine = cursorLine.clamp(0, lines.length - 1);
    final maxScroll = max(0, lines.length - viewportHeight);
    var nextScroll = scrollOffset.clamp(0, maxScroll);
    if (currentCursorLine < nextScroll) {
      nextScroll = currentCursorLine;
    } else if (currentCursorLine >= nextScroll + viewportHeight) {
      nextScroll = currentCursorLine - viewportHeight + 1;
    }
    controller._setAutoScrollOffset(nextScroll);
  }

  /// Adjusts the horizontal scroll offset based on [viewportWidth] so the
  /// cursor column stays visible.
  void adjustHorizontalScroll(int viewportWidth) {
    final lines = controller.value.lines;
    if (lines.isEmpty || viewportWidth <= 0) return;
    final lineIdx = cursorLine.clamp(0, lines.length - 1);
    final cursorDisplayCol = _displayColumnAt(
      lines[lineIdx],
      cursorColumn,
      obscureText: obscureText,
    );
    var nextHorizontal = horizontalScrollOffset;
    if (cursorDisplayCol < nextHorizontal) {
      nextHorizontal = cursorDisplayCol;
    } else if (cursorDisplayCol >= nextHorizontal + viewportWidth) {
      nextHorizontal = cursorDisplayCol - viewportWidth + 1;
    }
    controller._setAutoHorizontalScrollOffset(nextHorizontal);
  }

  static int _displayColumnAt(
    String line,
    int graphemeCol, {
    required bool obscureText,
  }) {
    var col = 0;
    var idx = 0;
    for (final ch in line.characters) {
      if (idx >= graphemeCol) break;
      col += obscureText ? 1 : max(1, graphemeWidth(ch));
      idx++;
    }
    return col;
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
  bool _needsInitialFocusSync = false;

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
    _needsInitialFocusSync = widget.focused;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_needsInitialFocusSync ||
        Zone.current[#isMeasuringIntrinsics] == true) {
      return;
    }
    _needsInitialFocusSync = false;
    _focusNode.seedInitialFocus(
      Focus.of(context),
      isMounted: () => mounted,
      onDeferredUnfocus: () {
        widget.focused = false;
        widget.onFocusChange?.call(false);
        if (mounted) setState(() {});
      },
    );
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
      onKeyEvent: (event) =>
          widget.handleKeyEvent(event) ||
          (widget.onKeyEvent?.call(event) ?? false),
      child: _TextFieldRenderWidget(widget, _focusNode),
    );
  }
}

class _TextFieldRenderWidget extends Widget {
  /// The parent TextField widget configuration.
  final TextField textFieldWidget;

  /// The focus node associated with this text field.
  final FocusNode focusNode;

  /// Creates a render proxy for a TextField.
  const _TextFieldRenderWidget(this.textFieldWidget, this.focusNode);

  @override
  Element createElement() => _TextFieldRenderWidgetElement(this);
}

/// Element that performs layout and paint for [_TextFieldRenderWidget].
class _TextFieldRenderWidgetElement extends Element
    implements ev.MouseEventConsumer {
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
    final lines = textField.controller.value.lines;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : lines.length;

    textField._viewportHeight = max(1, height);
    if (!textField.controller._manualScroll) {
      textField.adjustScroll(height);
    } else if (height > 0) {
      textField.controller._clampScrollOffset(max(0, lines.length - height));
    }
    if (textField.focused && !textField.controller._manualHorizontalScroll) {
      textField.adjustHorizontalScroll(width);
    }

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
      _paintPlaceholder(buffer, offset, textField);
      return;
    }

    final lines = textField.controller.value.lines;
    final mergedCursorStyle = textField.focused
        ? _getMergedStyle(textField)
        : textField.style;
    _paintVisiblePlainLines(
      buffer,
      offset,
      w,
      h,
      lines,
      textField,
      mergedCursorStyle,
    );
  }

  void _paintVisiblePlainLines(
    Buffer buffer,
    Offset offset,
    int width,
    int height,
    List<String> lines,
    TextField textField,
    Style mergedCursorStyle,
  ) {
    final cursorLine = textField.cursorLine;
    for (var y = 0; y < height; y++) {
      final lineIdx = textField.scrollOffset + y;
      if (lineIdx >= lines.length) break;
      _paintLine(
        buffer,
        Offset(offset.dx, offset.dy + y),
        width,
        lines[lineIdx],
        textField,
        mergedCursorStyle,
        isCursorLine: textField.focused && lineIdx == cursorLine,
      );
    }
  }

  void _paintPlaceholder(Buffer buffer, Offset offset, TextField textField) {
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
        underlineColor: 0,
      );
    }
  }

  @override
  bool handleMouseEvent(term.MouseEvent event, int localX, int localY) {
    if (localX < 0 ||
        localX >= size.width ||
        localY < 0 ||
        localY >= size.height) {
      return false;
    }
    if (event.type != .press) return false;

    final renderWidget = widget as _TextFieldRenderWidget;
    final textField = renderWidget.textFieldWidget;
    if (event.button == .wheelUp || event.button == .wheelDown) {
      return _handleMouseWheel(textField, event.button);
    }
    if (event.button != .left) return false;

    renderWidget.focusNode.requestFocus();
    textField.controller.breakUndoBurst();
    final text = textField.controller.value.text;
    final lines = textField.controller.value.lines;
    final targetLine = (textField.scrollOffset + localY).clamp(
      0,
      lines.length - 1,
    );
    final targetCol = _resolveClickedColumn(
      lines[targetLine],
      localX + textField.horizontalScrollOffset,
      obscureText: textField.obscureText,
    );
    final nextOffset = textField._getOffsetFromLineColumn(
      text,
      targetLine,
      targetCol,
    );
    textField.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: nextOffset,
        extentOffset: nextOffset,
        cursorLine: targetLine,
        cursorColumn: targetCol,
      ),
    );
    return true;
  }

  bool _handleMouseWheel(TextField textField, term.MouseButton button) {
    if (!textField.multiline) return false;
    final lines = textField.controller.value.lines;
    final maxScroll = max(0, lines.length - size.height);
    const wheelStep = 3;
    final delta = button == .wheelUp ? -wheelStep : wheelStep;
    textField.scrollOffset = min(
      maxScroll,
      max(0, textField.scrollOffset + delta),
    );
    return true;
  }

  static int _resolveClickedColumn(
    String line,
    int localX, {
    required bool obscureText,
  }) {
    if (localX <= 0) return 0;
    var col = 0;
    var idx = 0;
    for (final ch in line.characters) {
      final w = obscureText ? 1 : max(1, graphemeWidth(ch));
      if (localX < col + w) return idx;
      col += w;
      idx++;
    }
    return idx;
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
    final result = _paintLineGraphemes(
      buffer,
      rowOffset,
      width,
      line,
      textField,
      mergedCursorStyle,
      isCursorLine: isCursorLine,
    );
    _paintTrailingAndEolCursor(
      buffer,
      rowOffset,
      width,
      result,
      textField,
      mergedCursorStyle,
      isCursorLine: isCursorLine,
    );
  }

  void _paintTrailingAndEolCursor(
    Buffer buffer,
    Offset rowOffset,
    int width,
    ({int graphemeCount, int displayEnd, bool reachedLineEnd}) painted,
    TextField textField,
    Style mergedCursorStyle, {
    required bool isCursorLine,
  }) {
    for (var x = painted.displayEnd; x < width; x++) {
      buffer.setAttributes(
        rowOffset.dx + x,
        rowOffset.dy,
        char: ' ',
        fg: textField.style.foreground?.argb ?? 0,
        bg: textField.style.background?.argb ?? 0,
        modifiers: textField.style.modifiers,
        underlineColor: 0,
      );
    }
    if (isCursorLine &&
        painted.reachedLineEnd &&
        textField.cursorColumn >= painted.graphemeCount &&
        painted.displayEnd >= 0 &&
        painted.displayEnd < width) {
      buffer.setAttributes(
        rowOffset.dx + painted.displayEnd,
        rowOffset.dy,
        fg: mergedCursorStyle.foreground?.argb ?? 0,
        bg: mergedCursorStyle.background?.argb ?? 0,
        modifiers: mergedCursorStyle.modifiers,
        underlineColor: 0,
      );
    }
  }

  ({int graphemeCount, int displayEnd, bool reachedLineEnd})
  _paintLineGraphemes(
    Buffer buffer,
    Offset rowOffset,
    int width,
    String line,
    TextField textField,
    Style mergedCursorStyle, {
    required bool isCursorLine,
  }) {
    final hScroll = textField.horizontalScrollOffset;
    var displayCol = 0;
    var displayEnd = 0;
    var graphemeIdx = 0;
    for (final rawChar in line.characters) {
      final char = textField.obscureText
          ? textField.obscuringCharacter
          : rawChar;
      final step = textField.obscureText ? 1 : max(1, graphemeWidth(char));
      final placed = _placeVisibleCell(
        buffer,
        rowOffset,
        width,
        hScroll,
        displayCol,
        step,
        char,
        (isCursorLine && graphemeIdx == textField.cursorColumn)
            ? mergedCursorStyle
            : textField.style,
        textField.style,
      );
      if (placed == null) {
        return (
          graphemeCount: graphemeIdx,
          displayEnd: displayEnd,
          reachedLineEnd: false,
        );
      }
      displayEnd = max(displayEnd, placed);
      displayCol += step;
      graphemeIdx++;
    }
    return (
      graphemeCount: graphemeIdx,
      displayEnd: displayEnd,
      reachedLineEnd: true,
    );
  }

  int? _placeVisibleCell(
    Buffer buffer,
    Offset rowOffset,
    int width,
    int hScroll,
    int displayCol,
    int step,
    String char,
    Style cellStyle,
    Style fallbackStyle,
  ) {
    if (displayCol + step <= hScroll) return 0;
    final screenX = displayCol - hScroll;
    if (screenX < 0) {
      buffer.setAttributes(
        rowOffset.dx,
        rowOffset.dy,
        char: ' ',
        fg: fallbackStyle.foreground?.argb ?? 0,
        bg: fallbackStyle.background?.argb ?? 0,
        modifiers: fallbackStyle.modifiers,
        underlineColor: 0,
      );
      return displayCol + step - hScroll;
    }
    if (screenX + step > width) return null;
    buffer.setAttributes(
      rowOffset.dx + screenX,
      rowOffset.dy,
      char: char,
      fg: cellStyle.foreground?.argb ?? 0,
      bg: cellStyle.background?.argb ?? 0,
      modifiers: cellStyle.modifiers,
      underlineColor: cellStyle.underlineColor?.argb ?? 0,
      uri: cellStyle.uri,
    );
    return screenX + step;
  }
}
