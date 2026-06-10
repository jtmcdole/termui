import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' as ui;
import '../example/dashboard_demo.dart';

void main() {
  test('DashboardApp keyboard navigation and action selection test', () {
    final app = Overlay(child: const DashboardApp(width: 80, height: 20));

    final rootEl = StatefulElement(app)..mount(null);
    final buffer = Buffer.blank(80, 20);

    // Initial render
    rootEl.render(buffer, const Rect(0, 0, 80, 20));

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
    final appState = dashboardEl!.state as dynamic;

    expect(appState, isNotNull);
    expect(appState.selectedRow, equals(0));
    expect(appState.isActionFocused, isFalse);

    // 1. Send 'right' key to focus the action
    appState.handleKeyEvent(const ui.KeyEvent('right', ui.KeyType.right));
    rootEl.render(buffer, const Rect(0, 0, 80, 20));
    expect(appState.isActionFocused, isTrue);

    // Find the DropdownButton element and verify it is focused
    bool foundFocusedDropdown = false;
    void findFocusedDropdown(Element el) {
      if (el is StatefulElement) {
        final w = el.widget;
        if (w.runtimeType.toString().startsWith('DropdownButton')) {
          final focused = (w as dynamic).focused;
          if (focused) {
            foundFocusedDropdown = true;
          }
        }
      }
      el.visitChildren(findFocusedDropdown);
    }

    findFocusedDropdown(rootEl);
    expect(foundFocusedDropdown, isTrue);

    // Verify if there is an open overlay. It should be closed initially.
    bool overlayOpen = false;
    dynamic openOverlayState;
    void traverseForOpenOverlay(Element el) {
      if (el is StatefulElement) {
        final s = el.state;
        if (s.widget.runtimeType.toString().startsWith('DropdownButton') &&
            (s as dynamic).isOpen) {
          overlayOpen = true;
          openOverlayState = s;
        }
      }
      el.visitChildren(traverseForOpenOverlay);
    }

    traverseForOpenOverlay(rootEl);
    expect(overlayOpen, isFalse);

    // 2. Simulate pressing Space to open the dropdown
    // Let's call the outer event loop logic in dashboard_demo.dart:
    void simulateGlobalKey(ui.KeyEvent event) {
      // Check if action overlay is open and intercept key events
      bool isOverlayOpen = false;
      dynamic activeOverlayState;

      void checkOverlay(Element el) {
        if (isOverlayOpen) return;
        if (el is StatefulElement) {
          final s = el.state;
          if (s.widget.runtimeType.toString().startsWith('DropdownButton') &&
              (s as dynamic).isOpen) {
            isOverlayOpen = true;
            activeOverlayState = s;
          } else if (s.widget.runtimeType.toString().startsWith(
                'PopupMenuButton',
              ) &&
              (s as dynamic).isOpen) {
            isOverlayOpen = true;
            activeOverlayState = s;
          }
        }
        el.visitChildren(checkOverlay);
      }

      checkOverlay(rootEl);

      if (isOverlayOpen && activeOverlayState != null) {
        activeOverlayState.handleKeyEvent(event);
      } else {
        if (appState.isActionFocused) {
          void traverseForFocusedAction(Element el) {
            if (el is StatefulElement) {
              final s = el.state;
              final w = el.widget;
              if (w.runtimeType.toString().startsWith('DropdownButton') &&
                  (w as dynamic).focused) {
                (s as dynamic).handleKeyEvent(event);
              } else if (w.runtimeType.toString().startsWith(
                    'PopupMenuButton',
                  ) &&
                  (w as dynamic).focused) {
                (s as dynamic).handleKeyEvent(event);
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
    rootEl.render(buffer, const Rect(0, 0, 80, 20));

    // Verify dropdown is now open
    overlayOpen = false;
    traverseForOpenOverlay(rootEl);
    expect(overlayOpen, isTrue);
    expect(openOverlayState, isNotNull);

    // 3. Move selection down to 'Paused' (index 1)
    simulateGlobalKey(const ui.KeyEvent('down', ui.KeyType.down));
    rootEl.render(buffer, const Rect(0, 0, 80, 20));
    expect(openOverlayState.selectedIndex, equals(1));

    // 4. Confirm selection using 'enter'
    simulateGlobalKey(const ui.KeyEvent('\n', ui.KeyType.enter));
    rootEl.render(buffer, const Rect(0, 0, 80, 20));

    // Verify dropdown is closed and value changed
    overlayOpen = false;
    traverseForOpenOverlay(rootEl);
    expect(overlayOpen, isFalse);
    expect(appState.dropdownValues[0], equals('paused'));
  });
}
