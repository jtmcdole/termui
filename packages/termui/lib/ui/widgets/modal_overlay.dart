import 'dart:math';
import 'package:characters/characters.dart';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../event.dart' hide Modifier;
import '../event.dart' as ev show Modifier;
import '../window.dart';

/// A specialized, high Z-index container that traps focus and intercepts mouse events.
class ModalOverlay extends Window {
  /// The physical bounding box of the central dialog.
  final Rect dialogBounds;

  /// The list of child focus nodes managed by this modal.
  final List<FocusNode> modalFocusNodes;

  /// A callback invoked when the user attempts to dismiss the modal (e.g. clicking outside).
  final void Function()? onDismiss;

  /// The styling for the dimming overlay behind the dialog.
  final Style scrimStyle;

  /// An optional custom key event handler for unhandled events in the modal.
  final void Function(KeyEvent event)? customOnKeyEvent;

  /// Creates a [ModalOverlay] widget that traps focus within its bounds.
  ModalOverlay({
    required super.title,
    required super.bounds,
    required this.dialogBounds,
    required super.child,
    required this.modalFocusNodes,
    this.onDismiss,
    this.scrimStyle = const Style(modifiers: Modifier.dim),
    super.focusNode,
    super.zIndex = 10,
    void Function(KeyEvent event)? onKeyEvent,
  }) : customOnKeyEvent = onKeyEvent,
       super(borderChars: ['┌', '─', '┐', '│', ' ', '│', '└', '─', '┘']) {
    for (final node in modalFocusNodes) {
      focusNode.addChild(node);
    }
    bool anyFocused = false;
    for (final node in modalFocusNodes) {
      if (node.isFocused) {
        anyFocused = true;
        break;
      }
    }
    if (!anyFocused && modalFocusNodes.isNotEmpty) {
      modalFocusNodes.first.requestFocus();
    }
  }

  @override
  void Function(MouseEvent event, int localX, int localY)? get onMouseEvent =>
      _handleMouseEvent;

  void _handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      final isInside =
          localX >= dialogBounds.x &&
          localX < dialogBounds.x + dialogBounds.width &&
          localY >= dialogBounds.y &&
          localY < dialogBounds.y + dialogBounds.height;
      if (!isInside) {
        onDismiss?.call();
      }
    }
  }

  @override
  void Function(KeyEvent event)? get onKeyEvent => _handleKeyEvent;

  void _handleKeyEvent(KeyEvent event) {
    if (modalFocusNodes.isEmpty) {
      customOnKeyEvent?.call(event);
      return;
    }

    if (event.key == 'tab' || event.key == '\t') {
      int currentIndex = -1;
      for (var i = 0; i < modalFocusNodes.length; i++) {
        if (modalFocusNodes[i].isFocused) {
          currentIndex = i;
          break;
        }
      }
      final nextIndex = (currentIndex + 1) % modalFocusNodes.length;
      modalFocusNodes[nextIndex].requestFocus();
    } else if (event.key == 'backtab' ||
        (event.type == KeyType.tab &&
            event.modifiers.contains(ev.Modifier.shift))) {
      int currentIndex = -1;
      for (var i = 0; i < modalFocusNodes.length; i++) {
        if (modalFocusNodes[i].isFocused) {
          currentIndex = i;
          break;
        }
      }
      final prevIndex =
          (currentIndex - 1 + modalFocusNodes.length) % modalFocusNodes.length;
      modalFocusNodes[prevIndex].requestFocus();
    } else {
      customOnKeyEvent?.call(event);
    }
  }

  @override
  bool isPositionOnTitle(int localX, int localY) {
    if (localY != dialogBounds.y || title.isEmpty) return false;
    final w = dialogBounds.width;
    if (w < 2) return false;

    final titleChars = title.characters;
    final maxTitleLen = w - 4;
    String displayedTitle;
    if (titleChars.length > maxTitleLen) {
      final cutLen = w - 7;
      if (cutLen > 0) {
        displayedTitle = ' ${titleChars.take(cutLen).toString()}... ';
      } else {
        displayedTitle = '';
      }
    } else {
      displayedTitle = ' $title ';
    }

    if (displayedTitle.isEmpty) return false;
    final dispChars = displayedTitle.characters;
    final titleX =
        dialogBounds.x +
        max(1, min(w - 2, ((w - dispChars.length) / 2).floor()));
    return localX >= titleX && localX < titleX + dispChars.length;
  }

  @override
  void render(Buffer buffer, Rect area) {
    if (bounds.width <= 0 || bounds.height <= 0) return;

    // 1. Check/force focus to modal if it got lost/not set
    bool anyFocused = false;
    for (final node in modalFocusNodes) {
      if (node.isFocused) {
        anyFocused = true;
        break;
      }
    }
    if (!anyFocused && modalFocusNodes.isNotEmpty) {
      modalFocusNodes.first.requestFocus();
    }

    // 2. Draw the background scrim (dimming the cells beneath the modal)
    for (var y = 0; y < bounds.height; y++) {
      for (var x = 0; x < bounds.width; x++) {
        final cell = buffer.getCell(bounds.x + x, bounds.y + y);
        if (cell != null) {
          final isInsideDialog =
              x >= dialogBounds.x &&
              x < dialogBounds.x + dialogBounds.width &&
              y >= dialogBounds.y &&
              y < dialogBounds.y + dialogBounds.height;
          if (!isInsideDialog) {
            cell.style = Style(
              foreground: cell.style.foreground,
              background: cell.style.background,
              modifiers: cell.style.modifiers | Modifier.dim,
            );
          }
        }
      }
    }

    // 3. Draw the central dialog box inside dialogBounds
    final originalBounds = bounds;
    bounds = dialogBounds;
    super.render(buffer, area);
    bounds = originalBounds;
  }
}
