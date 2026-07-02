import 'dart:async';
import 'package:termui/termui.dart';
import 'package:termui_hotreload/termui_hotreload.dart';

/// 1. MODEL
/// Represents the raw data state.
class CounterModel {
  int clicks = 0;
}

/// 2. VIEW MODEL
/// Encapsulates business logic, modifies the model, and broadcasts updates.
class CounterViewModel {
  final CounterModel _model = CounterModel();

  // Using a standard Dart broadcast stream for reactive updates
  final _stateController = StreamController<int>.broadcast();
  Stream<int> get stateStream => _stateController.stream;

  int get currentClicks => _model.clicks;

  void increment() {
    _model.clicks++;
    _stateController.add(_model.clicks);
  }

  void dispose() {
    _stateController.close();
  }
}

/// 3. VIEW
/// Binds to the ViewModel. Only the exact node requiring updates rebuilds.
class MyAppMVVM extends StatelessWidget {
  final CounterViewModel viewModel;

  const MyAppMVVM({super.key, required this.viewModel});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column([
        const Text(
          'TermUI Strict MVVM Demo',
          style: Style(modifiers: Modifier.bold, foreground: Colors.yellow),
        ),
        const SizedBox(height: 2),
        // We only wrap the reactive text component in a stateful listener.
        // The rest of the tree (Column, Center, Button) remains const/static.
        StreamBuilder<int>(
          stream: viewModel.stateStream,
          initialData: viewModel.currentClicks,
          builder: (context, snapshot) {
            final data = snapshot.data ?? 0;
            return Text(
              'Button clicked: $data times',
              style: const Style(foreground: Colors.white),
            );
          },
        ),
        const SizedBox(height: 1),
        Button(
          text: 'Click Me!',
          onPressed: viewModel.increment,
          style: const Style(
            foreground: Colors.black,
            background: Colors.green,
          ),
          focusedStyle: const Style(
            foreground: Colors.white,
            background: Colors.blue,
            modifiers: Modifier.bold,
          ),
        ),
      ]),
    );
  }
}

void main() async {
  final hotreload = await TermuiHotReload.enable(
    onError: (e) {
      // Ignored in non-debug mode or gracefully handle missing VM service
    },
  );

  final terminal = Terminal();
  final viewModel = CounterViewModel();

  final runner = PromptRunner<void>(
    terminal: terminal,
    alternateScreen: true,
    widget: MyAppMVVM(viewModel: viewModel),
    exitConditions: {
      PromptExitTrigger.escape: PromptExitAction.cancel,
      PromptExitTrigger.controlC: PromptExitAction.abort,
    },
  );

  terminal.enableMouseTracking();
  await runner.run();

  terminal.disableMouseTracking();
  await hotreload?.disable();
  viewModel.dispose();
  terminal.dispose();
}
