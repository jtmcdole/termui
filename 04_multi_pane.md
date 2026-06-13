#### [ ] 04. Multi-Pane Settings (`04_multi_pane_settings.dart`)

**Focus:** Focus Traversal, Input Routing, and Event Bubbling.

* **Objective:** Validate `FocusNode`, `FocusScope`, and directional keyboard navigation across nested hierarchies.
* **The UI:** A classic dual-pane configuration interface.
* Left column: A vertical list of selectable tabs (e.g., General, Network, Appearance).
* Right column: Corresponding form controls (toggles, text inputs) for the selected tab.


* **Architecture Tests:**
* [ ] **Sibling Traversal:** `Tab` or arrow keys reliably move the active state between adjacent layout nodes in entirely different branches of the widget tree.
* [ ] **Input Consumption:** When a `TextField` receives focus, it strictly consumes alphanumeric input, preventing event bubbling to parent layout widgets.
* [ ] **Focus State Rendering:** Focused widgets visibly alter their styling (e.g., border color or text style) automatically via the declarative state.
