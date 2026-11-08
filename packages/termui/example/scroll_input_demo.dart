import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ev;

/// Runs the interactive scroll and input form demo on [terminal].
Future<void> runScrollInputDemo(term.Terminal terminal) async {
  terminal.hideCursor();
  terminal.enableMouseTracking();
  try {
    final runner = PromptRunner<void>(
      terminal: terminal,
      widget: const ScrollInputDemo(),
      alternateScreen: true,
      exitConditions: const {
        PromptExitTrigger.controlC: PromptExitAction.complete,
      },
    );
    await runner.run();
  } finally {
    terminal.showCursor();
    terminal.disableMouseTracking();
    terminal.resetStyle();
  }
}

/// Interactive scrolling and form input demonstration widget.
class ScrollInputDemo extends StatefulWidget {
  /// Creates a [ScrollInputDemo].
  const ScrollInputDemo({super.key});

  @override
  State<ScrollInputDemo> createState() => ScrollInputDemoState();
}

/// State for [ScrollInputDemo].
class ScrollInputDemoState extends State<ScrollInputDemo>
    implements MouseEventHandler {
  /// Controller for the email single-line text field.
  final TextEditingController emailController = TextEditingController();

  /// Controller for the biography multi-line text field.
  final TextEditingController bioController = TextEditingController();

  /// Scroll controller for the main form viewport.
  final DiscreteScrollController scrollController = DiscreteScrollController();

  /// Scroll controller for the submission modal details viewport.
  final DiscreteScrollController modalScrollController =
      DiscreteScrollController();

  /// Focus scope node for the submission modal.
  final FocusScopeNode modalScopeNode = FocusScopeNode(id: 'modalScope');

  /// Whether the newsletter checkbox is checked.
  bool newsletterVal = false;

  /// Selected theme radio value ('light' or 'dark').
  String themeGroupVal = 'dark';

  /// Whether the sound FX switch is enabled.
  bool soundVal = true;

  /// Whether the form has been submitted and the modal is visible.
  bool submitted = false;

  /// Index of the currently focused form control (0..6).
  int focusedIndex = 0;

  int _viewportHeight = 14;

  @override
  void dispose() {
    modalScopeNode.dispose();
    scrollController.dispose();
    modalScrollController.dispose();
    super.dispose();
  }

  (int, int) _getFieldYBounds(int index) {
    return switch (index) {
      0 => (4, 5),
      1 => (7, 10),
      2 => (11, 12),
      3 => (14, 15),
      4 => (15, 16),
      5 => (17, 18),
      6 => (19, 20),
      _ => (0, 0),
    };
  }

  void _scrollToField(int index) {
    final (start, end) = _getFieldYBounds(index);
    final offset = scrollController.scrollOffset;
    if (start < offset) {
      scrollController.scrollOffset = start;
    } else if (_viewportHeight > 0 && end > offset + _viewportHeight) {
      scrollController.scrollOffset = end - _viewportHeight;
    }
  }

  void _resetForm() {
    setState(() {
      submitted = false;
      emailController.clear();
      bioController.clear();
      newsletterVal = false;
      themeGroupVal = 'dark';
      soundVal = true;
      focusedIndex = 0;
      scrollController.scrollOffset = 0;
      modalScrollController.scrollOffset = 0;
    });
  }

  bool _handleSubmittedKeyEvent(KeyEvent event) {
    if (event.type == KeyType.up) {
      setState(() {
        modalScrollController.scrollOffset--;
      });
      return true;
    }
    if (event.type == KeyType.down) {
      setState(() {
        modalScrollController.scrollOffset++;
      });
      return true;
    }
    _resetForm();
    return true;
  }

  bool _handleFormKeyEvent(BuildContext context, KeyEvent event) {
    if (submitted) {
      return _handleSubmittedKeyEvent(event);
    }

    if (event.type == KeyType.tab ||
        event.key == '\t' ||
        event.key == 'tab' ||
        event.key == 'backtab') {
      final isShift =
          event.modifiers.contains(ev.Modifier.shift) || event.key == 'backtab';
      setState(() {
        focusedIndex = isShift
            ? (focusedIndex - 1 + 7) % 7
            : (focusedIndex + 1) % 7;
        _scrollToField(focusedIndex);
      });
      return true;
    }

    final isEscape = event.type == KeyType.escape || event.key == 'escape';
    final isQuitOnControl =
        focusedIndex >= 2 && (event.key == 'q' || event.key == 'Q');
    if (isEscape || isQuitOnControl) {
      PromptScope.of(context)?.done();
      return true;
    }

    return false;
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    final wheelDelta = switch (event.button) {
      MouseButton.wheelDown => 1,
      MouseButton.wheelUp => -1,
      _ => 0,
    };
    if (wheelDelta != 0) {
      setState(() {
        final ctrl = submitted ? modalScrollController : scrollController;
        ctrl.scrollOffset += wheelDelta;
      });
      return;
    }

    if (!submitted && event.type == MouseEventType.press) {
      final virtualY = (localY - 3) + scrollController.scrollOffset;
      if (virtualY == 4) {
        setState(() => focusedIndex = 0);
      } else if (virtualY >= 7 && virtualY < 10) {
        setState(() => focusedIndex = 1);
      }
    }
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 2,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          backgroundStyle: Style(background: CharmColors.charple),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row([
            const Expanded(
              child: Text(
                'Phase 3: Interactive Scrolling & Input Form',
                style: Style(
                  foreground: CharmColors.soda,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
            const SizedBox(
              width: 12,
              child: Text(
                'TermUI Demo',
                style: Style(foreground: CharmColors.julep),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildFormFields() {
    final emailField = TextField(
      controller: emailController,
      multiline: false,
      placeholder: 'Enter email address...',
      style: const Style(foreground: CharmColors.soda),
      placeholderStyle: const Style(foreground: CharmColors.squid),
      focused: !submitted && focusedIndex == 0,
    );

    final bioField = TextField(
      controller: bioController,
      multiline: true,
      placeholder: 'Write a short bio here...',
      style: const Style(foreground: CharmColors.soda),
      placeholderStyle: const Style(foreground: CharmColors.squid),
      focused: !submitted && focusedIndex == 1,
    );

    final checkboxWidget = Checkbox(
      value: newsletterVal,
      label: 'Subscribe to Newsletter',
      focused: !submitted && focusedIndex == 2,
      onChanged: (v) {
        setState(() {
          focusedIndex = 2;
          newsletterVal = v;
        });
      },
    );

    final radioLightWidget = Radio<String>(
      value: 'light',
      groupValue: themeGroupVal,
      label: 'Light Mode Theme',
      focused: !submitted && focusedIndex == 3,
      onChanged: (v) {
        setState(() {
          focusedIndex = 3;
          themeGroupVal = v;
        });
      },
    );

    final radioDarkWidget = Radio<String>(
      value: 'dark',
      groupValue: themeGroupVal,
      label: 'Dark Mode Theme',
      focused: !submitted && focusedIndex == 4,
      onChanged: (v) {
        setState(() {
          focusedIndex = 4;
          themeGroupVal = v;
        });
      },
    );

    final switchWidget = Switch(
      value: soundVal,
      label: 'Sound FX Output',
      focused: !submitted && focusedIndex == 5,
      onChanged: (v) {
        setState(() {
          focusedIndex = 5;
          soundVal = v;
        });
      },
    );

    final submitBtn = Button(
      text: 'SUBMIT FORM DATA',
      focused: !submitted && focusedIndex == 6,
      onPressed: () {
        setState(() {
          focusedIndex = 6;
          submitted = true;
        });
      },
    );

    return Column([
      const SizedBox(
        height: 2,
        child: Text(
          '📝 USER PROFILE DASHBOARD',
          style: Style(foreground: CharmColors.julep, modifiers: Modifier.bold),
        ),
      ),
      const SizedBox(height: 1),
      const SizedBox(
        height: 1,
        child: Text(
          'Email Address:',
          style: Style(foreground: CharmColors.soda),
        ),
      ),
      SizedBox(height: 1, child: emailField),
      const SizedBox(height: 1),
      const SizedBox(
        height: 1,
        child: Text(
          'Short Biography:',
          style: Style(foreground: CharmColors.soda),
        ),
      ),
      SizedBox(height: 3, child: bioField),
      const SizedBox(height: 1),
      SizedBox(height: 1, child: checkboxWidget),
      const SizedBox(height: 1),
      const SizedBox(
        height: 1,
        child: Text('Color Theme:', style: Style(foreground: CharmColors.soda)),
      ),
      SizedBox(height: 1, child: radioLightWidget),
      SizedBox(height: 1, child: radioDarkWidget),
      const SizedBox(height: 1),
      SizedBox(height: 1, child: switchWidget),
      const SizedBox(height: 1),
      SizedBox(height: 1, child: submitBtn),
    ]);
  }

  Widget _buildStatusBanner() {
    final bioSummary = bioController.text.replaceAll('\n', ' ');
    return SizedBox(
      height: 4,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          backgroundStyle: Style(background: CharmColors.bbq),
          border: Border(style: Style(foreground: CharmColors.squid)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column([
            SizedBox(
              height: 1,
              child: Text(
                submitted
                    ? '🎉 SUCCESS: Form submitted successfully! Press any key to reset.'
                    : '⚡ STATUS: Form input in progress...',
                style: Style(
                  foreground: submitted ? CharmColors.julep : CharmColors.tang,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
            SizedBox(
              height: 1,
              child: Text(
                submitted
                    ? 'Email: ${emailController.text} | Bio: $bioSummary | News: $newsletterVal | Theme: $themeGroupVal | Sound: $soundVal'
                    : 'Use Tab/Shift-Tab to move | Enter/Space to select/toggle | Esc/Q to quit',
                style: const Style(foreground: CharmColors.soda),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildModalOverlay(int width, int height) {
    final detailsText =
        'Email: ${emailController.text}\n'
        'Bio: ${bioController.text}\n'
        'Newsletter: ${newsletterVal ? "Yes" : "No"}\n'
        'Theme: $themeGroupVal\n'
        'Sound FX: $soundVal';
    final detailLinesCount = detailsText.split('\n').length;

    return ModalOverlay(
      title: 'Submission Success',
      width: width,
      height: height,
      dialogBounds: Rect((width - 48) ~/ 2, (height - 12) ~/ 2, 48, 12),
      focusNode: modalScopeNode,
      modalFocusNodes: const [],
      onDismiss: _resetForm,
      onKeyEvent: _handleSubmittedKeyEvent,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          backgroundStyle: Style(background: CharmColors.bbq),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Column([
            const SizedBox(
              height: 1,
              child: Text(
                'Form Submitted Successfully!',
                style: Style(
                  foreground: CharmColors.julep,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
            const SizedBox(height: 1),
            SizedBox(
              height: 4,
              child: Row([
                Expanded(
                  child: SingleChildScrollView(
                    controller: modalScrollController,
                    childLength: detailLinesCount,
                    child: Text(
                      detailsText,
                      style: const Style(foreground: CharmColors.soda),
                    ),
                  ),
                ),
                const SizedBox(width: 1),
                SizedBox(
                  width: 1,
                  child: ScrollBar(
                    controller: modalScrollController,
                    thumbStyle: const Style(
                      foreground: CharmColors.julep,
                      background: CharmColors.bbq,
                    ),
                    trackStyle: const Style(foreground: CharmColors.pepper),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 1),
            SizedBox(
              height: 1,
              child: Button(text: 'OK', focused: true, onPressed: _resetForm),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : 80;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 24;
        _viewportHeight = (height - 10).clamp(1, height);

        final formBody = DecoratedBox(
          decoration: const BoxDecoration(
            backgroundStyle: Style(background: CharmColors.pepper),
          ),
          child: Column([
            _buildHeader(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(1),
                child: Row([
                  Expanded(
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        border: Border(
                          style: Style(foreground: CharmColors.squid),
                          topLeftChar: '╭',
                          topRightChar: '╮',
                          bottomLeftChar: '╰',
                          bottomRightChar: '╯',
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: SingleChildScrollView(
                          controller: scrollController,
                          childLength: 22,
                          child: _buildFormFields(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 1),
                  SizedBox(
                    width: 1,
                    child: ScrollBar(
                      controller: scrollController,
                      thumbStyle: const Style(
                        foreground: CharmColors.julep,
                        background: CharmColors.charple,
                      ),
                      trackStyle: const Style(foreground: CharmColors.bbq),
                    ),
                  ),
                ]),
              ),
            ),
            _buildStatusBanner(),
          ]),
        );

        return FocusScope(
          onKeyEvent: (event) => _handleFormKeyEvent(context, event),
          child: Stack([
            Positioned(left: 0, top: 0, right: 0, bottom: 0, child: formBody),
            if (submitted)
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                bottom: 0,
                child: _buildModalOverlay(width, height),
              ),
          ]),
        );
      },
    );
  }
}

void main() async {
  await term.Terminal.runGuarded((terminal) async {
    await runScrollInputDemo(terminal);
  });

  print('\nScroll & Input Demo exited cleanly.');
  exit(0);
}
