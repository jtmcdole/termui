import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';
import 'dart:math';

class MockRenderer implements SceneRenderer {
  @override
  Buffer currentBuffer;

  MockRenderer(this.currentBuffer);

  @override
  bool handleMouseEvent(MouseEvent event) => false;

  @override
  bool handleKeyEvent(KeyEvent event) => false;

  @override
  void resize(int width, int height) {}

  @override
  void dispose() {}

  @override
  Point<int>? get requestedCursorPosition => null;
  @override
  bool get showsCursor => false;
  @override
  bool get wantsAlternateScreen => false;
  @override
  bool get wantsMouseTracking => false;
}

void makeTransparent(Buffer buf) {
  for (int y = 0; y < buf.height; y++) {
    for (int x = 0; x < buf.width; x++) {
      buf.setModifiers(x, y, Modifier.transparent);
    }
  }
}

void main() {
  test('SceneManager routes mouse clicks through transparent layers', () async {
    final backend = MockTerminalBackend();
    final terminal = Terminal(backend);

    // Top layer with mouseOpaque = true, but renders transparent except at (0,0)
    bool topHandled = false;
    final topBuffer = Buffer.blank(10, 10);
    makeTransparent(topBuffer);
    topBuffer.writeString(0, 0, 'O', const Style());
    final topRenderer = MockRenderer(topBuffer);

    final topLayer = SceneLayer(
      renderer: topRenderer,
      width: 10,
      height: 10,
      zIndex: 20,
      mouseOpaque: true, // It traps clicks on opaque cells
      onFocus: () => topHandled = true,
    );

    // Bottom layer completely opaque
    bool bottomHandled = false;
    final bottomBuffer = Buffer.blank(10, 10);
    bottomBuffer.writeString(0, 0, 'B', const Style());
    bottomBuffer.writeString(1, 1, 'B', const Style());
    final bottomRenderer = MockRenderer(bottomBuffer);

    final bottomLayer = SceneLayer(
      renderer: bottomRenderer,
      width: 10,
      height: 10,
      zIndex: 10,
      mouseOpaque: true,
      onFocus: () => bottomHandled = true,
    );

    final sceneManager = SceneManager(
      terminal,
      renderingMode: RenderingMode.inline,
    );
    sceneManager.layers.add(bottomLayer);
    sceneManager.layers.add(topLayer);

    sceneManager.scheduleRender();
    await Future.delayed(const Duration(milliseconds: 50));

    // Click at (1, 1) -> Top layer is transparent there, bottom is opaque
    sceneManager.handleMouseEvent(
      MouseEvent(
        type: MouseEventType.press,
        button: MouseButton.left,
        x: 2, // 1-indexed in handleMouseEvent
        y: 2,
        modifiers: {},
      ),
    );

    expect(
      topHandled,
      isFalse,
      reason: 'Top layer should be transparent at (1, 1)',
    );
    expect(bottomHandled, isTrue, reason: 'Bottom layer should receive focus');
    expect(sceneManager.focusedLayer, bottomLayer);

    bottomHandled = false;

    // Click at (0, 0) -> Top layer is opaque there
    sceneManager.handleMouseEvent(
      MouseEvent(
        type: MouseEventType.press,
        button: MouseButton.left,
        x: 1, // 1-indexed in handleMouseEvent
        y: 1,
        modifiers: {},
      ),
    );

    expect(topHandled, isTrue, reason: 'Top layer is opaque at (0, 0)');
    expect(sceneManager.focusedLayer, topLayer);
  });
}
