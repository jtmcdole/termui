// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/ui.dart';

/// A dashboard widget simulating a heavy compilation process.
/// This example demonstrates live timing, vsync-aligned repaints,
/// and the robust features of our LinearProgressIndicator.
class BuildDashboard extends StatefulWidget {
  final int totalDurationMs;

  const BuildDashboard({super.key, this.totalDurationMs = 15000});

  @override
  State<BuildDashboard> createState() => _BuildDashboardState();
}

class _BuildDashboardState extends State<BuildDashboard> {
  late final Stopwatch _stopwatch;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Initialize the stopwatch using the clock package for testability.
    _stopwatch = clock.stopwatch()..start();

    // Start a periodic timer tied to a standard vsync interval (~16ms)
    // to trigger rebuilds at a steady frame rate for smooth progress rendering.
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_stopwatch.elapsedMilliseconds >= widget.totalDurationMs) {
        _stopwatch.stop();
        _ticker?.cancel();
        PromptScope.of(context)?.done();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // We calculate the overall progress fraction dynamically based on elapsed time.
    final elapsed = _stopwatch.elapsedMilliseconds;

    // Format the live clock using the clock package.
    final now = clock.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    // Build the UI using termui's declarative layout system with modern Dart collections.
    return Column([
      Text(
        'Live Clock: $timeStr',
        style: const Style(modifiers: Modifier.bold),
      ),
      const SizedBox(height: 1),
      if (elapsed < 3000) ...[
        // Task 1: Indeterminate State (0 - 3 seconds)
        // We simulate fetching dependencies with a text-based spinner.
        const Text('[1/3] Fetching dependencies...'),
        Row([
          const SizedBox(width: 2, child: Text('  ')),
          SizedBox(width: 1, child: Spinner.line(clockStopwatch: _stopwatch)),
        ]),
      ] else if (elapsed < 10000) ...[
        // Task 2: Standard Compilation (3 - 10 seconds)
        const Text('[2/3] Compiling C++ source...'),
        // The LinearProgressIndicator shows off smooth fractional block characters
        // and a solid color style to cleanly display progress.
        LinearProgressIndicator(
          ((elapsed - 3000) / 7000).clamp(0.0, 1.0),
          smooth: true,
          style: const Style(foreground: Colors.blue),
        ),
      ] else ...[
        // Task 3: Linking & Finalizing (10 - 15 seconds)
        const Text('[3/3] Linking binaries...'),
        // This LinearProgressIndicator showcases advanced features:
        // It leverages smooth fractional blocks, interpolates a horizontal gradient
        // between startColor and endColor, and uses an easing function to adjust progress speed.
        LinearProgressIndicator(
          ((elapsed - 10000) / 5000).clamp(0.0, 1.0),
          smooth: true,
          startColor: const Color.argb(0xFF00FFFF), // Cyan
          endColor: const Color.argb(0xFF00FF00), // Green
          easing: Easing.easeOutQuad,
        ),
      ],
    ]);
  }
}

void main() async {
  // We run the application inside runGuarded to guarantee that the terminal's
  // configuration (raw mode, echo, cursor visibility, etc.) is restored safely,
  // even if an uncaught exception or crash occurs.
  await term.Terminal.runGuarded((terminal) async {
    // Hide the hardware cursor to avoid visual flickering while updating our dashboard.
    terminal.hideCursor();

    try {
      // PromptRunner sets up an inline rendering loop by default.
      // It respects the natural height of our BuildDashboard widget.
      // The prompt will complete programmatically when the BuildDashboard calls
      // PromptScope.done() once the compilation simulation finishes.
      // Inline rendering means the final build output remains visible in the
      // terminal's scrollback history after the application exits!
      await PromptRunner(
        terminal: terminal,
        widget: const BuildDashboard(totalDurationMs: 15000),
      ).run();

      // Print the final completion message after the prompt runner exits.
      terminal.backend.write('\r\n🎉 Build Complete!\r\n');
    } finally {
      // Ensure cursor visibility is restored on exit.
      terminal.showCursor();
    }
  });

  exit(0);
}
