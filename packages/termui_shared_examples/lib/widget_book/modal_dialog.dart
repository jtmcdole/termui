import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Example demonstrating a modal dialog overlay with a focus trap.
class ModalDialogExample extends WidgetBookExample {
  /// Whether the modal dialog is currently visible.
  bool showModalDemo = false;

  /// The result string after the modal is dismissed.
  String? modalResult;

  /// The focus node for the first button (Confirm).
  final modalBtn1Node = FocusNode(id: 'modalBtn1');

  /// The focus node for the second button (Cancel).
  final modalBtn2Node = FocusNode(id: 'modalBtn2');

  @override
  bool get hasActiveOverlay => showModalDemo;

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return Column([
      SizedBox(
        height: 1,
        child: Text(
          'Modal & Focus Trap Demo',
          style: const Style(
            foreground: CharmColors.charple,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 3,
        child: Text(
          'Press [Enter] to open a modal dialog overlay that traps focus between confirm/cancel buttons and dims the background.',
          style: const Style(foreground: CharmColors.soda),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          ' [ Press Enter to Open Modal ] ',
          style: const Style(
            foreground: CharmColors.pepper,
            background: CharmColors.julep,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          modalResult != null ? 'Result: $modalResult' : 'Result: None',
          style: const Style(
            foreground: CharmColors.charple,
            modifiers: Modifier.bold,
          ),
        ),
      ),
    ]);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.type == ui.KeyType.enter) {
      showModalDemo = true;
      modalBtn1Node.requestFocus();
      return true;
    }
    return false;
  }

  @override
  void renderOverlay(Buffer buffer, int width, int height) {
    if (!showModalDemo) return;

    final modal = ModalOverlay(
      title: 'Charm Modal Dialog',
      width: width,
      height: height,
      dialogBounds: Rect((width - 44) ~/ 2, (height - 8) ~/ 2, 44, 8),
      modalFocusNodes: [modalBtn1Node, modalBtn2Node],
      onDismiss: () {},
      child: Column([
        Expanded(
          child: Text(
            'This is a focus-trapped modal! Use Tab to cycle between buttons.',
            style: const Style(foreground: CharmColors.soda),
          ),
        ),
        SizedBox(
          height: 3,
          child: Row([
            const SizedBox(width: 4, child: Text('')),
            SizedBox(
              width: 13,
              child: Text(
                modalBtn1Node.isFocused
                    ? '             \n  ▶ Confirm  \n             '
                    : '             \n    Confirm  \n             ',
                style: Style(
                  foreground: modalBtn1Node.isFocused
                      ? CharmColors.pepper
                      : CharmColors.julep,
                  background: modalBtn1Node.isFocused
                      ? CharmColors.julep
                      : Colors.black,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
            const SizedBox(width: 8, child: Text('')),
            SizedBox(
              width: 13,
              child: Text(
                modalBtn2Node.isFocused
                    ? '             \n  ▶ Cancel   \n             '
                    : '             \n    Cancel   \n             ',
                style: Style(
                  foreground: modalBtn2Node.isFocused
                      ? CharmColors.pepper
                      : CharmColors.paprika,
                  background: modalBtn2Node.isFocused
                      ? CharmColors.paprika
                      : Colors.black,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
            const SizedBox(width: 4, child: Text('')),
          ]),
        ),
      ]),
    );
    final modalEl = modal.createElement()..mount(null);
    modalEl.layout(BoxConstraints.tight(Size(width, height)));
    modalEl.paint(buffer, Offset.zero);
    modalEl.unmount();
  }

  @override
  void handleOverlayKeyEvent(ui.KeyEvent event) {
    if (event.type == ui.KeyType.enter) {
      if (modalBtn1Node.isFocused) {
        modalResult = 'Confirmed';
      } else if (modalBtn2Node.isFocused) {
        modalResult = 'Cancelled';
      }
      showModalDemo = false;
      return;
    }

    if (event.key == 'escape') {
      showModalDemo = false;
      return;
    }

    if (event.key == '\t' || event.key == 'backtab') {
      final modal = ModalOverlay(
        title: 'Charm Modal Dialog',
        width: 80,
        height: 24,
        dialogBounds: Rect(0, 0, 44, 8),
        modalFocusNodes: [modalBtn1Node, modalBtn2Node],
        onDismiss: () {},
        child: const Text(''),
      );
      modal.onKeyEvent?.call(event);
    }
  }

  @override
  void handleOverlayMouseEvent(
    ui.MouseEvent event,
    int x,
    int y,
    int width,
    int height,
  ) {
    final dialogX = (width - 44) ~/ 2;
    final dialogY = (height - 8) ~/ 2;
    final localX = x - dialogX;
    final localY = y - dialogY;

    final modal = ModalOverlay(
      title: 'Charm Modal Dialog',
      width: width,
      height: height,
      dialogBounds: Rect(dialogX, dialogY, 44, 8),
      modalFocusNodes: [modalBtn1Node, modalBtn2Node],
      onDismiss: () {
        showModalDemo = false;
      },
      child: const Text(''),
    );

    if (event.type == ui.MouseEventType.press) {
      if (localX >= 5 && localX < 18 && localY >= 4 && localY <= 6) {
        // Clicked Confirm
        modalBtn1Node.requestFocus();
        modalResult = 'Confirmed';
        showModalDemo = false;
      } else if (localX >= 26 && localX < 39 && localY >= 4 && localY <= 6) {
        // Clicked Cancel
        modalBtn2Node.requestFocus();
        modalResult = 'Cancelled';
        showModalDemo = false;
      } else if (localX >= 0 && localX < 44 && localY >= 0 && localY < 8) {
        // Clicked inside modal dialog, do nothing
      } else {
        // Clicked outside modal dialog, dismiss
        showModalDemo = false;
      }
    } else {
      modal.onMouseEvent?.call(event, x, y);
    }
  }

  @override
  Map<String, String> get helpBindings => {'Enter': 'Open Modal Overlay'};
}
