/// Wraps a single-subscription [source] byte stream (such as `dart:io`
/// `stdin`) as a reusable broadcast stream across multiple `Terminal` sessions.
///
/// Pauses [source] when the last listener cancels and resumes it on re-listen
/// so keystrokes arriving between sessions stay buffered instead of dropping.
Stream<List<int>> shareReusableInputStream(Stream<List<int>> source) =>
    source.asBroadcastStream(
      onListen: (subscription) => subscription.resume(),
      onCancel: (subscription) => subscription.pause(),
    );
