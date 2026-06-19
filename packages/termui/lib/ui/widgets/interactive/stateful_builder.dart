import 'package:termui/termui.dart';

/// A custom stateful builder widget matching standard Flutter patterns.
/// It allows stateful builders to declare their widget layouts dynamically
/// and obtain local access to `setState` to trigger rebuilds within inline loops.
class StatefulBuilder extends StatefulWidget {
  /// The builder callback.
  final Widget Function(
    BuildContext context,
    void Function(void Function()) setState,
  )
  builder;

  /// Creates a [StatefulBuilder].
  const StatefulBuilder({required this.builder});

  @override
  State<StatefulBuilder> createState() => _StatefulBuilderState();
}

class _StatefulBuilderState extends State<StatefulBuilder> {
  @override
  Widget build(BuildContext context) {
    return widget.builder(context, setState);
  }
}
