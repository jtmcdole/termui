import 'layout.dart';
import 'style.dart';
import 'color.dart';

/// A class that holds the color and style configurations for a [Theme].
class ThemeData {
  /// The style for primary branded UI elements.
  final Style primaryStyle;

  /// The style used for application backgrounds.
  final Style backgroundStyle;

  /// The default style for standard text.
  final Style textStyle;

  /// The style used to highlight secondary interactive elements.
  final Style accentStyle;

  /// The style used for error or warning states.
  final Style warningStyle;

  /// The style used for text input areas.
  final Style inputStyle;

  /// The style applied to currently focused widgets.
  final Style focusStyle;

  /// The style used for selected text or list items.
  final Style selectionStyle;

  /// Creates a new [ThemeData] with the provided styles.
  const ThemeData({
    this.primaryStyle = Style.empty,
    this.backgroundStyle = Style.empty,
    this.textStyle = Style.empty,
    this.accentStyle = Style.empty,
    this.warningStyle = Style.empty,
    this.inputStyle = Style.empty,
    this.focusStyle = Style.empty,
    this.selectionStyle = Style.empty,
  });

  /// The default dark theme configuration.
  static final ThemeData dark = ThemeData(
    primaryStyle: const Style(
      foreground: Colors.white,
      background: Color(33, 150, 243), // Blue
    ),
    backgroundStyle: const Style(
      foreground: Color(224, 224, 224),
      background: Color(18, 18, 18), // Dark charcoal
    ),
    textStyle: const Style(foreground: Color(224, 224, 224)),
    accentStyle: const Style(
      foreground: Color(0, 230, 118), // Green
    ),
    warningStyle: const Style(
      foreground: Color(255, 23, 68), // Red
    ),
    inputStyle: const Style(
      foreground: Colors.white,
      background: Color(45, 45, 45),
    ),
    focusStyle: const Style(
      foreground: Color(255, 215, 0), // Gold
      modifiers: Modifier.bold,
    ),
    selectionStyle: const Style(
      foreground: Colors.black,
      background: Colors.white,
    ),
  );

  /// The default light theme configuration.
  static final ThemeData light = ThemeData(
    primaryStyle: const Style(
      foreground: Colors.black,
      background: Color(0, 188, 212), // Cyan
    ),
    backgroundStyle: const Style(
      foreground: Colors.black,
      background: Color(245, 245, 245), // Off-white
    ),
    textStyle: const Style(foreground: Colors.black),
    accentStyle: const Style(
      foreground: Color(76, 175, 80), // Muted green
    ),
    warningStyle: const Style(
      foreground: Color(244, 67, 54), // Muted red
    ),
    inputStyle: const Style(
      foreground: Colors.black,
      background: Color(225, 225, 225),
    ),
    focusStyle: const Style(
      foreground: Color(33, 150, 243), // Blue
      modifiers: Modifier.bold,
    ),
    selectionStyle: const Style(
      foreground: Colors.white,
      background: Colors.black,
    ),
  );
}

/// A widget that propagates a [ThemeData] down the widget tree.
class Theme extends InheritedWidget {
  /// The styling configurations provided to descendants.
  final ThemeData data;

  /// Creates a [Theme] widget.
  const Theme({required this.data, required super.child});

  /// Retrieves the closest [ThemeData] from the [BuildContext].
  ///
  /// Defaults to [ThemeData.dark] if no [Theme] is found in the ancestor path.
  static ThemeData of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<Theme>();
    return theme?.data ?? ThemeData.dark;
  }

  @override
  bool updateShouldNotify(Theme oldWidget) {
    return data != oldWidget.data;
  }
}
