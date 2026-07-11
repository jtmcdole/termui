import 'dart:math';
import 'package:termui/termui.dart';

/// Represents an active drag session.
class DragSession {
  /// The payload data being dragged.
  final Object data;

  /// The element that initiated the drag.
  final Element sourceElement;

  /// The initial mouse position when the drag started.
  final Point<int> startMousePosition;

  /// The current mouse position of the drag pointer.
  Point<int> currentMousePosition;

  /// Creates a [DragSession] instance.
  DragSession({
    required this.data,
    required this.sourceElement,
    required this.startMousePosition,
    required this.currentMousePosition,
  });
}

/// Global coordinator for handling in-terminal drag and drop sessions.
class DragDropManager {
  static DragSession? _activeSession;
  static DragTargetElement? _lastHoveredTarget;

  /// Hook triggered whenever the active drag session changes.
  static void Function(DragSession? session)? onDragSessionChanged;

  /// Exposes the currently active drag session, if any.
  static DragSession? get activeSession => _activeSession;

  /// Starts a new drag session.
  static void startDrag(DragSession session) {
    _activeSession = session;
    onDragSessionChanged?.call(session);
  }

  /// Cancels the current drag session.
  static void cancelDrag() {
    final target = _lastHoveredTarget;
    if (target != null) {
      if (target.mounted) {
        target.handleDragLeave(_activeSession);
      }
      _lastHoveredTarget = null;
    }
    _activeSession = null;
    onDragSessionChanged?.call(null);
  }

  /// Updates the mouse coordinate of the active drag session and triggers dropzone hit testing.
  static void updateDrag(Point<int> mousePosition) {
    final session = _activeSession;
    if (session == null) return;

    if (!session.sourceElement.mounted) {
      cancelDrag();
      return;
    }

    session.currentMousePosition = mousePosition;

    // Find the topmost DragTargetElement under the mouse cursor
    final root = _findRoot(session.sourceElement);
    if (root == null || !root.mounted) return;

    final hitElements = root.hitTest(mousePosition);
    final hoveredTarget = hitElements
        .whereType<DragTargetElement>()
        .firstOrNull;

    if (hoveredTarget != _lastHoveredTarget) {
      final lastTarget = _lastHoveredTarget;
      if (lastTarget != null && lastTarget.mounted) {
        lastTarget.handleDragLeave(session);
      }
      if (hoveredTarget != null && hoveredTarget.mounted) {
        hoveredTarget.handleDragEnter(session);
      }
      _lastHoveredTarget = hoveredTarget;
    }

    if (hoveredTarget != null && hoveredTarget.mounted) {
      hoveredTarget.handleDragOver(session);
    }
    onDragSessionChanged?.call(session);
  }

  /// Drops the active session payload onto the hovered target and resets session state.
  static void drop() {
    final session = _activeSession;
    final target = _lastHoveredTarget;
    if (session != null &&
        session.sourceElement.mounted &&
        target != null &&
        target.mounted) {
      target.handleDrop(session);
    }
    cancelDrag();
  }

  /// Clears references to the given target element if it is currently tracked.
  static void unregisterTarget(DragTargetElement target) {
    if (_lastHoveredTarget == target) {
      _lastHoveredTarget = null;
    }
  }

  /// Clears references to the given source element if it is currently tracked.
  static void unregisterSource(Element source) {
    if (_activeSession?.sourceElement == source) {
      cancelDrag();
    }
  }

  static Element? _findRoot(Element element) {
    var current = element;
    while (current.parent != null) {
      current = current.parent!;
    }
    return current;
  }
}
