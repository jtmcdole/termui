import 'package:termui/termui.dart';
import 'package:test/test.dart';
import 'tester.dart';

/// Base class for all widget query finders in the [termui] element tree.
abstract base class Finder {
  /// Creates a [Finder].
  const Finder();

  /// Filters [candidates] to only return matching elements.
  Iterable<Element> apply(Iterable<Element> candidates);
}

/// Registry of common widget search patterns.
final class CommonFinders {
  /// Creates a [CommonFinders] provider.
  const CommonFinders();

  /// Finds widgets that match type [T].
  Finder byType<T extends Widget>() => _ByTypeFinder(T);

  /// Finds widgets that contain the given [text] string.
  Finder text(String text) => _ByTextFinder(text);

  /// Finds widgets with text that matches the provided Regular Expression string.
  Finder textPattern(String regExpPattern, {bool caseSensitive = true}) {
    return _ByTextFinder(RegExp(regExpPattern, caseSensitive: caseSensitive));
  }

  /// Finds widgets that have the specified [key].
  Finder byKey(Key key) => _ByKeyFinder(key);

  /// Finds widgets matching [matching] that are descendants of widgets matching [of].
  Finder descendant({required Finder of, required Finder matching}) =>
      _DescendantFinder(of, matching);
}

/// The global finder builder namespace.
const CommonFinders find = CommonFinders();

final class _ByTypeFinder extends Finder {
  final Type type;
  const _ByTypeFinder(this.type);

  @override
  Iterable<Element> apply(Iterable<Element> candidates) {
    return candidates.where((element) => element.widget.runtimeType == type);
  }

  @override
  String toString() => 'widget with type $type';
}

final class _ByTextFinder extends Finder {
  final Pattern pattern;
  const _ByTextFinder(this.pattern);

  bool _matches(String? data) {
    if (data case final String d) {
      return switch (pattern) {
        final String p when d.contains('\n') =>
          d.split('\n').any((line) => line == p),
        final String p => d == p,
        final RegExp r => r.hasMatch(d),
        _ => false,
      };
    }
    return false;
  }

  @override
  Iterable<Element> apply(Iterable<Element> candidates) {
    return candidates.where((element) {
      final widget = element.widget;
      switch (widget) {
        case Text(data: final data):
          return _matches(data);
        case RichText(text: final span):
          return _matches(_collectTextSpan(span));
        case TextField(controller: final ctrl):
          final txt = ctrl.text;
          return switch (pattern) {
            final String p => txt.contains(p),
            final RegExp r => r.hasMatch(txt),
            _ => false,
          };
        default:
          try {
            final dynamic dynWidget = widget;
            if (dynWidget.text case final String widgetText
                when _matches(widgetText)) {
              return true;
            }
          } catch (_) {}
          try {
            final dynamic dynWidget = widget;
            if (dynWidget.label case final String widgetLabel
                when _matches(widgetLabel)) {
              return true;
            }
          } catch (_) {}
          return false;
      }
    });
  }

  String _collectTextSpan(TextSpan span) {
    final sb = StringBuffer();
    if (span.text case final text?) sb.write(text);
    for (final child in span.children) {
      sb.write(_collectTextSpan(child));
    }
    return '$sb';
  }

  @override
  String toString() => switch (pattern) {
    final String p => 'text "$p"',
    final RegExp r => 'textMatch "${r.pattern}"',
    _ => 'textMatch "$pattern"',
  };
}

final class _ByKeyFinder extends Finder {
  final Key key;
  const _ByKeyFinder(this.key);

  @override
  Iterable<Element> apply(Iterable<Element> candidates) {
    return candidates.where((element) => element.widget.key == key);
  }

  @override
  String toString() => 'key $key';
}

void _collectElements(Element element, List<Element> result) {
  result.add(element);
  element.visitChildren((child) {
    _collectElements(child, result);
  });
}

/// Recursively traverses the element tree from the [root] node to find all elements.
Iterable<Element> collectAllElements(Element root) {
  final list = <Element>[];
  _collectElements(root, list);
  return list;
}

/// Asserts that a [Finder] matches no widgets in the tree.
const Matcher findsNothing = _findsNothing;

/// Asserts that a [Finder] matches exactly one widget in the tree.
const Matcher findsOneWidget = _findsOneWidget;

const Matcher _findsNothing = _FinderMatcher(0, 0);
const Matcher _findsOneWidget = _FinderMatcher(1, 1);

/// Asserts that a [Finder] matches exactly [count] widgets in the tree.
Matcher findsNWidgets(int count) => _FinderMatcher(count, count);

final class _FinderMatcher extends Matcher {
  final int? min;
  final int? max;

  const _FinderMatcher(this.min, this.max);

  @override
  bool matches(Object? item, Map matchState) {
    if (item is! Finder) {
      return false;
    }
    final tester = TerminalTester.active;
    if (tester == null) {
      matchState['error'] =
          'No active TerminalTester found. Ensure your test runs inside tester.run().';
      return false;
    }
    final root = tester.rootElement;
    if (root == null) {
      matchState['error'] = 'TerminalTester has no active/mounted rootElement.';
      return false;
    }
    final elements = item.apply(collectAllElements(root));
    final count = elements.length;
    if (min != null && count < min!) return false;
    if (max != null && count > max!) return false;
    return true;
  }

  @override
  Description describe(Description description) => switch ((min, max)) {
    (0, 0) => description.add('nothing'),
    (1, 1) => description.add('exactly one widget'),
    (final min, final max) when min == max => description.add(
      'exactly $min widgets',
    ),
    (final min?, final max?) => description.add(
      'between $min and $max widgets',
    ),
    (final min?, null) => description.add('at least $min widgets'),
    (null, final max?) => description.add('at most $max widgets'),
    _ => description,
  };

  @override
  Description describeMismatch(
    dynamic item,
    Description mismatchDescription,
    Map matchState,
    bool verbose,
  ) {
    if (matchState.containsKey('error')) {
      return mismatchDescription.add(matchState['error'] as String);
    }
    if (item is! Finder) {
      return mismatchDescription.add('is not a Finder');
    }
    final tester = TerminalTester.active;
    if (tester == null) {
      return mismatchDescription.add('no active TerminalTester');
    }
    final root = tester.rootElement;
    if (root == null) {
      return mismatchDescription.add('no active/mounted rootElement');
    }
    final elements = item.apply(collectAllElements(root));
    final count = elements.length;
    return mismatchDescription.add('found $count widgets matching $item');
  }
}

final class _DescendantFinder extends Finder {
  final Finder of;
  final Finder matching;
  const _DescendantFinder(this.of, this.matching);

  @override
  Iterable<Element> apply(Iterable<Element> candidates) {
    final parentElements = of.apply(candidates);
    if (parentElements.isEmpty) return const [];

    // For every matching parent, search its children
    final results = <Element>{};
    for (final parent in parentElements) {
      final children = <Element>[];
      parent.visitChildren((child) => _collectElements(child, children));
      results.addAll(matching.apply(children));
    }
    return results;
  }
}
