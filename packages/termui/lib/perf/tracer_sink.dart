/// Abstract class representing a target sink for event tracing data.
abstract class TracerSink {
  /// Send a buffer of event data and list of newly registered strings to the sink.
  void add(List<int> buffer, List<String> newStrings);

  /// Close the sink and ensure all pending trace data is flushed to the target.
  Future<void> close();
}
