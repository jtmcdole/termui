import 'package:termui/termui.dart';
import 'example_base.dart';

/// Example showcasing the [RichText] widget and a [TimerWidget].
///
/// Demonstrates mixed styling within a single line, multi-line wrapped
/// rich text, and a custom interactive countdown timer layout.
final class RichTextTimerExample extends WidgetBookExample {
  /// The active countdown timer widget instance.
  final timerWidget = TimerWidget(
    duration: const Duration(seconds: 120),
    running: true,
  );

  @override
  bool get requiresTick => true;

  @override
  bool tick(Duration duration) {
    final oldDuration = timerWidget.duration;
    timerWidget.tick(duration);
    return timerWidget.running || oldDuration != timerWidget.duration;
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
          '1. SGR Text Modifiers (Bold, Dim, Italic, Reverse, Strike, Overline, Hidden):',
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
                text: 'Bold ',
                style: Style(
                  foreground: CharmColors.cherry,
                  modifiers: Modifier.bold,
                ),
              ),
              TextSpan(
                text: 'Dim ',
                style: Style(
                  foreground: CharmColors.salt,
                  modifiers: Modifier.dim,
                ),
              ),
              TextSpan(
                text: 'Italic ',
                style: Style(
                  foreground: CharmColors.zest,
                  modifiers: Modifier.italic,
                ),
              ),
              TextSpan(
                text: 'Bold+Italic ',
                style: Style(
                  foreground: CharmColors.butter,
                  modifiers: Modifier.bold | Modifier.italic,
                ),
              ),
              TextSpan(
                text: 'Reverse',
                style: Style(
                  foreground: CharmColors.dolly,
                  modifiers: Modifier.reverse,
                ),
              ),
              TextSpan(text: ' '),
              TextSpan(
                text: 'Strikethrough ',
                style: Style(
                  foreground: CharmColors.salmon,
                  modifiers: Modifier.crossedOut,
                ),
              ),
              TextSpan(
                text: 'Overline ',
                style: Style(
                  foreground: CharmColors.ice,
                  modifiers: Modifier.overline,
                ),
              ),
              TextSpan(
                text: '[',
                style: Style(foreground: CharmColors.smoke),
              ),
              TextSpan(
                text: 'HIDDEN',
                style: Style(
                  foreground: CharmColors.salt,
                  modifiers: Modifier.hidden,
                ),
              ),
              TextSpan(
                text: '<-Hidden]',
                style: Style(foreground: CharmColors.smoke),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          '2. Styled Underlines (4:1..4:5), Colors (SGR 58) & Hyperlinks (OSC 8):',
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
                text: 'Single',
                style: Style(
                  foreground: CharmColors.salt,
                  underlineStyle: UnderlineStyle.single,
                  underlineColor: CharmColors.malibu,
                ),
              ),
              TextSpan(text: '  '),
              TextSpan(
                text: 'Double',
                style: Style(
                  foreground: CharmColors.salt,
                  underlineStyle: UnderlineStyle.doubleLine,
                  underlineColor: CharmColors.julep,
                ),
              ),
              TextSpan(text: '  '),
              TextSpan(
                text: 'Curly',
                style: Style(
                  foreground: CharmColors.salt,
                  underlineStyle: UnderlineStyle.curly,
                  underlineColor: CharmColors.cherry,
                ),
              ),
              TextSpan(text: '  '),
              TextSpan(
                text: 'Dotted',
                style: Style(
                  foreground: CharmColors.salt,
                  underlineStyle: UnderlineStyle.dotted,
                  underlineColor: CharmColors.zest,
                ),
              ),
              TextSpan(text: '  '),
              TextSpan(
                text: 'Dashed',
                style: Style(
                  foreground: CharmColors.salt,
                  underlineStyle: UnderlineStyle.dashed,
                  underlineColor: CharmColors.dolly,
                ),
              ),
              TextSpan(text: '  '),
              TextSpan(
                text: 'https://dart.dev',
                style: Style(
                  foreground: CharmColors.malibu,
                  underlineStyle: UnderlineStyle.single,
                  underlineColor: CharmColors.malibu,
                  uri: 'https://dart.dev',
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
          '3. Rich Paragraph (Word Wrapping with Combined SGR Styles):',
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
                text: 'and wraps them at word boundaries. You can combine ',
                style: Style(foreground: CharmColors.soda),
              ),
              TextSpan(
                text: 'curly crimson diagnostics',
                style: Style(
                  foreground: CharmColors.salt,
                  underlineStyle: UnderlineStyle.curly,
                  underlineColor: CharmColors.cherry,
                ),
              ),
              TextSpan(
                text: ', ',
                style: Style(foreground: CharmColors.soda),
              ),
              TextSpan(
                text: 'double emerald underlines',
                style: Style(
                  foreground: CharmColors.julep,
                  underlineStyle: UnderlineStyle.doubleLine,
                  underlineColor: CharmColors.julep,
                ),
              ),
              TextSpan(
                text: ', ',
                style: Style(foreground: CharmColors.soda),
              ),
              TextSpan(
                text: 'overline + italic emphasis',
                style: Style(
                  foreground: CharmColors.zest,
                  modifiers: Modifier.italic | Modifier.overline,
                ),
              ),
              TextSpan(
                text: ', and ',
                style: Style(foreground: CharmColors.soda),
              ),
              TextSpan(
                text: 'crossed-out tokens',
                style: Style(
                  foreground: CharmColors.salmon,
                  modifiers: Modifier.crossedOut | Modifier.dim,
                ),
              ),
              TextSpan(
                text:
                    ' seamlessly across both CLI ANSI output and the Flutter GPU atlas.',
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
          '4. Countdown Timer Widget (Styled digits + progress bar):',
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
