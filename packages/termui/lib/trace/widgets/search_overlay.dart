import "package:termui/termui_trace.dart";
import "package:termui/termui.dart";
// ignore_for_file: public_member_api_docs
import 'package:termui/ui/event.dart' as evt;
import 'dart:math';

class QueryToken {
  /// Whether this token should exclude matching events (starts with '-').
  final bool isExclusion;

  /// The targeted field for this token (e.g., 'dur', 'name', 'widget').
  /// If null, matches against name, category, and all metadata.
  final String? field;

  /// The comparison operator, used for duration fields (e.g., '>', '<', '>=').
  final String? operator;

  /// The raw value to match or parse.
  final String value;

  /// If [value] is wrapped in slashes (e.g. `/foo/`), this holds the compiled RegExp.
  final RegExp? regex;

  /// If [field] is a duration field, this holds the parsed time in microseconds.
  final double? durationUs;

  /// Optimization: whether [value] contains any uppercase letters (Smart Case).
  final bool isSmartCase;

  static final RegExp _smartCaseDetector = RegExp(r'[A-Z]');

  /// Creates a [QueryToken] representing a single search requirement.
  ///
  /// Examples:
  /// * `QueryToken(isExclusion: false, field: 'name', operator: null, value: 'paint')`
  /// * `QueryToken(isExclusion: true, field: 'dur', operator: '>=', value: '16ms')`
  QueryToken({
    required this.isExclusion,
    required this.field,
    required this.operator,
    required this.value,
  }) : regex = _parseRegex(value),
       durationUs = _parseDuration(field, value),
       isSmartCase = value.contains(_smartCaseDetector);

  static RegExp? _parseRegex(String value) {
    if (value.length >= 2 && value.startsWith('/') && value.endsWith('/')) {
      try {
        return RegExp(value.substring(1, value.length - 1));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static double? _parseDuration(String? field, String value) {
    if (field != 'dur' && field != 'duration') return null;
    final valLower = value.toLowerCase();
    if (valLower.endsWith('ms')) {
      final numStr = valLower.substring(0, valLower.length - 2);
      final val = double.tryParse(numStr);
      if (val != null) return val * 1000.0;
    } else if (valLower.endsWith('us')) {
      final numStr = valLower.substring(0, valLower.length - 2);
      final val = double.tryParse(numStr);
      if (val != null) return val;
    } else if (valLower.endsWith('s')) {
      final numStr = valLower.substring(0, valLower.length - 1);
      final val = double.tryParse(numStr);
      if (val != null) return val * 1000000.0;
    } else {
      return double.tryParse(valLower);
    }
    return null;
  }

  /// Evaluates whether the given [span] satisfies this query token.
  bool matches(TraceSpan span) {
    var match = false;

    if (field == 'dur' || field == 'duration') {
      if (durationUs != null) {
        final spanDur = (span.endUs - span.startUs).toDouble();
        match = switch (operator) {
          '>' => spanDur > durationUs!,
          '<' => spanDur < durationUs!,
          '>=' => spanDur >= durationUs!,
          '<=' => spanDur <= durationUs!,
          _ => spanDur == durationUs!,
        };
      }
    } else {
      final searchTargets = <String>[];

      switch (field) {
        case 'name':
          searchTargets.add(span.name);
        case 'cat':
        case 'category':
          searchTargets.add(span.category);
        case String f:
          if (span.args.containsKey(f)) {
            searchTargets.add(span.args[f]!);
          }
        case null:
          searchTargets.add(span.name);
          searchTargets.add(span.category);
          searchTargets.addAll(span.args.values);
      }

      for (final target in searchTargets) {
        if (regex != null) {
          if (regex!.hasMatch(target)) {
            match = true;
            break;
          }
        } else {
          final targetLower = target.toLowerCase();
          final valLower = value.toLowerCase();

          if (isSmartCase) {
            if (target.contains(value)) {
              match = true;
              break;
            }
          } else {
            if (targetLower.contains(valLower)) {
              match = true;
              break;
            }
          }
        }
      }
    }

    return isExclusion ? !match : match;
  }

  static List<QueryToken> parseQuery(String query) {
    final tokens = <QueryToken>[];
    final regex = RegExp(
      r'(-?)(?:([a-zA-Z0-9_]+):)?([<>=]+)?(?:\"([^\"]*)\"|([^\s]+))',
    );

    for (final match in regex.allMatches(query)) {
      final isExcl = match.group(1) == '-';
      final field = match.group(2);
      final op = match.group(3);
      final val = match.group(4) ?? match.group(5);
      if (val != null && val.isNotEmpty) {
        tokens.add(
          QueryToken(
            isExclusion: isExcl,
            field: field,
            operator: op,
            value: val,
          ),
        );
      }
    }
    return tokens;
  }
}

class SearchOverlay extends StatefulWidget {
  final List<TraceSpan> spans;
  final void Function(TraceSpan span) onMatchSelected;
  final void Function(String query) onQueryChanged;
  final VoidCallback onClose;
  final String initialQuery;

  const SearchOverlay({
    required this.spans,
    required this.onMatchSelected,
    required this.onQueryChanged,
    required this.onClose,
    this.initialQuery = '',
  });

  @override
  State<SearchOverlay> createState() => SearchOverlayState();
}

class SearchOverlayState extends State<SearchOverlay> {
  late TextEditingController searchController;
  late FocusNode _focusNode;
  List<TraceSpan> filteredSpans = [];
  int selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    searchController = TextEditingController(text: widget.initialQuery);
    searchController.addListener(_onSearchChanged);
    _focusNode = FocusNode(id: 'search_overlay_input')..requestFocus();
    _onSearchChanged();
  }

  @override
  void dispose() {
    searchController.removeListener(_onSearchChanged);
    _focusNode.dispose();
    super.dispose();
  }

  int _searchVersion = 0;

  void _onSearchChanged() {
    final query = searchController.text;
    widget.onQueryChanged(query);
    _performSearch(query);
  }

  Future<void> _performSearch(String query) async {
    final version = ++_searchVersion;

    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          filteredSpans = [];
          selectedIndex = 0;
        });
      }
      return;
    }

    final tokens = QueryToken.parseQuery(query);
    final results = <TraceSpan>[];
    int count = 0;

    for (final span in widget.spans) {
      if (version != _searchVersion) return; // Abort stale search

      var allMatch = true;
      for (final token in tokens) {
        if (!token.matches(span)) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) {
        results.add(span);
      }

      // Yield to event loop every 5000 elements to keep UI perfectly responsive
      if (++count % 5000 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    if (version == _searchVersion && mounted) {
      setState(() {
        filteredSpans = results;
        selectedIndex = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (event) {
        if (event.type == evt.KeyType.escape) {
          PromptScope.of(context)?.done();
          widget.onClose();
          return true;
        }
        if (event.type == evt.KeyType.up) {
          if (filteredSpans.isNotEmpty) {
            setState(() {
              selectedIndex = (selectedIndex - 1).clamp(
                0,
                min(filteredSpans.length, 1000) - 1,
              );
            });
          }
          return true;
        }
        if (event.type == evt.KeyType.down) {
          if (filteredSpans.isNotEmpty) {
            setState(() {
              selectedIndex = (selectedIndex + 1).clamp(
                0,
                min(filteredSpans.length, 1000) - 1,
              );
            });
          }
          return true;
        }
        if (event.type == evt.KeyType.enter) {
          if (filteredSpans.isNotEmpty &&
              selectedIndex < filteredSpans.length) {
            widget.onMatchSelected(filteredSpans[selectedIndex]);
            return true;
          }
        }
        return false;
      },
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            topChar: '─',
            bottomChar: '─',
            leftChar: '│',
            rightChar: '│',
            topLeftChar: '╔',
            topRightChar: '╗',
            bottomLeftChar: '╚',
            bottomRightChar: '╝',
            style: Style(foreground: Colors.white),
          ),
          backgroundColor: Color(30, 30, 30),
        ),
        child: Column([
          Row([
            Text(
              ' Search [Esc or X to close]',
              style: const Style(foreground: Color(0, 255, 255)),
            ),
            Expanded(child: const SizedBox()),
            InkwellButton(onPressed: widget.onClose, text: '[X]'),
          ]),
          SizedBox(
            height: 1,
            child: Text(
              '─' * 50,
              style: const Style(foreground: Color(128, 128, 128)),
            ),
          ),
          Row([
            Text(' > ', style: const Style(foreground: Colors.yellow)),
            Expanded(
              child: TextField(
                controller: searchController,
                focusNode: _focusNode,
                style: const Style(
                  foreground: Colors.white,
                  background: CharmColors.char,
                ),
              ),
            ),
          ]),
          SizedBox(
            height: 1,
            child: Text(
              '─' * 50,
              style: const Style(foreground: Color(128, 128, 128)),
            ),
          ),
          SizedBox(
            height: 1,
            child: Row([
              Text(
                ' Syntax: "foo", "-bar", "/regex/"',
                style: const Style(foreground: Color(150, 150, 150)),
              ),
            ]),
          ),
          SizedBox(
            height: 1,
            child: Row([
              Text(
                ' Matches: ${filteredSpans.length} / ${searchController.text.isNotEmpty ? widget.spans.length : 0}',
                style: const Style(foreground: Colors.green),
              ),
            ]),
          ),
          Expanded(
            child: ListView.raw(
              showScrollbar: true,
              selectedIndex: selectedIndex,
              onSelect: (index) {
                setState(() {
                  selectedIndex = index;
                });
                widget.onMatchSelected(filteredSpans[index]);
              },
              lines: filteredSpans.take(1000).map((span) {
                return ' • ${span.name} (${(span.endUs - span.startUs) / 1000.0}ms)';
              }).toList(),
            ),
          ),
        ]),
      ),
    );
  }
}
