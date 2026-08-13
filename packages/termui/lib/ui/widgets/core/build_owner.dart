import 'package:termui/termui.dart';

/// Undocumented public member.
class BuildOwner {
  static final int _traceBuildScopeId = Tracer.registerString(
    'BuildOwner:buildScope',
  );

  /// Callback triggered when a visual update (rebuild) is needed.
  final void Function()? onNeedVisualUpdate;

  /// Undocumented public member.
  final Set<Element> isDirtyElements = {};

  /// Creates a new [BuildOwner] with an optional [onNeedVisualUpdate] callback.
  BuildOwner({this.onNeedVisualUpdate});

  /// Schedules the given [element] to be rebuilt.
  void scheduleBuildFor(Element element) {
    if (element.isDirty) return;
    element.isDirty = true;
    isDirtyElements.add(element);
    onNeedVisualUpdate?.call();
  }

  /// Rebuilds all dirty elements that have been scheduled.
  void buildScope() {
    if (isDirtyElements.isEmpty) return;
    Tracer.record(_traceBuildScopeId, Phase.begin, TraceCategory.build);
    try {
      final sorted = [
        for (final e in isDirtyElements)
          if (e.mounted) e,
      ]..sort((a, b) => a.treeDepth.compareTo(b.treeDepth));
      isDirtyElements.clear();
      for (final element in sorted) {
        if (element.mounted && element.isDirty) {
          element.performRebuild();
        }
      }
    } finally {
      Tracer.record(_traceBuildScopeId, Phase.end, TraceCategory.build);
    }
  }
}
