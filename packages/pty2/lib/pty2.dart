import 'dart:io';

import 'package:pty2/src/impl/unix.dart';
import 'package:pty2/src/impl/windows.dart';
import 'package:pty2/src/pty.dart';
import 'package:pty2/src/pty_core.dart';

export 'src/pty.dart';
export 'src/pty_error.dart';

/// A pseudo-terminal interface that provides programmatic access to a terminal process.
///
/// This class represents a pseudo-terminal (PTY), allowing you to interact
/// with command-line applications programmatically as if they were running
/// in a real terminal emulator.
abstract class PseudoTerminal {
  /// Internal testing flag to allow non-blocking PTY on Windows.
  /// If [blocking] is [true], the PseudoTerminal starts in blocking mode
  /// (better suited for flutter release mode), otherwise in polling mode
  /// (better suited for flutter debug mode).
  ///
  /// The [raw] flag puts the terminal into raw mode on Unix. By default, Unix
  /// pseudo-terminals operate in canonical mode with ECHO enabled. This means
  /// the kernel buffers input line-by-line and physically echoes characters back.
  /// If you are transferring binary data, streaming high-throughput buffers, or
  /// do not want the kernel to mangle line endings and echo data, set [raw] to true.
  static PseudoTerminal start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool ackProcessed = false,
    bool raw = false,
    // bool includeParentEnvironment = true,
    // bool runInShell = false,
    // ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    late PtyCore core;

    if (Platform.isWindows) {
      core = PtyCoreWindows.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } else {
      //add '-l' as argument for the shell to perform a login
      arguments = List<String>.generate(
        arguments.length + 1,
        (index) => index == 0 ? '-l' : arguments[index - 1],
      );

      core = PtyCoreUnix.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        raw: raw,
      );
    }

    return BlockingPseudoTerminal(core, ackProcessed)..init();
  }

  /// Initializes the pseudo-terminal process.
  ///
  /// This must be called after creating the terminal, usually done automatically
  /// by [start].
  void init();
  /// Kills the underlying process.
  ///
  /// Sends the provided [signal] (defaults to [ProcessSignal.sigterm]) to the
  /// running process. Returns true if the signal was successfully delivered.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);

  /// A future that completes with the exit code of the process when it terminates.
  Future<int> get exitCode;

  // int get pid {
  //   return _core.pid;
  // }

  /// Writes data to the standard input of the pseudo-terminal.
  ///
  /// The [input] string is encoded and sent to the process.
  void write(String input);

  /// A stream of output from the standard output and standard error of the pseudo-terminal.
  ///
  /// This stream emits the decoded output from the process.
  Stream<String> get out;

  /// Acknowledges that a chunk of output has been processed.
  ///
  /// Used in conjunction with `ackProcessed: true` in [start] to manage flow control
  /// and prevent the terminal from overwhelming the Dart process.
  void ackProcessed();

  /// Resizes the pseudo-terminal window size.
  ///
  /// The process running in the pseudo-terminal will be notified of the new
  /// [width] (columns) and [height] (rows).
  void resize(int width, int height);
}
