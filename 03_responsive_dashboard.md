#### [x] 03. Responsive Dashboard (`03_responsive_dashboard.dart`)

**Focus:** Layout Constraints, Resizing (`SIGWINCH`), and Flex boundaries.

* **Objective:** Validate `Flex`, `Expanded`, `Row`, `Column`, and `Container` (with `Border`).
* **The UI:** A mock server monitoring dashboard.
* Top row: Three equal-flex stat cards with borders.
* Bottom row: A 2/3 flex log window and a 1/3 flex system info panel.


* **Architecture Tests:**
* [x] **Dynamic Redistribution:** Terminal resize events dynamically redistribute space among `Expanded` widgets based strictly on their `flex` factors.
* [x] **Constraint Enforcement:** Text wraps correctly within tight constraints and truncates when constraints are violated.
* [x] **Overflow Prevention:** No rendering overflows break the terminal output during chaotic resizing.


