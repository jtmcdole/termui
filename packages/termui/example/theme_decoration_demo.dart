import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widgets/layout/row.dart';
import 'package:termui/ui/widgets/layout/column.dart';
import 'package:termui/ui/widgets/layout/sized_box.dart';
import 'package:termui/ui/widgets/layout/flexible.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/build_context.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/widget_toolkit.dart';

class ThemeDemoDashboard extends StatelessWidget {
  const ThemeDemoDashboard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme == ThemeData.dark;

    // The border lines should be drawn using a foreground style with a light background in light mode,
    // so they blend nicely with the box's background.
    final borderStyle = Style(
      foreground: isDark ? const Color(33, 150, 243) : const Color(0, 150, 166),
      background: isDark ? null : theme.backgroundStyle.background,
    );
    final textStyle = theme.textStyle;

    // titleStyle is used for header and footer text (where background is theme.primaryStyle)
    final titleStyle = theme.primaryStyle.merge(
      const Style(modifiers: Modifier.bold),
    );

    final boxTitleStyle = theme.textStyle.merge(
      const Style(modifiers: Modifier.bold),
    );
    final box1TitleStyle = boxTitleStyle.merge(
      Style(foreground: isDark ? Colors.orange : const Color(230, 81, 0)),
    );
    final box2TitleStyle = boxTitleStyle.merge(
      Style(
        foreground: isDark
            ? const Color(33, 150, 243)
            : const Color(21, 101, 192),
      ),
    );
    final box3TitleStyle = boxTitleStyle.merge(
      Style(
        foreground: isDark
            ? const Color(0, 230, 118)
            : const Color(46, 125, 50),
      ),
    );
    final box4TitleStyle = boxTitleStyle.merge(
      Style(
        foreground: isDark
            ? const Color(255, 23, 68)
            : const Color(198, 40, 40),
      ),
    );

    Border getThemedBorder(Border template) {
      return Border(
        style: borderStyle,
        topChar: template.topChar,
        bottomChar: template.bottomChar,
        leftChar: template.leftChar,
        rightChar: template.rightChar,
        topLeftChar: template.topLeftChar,
        topRightChar: template.topRightChar,
        bottomLeftChar: template.bottomLeftChar,
        bottomRightChar: template.bottomRightChar,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(backgroundStyle: theme.backgroundStyle),
      child: Column([
        // Header (1 line)
        SizedBox(
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(backgroundStyle: theme.primaryStyle),
            child: Row([
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Text(
                    '🎨 Theme & Decoration Showcase',
                    style: titleStyle,
                    wrap: false,
                  ),
                ),
              ),
              SizedBox(
                width: 16,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Text(
                    theme == ThemeData.dark
                        ? 'Theme: DARK 🌙'
                        : 'Theme: LIGHT ☀️',
                    style: titleStyle,
                    wrap: false,
                  ),
                ),
              ),
            ]),
          ),
        ),
        // Spacer
        const SizedBox(height: 1),
        // Main Area with 2x2 grid
        Expanded(
          child: Row([
            // Column 1
            Expanded(
              child: Column([
                // Box 1: Border.single
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      backgroundStyle: theme.backgroundStyle,
                      border: getThemedBorder(Border.single),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(1),
                      child: Column([
                        SizedBox(
                          height: 1,
                          child: Text(
                            '1. Single Border & CJK Measurement',
                            style: box1TitleStyle,
                          ),
                        ),
                        const SizedBox(height: 1),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Narrow text (ASCII): 1 cell/char',
                            style: textStyle,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Wide text (CJK): 2 cells/char',
                            style: textStyle,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text('Character lengths:', style: textStyle),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text('  "Hello" = 5 cells', style: textStyle),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text('  "你好" = 4 cells', style: textStyle),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text('  "😀🚀" = 4 cells', style: textStyle),
                        ),
                      ]),
                    ),
                  ),
                ),
                // Spacer between Row 1 and Row 2 in Column 1
                const SizedBox(height: 1),
                // Box 3: Border.rounded
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      backgroundStyle: theme.backgroundStyle,
                      border: getThemedBorder(Border.rounded),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(1),
                      child: Column([
                        SizedBox(
                          height: 1,
                          child: Text(
                            '3. Rounded Border & Alignment',
                            style: box3TitleStyle,
                          ),
                        ),
                        const SizedBox(height: 1),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Left-aligned CJK/Emoji:',
                            style: textStyle,
                            textAlign: TextAlign.left,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text(
                            '世界, 你好! 🌸',
                            style: textStyle,
                            textAlign: TextAlign.left,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Center-aligned CJK/Emoji:',
                            style: textStyle,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text(
                            '世界, 你好! 🌸',
                            style: textStyle,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Right-aligned CJK/Emoji:',
                            style: textStyle,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text(
                            '世界, 你好! 🌸',
                            style: textStyle,
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
            // Spacer between columns
            const SizedBox(width: 1),
            // Column 2
            Expanded(
              child: Column([
                // Box 2: Border.doubleLine
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      backgroundStyle: theme.backgroundStyle,
                      border: getThemedBorder(Border.doubleLine),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(1),
                      child: Column([
                        SizedBox(
                          height: 1,
                          child: Text(
                            '2. Double Line Border & Word Wrap',
                            style: box2TitleStyle,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Expanded(
                          flex: 3,
                          child: Text(
                            'Below is a wrapped text block mixing narrow English text, CJK character sequences, and colorful emojis. It demonstrates correct wrapping boundaries without slicing wide characters in half:',
                            style: textStyle,
                            wrap: true,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            '🌟 Hello! 你好! こんにちは! 안녕하세요! 🌟 We support emojis: 🍔🍟🥤🚀🚁🚂. Beautiful and consistent.',
                            style: textStyle,
                            wrap: true,
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
                // Spacer between Row 1 and Row 2 in Column 2
                const SizedBox(height: 1),
                // Box 4: Border.ascii
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      backgroundStyle: theme.backgroundStyle,
                      border: getThemedBorder(Border.ascii),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(1),
                      child: Column([
                        SizedBox(
                          height: 1,
                          child: Text(
                            '4. ASCII Border & Custom Styles',
                            style: box4TitleStyle,
                          ),
                        ),
                        const SizedBox(height: 1),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Uses "+", "-", and "|" for compatibility.',
                            style: textStyle,
                          ),
                        ),
                        const SizedBox(height: 1),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Theme Accent Style: Color text',
                            style: theme.accentStyle,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Theme Warning Style: Alert text',
                            style: theme.warningStyle,
                          ),
                        ),
                        SizedBox(
                          height: 1,
                          child: Text(
                            'Theme Focus Style: Highlight text',
                            style: theme.focusStyle,
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
        // Spacer
        const SizedBox(height: 1),
        // Footer (1 line)
        SizedBox(
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(backgroundStyle: theme.primaryStyle),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Row([
                Expanded(
                  child: Text(
                    'Press [T] to Toggle Theme | Press [Q] to Quit',
                    style: titleStyle,
                    wrap: false,
                  ),
                ),
                SizedBox(
                  width: 18,
                  child: Text(
                    'Built with TermUI',
                    style: titleStyle,
                    wrap: false,
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

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

    var isDarkTheme = true;

    // Hide cursor, enable mouse tracking & switch to alternate screen buffer
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    void drawFrame() {
      buffer.clear();
      final rootWidget = Theme(
        data: isDarkTheme ? ThemeData.dark : ThemeData.light,
        child: const ThemeDemoDashboard(),
      );
      final rootWrapper = ElementWidget(rootWidget);
      rootWrapper.layout(BoxConstraints.tight(Size(width, height)));
      rootWrapper.paint(buffer, Offset.zero);

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
        if (event.key == 'q' || event.key == 'Q') {
          break;
        }
        if (event.key.length == 1 && event.key.codeUnits[0] == 3) {
          break; // Ctrl+C
        }
        if (event.key == 't' || event.key == 'T') {
          isDarkTheme = !isDarkTheme;
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

  print('Theme & Decoration Demo exited cleanly.');
  exit(0);
}
