import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  test(
    'ListView preserves mutated selectedIndex when parent rebuilds with same selectedIndex',
    () {
      final list = ListView.fromStrings(
        List.generate(30, (i) => 'Item $i'),
        selectedIndex: 0,
      );

      final element = list.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(Size(20, 10)));

      // Simulate user using mouse wheel down, mutating selectedIndex
      (element as ListViewElement).scrollOffset = 5;
      element.selectedIndex = 5;

      // Parent rebuilds (e.g. FPS tick) with the original selectedIndex (0)
      final list2 = ListView.fromStrings(
        List.generate(30, (i) => 'Item $i'),
        selectedIndex: 0,
      );

      element.update(list2);
      element.layout(BoxConstraints.tight(Size(20, 10)));

      final scroll2 = element.scrollOffset;
      final selected2 = element.selectedIndex;

      expect(
        selected2,
        5,
        reason: "Mutated selectedIndex was overwritten by parent rebuild!",
      );
      expect(
        scroll2,
        5,
        reason: "Scroll offset snapped back due to lost selectedIndex!",
      );
    },
  );
}
