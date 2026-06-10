# TermUI Phase 1: Layout & State Management Guide

Welcome to the new Flutter-aligned layout and state management subsystem of `termui`. This document details how to compose layouts and manage interactive, reactive state in your terminal applications.

---

## 1. Geometry & Padding

### `EdgeInsets`
Offsets in standard Flutter applications use `EdgeInsets`. In `termui`, we introduce integer-based `EdgeInsets` measuring terminal cells (rows/columns):

* `EdgeInsets.all(int value)`: Equal spacing on all sides.
* `EdgeInsets.symmetric({int vertical = 0, int horizontal = 0})`: Symmetrical spacing.
* `EdgeInsets.only({int left, int top, int right, int bottom})`: Explicit spacing per side.
* `EdgeInsets.fromLTRB(int left, int top, int right, int bottom)`: Left, Top, Right, Bottom spacing.

### `Padding`
Wrap any child widget in a `Padding` widget:

```dart
Padding(
  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
  child: Text('Hello Terminal!'),
)
```

---

## 2. Layout Box Widgets

### `Row` and `Column`
Align children horizontally (`Row`) or vertically (`Column`). They take a standard `List<Widget> children`:

```dart
Column([
  Text('Header Line'),
  Expanded(
    child: Row([
      Flexible(flex: 1, child: Sidebar()),
      Flexible(flex: 3, child: MainContent()),
    ]),
  ),
  Text('Footer Line'),
])
```

* **`Flexible`**: Defines a child's proportional share of remaining space via its `flex` factor.
* **`Expanded`**: A subclass of `Flexible` that forces a child to consume remaining layout space.
* **`SizedBox`**: Enforces tight width and height constraints.

### `Stack` and `Positioned`
Overlaps multiple child widgets. Non-positioned children occupy the full stack area; `Positioned` children can be aligned to custom offsets:

```dart
Stack([
  BackgroundWidget(), // Fills stack
  Positioned(
    left: 2,
    top: 1,
    width: 20,
    height: 5,
    child: FloatingMenu(),
  ),
])
```

### `ConstrainedBox`
Enforces custom minimum and maximum box constraints (`BoxConstraints`):

```dart
ConstrainedBox(
  constraints: const BoxConstraints(
    minWidth: 10,
    maxWidth: 30,
  ),
  child: Text('Flexible content...'),
)
```

### `Align` and `Center`
Aligns a child widget within the parent boundary according to an `Alignment` value:

```dart
Center(
  child: SizedBox(
    width: 20,
    height: 3,
    child: ButtonWidget('Save'),
  ),
)
```

---

## 3. Reactive State Management

`termui` now implements a lightweight Element tree mirroring Flutter's reactive component model.

### `StatelessWidget`
A configuration widget that builds a subtree but maintains no mutable state:

```dart
class HeaderTitle extends StatelessWidget {
  final String title;
  const HeaderTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(title, style: const Style(modifiers: Modifier.bold));
  }
}
```

### `StatefulWidget` and `State`
Maintains mutable state across rebuilds and triggers paint refreshes reactively:

```dart
class ToggleButton extends StatefulWidget {
  const ToggleButton();

  @override
  State createState() => _ToggleButtonState();
}

class _ToggleButtonState extends State<ToggleButton> {
  bool isPressed = false;

  void toggle() {
    setState(() {
      isPressed = !isPressed;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Text(isPressed ? '[ON]' : '[OFF]');
  }
}
```

### `InheritedWidget`
Enables widgets to efficiently search up the context tree to fetch parent settings (like themes or application configurations) dynamically:

```dart
class ThemeColor extends InheritedWidget {
  final String colorName;
  const ThemeColor({required this.colorName, required super.child});

  static ThemeColor? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ThemeColor>();
  }

  @override
  bool updateShouldNotify(ThemeColor oldWidget) {
    return colorName != oldWidget.colorName;
  }
}
```

---

## 4. Rebuilding on State Changes

To drive redrawing on the screen when state changes:
1. Mount the element tree: `final rootElement = rootWidget.createElement(); rootElement.mount(null);`
2. Bind the global redraw loop callback: `State.onNeedRepaint = () { drawFrame(); };`
3. Inside your event loop, call `setState()` on your active states. The element tree will automatically mark components as dirty, rebuild only what changed, and execute the global repaint routine!
