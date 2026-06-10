import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'example_base.dart';

/// Example showcasing the [RichText] widget and a [TimerWidget].
///
/// Demonstrates mixed styling within a single line, multi-line wrapped
/// rich text, and a custom interactive countdown timer layout.
class RichTextTimerExample extends WidgetBookExample {
  /// The active countdown timer widget instance.
  final timerWidget = TimerWidget(
    duration: const Duration(seconds: 120),
    running: true,
  );

  @override
  void tick(Duration duration) {
    timerWidget.tick(duration);
  }

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
          '1. Rich Label (Single Line, Custom Styling):',
          style: const Style(modifiers: Modifier.bold),
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(
                text: 'This ',
                style: Style(
                  foreground: CharmColors.cherry,
                  modifiers: Modifier.bold,
                ),
              ),
              TextSpan(
                text: 'is ',
                style: Style(
                  foreground: CharmColors.zest,
                  modifiers: Modifier.italic,
                ),
              ),
              TextSpan(
                text: 'expressive ',
                style: Style(
                  foreground: CharmColors.julep,
                  modifiers: Modifier.underline,
                ),
              ),
              TextSpan(
                text: 'rich ',
                style: Style(foreground: CharmColors.ice),
              ),
              TextSpan(
                text: 'text!',
                style: Style(
                  foreground: CharmColors.dolly,
                  modifiers: Modifier.reverse,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          '2. Rich Paragraph (Word Wrapping with Styled Runs):',
          style: const Style(modifiers: Modifier.bold),
        ),
      ),
      const Expanded(
        child: RichText(
          wrap: true,
          text: TextSpan(
            children: [
              TextSpan(
                text: 'The TUI engine parses a sequence of styled ',
                style: Style(foreground: CharmColors.soda),
              ),
              TextSpan(
                text: 'text runs ',
                style: Style(
                  foreground: CharmColors.charple,
                  modifiers: Modifier.bold,
                ),
              ),
              TextSpan(
                text: 'and wraps them at word boundaries. ',
                style: Style(foreground: CharmColors.soda),
              ),
              TextSpan(
                text: 'Underline, ',
                style: Style(
                  foreground: CharmColors.malibu,
                  modifiers: Modifier.underline,
                ),
              ),
              TextSpan(
                text: 'italic, ',
                style: Style(
                  foreground: CharmColors.zest,
                  modifiers: Modifier.italic,
                ),
              ),
              TextSpan(
                text: 'bold, ',
                style: Style(
                  foreground: CharmColors.cherry,
                  modifiers: Modifier.bold,
                ),
              ),
              TextSpan(
                text:
                    'and different foreground or background colors can be mixed arbitrarily on a single line.',
                style: Style(foreground: CharmColors.julep),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          '3. Countdown Timer Widget (Styled digits + progress bar):',
          style: const Style(modifiers: Modifier.bold),
        ),
      ),
      SizedBox(
        height: 2,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: timerWidget,
        ),
      ),
    ]);
  }
}
