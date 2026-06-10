import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'example_base.dart';

/// Example showcasing the various [CharmColors] available in the terminal UI.
///
/// This widget book example demonstrates the primary palette, gradient ramps,
/// semantic pairings (additions/deletions), neutral gradients, and warm
/// highlights that can be used for text foreground and background styles.
class CharmColorsExample extends WidgetBookExample {
  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return Column([
      // Section 1: Primaries
      const SizedBox(
        height: 1,
        child: Text(
          '1. Primary Palette:',
          style: Style(modifiers: Modifier.bold),
          wrap: false,
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.charple),
              ),
              TextSpan(text: 'charple  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.dolly),
              ),
              TextSpan(text: 'dolly  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.julep),
              ),
              TextSpan(text: 'julep  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.zest),
              ),
              TextSpan(text: 'zest'),
            ],
          ),
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.hazy),
              ),
              TextSpan(text: 'hazy     '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.blush),
              ),
              TextSpan(text: 'blush  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.bok),
              ),
              TextSpan(text: 'bok    '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.butter),
              ),
              TextSpan(text: 'butter'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('', wrap: true)), // Spacer
      // Section 2: Charples Ramp
      const SizedBox(
        height: 1,
        child: Text(
          '2. Charple Gradient Ramp:',
          style: Style(modifiers: Modifier.bold),
          wrap: false,
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.jelly),
              ),
              TextSpan(text: 'jelly ➔ '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.darple),
              ),
              TextSpan(text: 'darple ➔ '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.charple),
              ),
              TextSpan(text: 'charple ➔ '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.larple),
              ),
              TextSpan(text: 'larple ➔ '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.hazy),
              ),
              TextSpan(text: 'hazy'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('', wrap: true)), // Spacer
      // Section 3: Diff Ramps (Additions & Deletions)
      const SizedBox(
        height: 1,
        child: Text(
          '3. Diff Semantic Pairings (Add / Del):',
          style: Style(modifiers: Modifier.bold),
          wrap: false,
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(text: 'Add: '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.spinach),
              ),
              TextSpan(text: 'spinach ➔ '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.gator),
              ),
              TextSpan(text: 'gator ➔ '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.pickle),
              ),
              TextSpan(text: 'pickle ➔ '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.julep),
              ),
              TextSpan(text: 'julep'),
            ],
          ),
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(text: 'Del: '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.toast),
              ),
              TextSpan(text: 'toast ➔   '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.steak),
              ),
              TextSpan(text: 'steak ➔ '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.pom),
              ),
              TextSpan(text: 'pom ➔    '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.cherry),
              ),
              TextSpan(text: 'cherry'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('', wrap: true)), // Spacer
      // Section 4: Neutrals Ramp
      const SizedBox(
        height: 1,
        child: Text(
          '4. Neutrals (Pepper ➔ Soda):',
          style: Style(modifiers: Modifier.bold),
          wrap: false,
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.pepper),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.bbq),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.char),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.iron),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.oyster),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.squid),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.steam),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.smoke),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.steep),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.sash),
              ),
              TextSpan(
                text: '█',
                style: Style(foreground: CharmColors.salt),
              ),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.soda),
              ),
              TextSpan(text: ' (12-step grayscale gradient)'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('', wrap: true)), // Spacer
      // Section 5: Warm Highlights
      const SizedBox(
        height: 1,
        child: Text(
          '5. Warm Palette Highlights:',
          style: Style(modifiers: Modifier.bold),
          wrap: false,
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.cumin),
              ),
              TextSpan(text: 'cumin  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.tang),
              ),
              TextSpan(text: 'tang  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.yam),
              ),
              TextSpan(text: 'yam  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.paprika),
              ),
              TextSpan(text: 'paprika  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.bengal),
              ),
              TextSpan(text: 'bengal'),
            ],
          ),
        ),
      ),
      const SizedBox(
        height: 1,
        child: RichText(
          wrap: false,
          text: TextSpan(
            children: [
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.sriracha),
              ),
              TextSpan(text: 'sriracha  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.coral),
              ),
              TextSpan(text: 'coral  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.salmon),
              ),
              TextSpan(text: 'salmon  '),
              TextSpan(
                text: '█ ',
                style: Style(foreground: CharmColors.chili),
              ),
              TextSpan(text: 'chili'),
            ],
          ),
        ),
      ),
      const Expanded(child: Text('', wrap: true)),
    ]);
  }
}
