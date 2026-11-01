import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' as ui;
import '../example/dashboard_demo.dart';

void main() {
  test('DashboardApp keyboard navigation and action selection test', () {
    final app = Overlay(child: const DashboardApp(width: 80, height: 20));

    final rootEl = StatefulElement(app)..mount(null);
    final buffer = Buffer.blank(80, 20);

    // Initial render
    rootEl.layout(BoxConstraints.tight(const Size(80, 20)));
    rootEl.paint(buffer, Offset.zero);

    // Find the state dynamically by looking for the DashboardApp widget's element
    StatefulElement? dashboardEl;
    void findDashboardElement(Element el) {
      if (el is StatefulElement && el.widget is DashboardApp) {
        dashboardEl = el;
        return;
      }
      el.visitChildren(findDashboardElement);
    }

    findDashboardElement(rootEl);
    expect(dashboardEl, isNotNull);
    final appState = dashboardEl!.state as DashboardAppState;

    expect(appState, isNotNull);
    expect(appState.selectedRow, equals(0));
    expect(appState.isActionFocused, isFalse);

    // 1. Send 'right' key to focus the action
    appState.handleKeyEvent(const ui.KeyEvent('right', ui.KeyType.right));
    rootEl.layout(BoxConstraints.tight(const Size(80, 20)));
    rootEl.paint(buffer, Offset.zero);
    expect(appState.isActionFocused, isTrue);

    // Find the DropdownButton element and verify it is focused
    bool foundFocusedDropdown = false;
    void findFocusedDropdown(Element el) {
      if (el case StatefulElement(
        widget: DropdownButton<Object?>(focused: true),
      )) {
        foundFocusedDropdown = true;
      }
      el.visitChildren(findFocusedDropdown);
    }

    findFocusedDropdown(rootEl);
    expect(foundFocusedDropdown, isTrue);

    // Verify if there is an open overlay. It should be closed initially.
    DropdownButtonState<Object?>? openOverlayState;
    void traverseForOpenOverlay(Element el) {
      if (el case StatefulElement(
        state: final DropdownButtonState<Object?> s,
      ) when s.isOpen) {
        openOverlayState = s;
      }
      el.visitChildren(traverseForOpenOverlay);
    }

    traverseForOpenOverlay(rootEl);
    expect(openOverlayState, isNull);

    // 2. Simulate pressing Space to open the dropdown
    // Let's call the outer event loop logic in dashboard_demo.dart:
    void simulateGlobalKey(ui.KeyEvent event) {
      ui.KeyEventHandler? activeOverlayState;

      void checkOverlay(Element el) {
        if (activeOverlayState != null) return;
        if (el is StatefulElement) {
          switch (el.state) {
            case final DropdownButtonState<Object?> s when s.isOpen:
              activeOverlayState = s;
            case final PopupMenuButtonState<Object?> s when s.isOpen:
              activeOverlayState = s;
          }
        }
        el.visitChildren(checkOverlay);
      }

      checkOverlay(rootEl);

      if (activeOverlayState != null) {
        activeOverlayState!.handleKeyEvent(event);
      } else {
        if (appState.isActionFocused) {
          void traverseForFocusedAction(Element el) {
            if (el is StatefulElement) {
              if ((el.widget, el.state) case (
                DropdownButton<Object?>(focused: true) ||
                    PopupMenuButton<Object?>(focused: true),
                final ui.KeyEventHandler handler,
              )) {
                handler.handleKeyEvent(event);
              }
            }
            el.visitChildren(traverseForFocusedAction);
          }

          traverseForFocusedAction(rootEl);
        }
        appState.handleKeyEvent(event);
      }
    }

    simulateGlobalKey(const ui.KeyEvent(' ', ui.KeyType.character));
    rootEl.layout(BoxConstraints.tight(const Size(80, 20)));
    rootEl.paint(buffer, Offset.zero);

    // Verify dropdown is now open
    openOverlayState = null;
    traverseForOpenOverlay(rootEl);
    expect(openOverlayState, isNotNull);

    // 3. Move selection down to 'Paused' (index 1)
    simulateGlobalKey(const ui.KeyEvent('down', ui.KeyType.down));
    rootEl.layout(BoxConstraints.tight(const Size(80, 20)));
    rootEl.paint(buffer, Offset.zero);
    expect(openOverlayState!.selectedIndex, equals(1));

    // 4. Confirm selection using 'enter'
    simulateGlobalKey(const ui.KeyEvent('\n', ui.KeyType.enter));
    rootEl.layout(BoxConstraints.tight(const Size(80, 20)));
    rootEl.paint(buffer, Offset.zero);

    // Verify dropdown is closed and value changed
    openOverlayState = null;
    traverseForOpenOverlay(rootEl);
    expect(openOverlayState, isNull);
    expect(appState.dropdownValues[0], equals('paused'));
  });
}
