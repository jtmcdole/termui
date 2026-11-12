import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:termui/terminal/event.dart' as term;

/// Collects currently pressed hardware modifiers from [HardwareKeyboard].
Set<term.Modifier> collectHardwareModifiers() {
  final kb = HardwareKeyboard.instance;
  return {
    if (kb.isShiftPressed) term.Modifier.shift,
    if (kb.isAltPressed) term.Modifier.alt,
    if (kb.isControlPressed) term.Modifier.control,
    if (kb.isMetaPressed) term.Modifier.meta,
  };
}

/// Whether [key] is a non-printable functional or navigation key (`Enter`,
/// `Backspace`, `Tab`, `Escape`, arrows, `Home`/`End`/`PgUp`/`PgDn`,
/// `Insert`/`Delete`, or `F1..F12`).
bool isTerminalFunctionalKey(LogicalKeyboardKey key) => switch (key) {
  LogicalKeyboardKey.arrowUp ||
  LogicalKeyboardKey.arrowDown ||
  LogicalKeyboardKey.arrowLeft ||
  LogicalKeyboardKey.arrowRight ||
  LogicalKeyboardKey.home ||
  LogicalKeyboardKey.end ||
  LogicalKeyboardKey.delete ||
  LogicalKeyboardKey.insert ||
  LogicalKeyboardKey.backspace ||
  LogicalKeyboardKey.pageUp ||
  LogicalKeyboardKey.pageDown ||
  LogicalKeyboardKey.escape ||
  LogicalKeyboardKey.enter ||
  LogicalKeyboardKey.numpadEnter ||
  LogicalKeyboardKey.tab ||
  LogicalKeyboardKey.f1 ||
  LogicalKeyboardKey.f2 ||
  LogicalKeyboardKey.f3 ||
  LogicalKeyboardKey.f4 ||
  LogicalKeyboardKey.f5 ||
  LogicalKeyboardKey.f6 ||
  LogicalKeyboardKey.f7 ||
  LogicalKeyboardKey.f8 ||
  LogicalKeyboardKey.f9 ||
  LogicalKeyboardKey.f10 ||
  LogicalKeyboardKey.f11 ||
  LogicalKeyboardKey.f12 => true,
  _ => false,
};

/// Whether `(key, mods)` represents a built-in clipboard paste shortcut
/// (`Cmd+V`, `Ctrl+Shift+V`, or `Shift+Insert`).
bool isTerminalPasteShortcut(LogicalKeyboardKey key, Set<term.Modifier> mods) {
  if (key == LogicalKeyboardKey.keyV) {
    final isCmdV =
        mods.contains(term.Modifier.meta) &&
        !mods.contains(term.Modifier.control) &&
        !mods.contains(term.Modifier.alt);
    final isCtrlShiftV =
        mods.contains(term.Modifier.control) &&
        mods.contains(term.Modifier.shift) &&
        !mods.contains(term.Modifier.meta) &&
        !mods.contains(term.Modifier.alt);
    return isCmdV || isCtrlShiftV;
  }
  if (key == LogicalKeyboardKey.insert) {
    return mods.contains(term.Modifier.shift) &&
        !mods.contains(term.Modifier.control) &&
        !mods.contains(term.Modifier.alt) &&
        !mods.contains(term.Modifier.meta);
  }
  return false;
}

/// Resolves a Flutter hardware [KeyEvent] and active [mods] into a `termui`
/// [term.KeyEvent], or returns `null` for standalone modifier keys.
term.KeyEvent? resolveTerminalKeyEvent(
  KeyEvent event,
  Set<term.Modifier> mods, {
  term.KeyEventType eventType = term.KeyEventType.press,
}) {
  final key = event.logicalKey;
  final (termKey, termType) = switch (key) {
    LogicalKeyboardKey.arrowUp => ('up', term.KeyType.up),
    LogicalKeyboardKey.arrowDown => ('down', term.KeyType.down),
    LogicalKeyboardKey.arrowLeft => ('left', term.KeyType.left),
    LogicalKeyboardKey.arrowRight => ('right', term.KeyType.right),
    LogicalKeyboardKey.home => ('home', term.KeyType.home),
    LogicalKeyboardKey.end => ('end', term.KeyType.end),
    LogicalKeyboardKey.delete => ('delete', term.KeyType.delete),
    LogicalKeyboardKey.insert => ('insert', term.KeyType.insert),
    LogicalKeyboardKey.backspace => ('backspace', term.KeyType.backspace),
    LogicalKeyboardKey.pageUp => ('pageUp', term.KeyType.pageUp),
    LogicalKeyboardKey.pageDown => ('pageDown', term.KeyType.pageDown),
    LogicalKeyboardKey.escape => ('escape', term.KeyType.escape),
    LogicalKeyboardKey.enter ||
    LogicalKeyboardKey.numpadEnter => ('\n', term.KeyType.enter),
    LogicalKeyboardKey.tab => (
      mods.contains(term.Modifier.shift) ? 'backtab' : '\t',
      term.KeyType.tab,
    ),
    LogicalKeyboardKey.f1 => ('f1', term.KeyType.f1),
    LogicalKeyboardKey.f2 => ('f2', term.KeyType.f2),
    LogicalKeyboardKey.f3 => ('f3', term.KeyType.f3),
    LogicalKeyboardKey.f4 => ('f4', term.KeyType.f4),
    LogicalKeyboardKey.f5 => ('f5', term.KeyType.f5),
    LogicalKeyboardKey.f6 => ('f6', term.KeyType.f6),
    LogicalKeyboardKey.f7 => ('f7', term.KeyType.f7),
    LogicalKeyboardKey.f8 => ('f8', term.KeyType.f8),
    LogicalKeyboardKey.f9 => ('f9', term.KeyType.f9),
    LogicalKeyboardKey.f10 => ('f10', term.KeyType.f10),
    LogicalKeyboardKey.f11 => ('f11', term.KeyType.f11),
    LogicalKeyboardKey.f12 => ('f12', term.KeyType.f12),
    LogicalKeyboardKey.equal => ('=', term.KeyType.character),
    LogicalKeyboardKey.numpadAdd => ('+', term.KeyType.character),
    LogicalKeyboardKey.minus ||
    LogicalKeyboardKey.numpadSubtract => ('-', term.KeyType.character),
    _ when _isCtrlLetter(key, mods, event.character) => (
      key.keyLabel.toLowerCase(),
      term.KeyType.character,
    ),
    _ when event.character != null && event.character!.isNotEmpty =>
      _resolveCharacterKey(event.character!),
    LogicalKeyboardKey.space => (' ', term.KeyType.character),
    _ when key.keyLabel.length == 1 => (
      key.keyLabel.toLowerCase(),
      term.KeyType.character,
    ),
    _ => (null, null),
  };
  if (termKey == null || termType == null) return null;
  final shiftedCodepoint = _resolveShiftedCodepoint(
    key,
    mods,
    termKey,
    event.character,
  );
  return term.KeyEvent(
    termKey,
    termType,
    modifiers: mods,
    eventType: eventType,
    shiftedCodepoint: shiftedCodepoint,
  );
}

bool _isAsciiLetterKey(LogicalKeyboardKey key) =>
    key.keyId >= LogicalKeyboardKey.keyA.keyId &&
    key.keyId <= LogicalKeyboardKey.keyZ.keyId;

bool _isCtrlLetter(
  LogicalKeyboardKey key,
  Set<term.Modifier> mods,
  String? character,
) {
  if (!mods.contains(term.Modifier.control) ||
      !_isAsciiLetterKey(key) ||
      key.keyLabel.length != 1) {
    return false;
  }
  if (character == null || character.isEmpty) return true;
  final unit = character.codeUnitAt(0);
  if (character.length == 1 && (unit <= 0x1F || unit == 0x7F)) {
    return true;
  }
  return character.toLowerCase() == key.keyLabel.toLowerCase();
}

int? _resolveShiftedCodepoint(
  LogicalKeyboardKey key,
  Set<term.Modifier> mods,
  String termKey,
  String? character,
) {
  if (!mods.contains(term.Modifier.shift)) return null;
  if (_isAsciiLetterKey(key) && key.keyLabel.length == 1) {
    final lower = key.keyLabel.toLowerCase();
    return termKey == lower ? lower.toUpperCase().codeUnitAt(0) : null;
  }
  if (character != null &&
      character.isNotEmpty &&
      character != termKey &&
      character.runes.length == 1) {
    return character.runes.first;
  }
  return null;
}

(String, term.KeyType) _resolveCharacterKey(String ch) =>
    (ch == '\n' || ch == '\r' || ch == '\r\n')
    ? ('\n', term.KeyType.enter)
    : (ch, term.KeyType.character);

final class _PendingClaimedKey {
  final LogicalKeyboardKey logicalKey;
  final Set<String> candidates;
  final bool isEnter;
  final DateTime expiresAt;
  bool actionConsumed = false;
  bool deltaConsumed = false;

  _PendingClaimedKey({
    required this.logicalKey,
    required this.candidates,
    required this.isEnter,
    required this.expiresAt,
  });
}

/// Deterministic `DeltaTextInputClient` and `Focus.onKeyEvent` arbitrator for
/// terminal panes.
///
/// Enforces three mutually exclusive keyboard/IME rules:
/// 1. **Active IME composition** (`composingRange` valid and non-collapsed):
///    [handleKeyEvent] returns [KeyEventResult.ignored] for all keys so the OS
///    candidate/dead-key UI handles composition, and only committed text is
///    emitted once composition ends.
/// 2. **Not composing & `(kittyKeyboardFlags & (2 | 8)) == 0`**:
///    [handleKeyEvent] claims functional/navigation keys, `Ctrl+*`, `Meta+*`,
///    and `Alt+*` (except macOS `Option` printable keys when
///    [macosOptionAsAlt] is `false`), returning [KeyEventResult.handled] and
///    suppressing matching `performAction` / control deltas. Unmodified,
///    `Shift`-only, and macOS dead-key `Option` printable keys return
///    [KeyEventResult.ignored] and emit solely through
///    [updateEditingValueWithDeltas].
/// 3. **Not composing & `(kittyKeyboardFlags & (2 | 8)) != 0`**:
///    [handleKeyEvent] claims hardware press/repeat/release events for Kitty
///    `CSI u` encoding and suppresses matching non-composing IME insertions.
final class TerminalImeClient with TextInputClient, DeltaTextInputClient {
  static const Duration _claimedSuppressionWindow = Duration(milliseconds: 100);

  /// Default [TextInputConfiguration] enabling delta tracking with terminal-safe flags.
  static const TextInputConfiguration defaultInputConfiguration =
      TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        enableDeltaModel: true,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        enableIMEPersonalizedLearning: false,
      );

  final int Function()? _kittyKeyboardFlags;
  final bool Function()? _reportKeyReleaseEvents;
  final void Function(term.KeyEvent event)? _onKeyEvent;
  final void Function(String text)? _onTextInput;
  final bool Function(KeyEvent event, Set<term.Modifier> modifiers)?
  _onHostShortcut;
  final VoidCallback? _onComposingChanged;
  final VoidCallback? _onModifiersChanged;

  // Fallback surface bindings attached by TerminalSurface when created externally.
  int Function()? _boundKittyFlags;
  bool Function()? _boundReportKeyRelease;
  void Function(term.KeyEvent event)? _boundOnKeyEvent;
  void Function(String text)? _boundOnTextInput;
  bool Function(KeyEvent event, Set<term.Modifier> modifiers)?
  _boundOnHostShortcut;
  VoidCallback? _boundOnModifiersChanged;

  final List<VoidCallback> _listeners = [];
  final Set<LogicalKeyboardKey> _suppressedHostShortcutKeys = {};
  final List<_PendingClaimedKey> _pendingClaimedKeys = [];

  /// Whether macOS `Option`+printable keys act as `Alt` instead of dead-key composition.
  bool macosOptionAsAlt;

  /// Whether non-Kitty printable keys route through `DeltaTextInputClient` instead of `Focus.onKeyEvent`.
  bool routePrintableThroughIme;

  TextInputConnection? _connection;
  TextEditingValue _editingValue = TextEditingValue.empty;

  Size? _lastEditableSize;
  Matrix4? _lastTransform;
  Rect? _lastComposingRect;
  Rect? _lastCaretRect;

  /// Creates a [TerminalImeClient] with optional input/mode callbacks.
  TerminalImeClient({
    int Function()? kittyKeyboardFlags,
    bool Function()? reportKeyReleaseEvents,
    this.macosOptionAsAlt = false,
    this.routePrintableThroughIme = true,
    void Function(term.KeyEvent event)? onKeyEvent,
    void Function(String text)? onTextInput,
    bool Function(KeyEvent event, Set<term.Modifier> modifiers)? onHostShortcut,
    VoidCallback? onComposingChanged,
    VoidCallback? onModifiersChanged,
  }) : _kittyKeyboardFlags = kittyKeyboardFlags,
       _reportKeyReleaseEvents = reportKeyReleaseEvents,
       _onKeyEvent = onKeyEvent,
       _onTextInput = onTextInput,
       _onHostShortcut = onHostShortcut,
       _onComposingChanged = onComposingChanged,
       _onModifiersChanged = onModifiersChanged;

  /// Active Kitty keyboard flags (`0..31`).
  int get kittyKeyboardFlags =>
      (_kittyKeyboardFlags ?? _boundKittyFlags)?.call() ?? 0;

  /// Whether key release events (`KeyUpEvent`) should be emitted.
  bool get reportKeyReleaseEvents =>
      (_reportKeyReleaseEvents ?? _boundReportKeyRelease)?.call() ??
      ((kittyKeyboardFlags & 2) != 0);

  /// Current active IME composing range within [currentTextEditingValue].
  TextRange get composingRange => _editingValue.composing;

  /// Whether an active non-collapsed IME composition is in progress.
  bool get isComposing =>
      _isValidNonCollapsed(_editingValue.composing, _editingValue.text.length);

  /// Active pre-edit composing string, or `''` when not composing.
  String get composingText =>
      isComposing ? _editingValue.composing.textInside(_editingValue.text) : '';

  /// Whether a [TextInputConnection] is currently attached to Flutter's text input plugin.
  bool get isAttached => _connection?.attached ?? false;

  @override
  TextEditingValue? get currentTextEditingValue => _editingValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  /// Registers a listener notified whenever [composingText] or [composingRange] changes.
  void addListener(VoidCallback listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// Unregisters a previously added listener.
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// Attaches fallback surface callbacks used when [TerminalImeClient] is instantiated without explicit handlers.
  void bindSurfaceHandlers({
    required int Function() kittyKeyboardFlags,
    required bool Function() reportKeyReleaseEvents,
    required void Function(term.KeyEvent event) onKeyEvent,
    void Function(String text)? onTextInput,
    bool Function(KeyEvent event, Set<term.Modifier> modifiers)? onHostShortcut,
    VoidCallback? onModifiersChanged,
  }) {
    _boundKittyFlags = kittyKeyboardFlags;
    _boundReportKeyRelease = reportKeyReleaseEvents;
    _boundOnKeyEvent = onKeyEvent;
    _boundOnTextInput = onTextInput;
    _boundOnHostShortcut = onHostShortcut;
    _boundOnModifiersChanged = onModifiersChanged;
  }

  /// Clears fallback surface callbacks on widget unmount/replacement.
  void clearSurfaceHandlers() {
    _boundKittyFlags = null;
    _boundReportKeyRelease = null;
    _boundOnKeyEvent = null;
    _boundOnTextInput = null;
    _boundOnHostShortcut = null;
    _boundOnModifiersChanged = null;
  }

  /// Opens or ensures an active [TextInputConnection] and syncs editing state and cursor geometry.
  void attach([
    TextInputConfiguration configuration = defaultInputConfiguration,
  ]) {
    final existing = _connection;
    if (existing != null && existing.attached) return;
    final connection = TextInput.attach(this, configuration)
      ..show()
      ..setEditingState(_editingValue);
    _connection = connection;
    _pushGeometryToConnection(connection);
  }

  /// Closes any active [TextInputConnection] and clears incomplete composition state.
  void detach() {
    final existing = _connection;
    _connection = null;
    if (existing != null && existing.attached) {
      existing.close();
    }
    _clearComposingState();
  }

  /// Reports editable viewport size, transform, and cursor/composing rectangles to the platform IME.
  void updateCursorGeometry({
    required Size editableSize,
    required Matrix4 transform,
    required Rect composingRect,
    Rect? caretRect,
  }) {
    _lastEditableSize = editableSize;
    _lastTransform = Matrix4.copy(transform);
    _lastComposingRect = composingRect;
    _lastCaretRect = caretRect ?? composingRect;
    final connection = _connection;
    if (connection != null && connection.attached) {
      _pushGeometryToConnection(connection);
    }
  }

  void _pushGeometryToConnection(TextInputConnection connection) {
    final size = _lastEditableSize;
    final transform = _lastTransform;
    if (size != null && transform != null) {
      connection.setEditableSizeAndTransform(size, transform);
    }
    final composingRect = _lastComposingRect;
    if (composingRect != null) {
      connection.setComposingRect(composingRect);
    }
    final caretRect = _lastCaretRect;
    if (caretRect != null) {
      connection.setCaretRect(caretRect);
    }
  }

  /// Handles hardware keyboard events for [Focus.onKeyEvent] according to the
  /// active IME composition and Kitty protocol state.
  KeyEventResult handleKeyEvent(KeyEvent event) {
    (_onModifiersChanged ?? _boundOnModifiersChanged)?.call();

    if (isComposing) {
      return KeyEventResult.ignored;
    }

    final flags = kittyKeyboardFlags;
    final kittyClaimAll = (flags & (2 | 8)) != 0;
    final reportReleases = reportKeyReleaseEvents || (flags & 2) != 0;

    if (event is KeyUpEvent) {
      return _handleKeyUpEvent(
        event,
        kittyClaimAll: kittyClaimAll,
        reportReleases: reportReleases,
      );
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final mods = collectHardwareModifiers();
    final shortcutHandler = _onHostShortcut ?? _boundOnHostShortcut;
    if (shortcutHandler != null && shortcutHandler(event, mods)) {
      _recordSuppressedClaimedKey(event, mods);
      if (reportReleases || kittyClaimAll) {
        _suppressedHostShortcutKeys.add(event.logicalKey);
      }
      return KeyEventResult.handled;
    }

    final eventType = event is KeyRepeatEvent
        ? term.KeyEventType.repeat
        : term.KeyEventType.press;

    if (!kittyClaimAll &&
        routePrintableThroughIme &&
        !_shouldFocusHandleStandardModeKey(event.logicalKey, mods)) {
      if (event is KeyDownEvent) {
        _pendingClaimedKeys.removeWhere(
          (entry) => entry.logicalKey == event.logicalKey,
        );
      }
      return KeyEventResult.ignored;
    }

    return _claimKeyInFocus(event, mods, eventType);
  }

  KeyEventResult _handleKeyUpEvent(
    KeyUpEvent event, {
    required bool kittyClaimAll,
    required bool reportReleases,
  }) {
    if (!reportReleases && !kittyClaimAll) {
      _suppressedHostShortcutKeys.clear();
      return KeyEventResult.ignored;
    }
    if (_suppressedHostShortcutKeys.remove(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    final mods = collectHardwareModifiers();
    final resolved = resolveTerminalKeyEvent(
      event,
      mods,
      eventType: term.KeyEventType.release,
    );
    if (resolved == null) {
      return KeyEventResult.ignored;
    }
    if (reportReleases) {
      _emitKeyEvent(resolved);
    }
    return KeyEventResult.handled;
  }

  bool _shouldFocusHandleStandardModeKey(
    LogicalKeyboardKey key,
    Set<term.Modifier> mods,
  ) {
    if (isTerminalFunctionalKey(key)) return true;
    if (mods.contains(term.Modifier.control) ||
        mods.contains(term.Modifier.meta)) {
      return true;
    }
    if (mods.contains(term.Modifier.alt)) {
      final isMacOs = defaultTargetPlatform == TargetPlatform.macOS;
      return !(isMacOs && !macosOptionAsAlt);
    }
    return false;
  }

  KeyEventResult _claimKeyInFocus(
    KeyEvent event,
    Set<term.Modifier> mods,
    term.KeyEventType eventType,
  ) {
    final resolved = resolveTerminalKeyEvent(event, mods, eventType: eventType);
    if (resolved == null) {
      return KeyEventResult.ignored;
    }
    _recordSuppressedClaimedKey(event, mods);
    _emitKeyEvent(resolved);
    return KeyEventResult.handled;
  }

  void _recordSuppressedClaimedKey(KeyEvent event, Set<term.Modifier> mods) {
    final now = clock.now();
    _pruneExpiredClaims(now);

    final key = event.logicalKey;
    final candidates = <String>{};
    if (event.character case final ch? when ch.isNotEmpty) {
      candidates.add(ch);
    }
    final isCtrlOnly =
        mods.contains(term.Modifier.control) &&
        !mods.contains(term.Modifier.alt) &&
        !mods.contains(term.Modifier.meta);
    if (!isCtrlOnly && key.keyLabel.length == 1) {
      candidates
        ..add(key.keyLabel.toLowerCase())
        ..add(key.keyLabel.toUpperCase());
    }
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    final isTab = key == LogicalKeyboardKey.tab;
    if (isEnter) {
      candidates.addAll(const ['\n', '\r', '\r\n']);
    } else if (isTab) {
      candidates.add('\t');
    } else if (key == LogicalKeyboardKey.space) {
      candidates.add(' ');
    }

    if (candidates.isEmpty && !isEnter && !isTab) return;
    _pendingClaimedKeys.add(
      _PendingClaimedKey(
        logicalKey: key,
        candidates: candidates,
        isEnter: isEnter,
        expiresAt: now.add(_claimedSuppressionWindow),
      ),
    );
  }

  void _pruneExpiredClaims(DateTime now) {
    _pendingClaimedKeys.removeWhere(
      (entry) =>
          now.isAfter(entry.expiresAt) ||
          (entry.deltaConsumed && (!entry.isEnter || entry.actionConsumed)),
    );
  }

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    if (textEditingDeltas.isEmpty) return;

    final prevComposing = isComposing;
    final prevComposingText = composingText;
    final committedOut = StringBuffer();
    var state = _editingValue;
    var needsPlatformReset = false;

    for (final delta in textEditingDeltas) {
      final step = _applySingleDelta(state, delta, committedOut);
      state = step.nextState;
      needsPlatformReset = needsPlatformReset || step.needsPlatformReset;
    }

    _editingValue = state;
    final committed = committedOut.toString();
    if (committed.isNotEmpty) {
      _emitCommittedText(committed);
    }
    if (needsPlatformReset && _connection != null && _connection!.attached) {
      _connection!.setEditingState(_editingValue);
    }
    if (prevComposing != isComposing || prevComposingText != composingText) {
      _notifyComposingChanged();
    }
  }

  ({TextEditingValue nextState, bool needsPlatformReset}) _applySingleDelta(
    TextEditingValue state,
    TextEditingDelta delta,
    StringBuffer committedOut,
  ) {
    if (_isValidNonCollapsed(state.composing, state.text.length)) {
      return _applyComposingDelta(state, delta, committedOut);
    }
    return _applyNonComposingDelta(delta, committedOut);
  }

  ({TextEditingValue nextState, bool needsPlatformReset})
  _applyNonComposingDelta(TextEditingDelta delta, StringBuffer committedOut) {
    if (delta is TextEditingDeltaInsertion) {
      return _handleNonComposingEdit(
        oldText: delta.oldText,
        replacement: delta.textInserted,
        start: delta.insertionOffset,
        end: delta.insertionOffset,
        composing: delta.composing,
        selection: delta.selection,
        committedOut: committedOut,
      );
    }
    if (delta is TextEditingDeltaReplacement) {
      return _handleNonComposingEdit(
        oldText: delta.oldText,
        replacement: delta.replacementText,
        start: delta.replacedRange.start,
        end: delta.replacedRange.end,
        composing: delta.composing,
        selection: delta.selection,
        committedOut: committedOut,
      );
    }
    return (
      nextState: TextEditingValue.empty,
      needsPlatformReset: delta.oldText.isNotEmpty,
    );
  }

  ({TextEditingValue nextState, bool needsPlatformReset})
  _handleNonComposingEdit({
    required String oldText,
    required String replacement,
    required int start,
    required int end,
    required TextRange composing,
    required TextSelection selection,
    required StringBuffer committedOut,
  }) {
    final newText = _safeReplace(oldText, replacement, start, end);
    if (_isValidNonCollapsed(composing, newText.length)) {
      final commitStart = oldText.length;
      if (composing.start > commitStart) {
        final prefix = newText.substring(commitStart, composing.start);
        if (!_shouldSuppressNonComposingInsertion(prefix)) {
          committedOut.write(prefix);
        }
      }
      final compText = newText.substring(composing.start, composing.end);
      return (
        nextState: TextEditingValue(
          text: compText,
          selection: _rebaseSelection(
            selection,
            composing.start,
            compText.length,
          ),
          composing: TextRange(start: 0, end: compText.length),
        ),
        needsPlatformReset: false,
      );
    }
    if (!_shouldSuppressNonComposingInsertion(replacement)) {
      committedOut.write(replacement);
    }
    return (
      nextState: TextEditingValue.empty,
      needsPlatformReset: newText.isNotEmpty,
    );
  }

  ({TextEditingValue nextState, bool needsPlatformReset}) _applyComposingDelta(
    TextEditingValue state,
    TextEditingDelta delta,
    StringBuffer committedOut,
  ) {
    final next = delta.apply(state);
    if (!_isValidNonCollapsed(next.composing, next.text.length)) {
      if (next.text.isNotEmpty) {
        committedOut.write(next.text);
      }
      return (nextState: TextEditingValue.empty, needsPlatformReset: true);
    }

    if (next.composing.start == 0 && next.composing.end == next.text.length) {
      return (nextState: next, needsPlatformReset: false);
    }

    if (next.composing.start > 0) {
      committedOut.write(next.text.substring(0, next.composing.start));
    }
    if (next.composing.end < next.text.length) {
      committedOut.write(next.text.substring(next.composing.end));
    }
    final compText = next.text.substring(
      next.composing.start,
      next.composing.end,
    );
    return (
      nextState: TextEditingValue(
        text: compText,
        selection: _rebaseSelection(
          next.selection,
          next.composing.start,
          compText.length,
        ),
        composing: TextRange(start: 0, end: compText.length),
      ),
      needsPlatformReset: true,
    );
  }

  bool _shouldSuppressNonComposingInsertion(String text) {
    if (text.isEmpty) return true;
    final now = clock.now();
    _pruneExpiredClaims(now);

    for (final entry in _pendingClaimedKeys) {
      if (!entry.deltaConsumed && entry.candidates.contains(text)) {
        entry.deltaConsumed = true;
        return true;
      }
    }

    if (text.length == 1) {
      final code = text.codeUnitAt(0);
      final isControl =
          (code < 0x20 && code != 0x0A && code != 0x0D && code != 0x09) ||
          code == 0x7F;
      if (isControl) return true;
    }
    return false;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    final prevComposing = isComposing;
    final prevComposingText = composingText;

    if (_isValidNonCollapsed(value.composing, value.text.length)) {
      final compText = value.composing.textInside(value.text);
      _editingValue = TextEditingValue(
        text: compText,
        selection: _rebaseSelection(
          value.selection,
          value.composing.start,
          compText.length,
        ),
        composing: TextRange(start: 0, end: compText.length),
      );
      if (prevComposing != isComposing || prevComposingText != composingText) {
        _notifyComposingChanged();
      }
      return;
    }

    final committed =
        (!prevComposing && value.text.startsWith(_editingValue.text))
        ? value.text.substring(_editingValue.text.length)
        : value.text;
    _editingValue = TextEditingValue.empty;
    if (committed.isNotEmpty &&
        (prevComposing || !_shouldSuppressNonComposingInsertion(committed))) {
      _emitCommittedText(committed);
    }
    if (value.text.isNotEmpty && _connection != null && _connection!.attached) {
      _connection!.setEditingState(TextEditingValue.empty);
    }
    if (prevComposing != isComposing || prevComposingText != composingText) {
      _notifyComposingChanged();
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (isComposing) return;
    final now = clock.now();
    _pruneExpiredClaims(now);
    for (final entry in _pendingClaimedKeys) {
      if (entry.isEnter && !entry.actionConsumed) {
        entry.actionConsumed = true;
        return;
      }
    }
    if (action == TextInputAction.newline ||
        action == TextInputAction.done ||
        action == TextInputAction.send ||
        action == TextInputAction.go ||
        action == TextInputAction.search) {
      _emitKeyEvent(const term.KeyEvent('\n', term.KeyType.enter));
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, Object?> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
    _clearComposingState();
  }

  void _clearComposingState() {
    if (_editingValue == TextEditingValue.empty) return;
    final hadComposing = isComposing;
    _editingValue = TextEditingValue.empty;
    if (hadComposing) {
      _notifyComposingChanged();
    }
  }

  void _notifyComposingChanged() {
    _onComposingChanged?.call();
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  void _emitKeyEvent(term.KeyEvent event) {
    final handler = _onKeyEvent ?? _boundOnKeyEvent;
    handler?.call(event);
  }

  void _emitCommittedText(String text) {
    final textHandler = _onTextInput ?? _boundOnTextInput;
    if (textHandler != null) {
      textHandler(text);
      return;
    }
    final keyHandler = _onKeyEvent ?? _boundOnKeyEvent;
    if (keyHandler == null) return;
    for (final grapheme in text.characters) {
      if (grapheme == '\n' || grapheme == '\r' || grapheme == '\r\n') {
        keyHandler(const term.KeyEvent('\n', term.KeyType.enter));
      } else {
        keyHandler(term.KeyEvent(grapheme, term.KeyType.character));
      }
    }
  }

  static bool _isValidNonCollapsed(TextRange range, int textLength) =>
      range.isValid &&
      !range.isCollapsed &&
      range.start >= 0 &&
      range.end <= textLength;

  static String _safeReplace(
    String text,
    String replacement,
    int start,
    int end,
  ) {
    final safeStart = start.clamp(0, text.length);
    final safeEnd = end.clamp(safeStart, text.length);
    return text.replaceRange(safeStart, safeEnd, replacement);
  }

  static TextSelection _rebaseSelection(
    TextSelection selection,
    int offsetDelta,
    int maxLength,
  ) {
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: maxLength);
    }
    return TextSelection(
      baseOffset: (selection.baseOffset - offsetDelta).clamp(0, maxLength),
      extentOffset: (selection.extentOffset - offsetDelta).clamp(0, maxLength),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  /// Releases any active [TextInputConnection] and clears listeners/pending claims.
  void dispose() {
    detach();
    clearSurfaceHandlers();
    _listeners.clear();
    _suppressedHostShortcutKeys.clear();
    _pendingClaimedKeys.clear();
  }
}
