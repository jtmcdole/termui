// ignore_for_file: file_names

import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/ui.dart';

void main() async {
  // We run the application inside runGuarded to guarantee that the terminal's
  // configuration (raw mode, echo, cursor visibility, etc.) is restored safely,
  // even if an uncaught exception or crash occurs.
  await term.Terminal.runGuarded((terminal) async {
    await runQuestionnaire(terminal);
  });

  print('Questionnaire completed. Exited cleanly.');
  exit(0);
}

/// The core questionnaire flow, extracted for integration testing.
Future<void> runQuestionnaire(term.Terminal terminal) async {
  // 1. Immediately disable mouse tracking to clean up any leftover state from previous runs.
  terminal.disableMouseTracking();
  // 2. Hide the hardware cursor since we will draw our own cursor style.
  terminal.hideCursor();

  try {
    // Reusable styles
    const questionStyle = Style(
      modifiers: Modifier.bold,
      foreground: CharmColors.julep,
    );
    const highlightStyle = Style(foreground: Colors.yellow);

    // ==========================================
    // QUESTION 1: What is your name?
    // ==========================================
    // We pass a TextEditingController down to TextField to manage and retrieve
    // the entered text state without needing GlobalKeys or Builder wrappers.
    final nameCtrl = TextEditingController(text: '');

    await PromptRunner(
      terminal: terminal,
      // Notice: No hardcoded 'height' required! The framework calculates it dynamically
      // using the widget tree's intrinsic height.
      widget: Column([
        const Text('1. What is your name:', style: questionStyle),
        TextField(
          controller: nameCtrl,
          placeholder: 'Enter your name...',
          style: highlightStyle,
          focused: true,
        ),
      ]),
    ).run();

    final finalName = nameCtrl.text.trim().isEmpty
        ? 'Anonymous'
        : nameCtrl.text.trim();
    terminal.backend.write('\r\n  ✔ Name saved: $finalName\r\n\r\n');

    // ==========================================
    // QUESTION 2: Favorite Text Editor
    // ==========================================
    // We use the new SelectionController to manage choices and selections.
    final editors = ['VScode', 'VIM', 'Emacs', 'Zed', 'Notepad'];
    final editorCtrl = SelectionController<String>(
      options: editors,
      initialIndex: 0,
    );

    await PromptRunner(
      terminal: terminal,
      widget: Column([
        const Text(
          "2. What's your favorite text editor?",
          style: questionStyle,
        ),
        HorizontalRadioGroup(controller: editorCtrl, focused: true),
      ]),
    ).run();

    terminal.backend.write(
      '\r\n  ✔ Editor choice saved: ${editorCtrl.selected}\r\n\r\n',
    );

    // ==========================================
    // QUESTION 3: Preferred Operating System
    // ==========================================
    final osOptions = ['Linux', 'macOS', 'Windows'];
    final osCtrl = SelectionController<String>(
      options: osOptions,
      initialIndex: 0,
    );

    await PromptRunner(
      terminal: terminal,
      widget: Column([
        const Text(
          "3. What is your preferred operating system?",
          style: questionStyle,
        ),
        HorizontalRadioGroup(controller: osCtrl, focused: true),
      ]),
    ).run();

    terminal.backend.write(
      '\r\n  ✔ OS choice saved: ${osCtrl.selected}\r\n\r\n',
    );

    // ==========================================
    // SUMMARY SECTION: Rendered natively via printWidget
    // ==========================================
    terminal.backend.write('────────────────────────────────────────\r\n');

    // The new printWidget utility eliminates all Buffer/Renderer boilerplate.
    terminal.printWidget(
      Column([
        const Text(
          '🎉 QUESTIONNAIRE SUMMARY',
          style: Style(foreground: CharmColors.julep, modifiers: Modifier.bold),
        ),
        const SizedBox(height: 1),
        Text('• Name: $finalName'),
        Text('• Favorite Editor: ${editorCtrl.selected}'),
        Text('• Operating System: ${osCtrl.selected}'),
      ]),
    );

    terminal.backend.write('\r\n\r\n');
  } finally {
    // 3. Guarantee that mouse tracking is disabled and cursor is restored on exit.
    terminal.disableMouseTracking();
    terminal.showCursor();
  }
}
