import 'package:termui/termui.dart';

/// A function that builds a widget given a build context.
typedef WidgetBuilder = Widget Function(BuildContext context);

/// A stateless widget that delegates its build method to a callback.
class Builder extends StatelessWidget {
  /// The builder function.
  final WidgetBuilder builder;

  /// Creates a [Builder] widget.
  const Builder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) => builder(context);
}
