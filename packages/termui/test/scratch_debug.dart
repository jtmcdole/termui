import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/widget_toolkit.dart';

void main() {
  final f1 = TextFormField(label: 'F1', initialValue: '');
  final f2 = TextFormField(label: 'F2', initialValue: '');
  final form = Form(fields: [f1, f2]);

  final tree = ElementWidget(form);
  final buffer = Buffer.blank(20, 10);
  tree.layout(BoxConstraints.tight(const Size(20, 10)));
  tree.paint(buffer, Offset.zero);

  print('Initial: f1.focused=${f1.focused}, f2.focused=${f2.focused}');
  print('Initial values: f1.value=${f1.value}, f2.value=${f2.value}');

  // Simulate typing 'a' on f1
  form.handleKeyEvent(const KeyEvent('a', KeyType.character));
  print('After typing a: f1.value=${f1.value}');

  // Re-layout/paint
  tree.layout(BoxConstraints.tight(const Size(20, 10)));
  tree.paint(buffer, Offset.zero);
  print('After layout/paint: f1.value=${f1.value}');

  // Simulate Tab key
  form.handleKeyEvent(const KeyEvent('tab', KeyType.character));
  print('After tab: f1.focused=${f1.focused}, f2.focused=${f2.focused}');
  print('After tab values: f1.value=${f1.value}, f2.value=${f2.value}');

  // Re-layout/paint
  tree.layout(BoxConstraints.tight(const Size(20, 10)));
  tree.paint(buffer, Offset.zero);
  print(
    'After layout/paint post-tab: f1.focused=${f1.focused}, f2.focused=${f2.focused}',
  );
  print(
    'After layout/paint post-tab values: f1.value=${f1.value}, f2.value=${f2.value}',
  );
}
