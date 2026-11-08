import 'dart:async';
import 'dart:math';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Defines keyboard inputs or signals that can terminate the prompt runner's execution.
enum PromptExitTrigger {
  /// Pressing the Enter key (carriage return `\r`, newline `\n`, or key string `'enter'`).
  enter,

  /// Pressing the Escape key (key string `'escape'`).
  escape,

  /// Pressing Ctrl+C (character code 3).
  controlC,

  /// Pressing Ctrl+D (character code 4, signifying EOF).
  controlD,
}

/// Defines the state outcome of the [PromptRunner] when an exit trigger is matched.
enum PromptExitAction {
  /// Resolves the prompt runner's future with the current value retrieved from [onComplete].
  complete,

  /// Resolves the prompt runner's future with `null`, signaling cancellation without error.
  cancel,

  /// Rejects the prompt runner's future by throwing a [PromptAbortedException].
  abort,
}

/// Defines the execution mode for the [PromptRunner].
enum ExecutionMode {
  /// The runner manages its own terminal event subscriptions, input handling, and terminal writing.
  standalone,

  /// The runner is controlled by an external manager, bypassing hardware hooks and direct terminal writing.
  managed,
}

/// Base exception thrown when a [PromptRunner] is aborted via [PromptExitAction.abort].
class PromptAbortedException implements Exception {
  /// The specific exit trigger that caused the abort.
  final PromptExitTrigger trigger;

  /// The raw key event that triggered the abort, if available.
  final term.KeyEvent? event;

  /// Descriptive message explaining why the runner aborted.
  final String message;

  /// Creates a new [PromptAbortedException].
  const PromptAbortedException({
    required this.trigger,
    this.event,
    this.message = 'Prompt runner aborted.',
  });

  @override
  String toString() =>
      'PromptAbortedException: $message (triggered by $trigger)';
}

/// Specialized exception for user keyboard interrupts (typically Ctrl+C).
class UserInterruptException extends PromptAbortedException {
  /// Creates a new [UserInterruptException].
  const UserInterruptException({
    super.event,
    super.message = 'User interrupted the prompt via Ctrl+C.',
  }) : super(trigger: PromptExitTrigger.controlC);
}

/// A helper class to run an interactive terminal prompt inline.
/// It encapsulates the event loop, rendering to an inline buffer, and lifecycle management.
///
/// Example:
/// ```dart
/// final name = await PromptRunner<String>(
///   terminal: terminal,
///   widget: Column([
///     const Text('Enter name:'),
///     TextField(controller: myController, focused: true),
///   ]),
///   exitConditions: {
///     PromptExitTrigger.enter: PromptExitAction.complete,
///     PromptExitTrigger.escape: PromptExitAction.cancel,
///   },
///   onComplete: () => myController.text,
/// ).run();
/// ```
class PromptRunner<T> implements ListenableSceneRenderer, Reassemblable {
  static final int _traceKeyEventId = Tracer.registerString(
    'PromptRunner:handleKeyEvent',
  );
  static final int _traceMouseEventId = Tracer.registerString(
    'PromptRunner:handleMouseEvent',
  );

  /// The active terminal instance.
  final term.Terminal terminal;

  Widget _widget;

  /// The root widget configuration to display.
  Widget get widget => _widget;
  set widget(Widget value) {
    if (_widget == value) return;
    _widget = value;
    final rootElement = _rootElement;
    if (rootElement == null) return;

    rootElement.update(_buildScopedWidget(_focusScopeNode, _completer));
    if (!alternateScreen && mode == ExecutionMode.standalone) {
      _computedHeight = _resolveInlineHeight(
        _width,
        fallbackHeight: terminal.backend.size.y,
      );
      _currentBuffer?.resize(_width, _computedHeight);
      _renderer = Renderer(_width, _computedHeight, mode: _renderingMode);
    }
    render();
  }

  int _resolveInlineHeight(int width, {required int fallbackHeight}) {
    final intrinsic = _widget.getIntrinsicHeight(width);
    return intrinsic >= BoxConstraints.infinity ? fallbackHeight : intrinsic;
  }

  RenderingMode get _renderingMode =>
      alternateScreen ? RenderingMode.alternateScreen : RenderingMode.inline;

  Widget _buildScopedWidget(
    FocusScopeNode scopeNode,
    Completer<T?>? completer,
  ) {
    return PromptScope(
      onDone: (result) {
        if (completer != null && !completer.isCompleted) {
          completer.complete(result is T? ? result : null);
        }
      },
      child: FocusScope(
        focusNode: scopeNode,
        autofocus: mode == ExecutionMode.standalone,
        child: _widget,
      ),
    );
  }

  /// An optional key event handler callback. Returns true if prompt is completed.
  final bool Function(term.KeyEvent event)? onKeyEvent;

  /// An optional paste event handler callback.
  final void Function(term.PasteEvent event)? onPasteEvent;

  /// An optional completion callback returning the final value of type [T].
  final T Function()? onComplete;

  /// Whether to render in alternate screen mode.
  final bool alternateScreen;

  /// Callback after each frame is painted onto the buffer.
  final void Function(Buffer buffer)? onFramePainted;

  /// Mapping of exit triggers to their corresponding actions.
  final Map<PromptExitTrigger, PromptExitAction> exitConditions;

  /// The execution mode of this runner.
  final ExecutionMode mode;

  /// Default exit conditions mapping.
  static const Map<PromptExitTrigger, PromptExitAction> defaultExitConditions =
      {
        PromptExitTrigger.controlC: PromptExitAction.abort,
        PromptExitTrigger.enter: PromptExitAction.complete,
      };

  /// Static hook called when a prompt runner starts running.
  static void Function(PromptRunner<Object?> runner)? onPromptStarted;

  /// Static hook called when a prompt runner ends/disposes.
  static void Function(PromptRunner<Object?> runner)? onPromptEnded;

  static final Set<FocusScopeNode> _activeRootScopes = {};

  FocusScopeNode _focusScopeNode = FocusScopeNode(id: 'prompt_runner_scope');

  Completer<T?>? _completer;
  Element? _rootElement;

  bool _isDisposed = false;
  void Function()? _onNeedVisualUpdate;

  /// Requests keyboard focus for this runner's root focus scope.
  void requestFocus() {
    if (_isDisposed) return;
    _focusScopeNode.requestFocus();
    scheduleMicrotask(() {
      if (_isDisposed) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null ||
          primary == _focusScopeNode ||
          _belongsToOtherRunnerScope(primary)) {
        _focusScopeNode.requestFocus();
      }
    });
  }

  bool _belongsToOtherRunnerScope(FocusNode node) {
    FocusNode? current = node;
    while (current != null) {
      if (current == _focusScopeNode) return false;
      if (_activeRootScopes.contains(current)) return true;
      current = current.parent;
    }
    return false;
  }

  @override
  void Function()? get onNeedVisualUpdate => _onNeedVisualUpdate;

  @override
  set onNeedVisualUpdate(void Function()? value) {
    _onNeedVisualUpdate = value;
  }

  @override
  bool get isDirty => _buildOwner?.isDirtyElements.isNotEmpty ?? false;

  /// Exposes whether a draw frame is currently scheduled.
  bool get hasScheduledFrame => _drawScheduled;

  Point<int>? _lastMousePosition;

  /// The last known mouse position coordinate.
  Point<int>? get lastMousePosition => _lastMousePosition;

  Element? _mouseCaptureElement;
  BuildOwner? _buildOwner;
  bool _drawScheduled = false;

  void _scheduleRender() {
    if (_isDisposed || _drawScheduled) return;
    _drawScheduled = true;
    scheduleMicrotask(() {
      if (_isDisposed || !_drawScheduled) return;
      _drawScheduled = false;
      render();
    });
  }

  Buffer? _currentBuffer;
  Renderer? _renderer;
  int _width = 0;
  int _computedHeight = 0;

  /// Exposes the root element of the mounted widget tree for testing.
  Element? get rootElement => _rootElement;

  /// Exposes whether the prompt runner is disposed.
  bool get isDisposed => _isDisposed;

  @override
  /// Exposes the current buffer containing the rendered output.
  Buffer? get currentBuffer => _currentBuffer;

  @override
  bool get wantsMouseTracking => debugPaintHoverEnabled;

  @override
  bool get wantsAlternateScreen => alternateScreen;

  @override
  bool get showsCursor => false;

  @override
  Point<int>? get requestedCursorPosition => null;

  /// Creates a new [PromptRunner].
  PromptRunner({
    required this.terminal,
    required Widget widget,
    Map<PromptExitTrigger, PromptExitAction>? exitConditions,
    this.onKeyEvent,
    this.onPasteEvent,
    this.onComplete,
    this.alternateScreen = false,
    this.onFramePainted,
    this.mode = ExecutionMode.standalone,
  }) : _widget = widget,
       exitConditions = exitConditions ?? defaultExitConditions;

  /// Public programmatic abort.
  void abort([Object? exception]) {
    if (_isDisposed) return;
    _isDisposed = true;
    _activeRootScopes.remove(_focusScopeNode);
    _rootElement?.unmount();
    _rootElement = null;
    _focusScopeNode.dispose();
    final activeCompleter = _completer;
    if (activeCompleter != null && !activeCompleter.isCompleted) {
      activeCompleter.completeError(
        exception ??
            const PromptAbortedException(
              trigger: PromptExitTrigger.controlC,
              message: 'Prompt runner aborted programmatically.',
            ),
      );
    }
  }

  /// Public programmatic dispose/cleanup.
  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _activeRootScopes.remove(_focusScopeNode);
    if (mode == ExecutionMode.standalone) {
      TermuiBinding.unregister(this);
    }
    onPromptEnded?.call(this);

    // Unmount element tree so focus nodes and states can clean up
    _rootElement?.unmount();
    _rootElement = null;
    _focusScopeNode.dispose();

    final activeCompleter = _completer;
    if (activeCompleter != null && !activeCompleter.isCompleted) {
      activeCompleter.complete(null);
    }

    onNeedVisualUpdate = null;
  }

  /// Helper to detect exit triggers case-insensitively.
  PromptExitTrigger? _detectTrigger(term.KeyEvent event) {
    // Check Ctrl+C (code unit 3 or character 'c' with control modifier)
    if ((event.key.length == 1 && event.key.codeUnits[0] == 3) ||
        (event.key.toLowerCase() == 'c' &&
            event.modifiers.contains(term.Modifier.control))) {
      return PromptExitTrigger.controlC;
    }

    // Check Ctrl+D (code unit 4 or character 'd' with control modifier)
    if ((event.key.length == 1 && event.key.codeUnits[0] == 4) ||
        (event.key.toLowerCase() == 'd' &&
            event.modifiers.contains(term.Modifier.control))) {
      return PromptExitTrigger.controlD;
    }

    // Check Escape
    if (event.key.toLowerCase() == 'escape' ||
        event.type == term.KeyType.escape) {
      return PromptExitTrigger.escape;
    }

    // Check Enter
    if (event.key.toLowerCase() == 'enter' ||
        event.type == term.KeyType.enter ||
        event.key == '\n' ||
        event.key == '\r') {
      return PromptExitTrigger.enter;
    }

    return null;
  }

  /// Helper to handle the matched exit trigger action.
  void _handleAction(PromptExitTrigger trigger, term.KeyEvent event) {
    final action = exitConditions[trigger];
    if (action == null) return;

    final comp = _completer;
    if (comp == null || comp.isCompleted) return;

    switch (action) {
      case PromptExitAction.complete:
        comp.complete(onComplete?.call());
        break;
      case PromptExitAction.cancel:
        comp.complete(null);
        break;
      case PromptExitAction.abort:
        final exception = trigger == PromptExitTrigger.controlC
            ? UserInterruptException(event: event)
            : PromptAbortedException(trigger: trigger, event: event);
        comp.completeError(exception);
        break;
    }
  }

  /// Recalculates layout and paints the widget tree to the internal buffer.
  @override
  void render() {
    if (_isDisposed) return;
    _drawScheduled = false;
    final rootElement = _rootElement;
    final buffer = _currentBuffer;
    if (rootElement == null || buffer == null) return;

    // Rebuild the element tree to consume any new state modifications.
    _buildOwner?.buildScope();

    buffer.clear();
    // Render the rebuilt element tree on our double buffer canvas.
    rootElement.layout(BoxConstraints.tight(Size(_width, _computedHeight)));
    rootElement.paint(buffer, Offset.zero);
    _paintDebugOverlays(buffer, rootElement);

    onFramePainted?.call(buffer);
    onNeedVisualUpdate?.call();

    if (mode == ExecutionMode.standalone) {
      _flushStandaloneBuffer(buffer);
    }
  }

  void _paintDebugOverlays(Buffer buffer, Element rootElement) {
    final pos = _lastMousePosition;
    if (pos == null) return;
    if (debugPaintHoverEnabled) {
      final hovered = _findHoveredElement(rootElement, pos);
      if (hovered != null) {
        _highlightHoveredElement(buffer, hovered);
      }
    }
    if (mode == ExecutionMode.standalone && debugMouseCursorEnabled) {
      const cursorStyle = Style(
        foreground: Color(0, 255, 255),
        modifiers: Modifier.bold,
      );
      buffer.writeString(pos.x - 1, pos.y - 1, '⦿', cursorStyle);
    }
  }

  void _flushStandaloneBuffer(Buffer buffer) {
    final b = terminal.backend;
    if (b is BufferedTerminalBackend) {
      b.buffer = buffer;
    }
    final sb = StringBuffer();
    _renderer?.render(buffer, sb);
    if (sb.isNotEmpty) {
      b.write(sb.toString());
    }
  }

  /// Forces a rebuild of the element tree and repaints to the internal buffer.
  void pump() {
    final rootElement = _rootElement;
    if (rootElement != null) {
      rootElement.markNeedsBuild();
    }
    render();
  }

  /// Called during hot reload to force the entire widget tree to rebuild and repaint.
  @override
  void reassemble() {
    _rootElement?.reassemble();
    _scheduleRender();
  }

  /// Starts the inline prompt loop and returns a Future containing the final result.
  Future<T?> run() async {
    onPromptStarted?.call(this);
    if (mode == ExecutionMode.standalone) {
      await _initStandaloneViewport();
    } else {
      _initManagedViewport();
    }

    StreamSubscription<Point<int>>? sizeSubscription;
    StreamSubscription<term.InputEvent>? subscription;
    final runScope = FocusScopeNode(id: 'prompt_runner_scope');

    try {
      final completer = Completer<T?>();
      final rootElement = _mountRunTree(runScope, completer);
      if (mode == ExecutionMode.standalone) {
        (sizeSubscription, subscription) = _attachStandaloneStreams(
          rootElement,
          completer,
        );
      }
      return await completer.future;
    } finally {
      _teardownRun(runScope, sizeSubscription, subscription);
    }
  }

  Future<void> _initStandaloneViewport() async {
    TermuiBinding.register(this);
    final termSize = await terminal.size;
    _width = termSize.x;
    _computedHeight = alternateScreen
        ? termSize.y
        : _resolveInlineHeight(_width, fallbackHeight: termSize.y);
    if (alternateScreen) {
      terminal.enterAlternateScreen();
    }
  }

  void _initManagedViewport() {
    if (_width <= 0) _width = 80;
    if (_computedHeight <= 0) {
      _computedHeight = _resolveInlineHeight(_width, fallbackHeight: 24);
    }
  }

  Element _mountRunTree(FocusScopeNode runScope, Completer<T?> completer) {
    _currentBuffer = Buffer.blank(_width, _computedHeight);
    _renderer = Renderer(_width, _computedHeight, mode: _renderingMode);
    _completer = completer;
    _isDisposed = false;
    _focusScopeNode = runScope;
    _activeRootScopes.add(runScope);

    final scopedWidget = _buildScopedWidget(runScope, completer);
    _buildOwner = BuildOwner(onNeedVisualUpdate: _scheduleRender);

    final rootElement = scopedWidget.createElement()
      ..owner = _buildOwner
      ..mount(null);
    _rootElement = rootElement;

    if (mode == ExecutionMode.standalone && debugPaintHoverEnabled) {
      terminal.enableMouseTracking();
    }
    rootElement.markNeedsBuild();
    render();
    return rootElement;
  }

  (StreamSubscription<Point<int>>, StreamSubscription<term.InputEvent>)
  _attachStandaloneStreams(Element rootElement, Completer<T?> completer) {
    final sizeSub = terminal.watchSize().listen((size) {
      if (_isDisposed) return;
      _width = size.x;
      _computedHeight = alternateScreen
          ? size.y
          : _resolveInlineHeight(_width, fallbackHeight: size.y);
      _currentBuffer?.resize(_width, _computedHeight);
      _renderer = Renderer(_width, _computedHeight, mode: _renderingMode);
      rootElement.markNeedsBuild();
      render();
    });

    final eventSub = terminal.events.listen(
      _handleStandaloneInput,
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
      onError: (Object e, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(e, stack);
      },
    );
    return (sizeSub, eventSub);
  }

  void _handleStandaloneInput(term.InputEvent event) {
    switch (event) {
      case final term.KeyEvent keyEvent:
        handleKeyEvent(keyEvent);
      case final term.MouseEvent mouseEvent:
        handleMouseEvent(mouseEvent);
      case final term.PasteEvent pasteEvent:
        handlePasteEvent(pasteEvent);
      case term.FocusInEvent() ||
          term.FocusOutEvent() ||
          term.CursorPositionReportEvent() ||
          term.KittyGraphicsEvent() ||
          term.KittyKeyboardEvent():
        break;
    }
  }

  void _teardownRun(
    FocusScopeNode runScope,
    StreamSubscription<Point<int>>? sizeSubscription,
    StreamSubscription<term.InputEvent>? subscription,
  ) {
    if (mode == ExecutionMode.standalone) {
      TermuiBinding.unregister(this);
    }
    final wasDisposedBefore = _isDisposed;
    _isDisposed = true;
    if (!wasDisposedBefore) {
      onPromptEnded?.call(this);
    }
    sizeSubscription?.cancel();
    subscription?.cancel();
    if (mode == ExecutionMode.standalone) {
      if (alternateScreen) terminal.exitAlternateScreen();
      terminal.showCursor();
      if (debugPaintHoverEnabled) terminal.disableMouseTracking();
    }
    _rootElement?.unmount();
    _rootElement = null;
    _activeRootScopes.remove(runScope);
    runScope.dispose();
  }

  /// Programmatically resizes the runner viewport and updates layout/buffers.
  @override
  void resize(int width, int height) {
    _width = width;
    _computedHeight = height;
    _currentBuffer?.resize(width, height);
    _renderer = Renderer(
      width,
      height,
      mode: alternateScreen
          ? RenderingMode.alternateScreen
          : RenderingMode.inline,
    );

    final rootElement = _rootElement;
    if (rootElement != null) {
      rootElement.markNeedsBuild();
    }
    render();
  }

  /// Recursively walks the element tree to find the focused element and route the key event.
  bool _routeKeyEvent(Element element, term.KeyEvent event) {
    if (event.eventType == term.KeyEventType.release) {
      return _routeKeyReleaseEvent(element, event);
    }
    if (_isElementFocused(element) &&
        _invokeElementKeyHandler(element, event)) {
      return true;
    }

    var childConsumed = false;
    element.visitChildren((child) {
      if (!childConsumed) {
        childConsumed = _routeKeyEvent(child, event);
      }
    });
    return childConsumed;
  }

  bool _routeKeyReleaseEvent(Element rootElement, term.KeyEvent event) =>
      _routeReleaseToFocusTree(rootElement, event) ||
      _routeReleaseToLegacyHandlers(rootElement, event);

  bool _routeReleaseToFocusTree(Element element, term.KeyEvent event) {
    var childConsumed = false;
    element.visitChildren((child) {
      if (!childConsumed) {
        childConsumed = _routeReleaseToFocusTree(child, event);
      }
    });
    if (childConsumed) return true;
    if (!_elementWantsKeyRelease(element)) return false;
    if (element case StatefulElement(state: final FocusState focusState)) {
      return focusState.focusNode.hasFocus &&
          (focusState.focusNode.onKeyEvent?.call(event) ?? false);
    }
    return false;
  }

  bool _routeReleaseToLegacyHandlers(Element element, term.KeyEvent event) {
    if (_elementWantsKeyRelease(element) &&
        _isElementFocused(element) &&
        _invokeElementKeyHandler(element, event)) {
      return true;
    }
    var childConsumed = false;
    element.visitChildren((child) {
      if (!childConsumed) {
        childConsumed = _routeReleaseToLegacyHandlers(child, event);
      }
    });
    return childConsumed;
  }

  static bool _elementWantsKeyRelease(Element element) =>
      element.widget.wantsKeyReleaseEvents ||
      (element.parent?.widget.wantsKeyReleaseEvents ?? false);

  static bool _isElementFocused(Element element) {
    if (element.widget case final Focusable focusable when focusable.focused) {
      return true;
    }
    if (element case StatefulElement(state: final Focusable focusable)) {
      return focusable.focused;
    }
    return false;
  }

  static bool _invokeElementKeyHandler(Element element, term.KeyEvent event) {
    if (element case StatefulElement(state: final KeyEventHandler handler)) {
      return handler.handleKeyEvent(event);
    }
    if (element.widget case final KeyEventHandler handler) {
      return handler.handleKeyEvent(event);
    }
    return false;
  }

  /// Recursively walks the element tree to route a mouse event spatially.
  bool _routeMouseEvent(
    Element element,
    term.MouseEvent event,
    Offset parentOffset,
  ) {
    final absOffset = parentOffset + element.relativeOffset;
    final sx = event.x - 1;
    final sy = event.y - 1;
    final inside = _isInsideElement(sx, sy, absOffset, element.size);
    final broadcast = _isBroadcastMouseType(event.type);
    if (!inside && !broadcast) return false;

    final localX = sx - absOffset.dx;
    final localY = sy - absOffset.dy;
    if (_absorbsPointer(element, inside)) {
      _routeToElement(element, event, localX, localY);
      return true;
    }

    final childConsumed = _routeMouseToChildren(
      element,
      event,
      absOffset,
      broadcast: broadcast,
    );
    if (childConsumed && inside) return true;

    if (_routeToElement(element, event, localX, localY)) {
      if (event.type == term.MouseEventType.press) {
        _mouseCaptureElement = element;
      }
      return inside;
    }
    return false;
  }

  static bool _isInsideElement(int sx, int sy, Offset offset, Size size) =>
      sx >= offset.dx &&
      sx < offset.dx + size.width &&
      sy >= offset.dy &&
      sy < offset.dy + size.height;

  static bool _isBroadcastMouseType(term.MouseEventType type) =>
      type == term.MouseEventType.move ||
      type == term.MouseEventType.drag ||
      type == term.MouseEventType.release;

  static bool _absorbsPointer(Element element, bool inside) =>
      inside &&
      element is AbsorbPointerElement &&
      (element.widget as AbsorbPointer).absorbing;

  bool _routeMouseToChildren(
    Element element,
    term.MouseEvent event,
    Offset absOffset, {
    required bool broadcast,
  }) {
    final children = <Element>[];
    element.visitChildren(children.add);

    var childConsumed = false;
    for (final child in children.reversed) {
      if (_routeMouseEvent(child, event, absOffset)) {
        childConsumed = true;
        if (!broadcast) break;
      }
    }
    return childConsumed;
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    Tracer.record(
      _traceKeyEventId,
      Phase.begin,
      TraceCategory.events,
      metadata: {'key': event.traceKey},
    );
    try {
      final completer = _completer;
      final rootElement = _rootElement;
      if (completer == null || completer.isCompleted || rootElement == null) {
        return false;
      }

      if (event.eventType == term.KeyEventType.release) {
        final handled = _routeKeyReleaseEvent(rootElement, event);
        if (handled) rootElement.markNeedsBuild();
        return handled;
      }

      if (_handleDebugToggle(event)) return true;

      final isDone =
          (onKeyEvent?.call(event) ?? false) ||
          _dispatchKeyToFocusedTree(rootElement, event);
      if (!isDone && _evaluateExitTrigger(event)) {
        return true;
      }
      if (isDone) {
        rootElement.markNeedsBuild();
      }
      return isDone;
    } finally {
      Tracer.record(_traceKeyEventId, Phase.end, TraceCategory.events);
    }
  }

  bool _handleDebugToggle(term.KeyEvent event) {
    if (debugToggleKey == null || event != debugToggleKey) return false;
    debugShowTouchesEnabled = !debugShowTouchesEnabled;
    debugPaintHoverEnabled = !debugPaintHoverEnabled;
    debugMouseCursorEnabled = !debugMouseCursorEnabled;
    debugPaintLayerBordersEnabled = !debugPaintLayerBordersEnabled;

    if (mode == ExecutionMode.standalone) {
      if (debugPaintHoverEnabled) {
        terminal.enableMouseTracking();
      } else {
        terminal.disableMouseTracking();
      }
    }
    _scheduleRender();
    return true;
  }

  bool _dispatchKeyToFocusedTree(Element rootElement, term.KeyEvent event) {
    var primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null && _belongsToOtherRunnerScope(primaryFocus)) {
      _focusScopeNode.requestFocus();
      primaryFocus = FocusManager.instance.primaryFocus;
    }
    final focusTarget =
        (primaryFocus != null && !_belongsToOtherRunnerScope(primaryFocus))
        ? primaryFocus
        : _focusScopeNode;
    return focusTarget.bubbleKeyEvent(event) ||
        _routeKeyEvent(rootElement, event);
  }

  bool _evaluateExitTrigger(term.KeyEvent event) {
    final trigger = _detectTrigger(event);
    if (trigger == null || !exitConditions.containsKey(trigger)) return false;
    _handleAction(trigger, event);
    return true;
  }

  @override
  bool handleMouseEvent(term.MouseEvent event) {
    Tracer.record(_traceMouseEventId, Phase.begin, TraceCategory.events);
    try {
      final completer = _completer;
      if (completer == null || completer.isCompleted) return false;

      _lastMousePosition = Point<int>(event.x, event.y);
      var isDone = false;
      final rootElement = _rootElement;
      if (rootElement == null) return false;

      if (_mouseCaptureElement != null &&
          (event.type == term.MouseEventType.drag ||
              event.type == term.MouseEventType.release)) {
        final captureElement = _mouseCaptureElement!;
        final absOffset = _getAbsoluteOffset(captureElement);
        final sx = event.x - 1;
        final sy = event.y - 1;
        final localX = sx - absOffset.dx;
        final localY = sy - absOffset.dy;

        isDone = _routeToElement(captureElement, event, localX, localY);

        if (event.type == term.MouseEventType.release) {
          _mouseCaptureElement = null;
        }
      } else {
        isDone = _routeMouseEvent(rootElement, event, Offset.zero);
      }

      if (isDone || debugPaintHoverEnabled) {
        _scheduleRender();
      }

      return isDone;
    } finally {
      Tracer.record(_traceMouseEventId, Phase.end, TraceCategory.events);
    }
  }

  /// Handles bracketed paste events.
  @override
  bool handlePasteEvent(term.PasteEvent event) {
    if (onPasteEvent != null) {
      onPasteEvent!(event);
    }
    for (final char in event.text.characters) {
      handleKeyEvent(term.KeyEvent(char, term.KeyType.character));
    }
    return true;
  }
}

/// Extension on [term.Terminal] to print a widget inline using the double-buffered renderer layout.
extension PrintWidgetExtension on term.Terminal {
  /// Renders and prints the given [widget] to standard output at the current inline cursor position.
  void printWidget(Widget widget) {
    var width = backend.size.x;
    if (width <= 0) {
      width = 80;
    }

    final height = widget.getIntrinsicHeight(width);

    final buffer = Buffer.blank(width, height);
    final element = widget.createElement();
    element.mount(null);
    element.layout(BoxConstraints.tight(Size(width, height)));
    element.paint(buffer, Offset.zero);
    element.unmount();

    final renderer = Renderer(width, height, mode: RenderingMode.inline);
    final sb = StringBuffer();
    renderer.render(buffer, sb);
    if (sb.isNotEmpty) {
      backend.write(sb.toString());
    }
  }
}

/// An inherited widget that abstracts prompt completion and lifecycle controls,
/// shielding descendant widgets from any low-level/internal event buses.
///
/// Example:
/// ```dart
/// class MySubmitButton extends Widget {
///   @override
///   void render(Buffer buffer, Rect area) { ... }
///
///   bool handleKeyEvent(KeyEvent event) {
///     if (event.key == 'enter') {
///       PromptScope.of(context)?.done('submitted_value');
///       return true;
///     }
///     return false;
///   }
/// }
/// ```
class PromptScope extends InheritedWidget {
  /// The callback invoked to signal completion to the parent [PromptRunner].
  final void Function(Object? result) _onDone;

  /// Creates a [PromptScope] with the given [onDone] callback and [child].
  const PromptScope({
    required void Function(Object? result) onDone,
    required super.child,
  }) : _onDone = onDone;

  /// Obtains the nearest [PromptScope] from the build context.
  static PromptScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PromptScope>();
  }

  /// Programmatically completes the current prompt, returning an optional [result].
  ///
  /// This signals the managing [PromptRunner] to stop its run loop, teardown
  /// its resources, and resolve the Future returned by [PromptRunner.run] with [result].
  ///
  /// Subsequent calls to this method after the prompt has already completed are safe no-ops.
  void done([Object? result]) {
    _onDone(result);
  }

  @override
  bool updateShouldNotify(PromptScope oldWidget) => false;
}

void _drawBoxOutline(Buffer buffer, Offset offset, Size size, Style style) {
  final ox = offset.dx;
  final oy = offset.dy;
  final w = size.width;
  final h = size.height;

  if (w <= 0 || h <= 0) return;

  if (w == 1 && h == 1) {
    _safeSetCell(buffer, ox, oy, '¤', style);
    return;
  }

  // Draw horizontal edges
  for (var x = ox + 1; x < ox + w - 1; x++) {
    _safeSetCell(buffer, x, oy, '─', style);
    _safeSetCell(buffer, x, oy + h - 1, '─', style);
  }

  // Draw vertical edges
  for (var y = oy + 1; y < oy + h - 1; y++) {
    _safeSetCell(buffer, ox, y, '│', style);
    _safeSetCell(buffer, ox + w - 1, y, '│', style);
  }

  // Draw corners
  _safeSetCell(buffer, ox, oy, '┌', style);
  if (w > 1) {
    _safeSetCell(buffer, ox + w - 1, oy, '┐', style);
  }
  if (h > 1) {
    _safeSetCell(buffer, ox, oy + h - 1, '└', style);
  }
  if (w > 1 && h > 1) {
    _safeSetCell(buffer, ox + w - 1, oy + h - 1, '┘', style);
  }
}

void _safeSetCell(Buffer buffer, int x, int y, String char, Style style) {
  buffer.setAttributes(
    x,
    y,
    char: char,
    fg: style.foreground?.argb ?? 0,
    bg: style.background?.argb ?? 0,
    modifiers: style.modifiers,
  );
}

Element? _findHoveredElement(
  Element rootElement,
  Point<int>? lastMousePosition,
) {
  if (lastMousePosition == null) return null;
  return _findDeepestElementAt(rootElement, Offset.zero, lastMousePosition);
}

Element? _findDeepestElementAt(
  Element element,
  Offset absoluteOffset,
  Point<int> mousePos,
) {
  final px = mousePos.x - 1;
  final py = mousePos.y - 1;

  final ox = absoluteOffset.dx;
  final oy = absoluteOffset.dy;
  final w = element.size.width;
  final h = element.size.height;

  if (px < ox || px >= ox + w || py < oy || py >= oy + h) {
    return null;
  }

  final children = <Element>[];
  element.visitChildren(children.add);

  for (var i = children.length - 1; i >= 0; i--) {
    final child = children[i];
    final childOffset = absoluteOffset + child.relativeOffset;
    final childDeepest = _findDeepestElementAt(child, childOffset, mousePos);
    if (childDeepest != null) {
      return childDeepest;
    }
  }

  return children.isEmpty ? element : null;
}

Offset _getAbsoluteOffset(Element element) {
  var offset = Offset.zero;
  Element? current = element;
  while (current != null) {
    offset = offset + current.relativeOffset;
    current = current.parent;
  }
  return offset;
}

void _highlightHoveredElement(Buffer buffer, Element element) {
  if (element.size.width <= 0 || element.size.height <= 0) return;
  final offset = _getAbsoluteOffset(element);

  final left = offset.dx - 1;
  final top = offset.dy - 1;
  final right = offset.dx + element.size.width;
  final bottom = offset.dy + element.size.height;

  final expandedOffset = Offset(left, top);
  final expandedSize = Size(right - left + 1, bottom - top + 1);

  const style = Style(
    foreground: Color(255, 0, 255), // Magenta
    modifiers: Modifier.bold,
  );

  _drawBoxOutline(buffer, expandedOffset, expandedSize, style);

  final typeName = '${element.widget.runtimeType}';
  final label = ' $typeName ';

  const labelStyle = Style(
    foreground: Color(255, 255, 255), // White
    background: Color(255, 0, 255), // Magenta
    modifiers: Modifier.bold,
  );

  final badgeY = (bottom >= buffer.height - 1) ? max(0, top) : bottom;
  final maxBadgeX = max(0, buffer.width - label.length);
  final badgeX = (left + 1).clamp(0, maxBadgeX);

  buffer.writeString(badgeX, badgeY, label, labelStyle);
}

bool _routeToElement(
  Element element,
  term.MouseEvent event,
  int localX,
  int localY,
) {
  final area = Rect(0, 0, element.size.width, element.size.height);

  bool tryRoute(Object handler) {
    if (handler case final MouseEventHandlerWithArea h) {
      h.handleMouseEvent(event, localX, localY, area);
      return true;
    }
    if (handler case final MouseEventHandler h) {
      h.handleMouseEvent(event, localX, localY);
      return true;
    }
    return false;
  }

  if (element is StatefulElement && tryRoute(element.state)) {
    return true;
  }
  if (tryRoute(element)) {
    return true;
  }
  if (tryRoute(element.widget)) {
    return true;
  }

  return false;
}

/// Defines sizing policies for layout layers in a compositing scene.
enum LayerSizing {
  /// Matches the dimensions of the terminal screen/viewport.
  fullscreen,

  /// Calculates dimensions dynamically based on child widget intrinsic height and width.
  intrinsic,

  /// Uses hardcoded dimensions.
  fixed,
}

/// A contract defining terminal state requests from a runner or layer.
abstract interface class TerminalStateRequest {
  /// Whether mouse tracking features are requested.
  bool get wantsMouseTracking;

  /// Whether alternate screen buffer mode is requested.
  bool get wantsAlternateScreen;

  /// Whether the hardware terminal cursor should be shown.
  bool get showsCursor;

  /// The requested cursor coordinates, if any.
  Point<int>? get requestedCursorPosition;
}

/// An interface representing a rendering system in a composited scene.
abstract interface class SceneRenderer implements TerminalStateRequest {
  /// The current rendering output buffer.
  Buffer? get currentBuffer;

  /// Handles key events routed to this renderer. Returns true if handled.
  bool handleKeyEvent(term.KeyEvent event);

  /// Handles mouse events routed to this renderer. Returns true if the event was consumed.
  bool handleMouseEvent(term.MouseEvent event);

  /// Handles paste events routed to this renderer. Returns true if the event was consumed.
  ///
  /// Native bracketed pastes exceeding [term.InputParser.maxPasteBytes] arrive
  /// as consecutive UTF-8 character-aligned [term.PasteEvent] chunks.
  bool handlePasteEvent(term.PasteEvent event);

  /// Resizes the renderer viewport and updates layout/buffers.
  void resize(int width, int height);

  /// Cleans up resources.
  void dispose();
}

/// An interface for [SceneRenderer]s that can notify their manager when they need a visual update.
abstract interface class ListenableSceneRenderer implements SceneRenderer {
  /// Callback triggered when this renderer's visual content changes and needs to be composited/repainted.
  void Function()? get onNeedVisualUpdate;
  set onNeedVisualUpdate(void Function()? value);

  /// Whether the renderer needs a visual rebuild/update.
  bool get isDirty;

  /// Forces a rebuild/paint of the renderer.
  void render();
}

/// Represents a single renderable layer inside a composited terminal scene.
class SceneLayer {
  /// The renderer managing this layer.
  final SceneRenderer renderer;

  /// The sizing policy for this layer.
  final LayerSizing sizing;

  /// The horizontal column coordinate of the layer's top-left corner.
  int x;

  /// The vertical row coordinate of the layer's top-left corner.
  int y;

  /// The width of this layer, if fixed.
  int? width;

  /// The height of this layer, if fixed.
  int? height;

  /// The stacking order index of the layer.
  int zIndex;

  /// Whether this layer is draggable via mouse click-and-drag.
  bool draggable;

  /// Whether this layer can be resized by dragging its corners.
  bool resizable;

  /// Whether this layer receives mouse events. If false, mouse events pass through to layers below.
  bool hitTestable;

  /// Whether visually opaque pixels in this layer explicitly intercept mouse clicks even if they aren't handled by widgets.
  bool mouseOpaque;

  /// Callback when the layer's size changes (typically for draggable/resizable).
  void Function(Point<int> newSize)? onResize;

  /// Callback when the layer gains focus.
  void Function()? onFocus;

  /// Creates a new [SceneLayer] with the given [renderer], [sizing], and placement parameters.
  SceneLayer({
    required this.renderer,
    this.sizing = LayerSizing.fixed,
    this.x = 0,
    this.y = 0,
    this.width,
    this.height,
    this.zIndex = 0,
    this.draggable = false,
    this.resizable = false,
    this.hitTestable = true,
    this.mouseOpaque = false,
    this.onResize,
    this.onFocus,
  }) {
    if (sizing == LayerSizing.fixed && width != null && height != null) {
      renderer.resize(width!, height!);
    }
  }
}
