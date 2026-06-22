# termui Overlay & Navigation System Refactoring Proposals

This document outlines structural design suggestions to elevate modal dialog rendering from local component stacks to a screen-wide global root overlay system, mirroring Flutter's overlay design.

---

## 1. Global Root Overlay & Navigator System
Currently, widgets like `ModalOverlay` in the `widget_book` are declared locally using a `Stack` component. This confines the modal bounds to the containing widget (e.g., the right-side preview pane in the split-layout widget book) instead of rendering over the entire terminal canvas.

### Proposed Architecture:
1. **Root Overlay Widget**:
   - Introduce an `Overlay` widget positioned at the very root of the application element tree (managed by the `SceneRenderer` or top-level shell).
   - This `Overlay` maintains a list of overlay entries (`OverlayEntry`) which are rendered sequentially on top of the base widget tree.
2. **Navigator Integration**:
   - Implement a lightweight `Navigator` widget that sits inside/alongside the `Overlay`.
   - Provide programmatic imperative APIs (e.g., `showDialog()`, `Navigator.push()`, etc.) that declare and append dialog components to the root `Overlay` tree.
3. **Decoupled Compositing & Focus**:
   - Programmatically handle focus trapping within the topmost active `OverlayEntry`.
   - Utilize a global `DimmingBarrier` inside the root overlay stack to dim all underlying application pages/components.

---

## 2. Benefits
- **Full Screen Bounds**: Modal dialogs, popup lists, dropdown selections, and tooltips will render on top of all panes, sidebars, and title headers.
- **Improved Declarative Ergonomics**: Component developers won't need to manually design local `Stack` structures or coordinate bounding boxes to overlay components on top.
- **Unified Event Interception**: Mouse events and keyboard events (like Esc for dismissal) can be intercepted cleanly at the root overlay level rather than trapped inside local page scopes.
