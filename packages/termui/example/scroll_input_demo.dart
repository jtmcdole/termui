import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' hide Modifier;

void main() async {
  // Run the application inside the crash protection zone
  await term.Terminal.runGuarded((terminal) async {
    final termSize = await terminal.size;
    var width = termSize.x;
    var height = termSize.y;

    final buffer = Buffer.blank(width, height);
    final renderer = Renderer(
      width,
      height,
      mode: RenderingMode.alternateScreen,
    );

    // Form inputs and state variables
    final emailField = TextField(
      initialText: '',
      multiline: false,
      placeholder: 'Enter email address...',
      style: const Style(foreground: CharmColors.soda),
      placeholderStyle: const Style(foreground: CharmColors.squid),
    );
    // Explicitly set cursor for first focus field (Email)
    emailField.focused = true;
    emailField.cursorColumn = 0;

    final bioField = TextField(
      initialText: '',
      multiline: true,
      placeholder: 'Write a short bio here...',
      style: const Style(foreground: CharmColors.soda),
      placeholderStyle: const Style(foreground: CharmColors.squid),
    );
    bioField.focused = false;
    bioField.cursorColumn = 0;

    bool newsletterVal = false;
    String themeGroupVal = 'dark';
    bool soundVal = true;
    bool submitted = false;

    // Focused field tracking
    // 0: Email
    // 1: Bio
    // 2: Checkbox
    // 3: Radio Light
    // 4: Radio Dark
    // 5: Switch
    // 6: Button
    int focusedIndex = 0;

    final scrollController = DiscreteScrollController();
    bool isDraggingScrollbar = false;
    final modalScrollController = DiscreteScrollController();
    bool isDraggingModalScrollbar = false;

    // Hide cursor, enable mouse tracking & switch to alternate screen buffer
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    (int, int) getFieldYBounds(int index) {
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

    void scrollToField(int index, int viewportHeight) {
      final (start, end) = getFieldYBounds(index);
      final offset = scrollController.scrollOffset;
      if (start < offset) {
        scrollController.scrollOffset = start;
      } else if (end > offset + viewportHeight) {
        scrollController.scrollOffset = end - viewportHeight;
      }
    }

    void drawFrame() {
      buffer.clear();

      // Update focused states
      emailField.focused = (focusedIndex == 0);
      bioField.focused = (focusedIndex == 1);

      // Create local widget instances for stateless checkbox/radio/switch/button
      final checkboxWidget = Checkbox(
        value: newsletterVal,
        label: 'Subscribe to Newsletter',
        focused: focusedIndex == 2,
        onChanged: (v) {
          newsletterVal = v;
        },
      );

      final radioLightWidget = Radio<String>(
        value: 'light',
        groupValue: themeGroupVal,
        label: 'Light Mode Theme',
        focused: focusedIndex == 3,
        onChanged: (v) {
          themeGroupVal = v;
        },
      );

      final radioDarkWidget = Radio<String>(
        value: 'dark',
        groupValue: themeGroupVal,
        label: 'Dark Mode Theme',
        focused: focusedIndex == 4,
        onChanged: (v) {
          themeGroupVal = v;
        },
      );

      final switchWidget = Switch(
        value: soundVal,
        label: 'Sound FX Output',
        focused: focusedIndex == 5,
        onChanged: (v) {
          soundVal = v;
        },
      );

      final submitBtn = Button(
        text: 'SUBMIT FORM DATA',
        focused: focusedIndex == 6,
        onPressed: () {
          submitted = true;
        },
      );

      final rootWidget = DecoratedBox(
        decoration: const BoxDecoration(
          backgroundStyle: Style(background: CharmColors.pepper),
        ),
        child: Column([
          // Title/Header (height 2)
          SizedBox(
            height: 2,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                backgroundStyle: Style(background: CharmColors.charple),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Row([
                  Expanded(
                    child: Text(
                      'Phase 3: Interactive Scrolling & Input Form',
                      style: const Style(
                        foreground: CharmColors.soda,
                        modifiers: Modifier.bold,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 12,
                    child: Text(
                      'TermUI Demo',
                      style: const Style(foreground: CharmColors.julep),
                    ),
                  ),
                ]),
              ),
            ),
          ),

          // Main Body
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: Row([
                // Form Viewport (clipped inside SingleChildScrollView)
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
                        child: Column([
                          // Title inside scroll view
                          SizedBox(
                            height: 2,
                            child: Text(
                              '📝 USER PROFILE DASHBOARD',
                              style: const Style(
                                foreground: CharmColors.julep,
                                modifiers: Modifier.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 1),

                          // Email
                          SizedBox(
                            height: 1,
                            child: Text(
                              'Email Address:',
                              style: const Style(foreground: CharmColors.soda),
                            ),
                          ),
                          SizedBox(height: 1, child: emailField),
                          const SizedBox(height: 1),

                          // Bio
                          SizedBox(
                            height: 1,
                            child: Text(
                              'Short Biography:',
                              style: const Style(foreground: CharmColors.soda),
                            ),
                          ),
                          SizedBox(height: 3, child: bioField),
                          const SizedBox(height: 1),

                          // Newsletter Checkbox
                          SizedBox(height: 1, child: checkboxWidget),
                          const SizedBox(height: 1),

                          // Theme Label
                          SizedBox(
                            height: 1,
                            child: Text(
                              'Color Theme:',
                              style: const Style(foreground: CharmColors.soda),
                            ),
                          ),
                          // Radios
                          SizedBox(height: 1, child: radioLightWidget),
                          SizedBox(height: 1, child: radioDarkWidget),
                          const SizedBox(height: 1),

                          // Sound FX Switch
                          SizedBox(height: 1, child: switchWidget),
                          const SizedBox(height: 1),

                          // Button
                          SizedBox(height: 1, child: submitBtn),
                        ]),
                      ),
                    ),
                  ),
                ),

                // Gap of 1 cell
                const SizedBox(width: 1),

                // Scrollbar
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

          // Status / Submission Banner
          SizedBox(
            height: 3,
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
                        foreground: submitted
                            ? CharmColors.julep
                            : CharmColors.tang,
                        modifiers: Modifier.bold,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 1,
                    child: Text(
                      submitted
                          ? 'Email: ${emailField.value} | Bio: ${bioField.value.replaceAll("\n", " ")} | News: $newsletterVal | Theme: $themeGroupVal | Sound: $soundVal'
                          : 'Use Tab/Shift-Tab to move | Enter/Space to select/toggle | Esc/Q to quit',
                      style: const Style(foreground: CharmColors.soda),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ]),
      );

      final rootWrapper = ElementWidget(rootWidget);
      rootWrapper.layout(BoxConstraints.tight(Size(width, height)));
      rootWrapper.paint(buffer, Offset.zero);

      if (submitted) {
        final okBtnNode = FocusNode(id: 'okBtn');
        final detailsText =
            'Email: ${emailField.value}\n'
            'Bio: ${bioField.value}\n'
            'Newsletter: ${newsletterVal ? "Yes" : "No"}\n'
            'Theme: $themeGroupVal\n'
            'Sound FX: $soundVal';
        final detailLinesCount = detailsText.split('\n').length;

        final modal = ModalOverlay(
          title: 'Submission Success',
          bounds: Rect(0, 0, width, height),
          dialogBounds: Rect((width - 48) ~/ 2, (height - 12) ~/ 2, 48, 12),
          modalFocusNodes: [okBtnNode],
          onDismiss: () {
            submitted = false;
            // Clear inputs on reset
            emailField.value = '';
            bioField.value = '';
            newsletterVal = false;
            themeGroupVal = 'dark';
            soundVal = true;
            focusedIndex = 0;
            scrollController.scrollOffset = 0;
            modalScrollController.scrollOffset = 0;
            drawFrame();
          },
          child: DecoratedBox(
            decoration: const BoxDecoration(
              backgroundStyle: Style(background: CharmColors.bbq),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: Column([
                SizedBox(
                  height: 1,
                  child: Text(
                    'Form Submitted Successfully!',
                    style: const Style(
                      foreground: CharmColors.julep,
                      modifiers: Modifier.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 1),
                SizedBox(
                  height: 5,
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
                  child: Button(
                    text: 'OK',
                    focused: true,
                    onPressed: () {
                      submitted = false;
                      // Clear inputs on reset
                      emailField.value = '';
                      bioField.value = '';
                      newsletterVal = false;
                      themeGroupVal = 'dark';
                      soundVal = true;
                      focusedIndex = 0;
                      scrollController.scrollOffset = 0;
                      modalScrollController.scrollOffset = 0;
                      drawFrame();
                    },
                  ),
                ),
              ]),
            ),
          ),
        );
        final modalWrapper = ElementWidget(modal);
        modalWrapper.layout(BoxConstraints.tight(Size(width, height)));
        modalWrapper.paint(buffer, Offset.zero);
      }

      final sb = StringBuffer();
      renderer.render(buffer, sb);
      if (sb.isNotEmpty) {
        stdout.write(sb.toString());
      }
    }

    // Draw initial frame
    drawFrame();

    // Listen to sizing changes
    final sizeSubscription = terminal.watchSize().listen((size) {
      width = size.x;
      height = size.y;
      buffer.resize(width, height);
      drawFrame();
    });

    try {
      // Main event loop
      await for (final event in terminal.events) {
        // Reset submitted status on any key press after submission
        if (submitted) {
          if (event is KeyEvent) {
            if (event.key == 'escape') {
              submitted = false;
              emailField.value = '';
              bioField.value = '';
              newsletterVal = false;
              themeGroupVal = 'dark';
              soundVal = true;
              focusedIndex = 0;
              scrollController.scrollOffset = 0;
              modalScrollController.scrollOffset = 0;
              drawFrame();
              continue;
            }

            if (event.type == KeyType.up) {
              modalScrollController.scrollOffset--;
              drawFrame();
              continue;
            } else if (event.type == KeyType.down) {
              modalScrollController.scrollOffset++;
              drawFrame();
              continue;
            }

            final okBtn = Button(
              text: 'OK',
              focused: true,
              onPressed: () {
                submitted = false;
                emailField.value = '';
                bioField.value = '';
                newsletterVal = false;
                themeGroupVal = 'dark';
                soundVal = true;
                focusedIndex = 0;
                scrollController.scrollOffset = 0;
                modalScrollController.scrollOffset = 0;
              },
            );
            okBtn.handleKeyEvent(event);
            drawFrame();
            continue;
          } else if (event is MouseEvent) {
            // Modal wheel scroll
            if (event.button == MouseButton.wheelDown) {
              modalScrollController.scrollOffset++;
              drawFrame();
              continue;
            } else if (event.button == MouseButton.wheelUp) {
              modalScrollController.scrollOffset--;
              drawFrame();
              continue;
            }

            final dialogX = (width - 48) ~/ 2;
            final dialogY = (height - 12) ~/ 2;
            final localX = event.x - 1 - dialogX;
            final localY = event.y - 1 - dialogY;

            // Modal scrollbar is at localX == 43 and localY between 3 and 7 (inclusive)
            final isInsideModalScrollbar =
                (localX == 43) && (localY >= 3) && (localY < 8);
            if (isInsideModalScrollbar) {
              if (event.type == MouseEventType.press) {
                isDraggingModalScrollbar = true;
              }
              if (isDraggingModalScrollbar ||
                  event.type == MouseEventType.press) {
                final localScrollbarY = localY - 3;
                final sb = ScrollBar(controller: modalScrollController);
                sb.handleMouseEvent(event, 0, localScrollbarY);
              }
              if (event.type == MouseEventType.release) {
                isDraggingModalScrollbar = false;
              }
              drawFrame();
              continue;
            } else if (event.type == MouseEventType.drag &&
                isDraggingModalScrollbar) {
              final localScrollbarY = (localY - 3).clamp(0, 4);
              final sb = ScrollBar(controller: modalScrollController);
              sb.handleMouseEvent(event, 0, localScrollbarY);
              drawFrame();
              continue;
            } else if (event.type == MouseEventType.release) {
              isDraggingModalScrollbar = false;
            }

            if (event.type == MouseEventType.press) {
              final isOkClicked = (localX >= 2 && localX < 46 && localY == 9);
              if (isOkClicked) {
                submitted = false;
                emailField.value = '';
                bioField.value = '';
                newsletterVal = false;
                themeGroupVal = 'dark';
                soundVal = true;
                focusedIndex = 0;
                scrollController.scrollOffset = 0;
                modalScrollController.scrollOffset = 0;
              } else if (localX < 0 ||
                  localX >= 48 ||
                  localY < 0 ||
                  localY >= 12) {
                submitted = false;
                emailField.value = '';
                bioField.value = '';
                newsletterVal = false;
                themeGroupVal = 'dark';
                soundVal = true;
                focusedIndex = 0;
                scrollController.scrollOffset = 0;
                modalScrollController.scrollOffset = 0;
              }
            }
            drawFrame();
            continue;
          }
        }

        if (event.key == 'q' || event.key == 'Q' || event.key == 'escape') {
          break;
        }
        if (event.key.length == 1 && event.key.codeUnits[0] == 3) {
          break; // Ctrl+C
        }

        // Calculate layout properties for coordinate mapping
        final viewportY = 3;
        final viewportHeight = height - 7;

        // Route mouse events
        if (event is MouseEvent) {
          // Check wheel scroll
          if (event.button == MouseButton.wheelDown) {
            scrollController.scrollOffset++;
            drawFrame();
            continue;
          } else if (event.button == MouseButton.wheelUp) {
            scrollController.scrollOffset--;
            drawFrame();
            continue;
          }

          // Check scrollbar mouse event
          final isInsideScrollbar =
              (event.x - 1 == width - 2) &&
              (event.y - 1 >= viewportY) &&
              (event.y - 1 < viewportY + viewportHeight);

          if (isInsideScrollbar) {
            if (event.type == MouseEventType.press) {
              isDraggingScrollbar = true;
            }
            if (isDraggingScrollbar || event.type == MouseEventType.press) {
              final localY = event.y - 1 - viewportY;
              final sb = ScrollBar(controller: scrollController);
              sb.handleMouseEvent(event, 0, localY);
            }
            if (event.type == MouseEventType.release) {
              isDraggingScrollbar = false;
            }
            drawFrame();
            continue;
          } else if (event.type == MouseEventType.drag && isDraggingScrollbar) {
            final localY = (event.y - 1 - viewportY).clamp(
              0,
              viewportHeight - 1,
            );
            final sb = ScrollBar(controller: scrollController);
            sb.handleMouseEvent(event, 0, localY);
            drawFrame();
            continue;
          } else if (event.type == MouseEventType.release) {
            isDraggingScrollbar = false;
          }

          // Check click inside form viewport
          final isInsideViewport =
              (event.x - 1 >= 2) &&
              (event.x - 1 < width - 4) &&
              (event.y - 1 >= viewportY) &&
              (event.y - 1 < viewportY + viewportHeight);

          if (isInsideViewport && event.type == MouseEventType.press) {
            final localY = event.y - 1 - viewportY;
            final virtualY = localY + scrollController.scrollOffset;

            // Map click to field index
            if (virtualY == 4) {
              focusedIndex = 0;
            } else if (virtualY >= 7 && virtualY < 10) {
              focusedIndex = 1;
            } else if (virtualY == 11) {
              focusedIndex = 2;
              newsletterVal = !newsletterVal;
            } else if (virtualY == 14) {
              focusedIndex = 3;
              themeGroupVal = 'light';
            } else if (virtualY == 15) {
              focusedIndex = 4;
              themeGroupVal = 'dark';
            } else if (virtualY == 17) {
              focusedIndex = 5;
              soundVal = !soundVal;
            } else if (virtualY == 19) {
              focusedIndex = 6;
              submitted = true;
            }
            scrollToField(focusedIndex, viewportHeight);
            drawFrame();
            continue;
          }
        }

        // Route key events
        if (event is KeyEvent) {
          if (event.key == 'tab' || event.key == '\t') {
            focusedIndex = (focusedIndex + 1) % 7;
            scrollToField(focusedIndex, viewportHeight);
            drawFrame();
            continue;
          } else if (event.key == 'backtab') {
            focusedIndex = (focusedIndex - 1 + 7) % 7;
            scrollToField(focusedIndex, viewportHeight);
            drawFrame();
            continue;
          }

          // Route other keys to the active element
          if (focusedIndex == 0) {
            emailField.handleKeyEvent(event);
          } else if (focusedIndex == 1) {
            bioField.handleKeyEvent(event);
          } else {
            // Reconstruct temp stateless widgets to route their key activations
            if (focusedIndex == 2) {
              final cb = Checkbox(
                value: newsletterVal,
                label: '',
                focused: true,
                onChanged: (v) {
                  newsletterVal = v;
                },
              );
              cb.handleKeyEvent(event);
            } else if (focusedIndex == 3) {
              final rad = Radio<String>(
                value: 'light',
                groupValue: themeGroupVal,
                label: '',
                focused: true,
                onChanged: (v) {
                  themeGroupVal = v;
                },
              );
              rad.handleKeyEvent(event);
            } else if (focusedIndex == 4) {
              final rad = Radio<String>(
                value: 'dark',
                groupValue: themeGroupVal,
                label: '',
                focused: true,
                onChanged: (v) {
                  themeGroupVal = v;
                },
              );
              rad.handleKeyEvent(event);
            } else if (focusedIndex == 5) {
              final sw = Switch(
                value: soundVal,
                label: '',
                focused: true,
                onChanged: (v) {
                  soundVal = v;
                },
              );
              sw.handleKeyEvent(event);
            } else if (focusedIndex == 6) {
              final btn = Button(
                text: '',
                focused: true,
                onPressed: () {
                  submitted = true;
                },
              );
              btn.handleKeyEvent(event);
            }
          }
          drawFrame();
        }
      }
    } finally {
      sizeSubscription.cancel();
      terminal.showCursor();
      terminal.disableMouseTracking();
      terminal.exitAlternateScreen();
      terminal.resetStyle();
    }
  });

  print('\nScroll & Input Demo exited cleanly.');
  exit(0);
}
