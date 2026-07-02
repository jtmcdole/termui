# termui Overlay & Navigation System Architecture

This document outlines the structural design choice for rendering screens, overlay menus, and modal dialogs in the `termui` windowing system.

---

## 1. The Chosen Architecture: State-Machine Driven Layout & SceneManager Layers

Instead of introducing a Flutter-style nested `Navigator` widget (which introduces high boilerplate, nested BuildContext dependency, and fragile focus trapping), `termui` applications should utilize a **Hierarchical State Machine (HSM)** and the **`SceneManager` layer stack**.

### Key Advantages:
1. **Headless Testability**: The application flow, menu transitions, and dialog triggers can be fully unit-tested headlessly in pure Dart without compiling/mounting the widget tree or simulating a visual terminal layout.
2. **Deterministic Focus Lifecycle**: Focus transitions are managed cleanly via the state machine's `onEnter` and `onExit` hooks, avoiding fragile ad-hoc focus checks in paint and build loops.
3. **Decoupled Business Logic**: Widgets remain purely declarative. They do not invoke imperative navigation commands (e.g. `Navigator.of(context).push(...)`). Instead, they post events to an event bus or transition state variables in a ViewModel.

---

## 2. Implementing Modal Overlays and Dialogs

To display modal overlays, dialogs, or dropdown lists, use a dedicated high Z-index `SceneLayer` registered directly on the `SceneManager`:

1. **Overlay Layer Registration**:
   Create a new fixed-size or intrinsic `SceneLayer` wrapping a `PromptRunner` or `SceneRenderer` that hosts the dialog widget. Add this layer to the `SceneManager.layers` stack with a high `zIndex` (e.g., `zIndex: 100`).
2. **Focus Redirection**:
   Set `SceneManager.focusedLayer` to the overlay layer to automatically direct keyboard and mouse inputs to the dialog.
3. **Global Dimming Scrim**:
   Wrap the dialog widget or base content in a `DimmingBarrier` (which utilizes `EffectWidget` with `DimmerEffect`) to dim all underlying application screens and intercept pointer events.
4. **Transition Animations (e.g., Screen Sliding)**:
   For screen transition effects (like sliding menus), animate the `x` or `y` coordinates of the target `SceneLayer` objects simultaneously over successive frames in the render loop.

---

## 3. Local vs. Global Overlays

- **Global Overlays (Dialogs, Modals, System Tooltips)**: Managed as top-level `SceneLayer`s in the `SceneManager` stack.
- **Local Overlays (Dropdown Selection, Button Hover Menu)**: Managed locally within a widget subtree using the existing `Overlay` and `OverlayEntry` stack (rendered via a local `Stack` component) since their layout bounds are confined to the coordinate system of the parent component.
