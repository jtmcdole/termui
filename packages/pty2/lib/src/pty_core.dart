import 'dart:io';
import 'dart:typed_data';

/// Result of a synchronous PTY write attempt by [PtyCoreWriter.write].
enum PtyWriteStatus {
  /// All bytes were written to the underlying PTY or pipe.
  written,

  /// The PTY or pipe is closed, stopped, or errored; no further writes will
  /// succeed and the owning isolate must call [PtyCoreWriter.free].
  closed,
}

/// Platform-specific low-level PTY handle container.
abstract interface class PtyCore {
  /// Reads the next chunk of PTY output, returning `null` on EOF.
  Uint8List? read();

  /// Returns the child exit code if it has already exited, or `null`.
  int? exitCodeNonBlocking();

  /// Blocks until the child exits and returns its exit code.
  int exitCodeBlocking();

  /// Terminates the child process and stops further PTY I/O.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);

  /// Updates the PTY window dimensions in character cells and optional pixels.
  void resize(int width, int height, {int pixelWidth = 0, int pixelHeight = 0});

  /// Writes [data] synchronously when writer ownership has not been transferred.
  ///
  /// Throws [StateError] if [takeWriter] has already been called.
  void write(List<int> data);

  /// Notifies the core that the reader isolate observed EOF and stopped.
  void onReaderClosed();

  /// Isolate-sendable handle used by the reader and exit-waiter isolates.
  PtyCoreWorker get worker;

  /// Transfers exclusive single-isolate ownership of the blocking input writer.
  ///
  /// Throws [StateError] if ownership has already been transferred. The caller
  /// must invoke [PtyCoreWriter.free] when the writer isolate shuts down.
  PtyCoreWriter takeWriter();
}

/// Isolate-sendable worker that performs blocking reads and exit waits.
abstract interface class PtyCoreWorker {
  /// Reads the next chunk of output from the PTY, returning `null` on EOF.
  Uint8List? read();

  /// Blocks until the child process exits and returns its exit code.
  int exitCodeBlocking();

  /// Releases native buffers and OS handles owned by the reader isolate.
  void free();
}

/// Isolate-sendable handle that performs blocking writes to a PTY input stream.
///
/// Implementations must be safe to pass across `Isolate.spawn` boundaries and
/// are owned by a single isolate at a time.
abstract interface class PtyCoreWriter {
  /// Writes all bytes in [data], blocking until written or the stream closes.
  ///
  /// Returns [PtyWriteStatus.closed] if the writer has been freed, stopped, or
  /// the underlying pipe/PTY closed or errored.
  PtyWriteStatus write(Uint8List data);

  /// Releases native write buffers and closes the owned OS input handle.
  ///
  /// Must be idempotent and invoked on the isolate that owns this writer.
  void free();
}

/// Reusable closed sentinel returned when writer ownership is taken after close.
final class ClosedPtyCoreWriter implements PtyCoreWriter {
  /// Creates a [ClosedPtyCoreWriter].
  const ClosedPtyCoreWriter();

  @override
  PtyWriteStatus write(Uint8List data) => PtyWriteStatus.closed;

  @override
  void free() {}
}
