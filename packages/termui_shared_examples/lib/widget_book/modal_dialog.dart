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

  /// The focus scope node for the modal overlay.
  final modalScopeNode = FocusScopeNode(id: 'modalScope');

  @override
  bool get hasActiveOverlay => false;

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return ModalDialogDemoWidget(example: this, width: width, height: height);
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
  void renderOverlay(Buffer buffer, int width, int height) {}

  @override
  void handleOverlayKeyEvent(ui.KeyEvent event) {}

  @override
  void handleOverlayMouseEvent(
    ui.MouseEvent event,
    int x,
    int y,
    int width,
    int height,
  ) {}

  @override
  Map<String, String> get helpBindings => {'Enter': 'Open Modal Overlay'};
}

/// A demo widget presenting the modal dialog layout, styling, and key interaction.
class ModalDialogDemoWidget extends StatefulWidget {
  /// The parent example instance containing state and focus node definitions.
  final ModalDialogExample example;

  /// Layout width constraints.
  final int width;

  /// Layout height constraints.
  final int height;

  /// Creates a [ModalDialogDemoWidget].
  const ModalDialogDemoWidget({
    required this.example,
    required this.width,
    required this.height,
  });

  @override
  State<ModalDialogDemoWidget> createState() => _ModalDialogDemoWidgetState();
}

class _ModalDialogDemoWidgetState extends State<ModalDialogDemoWidget> {
  void _onFocusChange(bool hasFocus) {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final mainContent = Column([
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
          widget.example.modalResult != null
              ? 'Result: ${widget.example.modalResult}'
              : 'Result: None',
          style: const Style(
            foreground: CharmColors.charple,
            modifiers: Modifier.bold,
          ),
        ),
      ),
    ]);

    if (!widget.example.showModalDemo) {
      return mainContent;
    }

    final dialogW = 44;
    final dialogH = 8;
    final dialogX = (widget.width - dialogW) ~/ 2;
    final dialogY = (widget.height - dialogH) ~/ 2;

    return Stack([
      Positioned(
        left: 0,
        top: 0,
        width: widget.width,
        height: widget.height,
        child: mainContent,
      ),
      Positioned(
        left: 0,
        top: 0,
        width: widget.width,
        height: widget.height,
        child: ModalOverlay(
          title: 'Charm Modal Dialog',
          width: widget.width,
          height: widget.height,
          dialogBounds: Rect(dialogX, dialogY, dialogW, dialogH),
          focusNode: widget.example.modalScopeNode,
          modalFocusNodes: [
            widget.example.modalBtn1Node,
            widget.example.modalBtn2Node,
          ],
          borderStyle: const Style(
            foreground: CharmColors.charple,
            background: CharmColors.bbq,
          ),
          titleStyle: const Style(
            foreground: CharmColors.soda,
            background: CharmColors.charple,
            modifiers: Modifier.bold,
          ),
          backgroundStyle: const Style(background: CharmColors.bbq),
          onDismiss: () {
            setState(() {
              widget.example.showModalDemo = false;
            });
          },
          onKeyEvent: (event) {
            if (event.type == ui.KeyType.enter) {
              setState(() {
                if (widget.example.modalBtn1Node.isFocused) {
                  widget.example.modalResult = 'Confirmed';
                } else if (widget.example.modalBtn2Node.isFocused) {
                  widget.example.modalResult = 'Cancelled';
                }
                widget.example.showModalDemo = false;
              });
              return true; // Consume event
            }
            if (event.key == 'escape') {
              setState(() {
                widget.example.showModalDemo = false;
              });
              return true; // Consume event
            }
            return false;
          },
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
                Focus(
                  focusNode: widget.example.modalBtn1Node,
                  onFocusChange: _onFocusChange,
                  child: InkwellButton(
                    text: 'Confirm',
                    width: 13,
                    height: 3,
                    color1: widget.example.modalBtn1Node.isFocused
                        ? CharmColors.julep
                        : Colors.black,
                    color2: CharmColors.pepper,
                    textStyle: Style(
                      foreground: widget.example.modalBtn1Node.isFocused
                          ? CharmColors.pepper
                          : CharmColors.julep,
                      modifiers: Modifier.bold,
                    ),
                    onPressed: () {
                      setState(() {
                        widget.example.modalResult = 'Confirmed';
                        widget.example.showModalDemo = false;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8, child: Text('')),
                Focus(
                  focusNode: widget.example.modalBtn2Node,
                  onFocusChange: _onFocusChange,
                  child: InkwellButton(
                    text: 'Cancel',
                    width: 13,
                    height: 3,
                    color1: widget.example.modalBtn2Node.isFocused
                        ? CharmColors.paprika
                        : Colors.black,
                    color2: CharmColors.pepper,
                    textStyle: Style(
                      foreground: widget.example.modalBtn2Node.isFocused
                          ? CharmColors.pepper
                          : CharmColors.paprika,
                      modifiers: Modifier.bold,
                    ),
                    onPressed: () {
                      setState(() {
                        widget.example.modalResult = 'Cancelled';
                        widget.example.showModalDemo = false;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 4, child: Text('')),
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}
