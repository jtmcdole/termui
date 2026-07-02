# termui

A modular, high-performance **Terminal User Interface (TUI)** and **Windowing System** for Dart.

This library shifts away from naive command-line printing (which causes terminal flickering and excessive CPU overhead) to provide a desktop-like windowed environment inside standard ANSI/TTY terminal applications.

<video src="https://github.com/user-attachments/assets/a850086b-de1b-4fda-86f0-c97e339ff271" width="100%" autoplay loop muted controls></video>

---

> [!WARNING]
> **Experimental Status:** This project is experimental and currently under active development. The APIs are subject to change, and features are being added and refactored frequently. If you want to use it, reach out and give feedback!

---

## Features

- **Overlapping Window Management**: Supports floating, draggable, and resizable window frames with titles, custom borders, and dynamic Z-index layering.
- **Double Buffering**: Eliminates terminal flickering by maintaining an in-memory frame buffer of what is visible on-screen and comparing it with a previous frame to compute delta updates.
- **Minimal ANSI Diffing**: Emits the shortest possible terminal sequences (cursor jumps and style transitions) to repaint only the modified cells.
- **Layout Solver**: Flexible constraints layout system featuring fixed size, percentage, flex (proportional), and min-max boundaries.
- **Hierarchical Input & Focus System**: Translates raw ANSI byte streams from `stdin` into high-level event objects (keys, mouse clicks/scrolls/drags, paste segments) and dispatches them down a keyboard focus node tree.
- **Vector Graphics & Braille Canvas**: Features a 2D sub-pixel braille-based grid canvas with antialiasing controls, filled polygons (triangles, rectangles), RGB coloring, and transformations.
- **Modular Widget Toolkit**: Standard widgets including paragraphs, lists, text inputs, text areas with cursors, progress bars, tables, paginators, spinners, and trees.

---

## Screenshots

<video src="https://github.com/user-attachments/assets/e7975a3a-0732-4f54-a987-49b0375bd307" width="50%" autoplay loop muted controls></video>

<img width="1267" height="110" alt="Screenshot 2026-06-19 221607" src="https://github.com/user-attachments/assets/86581ba2-722a-46db-a607-a0ce349ff80c" />
<img width="293" height="181" alt="Screenshot 2026-06-19 221456" src="https://github.com/user-attachments/assets/9c741765-a612-43cd-b0e0-9e58eb3fac2c" />
<img width="260" height="178" alt="Screenshot 2026-06-19 221452" src="https://github.com/user-attachments/assets/d45946fc-7186-4088-893e-cc81de04f07f" />
<img width="221" height="237" alt="Screenshot 2026-06-19 221439" src="https://github.com/user-attachments/assets/ced3691c-1fce-4342-ac17-9c742db39026" />
<img width="263" height="90" alt="Screenshot 2026-06-19 221409" src="https://github.com/user-attachments/assets/59040743-c9d3-4292-bbbd-12b7d48873b7" />
<img width="295" height="77" alt="Screenshot 2026-06-19 221402" src="https://github.com/user-attachments/assets/e9e67ff8-39cf-4df1-8214-805534fb5555" />
<img width="940" height="135" alt="Screenshot 2026-06-19 215626" src="https://github.com/user-attachments/assets/9a6f272e-757d-4aa3-b924-03572f294066" />
