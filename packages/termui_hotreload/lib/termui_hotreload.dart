import 'package:termui/termui.dart';
import 'package:hotreloader/hotreloader.dart';

/// An optional helper class that provides a dead-simple way to enable
/// Dart VM Hot Reload for a `termui` application.
class TermuiHotReload {
  final HotReloader _reloader;

  TermuiHotReload._(this._reloader);

  /// Enables auto hot reload in development environments.
  ///
  /// Automatically injects the `hotreloader` package and broadcasts hot reload
  /// events to all registered `Reassemblable` targets inside `termui`.
  ///
  /// Ensure you run your app with `dart --enable-vm-service bin/main.dart`.
  static Future<TermuiHotReload?> enable({
    void Function(Object error)? onError,
  }) async {
    const isDebug = !bool.fromEnvironment('dart.vm.product');
    if (!isDebug) return null;

    try {
      final reloader = await HotReloader.create(
        onAfterReload: (ctx) {
          TermuiBinding.reassembleAll();
        },
      );
      return TermuiHotReload._(reloader);
    } catch (e) {
      onError?.call(e);
      return null;
    }
  }

  /// Disposes of the hot reloader file watchers and VM service connection.
  /// Call this at the end of your `main()` method so the Dart process can gracefully exit.
  Future<void> disable() async {
    await _reloader.stop();
  }
}
