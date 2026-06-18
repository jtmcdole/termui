import 'dart:math';
import 'package:characters/characters.dart';
import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../event.dart' hide Modifier;
import '../event.dart' as ev show Modifier;
import '../window.dart';
import 'focus.dart';

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
  final bool Function(KeyEvent event)? customOnKeyEvent;

  /// Creates a [ModalOverlay] widget that traps focus within its bounds.
  factory ModalOverlay({
    required String title,
    required int width,
    required int height,
    required Rect dialogBounds,
    required Widget child,
    required List<FocusNode> modalFocusNodes,
    void Function()? onDismiss,
    Style scrimStyle = const Style(modifiers: Modifier.dim),
    FocusScopeNode? focusNode,
    Style borderStyle = Style.empty,
    Style titleStyle = Style.empty,
    Style backgroundStyle = Style.empty,
    bool Function(KeyEvent event)? onKeyEvent,
  }) {
    final resolvedFocusNode = focusNode ?? FocusScopeNode(id: title);

    bool localHandleKeyEvent(KeyEvent event) {
      if (modalFocusNodes.isEmpty) {
        return onKeyEvent?.call(event) ?? false;
      }

      final isNext =
          event.key == 'tab' ||
          event.key == '\t' ||
          (event.type == KeyType.tab &&
              !event.modifiers.contains(ev.Modifier.shift)) ||
          event.type == KeyType.right ||
          event.key == 'right' ||
          event.type == KeyType.down ||
          event.key == 'down';

      final isPrev =
          event.key == 'backtab' ||
          (event.type == KeyType.tab &&
              event.modifiers.contains(ev.Modifier.shift)) ||
          event.type == KeyType.left ||
          event.key == 'left' ||
          event.type == KeyType.up ||
          event.key == 'up';

      if (isNext) {
        int currentIndex = -1;
        for (var i = 0; i < modalFocusNodes.length; i++) {
          if (modalFocusNodes[i].isFocused) {
            currentIndex = i;
            break;
          }
        }
        final nextIndex = (currentIndex + 1) % modalFocusNodes.length;
        modalFocusNodes[nextIndex].requestFocus();
        return true;
      } else if (isPrev) {
        int currentIndex = -1;
        for (var i = 0; i < modalFocusNodes.length; i++) {
          if (modalFocusNodes[i].isFocused) {
            currentIndex = i;
            break;
          }
        }
        final prevIndex =
            (currentIndex - 1 + modalFocusNodes.length) %
            modalFocusNodes.length;
        modalFocusNodes[prevIndex].requestFocus();
        return true;
      } else {
        return onKeyEvent?.call(event) ?? false;
      }
    }

    return ModalOverlay._(
      title: title,
      width: width,
      height: height,
      dialogBounds: dialogBounds,
      child: FocusScope(
        focusNode: resolvedFocusNode,
        onKeyEvent: localHandleKeyEvent,
        child: child,
      ),
      modalFocusNodes: modalFocusNodes,
      onDismiss: onDismiss,
      scrimStyle: scrimStyle,
      focusNode: resolvedFocusNode,
      borderStyle: borderStyle,
      titleStyle: titleStyle,
      backgroundStyle: backgroundStyle,
      onKeyEvent: onKeyEvent,
    );
  }

  ModalOverlay._({
    required super.title,
    required super.width,
    required super.height,
    required this.dialogBounds,
    required super.child,
    required this.modalFocusNodes,
    this.onDismiss,
    required this.scrimStyle,
    required FocusScopeNode focusNode,
    super.borderStyle = Style.empty,
    super.titleStyle = Style.empty,
    super.backgroundStyle = Style.empty,
    bool Function(KeyEvent event)? onKeyEvent,
  }) : customOnKeyEvent = onKeyEvent,
       super(
         focusNode: focusNode,
         borderChars: ['┌', '─', '┐', '│', ' ', '│', '└', '─', '┘'],
       );

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

    final isNext =
        event.key == 'tab' ||
        event.key == '\t' ||
        (event.type == KeyType.tab &&
            !event.modifiers.contains(ev.Modifier.shift)) ||
        event.type == KeyType.right ||
        event.key == 'right' ||
        event.type == KeyType.down ||
        event.key == 'down';

    final isPrev =
        event.key == 'backtab' ||
        (event.type == KeyType.tab &&
            event.modifiers.contains(ev.Modifier.shift)) ||
        event.type == KeyType.left ||
        event.key == 'left' ||
        event.type == KeyType.up ||
        event.key == 'up';

    if (isNext) {
      int currentIndex = -1;
      for (var i = 0; i < modalFocusNodes.length; i++) {
        if (modalFocusNodes[i].isFocused) {
          currentIndex = i;
          break;
        }
      }
      final nextIndex = (currentIndex + 1) % modalFocusNodes.length;
      modalFocusNodes[nextIndex].requestFocus();
    } else if (isPrev) {
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
  Element createElement() => ModalOverlayElement(this);
}

/// Element class corresponding to [ModalOverlay], managing layout and paint of the modal.
class ModalOverlayElement extends WindowElement {
  /// Instantiates the rendering element for the given ModalOverlay.
  ModalOverlayElement(ModalOverlay super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    final modal = widget as ModalOverlay;

    // Clear any previous focus from the modal nodes to ensure a fresh start
    for (final node in modal.modalFocusNodes) {
      node.unfocus();
    }

    // Safely attach focus children during mounting
    for (final node in modal.modalFocusNodes) {
      modal.focusNode.addChild(node);
    }

    // Always focus the first child node when mounting the modal
    if (modal.modalFocusNodes.isNotEmpty) {
      modal.modalFocusNodes.first.requestFocus();
    } else {
      modal.focusNode.requestFocus();
    }
  }

  @override
  void update(Widget newWidget) {
    final oldModal = widget as ModalOverlay;
    super.update(newWidget);
    final newModal = widget as ModalOverlay;

    // Synchronize children focus nodes if the nodes list changes
    if (!_listEquals(oldModal.modalFocusNodes, newModal.modalFocusNodes)) {
      for (final node in oldModal.modalFocusNodes) {
        oldModal.focusNode.removeChild(node);
      }
      for (final node in newModal.modalFocusNodes) {
        newModal.focusNode.addChild(node);
      }
    }
  }

  @override
  void unmount() {
    final modal = widget as ModalOverlay;
    // Detach focus children to prevent leaks
    for (final node in modal.modalFocusNodes) {
      modal.focusNode.removeChild(node);
    }
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final modal = widget as ModalOverlay;
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : modal.width;
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : modal.height;

    if (childElement != null) {
      childElement!.relativeOffset = Offset(
        modal.dialogBounds.x + 1,
        modal.dialogBounds.y + 1,
      );
      final childW = max(0, modal.dialogBounds.width - 2);
      final childH = max(0, modal.dialogBounds.height - 2);
      childElement!.layout(BoxConstraints.tight(Size(childW, childH)));
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final modal = widget as ModalOverlay;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // 1. Check/force focus to modal if it got lost/not set
    bool anyFocused = false;
    for (final node in modal.modalFocusNodes) {
      if (node.isFocused) {
        anyFocused = true;
        break;
      }
    }
    if (!anyFocused && modal.modalFocusNodes.isNotEmpty) {
      modal.modalFocusNodes.first.requestFocus();
    }

    // 2. Draw the background scrim (dimming the cells beneath the modal)
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final cell = buffer.getCell(offset.dx + x, offset.dy + y);
        if (cell != null) {
          final isInsideDialog =
              x >= modal.dialogBounds.x &&
              x < modal.dialogBounds.x + modal.dialogBounds.width &&
              y >= modal.dialogBounds.y &&
              y < modal.dialogBounds.y + modal.dialogBounds.height;
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
    final dialogX = offset.dx + modal.dialogBounds.x;
    final dialogY = offset.dy + modal.dialogBounds.y;
    final dw = modal.dialogBounds.width;
    final dh = modal.dialogBounds.height;

    if (dw < 2 || dh < 2) {
      for (var y = 0; y < dh; y++) {
        for (var x = 0; x < dw; x++) {
          final cell = buffer.getCell(dialogX + x, dialogY + y);
          if (cell != null) {
            cell.char = ' ';
            cell.style = modal.borderStyle;
          }
        }
      }
      return;
    }

    // Draw top border
    final topBorder =
        modal.borderChars[0] +
        modal.borderChars[1] * (dw - 2) +
        modal.borderChars[2];
    buffer.writeString(dialogX, dialogY, topBorder, modal.borderStyle);

    // Overlay title
    if (modal.title.isNotEmpty) {
      final titleChars = modal.title.characters;
      final maxTitleLen = dw - 4;
      String displayedTitle;
      if (titleChars.length > maxTitleLen) {
        final cutLen = dw - 7;
        if (cutLen > 0) {
          displayedTitle = ' ${titleChars.take(cutLen).toString()}... ';
        } else {
          displayedTitle = '';
        }
      } else {
        displayedTitle = ' ${modal.title} ';
      }

      if (displayedTitle.isNotEmpty) {
        final dispChars = displayedTitle.characters;
        final titleX = max(
          1,
          min(dw - 2, ((dw - dispChars.length) / 2).floor()),
        );
        buffer.writeString(
          dialogX + titleX,
          dialogY,
          displayedTitle,
          modal.titleStyle,
        );
      }
    }

    // Side borders
    for (var y = 1; y < dh - 1; y++) {
      buffer.writeString(
        dialogX,
        dialogY + y,
        modal.borderChars[3],
        modal.borderStyle,
      );
      buffer.writeString(
        dialogX + dw - 1,
        dialogY + y,
        modal.borderChars[5],
        modal.borderStyle,
      );
    }

    // Bottom border
    final bottomBorder =
        modal.borderChars[6] +
        modal.borderChars[7] * (dw - 2) +
        modal.borderChars[8];
    buffer.writeString(
      dialogX,
      dialogY + dh - 1,
      bottomBorder,
      modal.borderStyle,
    );

    // Render child content viewport
    final contentArea = Rect(dialogX + 1, dialogY + 1, dw - 2, dh - 2);
    final contentViewport = Viewport(buffer, contentArea);
    contentViewport.fill(Cell(' ', modal.backgroundStyle));

    if (childElement != null) {
      childElement!.paint(contentViewport, Offset.zero);
    }
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
