#### [ ] 05. Command Palette (`05_command_palette.dart`)

**Focus:** Z-Indexing, Modal Overlays, and Render Occlusion.

* **Objective:** Validate `Stack`, `Positioned`, Z-order rendering, and modal focus trapping.
* **The UI:** A global search or command palette rendered over a complex background layout (reusing the dashboard from 03).
* Trigger: A designated hotkey (e.g., `Ctrl+K`).
* Action: A centered, bordered `Positioned` input field appears on top. Typing filters a list below the input.


* **Architecture Tests:**
* [ ] **Modal Event Capture:** The floating widget captures all keyboard input, entirely blocking interaction with the underlying tree.
* [ ] **Occlusion Rendering:** The framework renders the floating widget over the existing layout without ANSI rendering artifacts.
* [ ] **Clean Dismount:** Pressing `Esc` pops the modal cleanly, perfectly reconstructing the occluded area beneath it via dirty rect invalidation without requiring a full terminal clear (`\x1b[2J`).