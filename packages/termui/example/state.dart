import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/widget_toolkit.dart';

// A custom styled Container widget using composition
class Container extends StatelessWidget {
  final Widget child;
  final Style style;

  const Container({required this.child, required this.style});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(backgroundStyle: style),
      child: child,
    );
  }
}

// A custom VerticalDivider widget using custom element paint
class VerticalDivider extends Widget {
  final Style style;
  const VerticalDivider({required this.style});

  @override
  Element createElement() => _VerticalDividerElement(this);
}

class _VerticalDividerElement extends Element {
  _VerticalDividerElement(VerticalDivider super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.minWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;
    return constraints.constrain(Size(w > 1 ? w : 1, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final v = widget as VerticalDivider;
    for (var y = 0; y < size.height; y++) {
      buffer.setCell(
        offset.dx.toInt(),
        (offset.dy + y).toInt(),
        Cell('│', v.style),
      );
    }
  }
}

// A custom InheritedWidget to propagate style theme properties down the tree
class AppTheme extends InheritedWidget {
  final Style headerStyle;
  final Style bodyStyle;
  final Style accentStyle;
  final Style warningStyle;

  const AppTheme({
    required this.headerStyle,
    required this.bodyStyle,
    required this.accentStyle,
    required this.warningStyle,
    required super.child,
  });

  static AppTheme? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppTheme>();
  }

  @override
  bool updateShouldNotify(AppTheme oldWidget) {
    return headerStyle != oldWidget.headerStyle ||
        bodyStyle != oldWidget.bodyStyle ||
        accentStyle != oldWidget.accentStyle ||
        warningStyle != oldWidget.warningStyle;
  }
}

// A StatefulWidget representing the interactive portion of our dashboard
class DashboardStatus extends StatefulWidget {
  const DashboardStatus();

  @override
  State<DashboardStatus> createState() => _DashboardStatusState();
}

class _DashboardStatusState extends State<DashboardStatus> {
  int _counter = 0;
  bool _isRunning = true;
  String _lastAction = 'Initialised';

  void increment() {
    setState(() {
      _counter++;
      _lastAction = 'Incremented count';
    });
  }

  void toggleStatus() {
    setState(() {
      _isRunning = !_isRunning;
      _lastAction = _isRunning ? 'Started system' : 'Paused system';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final statusStyle = _isRunning
        ? (theme?.accentStyle ?? const Style(foreground: Colors.green))
        : (theme?.warningStyle ?? const Style(foreground: Colors.red));

    return Column([
      SizedBox(
        height: 1,
        child: Row([
          const SizedBox(width: 18, child: Text('System Status:')),
          SizedBox(
            width: 15,
            child: Text(
              _isRunning ? '● RUNNING' : '○ PAUSED',
              style: statusStyle.merge(const Style(modifiers: Modifier.bold)),
            ),
          ),
        ]),
      ),
      SizedBox(height: 1),
      SizedBox(
        height: 1,
        child: Row([
          const SizedBox(width: 18, child: Text('Interaction Counter:')),
          SizedBox(
            width: 10,
            child: Text(
              '$_counter',
              style:
                  theme?.accentStyle.merge(
                    const Style(modifiers: Modifier.bold),
                  ) ??
                  const Style(
                    foreground: Colors.green,
                    modifiers: Modifier.bold,
                  ),
            ),
          ),
        ]),
      ),
      SizedBox(height: 1),
      SizedBox(
        height: 1,
        child: Row([
          const SizedBox(width: 18, child: Text('Last Event Action:')),
          Expanded(
            child: Text(
              _lastAction,
              style: const Style(modifiers: Modifier.italic),
            ),
          ),
        ]),
      ),
    ]);
  }
}

// A StatelessWidget that displays the app footer
class ThemedFooter extends StatelessWidget {
  const ThemedFooter();

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final footerStyle = theme?.headerStyle ?? Style.empty;
    return Container(
      style: footerStyle,
      child: Center(
        child: Text(
          ' [Space] Increment | [T] Toggle Status | [Q] Quit Demo ',
          style: footerStyle.merge(const Style(modifiers: Modifier.bold)),
        ),
      ),
    );
  }
}

void main() async {
  // 1. Initialise the terminal and components
  final terminal = term.Terminal();
  final termSize = await terminal.size;
  var width = termSize.x;
  var height = termSize.y;

  // Let's constrain the minimum terminal size required for this demo
  if (width < 60 || height < 15) {
    stderr.writeln('Terminal is too small (minimum 60x15 required).');
    exit(1);
  }

  terminal.enterAlternateScreen();
  terminal.clear();
  terminal.hideCursor();

  var buffer = Buffer.blank(width, height);
  var renderer = Renderer(width, height);

  // 2. Define colors and theme styles
  const darkTheme = AppTheme(
    headerStyle: Style(
      foreground: Colors.white,
      background: Color(33, 150, 243), // Deep blue
    ),
    bodyStyle: Style(
      foreground: Color(224, 224, 224), // Light grey
    ),
    accentStyle: Style(
      foreground: Color(0, 230, 118), // Vibrant green
    ),
    warningStyle: Style(
      foreground: Color(255, 23, 68), // Bright red
    ),
    child: SizedBox(), // Place holder, actual layout will wrap this child
  );

  // 3. Define the main interactive root widget tree
  // We use ElementWidget to act as the rendering bridge for the stateful subtree
  final elementWrapper = ElementWidget(
    AppTheme(
      headerStyle: darkTheme.headerStyle,
      bodyStyle: darkTheme.bodyStyle,
      accentStyle: darkTheme.accentStyle,
      warningStyle: darkTheme.warningStyle,
      child: Column([
        // Header Row
        SizedBox(
          height: 1,
          child: Container(
            style: darkTheme.headerStyle,
            child: Center(
              child: Text(
                ' 🖥️  TERMUI DECLARATIVE WIDGET ENGINE  🖥️ ',
                style: darkTheme.headerStyle.merge(
                  const Style(modifiers: Modifier.bold),
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: 1),
        // Middle Workspace
        Expanded(
          child: Row([
            // Sidebar pane
            Flexible(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.all(1),
                child: Column([
                  SizedBox(
                    height: 1,
                    child: Text(
                      'INFORMATION',
                      style: const Style(
                        foreground: Colors.blue,
                        modifiers: Modifier.bold,
                      ),
                    ),
                  ),
                  SizedBox(height: 1),
                  const Expanded(
                    child: Text(
                      'This demo showcases the new Flutter-aligned layout & state tree: Column, Row, Stack, Positioned, Padding, SizedBox, Center, and InheritedWidgets.',
                      style: Style(modifiers: Modifier.dim),
                    ),
                  ),
                ]),
              ),
            ),
            // Vertical Divider
            const SizedBox(
              width: 1,
              child: VerticalDivider(style: Style(foreground: Colors.blue)),
            ),
            // Content pane
            Flexible(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                child: Stack([
                  // Aligned card decoration in the background
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 45,
                    height: 8,
                    child: Container(
                      style: const Style(
                        foreground: Colors.blue,
                        modifiers: Modifier.dim,
                      ),
                      child: const Column([
                        Text(
                          '┌───────────────────────────────────────────┐',
                          wrap: false,
                        ),
                        Text(
                          '│                                           │',
                          wrap: false,
                        ),
                        Text(
                          '│                                           │',
                          wrap: false,
                        ),
                        Text(
                          '│                                           │',
                          wrap: false,
                        ),
                        Text(
                          '│                                           │',
                          wrap: false,
                        ),
                        Text(
                          '│                                           │',
                          wrap: false,
                        ),
                        Text(
                          '│                                           │',
                          wrap: false,
                        ),
                        Text(
                          '└───────────────────────────────────────────┘',
                          wrap: false,
                        ),
                      ]),
                    ),
                  ),
                  // Positioned StatefulWidget in the foreground
                  Positioned(
                    left: 2,
                    top: 1,
                    width: 41,
                    height: 6,
                    child: const DashboardStatus(),
                  ),
                ]),
              ),
            ),
          ]),
        ),
        SizedBox(height: 1),
        // Footer Row
        const SizedBox(height: 1, child: ThemedFooter()),
      ]),
    ),
  );

  // 4. Set up rendering logic
  late final BuildOwner buildOwner;

  void drawFrame() {
    buildOwner.buildScope();
    buffer.clear();
    // Fill background with blank cells
    buffer.fill(Cell(' ', Style.empty));

    // Render the mounted element tree to the buffer
    elementWrapper.layout(
      BoxConstraints.tight(Size(width, height)),
      buildOwner,
    );
    elementWrapper.paint(buffer, Offset.zero);

    // Output to stdout via Renderer diffing
    final sb = StringBuffer();
    renderer.render(buffer, sb);
    stdout.write(sb.toString());
  }

  buildOwner = BuildOwner(onNeedVisualUpdate: drawFrame);

  // Watch for window size changes and adapt
  final sizeSubscription = terminal.watchSize().listen((size) {
    width = size.x;
    height = size.y;
    buffer.resize(width, height);
    renderer = Renderer(width, height);
    drawFrame();
  });

  // Render initial frame
  drawFrame();

  // 5. Main event listening loop
  try {
    await for (final event in terminal.events) {
      if (event.key == 'q' ||
          event.key == 'Q' ||
          (event.key.length == 1 && event.key.codeUnits[0] == 3)) {
        break;
      }
      if (event.key == ' ') {
        final state = elementWrapper.findState<_DashboardStatusState>();
        state?.increment();
      }
      if (event.key == 't' || event.key == 'T') {
        final state = elementWrapper.findState<_DashboardStatusState>();
        state?.toggleStatus();
      }
    }
  } finally {
    // 6. Cleanup terminal configuration on exit
    await sizeSubscription.cancel();
    terminal.exitAlternateScreen();
    terminal.showCursor();
    terminal.dispose();
    print('TermUI Interactive Example exited cleanly.');
  }
  exit(0);
}
