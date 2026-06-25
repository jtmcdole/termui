import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Example demonstrating stateful widgets, inherited widgets, and nested layouts.
class LayoutStateExample extends WidgetBookExample {
  /// The root element wrapper for the example that provides the context.
  late final ElementWidget elementWrapper;

  @override
  void init() {
    elementWrapper = ElementWidget(
      const AppTheme(
        titleStyle: Style(
          foreground: Colors.white,
          background: Colors.blue,
          modifiers: Modifier.bold,
        ),
        textStyle: Style(foreground: Colors.black, background: Colors.orange),
        child: DemoContent(),
      ),
    );
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return elementWrapper;
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.key == ' ') {
      final state = elementWrapper.findState<_StatefulCounterState>();
      state?.increment();
      return true;
    }
    return false;
  }

  @override
  Map<String, String> get helpBindings => {
    'Space': 'Increment Stateful Counter',
  };
}

/// A stateless widget that lays out the main demo content.
class DemoContent extends StatelessWidget {
  /// Creates a new [DemoContent] widget.
  const DemoContent();

  @override
  Widget build(BuildContext context) {
    return Column([
      SizedBox(
        height: 1,
        child: Text(
          'Nested Layout Box (Row, Column, Stack) & StatefulWidget',
          style: AppTheme.of(context)?.titleStyle ?? Style.empty,
        ),
      ),
      SizedBox(height: 1),
      Expanded(
        child: Row([
          // Sidebar
          Flexible(
            flex: 1,
            child: Column([
              SizedBox(
                height: 1,
                child: Text(
                  'Menu Options',
                  style: const Style(modifiers: Modifier.bold),
                ),
              ),
              SizedBox(height: 1),
              SizedBox(height: 1, child: Text('• [Space] Inc Counter')),
              SizedBox(height: 1, child: Text('• [Esc] Focus Out')),
            ]),
          ),
          // Divider
          const SizedBox(
            width: 1,
            child: VerticalDivider(style: Style(foreground: Colors.blue)),
          ),
          // Main Body
          Flexible(
            flex: 2,
            child: Stack([
              Positioned(
                left: 1,
                top: 1,
                width: 35,
                height: 8,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    'Stack Positioned Aligned Text Card...',
                    style: const Style(foreground: CharmColors.squid),
                  ),
                ),
              ),
              Positioned(
                left: 1,
                top: 3,
                width: 35,
                height: 6,
                child: const StatefulCounter(),
              ),
            ]),
          ),
        ]),
      ),
    ]);
  }
}

/// A stateful widget that displays a counter and a button state.
class StatefulCounter extends StatefulWidget {
  /// Creates a new [StatefulCounter] widget.
  const StatefulCounter();

  @override
  State createState() => _StatefulCounterState();
}

class _StatefulCounterState extends State<StatefulCounter> {
  int count = 0;
  bool isPressed = false;

  void increment() {
    setState(() {
      count++;
      isPressed = !isPressed;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column([
      SizedBox(
        height: 1,
        child: Row([
          SizedBox(width: 16, child: Text('Counter Value: ')),
          SizedBox(
            width: 10,
            child: Text(
              '$count',
              style: const Style(
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
          SizedBox(width: 16, child: Text('Button State:  ')),
          SizedBox(
            width: 16,
            child: Text(
              isPressed ? '[ ACTIVE ]' : '[ INACTIVE ]',
              style: Style(
                foreground: Colors.black,
                background: isPressed ? Colors.blue : Colors.red,
                modifiers: Modifier.bold,
              ),
            ),
          ),
        ]),
      ),
    ]);
  }
}

/// An inherited widget that provides the theme style to its descendants.
class AppTheme extends InheritedWidget {
  /// The style used for title text.
  final Style titleStyle;

  /// The style used for regular text.
  final Style textStyle;

  /// Creates a new [AppTheme] widget.
  const AppTheme({
    required this.titleStyle,
    required this.textStyle,
    required super.child,
  });

  /// Retrieves the nearest [AppTheme] from the given [context].
  static AppTheme? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppTheme>();
  }

  @override
  bool updateShouldNotify(AppTheme oldWidget) {
    return titleStyle != oldWidget.titleStyle ||
        textStyle != oldWidget.textStyle;
  }
}

/// A widget that renders a vertical divider line.
class VerticalDivider extends Widget {
  /// The style used to render the divider.
  final Style style;

  /// Creates a new [VerticalDivider] with an optional [style].
  const VerticalDivider({this.style = Style.empty});

  @override
  Element createElement() => _VerticalDividerElement(this);
}

class _VerticalDividerElement extends Element {
  _VerticalDividerElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(1, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final vWidget = widget as VerticalDivider;
    for (var y = 0; y < size.height; y++) {
      buffer.setAttributes(
        offset.dx,
        offset.dy + y,
        char: '│',
        fg: vWidget.style.foreground?.argb,
        bg: vWidget.style.background?.argb,
        modifiers: vWidget.style.modifiers,
      );
    }
  }
}
