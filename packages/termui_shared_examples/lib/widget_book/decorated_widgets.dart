import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// An example showcasing decorated widgets like number selectors and bordered boxes.
class DecoratedWidgetsExample extends WidgetBookExample {
  /// The submarine speed value controlled by the first selector.
  int speed = 3;

  /// The dive depth value controlled by the second selector.
  int depth = 45;

  /// The index of the currently active selector widget (0: speed, 1: depth).
  int activeSelectorIndex = 0; // 0: speed, 1: depth

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    final speedFocused = focusDemoPane && activeSelectorIndex == 0;
    final depthFocused = focusDemoPane && activeSelectorIndex == 1;

    final speedSelector = NumberSelector(
      label: 'Submarine Speed',
      value: speed,
      min: 0,
      max: 10,
      style: speedFocused
          ? const Style(foreground: CharmColors.soda, modifiers: Modifier.bold)
          : const Style(foreground: CharmColors.smoke),
      buttonStyle: speedFocused
          ? const Style(foreground: CharmColors.julep, modifiers: Modifier.bold)
          : const Style(foreground: CharmColors.smoke),
      onChanged: (val) {
        speed = val;
      },
    );

    final depthSelector = NumberSelector(
      label: 'Dive Depth (m)',
      value: depth,
      min: 0,
      max: 200,
      style: depthFocused
          ? const Style(foreground: CharmColors.soda, modifiers: Modifier.bold)
          : const Style(foreground: CharmColors.smoke),
      buttonStyle: depthFocused
          ? const Style(foreground: CharmColors.julep, modifiers: Modifier.bold)
          : const Style(foreground: CharmColors.smoke),
      onChanged: (val) {
        depth = val;
      },
    );

    return Column([
      SizedBox(
        height: 1,
        child: Text(
          '1. NumberSelector (Use Arrow keys to focus/change, or Mouse Click):',
          style: const Style(
            foreground: CharmColors.squid,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      SizedBox(
        height: 1,
        child: Row([
          SizedBox(
            width: 3,
            child: Text(
              speedFocused ? ' ▶ ' : '   ',
              style: const Style(
                foreground: CharmColors.julep,
                modifiers: Modifier.bold,
              ),
            ),
          ),
          Expanded(child: speedSelector),
        ]),
      ),
      SizedBox(
        height: 1,
        child: Row([
          SizedBox(
            width: 3,
            child: Text(
              depthFocused ? ' ▶ ' : '   ',
              style: const Style(
                foreground: CharmColors.julep,
                modifiers: Modifier.bold,
              ),
            ),
          ),
          Expanded(child: depthSelector),
        ]),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          '2. LeftBorder Widget (Draws a customized vertical left-border):',
          style: const Style(
            foreground: CharmColors.squid,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      SizedBox(
        height: 4,
        child: LeftBorder(
          style: const Style(
            foreground: CharmColors.tang,
            modifiers: Modifier.bold,
          ),
          char: '┃',
          padding: const EdgeInsets.only(left: 2),
          child: Column([
            const SizedBox(
              height: 1,
              child: Text('LeftBorder child content line 1'),
            ),
            const SizedBox(
              height: 1,
              child: Text('LeftBorder child content line 2'),
            ),
            const SizedBox(
              height: 1,
              child: Text('Provides clean indent and vertical bar decoration'),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          '3. DecoratedBox Widgets (Borders & Background styles):',
          style: const Style(
            foreground: CharmColors.squid,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      Expanded(
        child: Row([
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border.doubleLine,
                backgroundStyle: Style(background: CharmColors.bbq),
              ),
              child: Center(
                child: Text(
                  'Double Line\nBox',
                  textAlign: TextAlign.center,
                  style: const Style(foreground: CharmColors.soda),
                ),
              ),
            ),
          ),
          const SizedBox(width: 1, child: Text('')),
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border.rounded,
                backgroundStyle: Style(background: CharmColors.bbq),
              ),
              child: Center(
                child: Text(
                  'Rounded Corners\nBox',
                  textAlign: TextAlign.center,
                  style: const Style(foreground: CharmColors.julep),
                ),
              ),
            ),
          ),
          const SizedBox(width: 1, child: Text('')),
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(border: Border.ascii),
              child: Center(
                child: Text(
                  'ASCII Border\nBox',
                  textAlign: TextAlign.center,
                  style: const Style(foreground: CharmColors.charple),
                ),
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    // Up/Down changes active selector
    if (event.type == ui.KeyType.up) {
      activeSelectorIndex = (activeSelectorIndex - 1 + 2) % 2;
      return true;
    } else if (event.type == ui.KeyType.down) {
      activeSelectorIndex = (activeSelectorIndex + 1) % 2;
      return true;
    }

    // Left/Right changes selected values
    if (activeSelectorIndex == 0) {
      if (event.type == ui.KeyType.left) {
        if (speed > 0) speed--;
        return true;
      } else if (event.type == ui.KeyType.right) {
        if (speed < 10) speed++;
        return true;
      }
    } else {
      if (event.type == ui.KeyType.left) {
        if (depth > 0) depth--;
        return true;
      } else if (event.type == ui.KeyType.right) {
        if (depth < 200) depth++;
        return true;
      }
    }

    return false;
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    // Hit test the click for number selectors based on Y coordinates
    // Inside the build method, speedSelector is at Y=1 and depthSelector is at Y=2.
    // Adjusting for the layout offset, we subtract 2 from localX.
    if (localY == 1) {
      final selector = NumberSelector(
        label: 'Submarine Speed',
        value: speed,
        min: 0,
        max: 10,
        onChanged: (val) {
          speed = val;
        },
      );
      selector.handleMouseEvent(event, localX - 2, 0);
    } else if (localY == 2) {
      final selector = NumberSelector(
        label: 'Dive Depth (m)',
        value: depth,
        min: 0,
        max: 200,
        onChanged: (val) {
          depth = val;
        },
      );
      selector.handleMouseEvent(event, localX - 2, 0);
    }
  }

  @override
  Map<String, String> get helpBindings => {
    'Up/Down': 'Focus selector',
    'Left/Right': 'Change value',
    'Mouse Click': 'Modify selector',
  };
}
