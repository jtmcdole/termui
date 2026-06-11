import 'terminal_backend.dart';

/// Returns the appropriate [TerminalBackend] for the current platform.
///
/// Throws an [UnsupportedError] if the platform is not supported.
TerminalBackend getPlatformBackend() {
  throw UnsupportedError('No platform backend implementation found.');
}

/// Returns whether the current terminal program is iTerm2.
bool isItermTerminal() => false;
