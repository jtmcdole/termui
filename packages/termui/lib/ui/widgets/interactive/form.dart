import 'dart:async';

import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/event.dart' as ev;

bool _isEnterKeyEvent(term.KeyEvent event) =>
    event.type == .enter || event.baseKey == term.TermKey.enter;

final class _FormFieldTapTarget extends Widget {
  final VoidCallback onTapPress;
  final Widget child;

  const _FormFieldTapTarget({
    super.key,
    required this.onTapPress,
    required this.child,
  });

  @override
  Element createElement() => _FormFieldTapTargetElement(this);
}

final class _FormFieldTapTargetElement extends SingleChildElement
    implements ev.MouseEventConsumer {
  _FormFieldTapTargetElement(_FormFieldTapTarget super.widget);

  @override
  Widget? get childWidget => (widget as _FormFieldTapTarget).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    final childSize = childElement?.layout(constraints) ?? Size.zero;
    return constraints.constrain(childSize);
  }

  @override
  bool handleMouseEvent(term.MouseEvent event, int localX, int localY) {
    if (event.type != .press || event.button != .left) return false;
    if (localX < 0 ||
        localX >= size.width ||
        localY < 0 ||
        localY >= size.height) {
      return false;
    }
    (widget as _FormFieldTapTarget).onTapPress();
    return true;
  }
}

/// Ancestor provider to expose form state to field elements.
class FormScope extends InheritedWidget {
  /// The underlying [FormState] representing this form.
  final FormState formState;

  /// Creates a [FormScope] inherited widget.
  const FormScope({required this.formState, required super.child});

  @override
  bool updateShouldNotify(FormScope oldWidget) => true;
}

/// Abstract base class for all form field widgets in `termui`.
///
/// Form fields are widgets designed to collect user input, manage validation rules,
/// track focused status, and represent state within an ancestor [Form].
///
/// When using dynamic forms (with [Form(child: ...)]), form fields walk up the `BuildContext`
/// to locate the ancestor `Form` and register their state dynamically.
///
/// ### Subclassing FormField
///
/// To create a custom FormField:
/// 1. Extend [FormField] specifying the data type `T` (e.g. `class MyField extends FormField<int>`).
/// 2. Implement [createState] to return a state class extending [FormFieldState].
/// 3. Provide layout requirements by overriding [getPreferredHeight].
/// 4. Implement event processing by overriding [handleKeyEvent].
///
/// ### Core API Reference
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | [label] | `String` | Header title of the input field. |
/// | [description] | `String` | Auxiliary description shown below the label. |
/// | [initialValue] | `T?` | The default value when initialized or reset. |
/// | [validator] | `String? Function(T?)?` | Callback to execute during validation. |
/// | [focused] | `bool` | Current keyboard focus status. |
abstract class FormField<T> extends StatefulWidget
    implements Focusable, KeyEventHandler {
  /// The title label displayed for this field.
  final String label;

  /// Optional secondary description text for helper information.
  final String description;

  /// The initial value of the field when created or reset.
  final T? initialValue;

  /// A validation function called by [FormState.validate].
  /// Returns an error message string if invalid, or `null` if valid.
  final String? Function(T?)? validator;

  /// Optional external [FocusNode] for this field.
  final FocusNode? focusNode;

  /// The current value of the form field.
  T? value;

  /// The validation error text if validation fails; otherwise, `null`.
  String? errorText;

  /// Whether this field has been focused at least once.
  bool touched = false;

  bool _focused = false;

  /// Whether this field currently has input focus.
  @override
  bool get focused => _focused;

  set focused(bool val) {
    final wasFocused = _focused;
    if (wasFocused && !val && touched) {
      validate();
    }
    _focused = val;
    if (val) {
      touched = true;
    }
    if (wasFocused != val) {
      _state?._syncFromImperativeFocus(val);
    }
  }

  /// Creates a [FormField] with common properties.
  FormField({
    super.key,
    required this.label,
    this.description = '',
    this.initialValue,
    this.validator,
    this.focusNode,
    bool focused = false,
  }) : value = initialValue,
       _focused = focused;

  /// Returns whether this field currently contains a validation error.
  bool get hasError => errorText != null;

  /// Runs the validator callback against the current field value.
  /// Updates [errorText] and returns whether the field is valid.
  bool validate() {
    if (_state != null) {
      return _state!.validate();
    }
    errorText = validator?.call(value);
    return errorText == null;
  }

  /// Calculates preferred layout height needed to render this field cleanly.
  int getPreferredHeight();

  /// Handles user key inputs to update the internal value.
  @override
  bool handleKeyEvent(term.KeyEvent event);

  FormFieldState<T>? _state;
}

/// Abstract state management class for FormField elements.
///
/// Manages the validation errors, lifecycle context hooks, and registration of a
/// [FormField] with its parent [Form]. It hooks into [didChangeDependencies] and
/// [dispose] to coordinate dynamic inherited widget bindings with [FormScope].
abstract class FormFieldState<T> extends State<FormField<T>> {
  late FocusNode _focusNode;
  FormState? _registeredForm;
  bool _needsInitialFocusSync = false;
  bool _syncingFocusCallback = false;

  /// The [FocusNode] owned or managed by this field state.
  FocusNode get focusNode => _focusNode;

  /// Whether a child widget (such as [TextField]) hosts the [Focus] widget.
  bool get delegatesFocusToChild => false;

  /// Whether this field consumes `Enter` inside a [Form] instead of advancing.
  bool get consumesEnterInForm => false;

  /// Retrieves the current value of the form field.
  T? get value => widget.value;

  /// Retrieves the validation error message if invalid; otherwise, `null`.
  String? get errorText => widget.errorText;

  /// Returns whether this field currently holds an active validation error.
  bool get hasError => widget.errorText != null;

  /// Triggers field validation using [FormField.validator].
  ///
  /// Updates widget.errorText, notifies listeners of state updates via [setState], and returns
  /// whether the field is currently valid.
  bool validate() {
    final nextError = widget.validator?.call(widget.value);
    if (mounted) {
      setState(() {
        widget.errorText = nextError;
      });
    } else {
      widget.errorText = nextError;
    }
    return widget.errorText == null;
  }

  /// Resets the form field to its [FormField.initialValue] and clears any active errors.
  void reset() {
    if (!mounted) {
      widget.value = widget.initialValue;
      widget.errorText = null;
      widget.touched = false;
      return;
    }
    setState(() {
      widget.value = widget.initialValue;
      widget.errorText = null;
      widget.touched = false;
    });
  }

  /// Synchronizes [FormField.focused], rebuilds, and notifies the parent [Form].
  void handleFocusChange(bool hasFocus) {
    final changed = widget._focused != hasFocus;
    _syncingFocusCallback = true;
    try {
      widget.focused = hasFocus;
    } finally {
      _syncingFocusCallback = false;
    }
    if (mounted && changed) {
      setState(() {});
    }
    if (mounted) {
      _registeredForm?._onFieldFocusChanged(this, hasFocus);
    }
  }

  /// Handles keys not consumed by the field control (such as `Enter`, `Up`, `Down`).
  bool handleUnhandledKeyEvent(term.KeyEvent event) {
    final form = _registeredForm;
    if (form == null) return false;
    if (_isEnterKeyEvent(event) && !consumesEnterInForm) {
      return form._handleFieldEnter(this);
    }
    if (event.type == .up) return form._moveRelativeFrom(this, -1);
    if (event.type == .down) return form._moveRelativeFrom(this, 1);
    return false;
  }

  /// Key callback wired to [Focus] for non-text form fields.
  bool handleFocusKeyEvent(term.KeyEvent event) {
    final form = _registeredForm;
    if (form != null && _isEnterKeyEvent(event) && !consumesEnterInForm) {
      return form._handleFieldEnter(this);
    }
    if (widget.handleKeyEvent(event)) return true;
    return handleUnhandledKeyEvent(event);
  }

  void _syncFromImperativeFocus(bool val) {
    if (_syncingFocusCallback) return;
    if (val) {
      final scope = _focusNode.parent;
      if (scope != null && scope.hasFocus) {
        _focusNode.requestFocus();
      } else if (scope is FocusScopeNode) {
        scope.setInitialFocusChild(_focusNode);
      }
    } else if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.value == null && widget.initialValue != null) {
      widget.value = widget.initialValue;
    }
    widget._state = this;
    _focusNode =
        widget.focusNode ?? FocusNode(id: 'form_field_${widget.hashCode}');
    _needsInitialFocusSync = widget.focused;
  }

  @override
  void didUpdateWidget(covariant FormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget, widget) && oldWidget._state == this) {
      oldWidget._state = null;
    }
    widget._state = this;
    if (widget.focusNode != oldWidget.focusNode) {
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode =
          widget.focusNode ?? FocusNode(id: 'form_field_${widget.hashCode}');
    }
    if (!identical(oldWidget, widget)) {
      widget.value = oldWidget.value;
      widget.errorText = oldWidget.errorText;
      widget.touched = oldWidget.touched;
      widget._focused = oldWidget._focused;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextForm = Form.of(context);
    if (_registeredForm != nextForm) {
      _registeredForm?.unregisterField(this);
      _registeredForm = nextForm;
      _registeredForm?.registerField(this);
    }
    if (_needsInitialFocusSync &&
        !delegatesFocusToChild &&
        Zone.current[#isMeasuringIntrinsics] != true) {
      _needsInitialFocusSync = false;
      _focusNode.seedInitialFocus(
        Focus.of(context),
        isMounted: () => mounted,
        onDeferredUnfocus: () => handleFocusChange(false),
      );
    }
  }

  @override
  void dispose() {
    _registeredForm?.unregisterField(this);
    _registeredForm = null;
    if (widget._state == this) {
      widget._state = null;
    }
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  /// Wraps non-text field [content] in a [Focus] and tap target, or wraps
  /// text-field [content] in a tap target alone.
  Widget wrapInteractiveField(Widget content) {
    final focusableChild = delegatesFocusToChild
        ? content
        : Focus(
            focusNode: _focusNode,
            onFocusChange: handleFocusChange,
            onKeyEvent: handleFocusKeyEvent,
            child: content,
          );
    return _FormFieldTapTarget(
      onTapPress: _focusNode.requestFocus,
      child: focusableChild,
    );
  }
}

/// A container widget that coordinates focus, validation, and resets for multiple [FormField] widgets.
///
/// Form can be used in two ways:
/// 1. **Legacy Mode**: By providing a flat list of form fields directly via the [fields] parameter.
/// 2. **Declarative Mode**: By passing a [child] widget tree containing nested form fields.
///
/// Under declarative mode, form fields can be nested inside columns, rows, padding, or custom widgets.
/// They will dynamically locate and register their state with the [Form] using an inherited widget lookup.
///
/// ### Example (Declarative Mode)
/// ```dart
/// Form(
///   child: Column([
///     TextFormField(
///       label: 'Username',
///       validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
///     ),
///     ConfirmFormField(
///       label: 'Accept terms',
///     ),
///   ]),
/// )
/// ```
class Form extends StatefulWidget implements Focusable {
  @override
  bool get focused {
    if (_state != null) {
      return _state!._hasFocusedField;
    }
    return fields.any((f) => f.focused);
  }

  /// The child subtree containing form fields. Used in Declarative Mode.
  final Widget? child;

  /// A flat list of form fields. Used in Legacy Mode.
  final List<FormField<Object?>> fields;

  /// Optional callback invoked when `Enter` is pressed on the final field.
  final VoidCallback? onSubmit;

  FormState? _state;

  int _activeFieldIndex = 0;

  /// The index of the currently active form field.
  int get activeFieldIndex {
    if (_state != null) {
      return _state!.activeFieldIndex;
    }
    final idx = fields.indexWhere((f) => f.focused);
    return idx != -1 ? idx : _activeFieldIndex;
  }

  set activeFieldIndex(int val) {
    if (_state != null) {
      _state!.activeFieldIndex = val;
      return;
    }
    _activeFieldIndex = val;
    for (var i = 0; i < fields.length; i++) {
      fields[i].focused = (i == val);
    }
  }

  /// Creates a [Form] to group multiple input fields.
  Form({super.key, this.child, this.fields = const [], this.onSubmit}) {
    for (var i = 0; i < fields.length; i++) {
      fields[i]._focused = (i == 0);
    }
  }

  /// Validates all child fields, returning true if all are valid.
  bool validate() {
    if (_state != null) {
      return _state!.validate();
    }
    var allValid = true;
    for (final field in fields) {
      if (!field.validate()) {
        allValid = false;
      }
    }
    return allValid;
  }

  /// Moves focus between fields using Tab/Shift-Tab, and routes other events to the active field.
  void handleKeyEvent(KeyEvent event) {
    if (_state != null) {
      _state!.handleKeyEvent(event);
      return;
    }
    if (fields.isEmpty) return;
    if (event.logicalKey == term.TermKey.tab) {
      _stepHeadlessFocus(1);
    } else if (event.logicalKey == term.TermKey.shiftTab) {
      _stepHeadlessFocus(-1);
    } else if (_isEnterKeyEvent(event)) {
      _handleHeadlessEnter(event);
    } else if (!fields[activeFieldIndex].handleKeyEvent(event)) {
      _handleHeadlessArrow(event);
    }
  }

  void _stepHeadlessFocus(int delta) {
    final len = fields.length;
    final current = activeFieldIndex;
    fields[current].focused = false;
    activeFieldIndex = ((current + delta) % len + len) % len;
  }

  void _handleHeadlessEnter(KeyEvent event) {
    final currentIdx = activeFieldIndex;
    final currentField = fields[currentIdx];
    currentField.validate();
    if (currentField is TextAreaFormField) {
      currentField.handleKeyEvent(event);
      return;
    }
    if (currentIdx < fields.length - 1) {
      currentField.focused = false;
      activeFieldIndex = currentIdx + 1;
    } else {
      onSubmit?.call();
    }
  }

  void _handleHeadlessArrow(KeyEvent event) {
    if (event.type == .up) {
      _stepHeadlessFocus(-1);
    } else if (event.type == .down) {
      _stepHeadlessFocus(1);
    }
  }

  @override
  State<Form> createState() => FormState();

  /// Retrieves the closest ancestor [FormState] in the tree.
  static FormState? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<FormScope>();
    return scope?.formState;
  }
}

/// The mutable state of a [Form].
class FormState extends State<Form> implements KeyEventHandler {
  final Set<FormFieldState<Object?>> _fieldSet = {};
  List<FormFieldState<Object?>> _orderedFields = [];
  bool _fieldsOrderDirty = false;
  bool _orderSyncScheduled = false;

  /// Retrieves the list of currently registered form field states.
  Iterable<FormFieldState<Object?>> get fields {
    _ensureFieldOrder();
    return _orderedFields;
  }

  List<FormField<Object?>> get _activeFields => widget.fields.isNotEmpty
      ? widget.fields
      : [for (final fs in _orderedFields) fs.widget];

  bool get _hasFocusedField => _activeFields.any((f) => f.focused);

  /// Registers a [FormFieldState] dynamically with this form.
  void registerField(FormFieldState<Object?> field) {
    if (_fieldSet.add(field)) {
      _orderedFields.add(field);
      _markFieldOrderDirty();
    }
  }

  /// Unregisters a [FormFieldState] from this form.
  void unregisterField(FormFieldState<Object?> field) {
    if (_fieldSet.remove(field)) {
      _orderedFields.remove(field);
      _markFieldOrderDirty();
    }
  }

  void _markFieldOrderDirty() {
    _fieldsOrderDirty = true;
    if (_orderSyncScheduled) return;
    _orderSyncScheduled = true;
    scheduleMicrotask(() {
      _orderSyncScheduled = false;
      if (mounted) _ensureFieldOrder();
    });
  }

  void _ensureFieldOrder() {
    if (!_fieldsOrderDirty || !mounted) return;
    _fieldsOrderDirty = false;
    _orderedFields = widget.fields.isNotEmpty
        ? _collectLegacyFields()
        : _collectDeclarativeFields();
    _syncScopeChildOrder();
  }

  List<FormFieldState<Object?>> _collectLegacyFields() => [
    for (final f in widget.fields)
      if (f._state != null && _fieldSet.contains(f._state)) f._state!,
  ];

  List<FormFieldState<Object?>> _collectDeclarativeFields() {
    final collected = <FormFieldState<Object?>>[];
    _collectFieldStates(context as Element, _fieldSet, collected);
    if (collected.length == _fieldSet.length) return collected;
    _fieldsOrderDirty = true;
    return [
      ...collected,
      for (final fs in _orderedFields)
        if (!collected.contains(fs) && _fieldSet.contains(fs)) fs,
    ];
  }

  void _syncScopeChildOrder() {
    if (_orderedFields.length <= 1) return;
    final nodes = [for (final fs in _orderedFields) fs.focusNode];
    if (nodes.first.parent case final FocusScopeNode scope) {
      scope.syncChildOrder(nodes);
    }
  }

  static void _collectFieldStates(
    Element element,
    Set<FormFieldState<Object?>> known,
    List<FormFieldState<Object?>> out,
  ) {
    if (element case StatefulElement(state: final FormFieldState<Object?> fs)) {
      if (known.contains(fs)) {
        out.add(fs);
      }
    }
    element.visitChildren((child) => _collectFieldStates(child, known, out));
  }

  void _onFieldFocusChanged(FormFieldState<Object?> field, bool hasFocus) {
    _ensureFieldOrder();
    if (hasFocus) {
      final idx = _indexOfState(field);
      if (idx != -1) widget._activeFieldIndex = idx;
    }
    if (mounted && widget.fields.isNotEmpty) {
      setState(() {});
    }
  }

  int _indexOfState(FormFieldState<Object?> field) =>
      _activeFields.indexOf(field.widget);

  bool _handleFieldEnter(FormFieldState<Object?> fieldState) {
    _ensureFieldOrder();
    fieldState.validate();
    final count = _activeFields.length;
    final idx = _indexOfState(fieldState);
    if (idx == -1 || count == 0) return false;
    if (idx < count - 1) {
      _selectFieldIndex(idx + 1);
      return true;
    }
    if (widget.onSubmit != null) {
      widget.onSubmit!();
      return true;
    }
    return false;
  }

  bool _moveRelativeFrom(FormFieldState<Object?> fieldState, int delta) {
    _ensureFieldOrder();
    final count = _activeFields.length;
    final idx = _indexOfState(fieldState);
    if (idx == -1 || count == 0) return false;
    _selectFieldIndex(((idx + delta) % count + count) % count);
    return true;
  }

  /// Validates all fields registered in this form.
  bool validate() {
    _ensureFieldOrder();
    var isValid = true;
    for (final field in _activeFields) {
      if (!field.validate()) isValid = false;
    }
    return isValid;
  }

  /// Resets all fields to their initial values.
  void reset() {
    _ensureFieldOrder();
    for (final field in _activeFields) {
      if (field._state != null) {
        field._state!.reset();
      } else {
        field.value = field.initialValue;
        field.errorText = null;
        field.touched = false;
      }
    }
  }

  /// The index of the currently active form field.
  int get activeFieldIndex {
    _ensureFieldOrder();
    final list = _activeFields;
    final focusedIdx = list.indexWhere((f) => f.focused);
    if (focusedIdx != -1) return focusedIdx;
    return list.isEmpty
        ? 0
        : widget._activeFieldIndex.clamp(0, list.length - 1);
  }

  set activeFieldIndex(int val) {
    _ensureFieldOrder();
    _selectFieldIndex(val);
  }

  void _selectFieldIndex(int rawIndex) {
    final list = _activeFields;
    if (list.isEmpty) return;
    final clamped = rawIndex.clamp(0, list.length - 1);
    widget._activeFieldIndex = clamped;
    final targetState = list[clamped]._state;
    setState(() {
      for (var i = 0; i < list.length; i++) {
        if (i != clamped) list[i].focused = false;
      }
      list[clamped].focused = true;
    });
    if (targetState == null) return;
    final scope = targetState.focusNode.parent;
    if (scope != null && scope.hasFocus) {
      targetState.focusNode.requestFocus();
    } else if (scope is FocusScopeNode) {
      scope.setInitialFocusChild(targetState.focusNode);
    }
  }

  /// Routes a key event to the focused field, handling tab navigation.
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    _ensureFieldOrder();
    final list = _activeFields;
    final count = list.length;
    if (count == 0) return false;
    final activeIdx = activeFieldIndex;
    if (event.logicalKey == term.TermKey.tab) {
      _selectFieldIndex((activeIdx + 1) % count);
      return true;
    }
    if (event.logicalKey == term.TermKey.shiftTab) {
      _selectFieldIndex((activeIdx - 1 + count) % count);
      return true;
    }
    if (_isEnterKeyEvent(event)) {
      return _dispatchImperativeEnter(list[activeIdx], activeIdx, count, event);
    }
    return _dispatchImperativeFieldKey(
      list[activeIdx],
      activeIdx,
      count,
      event,
    );
  }

  bool _dispatchImperativeEnter(
    FormField<Object?> currentField,
    int activeIdx,
    int count,
    term.KeyEvent event,
  ) {
    currentField.validate();
    if (currentField is TextAreaFormField) {
      currentField.handleKeyEvent(event);
      currentField._state?.setState(() {});
      return true;
    }
    if (activeIdx < count - 1) {
      _selectFieldIndex(activeIdx + 1);
      return true;
    }
    if (widget.onSubmit != null) {
      widget.onSubmit!();
      return true;
    }
    return false;
  }

  bool _dispatchImperativeFieldKey(
    FormField<Object?> currentField,
    int activeIdx,
    int count,
    term.KeyEvent event,
  ) {
    final handled = currentField.handleKeyEvent(event);
    final currentState = currentField._state;
    if (currentState != null && currentState.mounted) {
      currentState.setState(() {});
    }
    if (handled) return true;
    if (event.type == .up) {
      _selectFieldIndex((activeIdx - 1 + count) % count);
      return true;
    }
    if (event.type == .down) {
      _selectFieldIndex((activeIdx + 1) % count);
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    widget._state = this;
  }

  @override
  void didUpdateWidget(covariant Form oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget, widget) && oldWidget._state == this) {
      oldWidget._state = null;
    }
    widget._state = this;
    if (identical(oldWidget, widget)) {
      widget._activeFieldIndex = oldWidget._activeFieldIndex;
    }
    _markFieldOrderDirty();
  }

  @override
  void dispose() {
    if (widget._state == this) {
      widget._state = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget childWidget;
    if (widget.child != null) {
      childWidget = widget.child!;
    } else {
      final items = <Widget>[];
      for (final field in widget.fields) {
        final height = field.getPreferredHeight();
        final wrappedField = LeftBorder(
          char: field.focused ? '│' : ' ',
          style: const Style(
            foreground: CharmColors.charple,
            modifiers: Modifier.bold,
          ),
          padding: const EdgeInsets.only(left: 1),
          borderHeight: (height - 1).clamp(0, height),
          child: field,
        );
        items.add(
          _FormFieldTapTarget(
            key: ValueKey<Object>(field),
            onTapPress: () => field._state?.focusNode.requestFocus(),
            child: SizedBox(height: height, child: wrappedField),
          ),
        );
      }
      childWidget = Column(
        key: ValueKey<int>(Object.hashAll(widget.fields)),
        items,
      );
    }

    return FormScope(formState: this, child: childWidget);
  }
}

/// A form field wrapping a single-line text input field.
///
/// Dispatches character key presses to update the value, and provides support for
/// placeholder text, customizable style properties, and reverse video visual cursor markers.
///
/// ### Example
/// ```dart
/// TextFormField(
///   label: 'Username',
///   placeholder: 'Enter username',
///   validator: (val) => (val == null || val.isEmpty) ? 'Cannot be empty' : null,
/// )
/// ```
class TextFormField extends FormField<String> {
  final TextField _input;

  /// The cursor line in the text field.
  int get cursorLine => _input.cursorLine;

  /// The cursor column in the text field.
  int get cursorColumn => _input.cursorColumn;

  /// Creates a [TextFormField] for single-line text input.
  TextFormField({
    super.key,
    required super.label,
    super.description = '',
    super.initialValue,
    super.validator,
    super.focusNode,
    super.focused = false,
    Style style = Style.empty,
    Style cursorStyle = const Style(modifiers: Modifier.underline),
    String placeholder = '',
    Style placeholderStyle = const Style(foreground: Color(128, 128, 128)),
  }) : _input = TextField(
         initialText: initialValue ?? '',
         style: style,
         cursorStyle: cursorStyle,
         placeholder: placeholder,
         placeholderStyle: placeholderStyle,
         focused: focused,
       );

  @override
  int getPreferredHeight() {
    var h = 1; // Label
    if (description.isNotEmpty) h += 1;
    h += 1; // Input control
    if (hasError) h += 1;
    h += 1; // Spacer below
    return h;
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    final handled = _input.handleKeyEvent(event);
    value = _input.value;
    if (_state != null && _state!.mounted) {
      _state!.setState(() {});
    }
    return handled;
  }

  @override
  State createState() => _TextFormFieldState();
}

Widget _buildFormFieldLayout({
  required FormField<Object?> field,
  required FormFieldState<Object?> state,
  required int contentHeight,
  required Widget content,
}) {
  final hasError = state.hasError;
  final errorText = state.errorText;

  return Column(<Widget>[
    SizedBox(
      height: 1,
      child: Text(
        field.label,
        style: Style(
          foreground: hasError
              ? CharmColors.cherry
              : (field.focused ? CharmColors.charple : CharmColors.soda),
          modifiers: field.focused ? Modifier.bold : Modifier.none,
        ),
      ),
    ),
    if (field.description.isNotEmpty)
      SizedBox(
        height: 1,
        child: Text(
          '  ${field.description}',
          style: const Style(foreground: CharmColors.squid),
        ),
      ),
    SizedBox(
      height: contentHeight,
      child: Padding(padding: const EdgeInsets.only(left: 2), child: content),
    ),
    if (hasError)
      SizedBox(
        height: 1,
        child: Text(
          '  ⚠ $errorText',
          style: const Style(
            foreground: CharmColors.cherry,
            modifiers: Modifier.bold,
          ),
        ),
      ),
  ]);
}

Widget _buildTextInputFormField({
  required FormField<String> field,
  required FormFieldState<String> state,
  required TextField input,
  required int contentHeight,
}) {
  input.focused = field.focused;
  if (input.value != state.value) {
    input.value = state.value ?? '';
  }

  return _buildFormFieldLayout(
    field: field,
    state: state,
    contentHeight: contentHeight,
    content: TextField(
      key: input.key,
      controller: input.controller,
      focused: field.focused,
      style: input.style,
      cursorStyle: input.cursorStyle,
      placeholder: input.placeholder,
      placeholderStyle: input.placeholderStyle,
      multiline: input.multiline,
      customShortcuts: input.customShortcuts,
      focusNode: state.focusNode,
      onFocusChange: state.handleFocusChange,
      onKeyEvent: state.handleUnhandledKeyEvent,
    ),
  );
}

abstract class _BaseTextInputFormFieldState<W extends FormField<String>>
    extends FormFieldState<String>
    implements KeyEventHandler {
  TextField _inputFor(W field);

  @override
  bool get delegatesFocusToChild => true;

  @override
  void initState() {
    super.initState();
    _inputFor(widget as W).controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _inputFor(widget as W).controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant W oldWidget) {
    final nextWidget = widget as W;
    final oldInput = _inputFor(oldWidget);
    final nextInput = _inputFor(nextWidget);
    if (!identical(oldWidget, nextWidget)) {
      nextInput.controller.value = oldInput.controller.value;
      nextInput.scrollOffset = oldInput.scrollOffset;
    }
    super.didUpdateWidget(oldWidget);
    if (nextInput.controller != oldInput.controller) {
      oldInput.controller.removeListener(_onControllerChanged);
      nextInput.controller.addListener(_onControllerChanged);
    }
  }

  void _onControllerChanged() {
    final newValue = _inputFor(widget as W).value;
    widget.value = newValue;
    final nextError = widget.validator?.call(newValue);
    if (nextError != widget.errorText && mounted) {
      setState(() {
        widget.errorText = nextError;
      });
    }
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) => widget.handleKeyEvent(event);
}

class _TextFormFieldState extends _BaseTextInputFormFieldState<TextFormField> {
  @override
  TextField _inputFor(TextFormField field) => field._input;

  @override
  Widget build(BuildContext context) {
    return wrapInteractiveField(
      _TextFormFieldRenderWidget(widget as TextFormField, this),
    );
  }
}

class _TextFormFieldRenderWidget extends StatelessWidget {
  final TextFormField widget;
  final _TextFormFieldState state;

  const _TextFormFieldRenderWidget(this.widget, this.state);

  @override
  Widget build(BuildContext context) => _buildTextInputFormField(
    field: widget,
    state: state,
    input: widget._input,
    contentHeight: 1,
  );
}

/// A form field wrapping a multi-line text editing area.
///
/// Handles text wrapping, multiple lines (using Enter key insertions), vertical scroll offsets
/// when cursor extends past the height constraint, and undo/redo history stacks.
///
/// ### Example
/// ```dart
/// TextAreaFormField(
///   label: 'Description',
///   description: 'Enter your bio',
///   fieldHeight: 5,
/// )
/// ```
class TextAreaFormField extends FormField<String> {
  final TextField _input;

  /// The cursor line in the text area.
  int get cursorLine => _input.cursorLine;

  /// The cursor column in the text area.
  int get cursorColumn => _input.cursorColumn;

  /// The fixed height of the text area.
  final int fieldHeight;

  /// Creates a [TextAreaFormField] for multi-line text editing.
  TextAreaFormField({
    super.key,
    required super.label,
    super.description = '',
    super.initialValue,
    super.validator,
    super.focusNode,
    super.focused = false,
    this.fieldHeight = 3,
    Style style = Style.empty,
    Style cursorStyle = const Style(modifiers: Modifier.underline),
    String placeholder = '',
    Style placeholderStyle = const Style(foreground: Color(128, 128, 128)),
  }) : _input = TextField(
         initialText: initialValue ?? '',
         multiline: true,
         style: style,
         cursorStyle: cursorStyle,
         placeholder: placeholder,
         placeholderStyle: placeholderStyle,
         focused: focused,
       );

  @override
  int getPreferredHeight() {
    var h = 1; // Label
    if (description.isNotEmpty) h += 1;
    h += fieldHeight; // TextArea control
    if (hasError) h += 1;
    h += 1; // Spacer below
    return h;
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    final handled = _input.handleKeyEvent(event);
    value = _input.value;
    if (_state != null && _state!.mounted) {
      _state!.setState(() {});
    }
    return handled;
  }

  @override
  State createState() => _TextAreaFormFieldState();
}

class _TextAreaFormFieldState
    extends _BaseTextInputFormFieldState<TextAreaFormField> {
  @override
  bool get consumesEnterInForm => true;

  @override
  TextField _inputFor(TextAreaFormField field) => field._input;

  @override
  Widget build(BuildContext context) {
    return wrapInteractiveField(
      _TextAreaFormFieldRenderWidget(widget as TextAreaFormField, this),
    );
  }
}

class _TextAreaFormFieldRenderWidget extends StatelessWidget {
  final TextAreaFormField widget;
  final _TextAreaFormFieldState state;

  const _TextAreaFormFieldRenderWidget(this.widget, this.state);

  @override
  Widget build(BuildContext context) => _buildTextInputFormField(
    field: widget,
    state: state,
    input: widget._input,
    contentHeight: widget.fieldHeight,
  );
}

/// An option in a selection form field.
class SelectOption<T> {
  /// The label displayed for this option.
  final String label;

  /// The underlying value of the option.
  final T value;

  /// Creates a [SelectOption] with a [label] and a [value].
  const SelectOption(this.label, this.value);
}

/// A form field representing single-option selection from a list of choices.
///
/// Users navigate the list of choices using the Up and Down arrow keys.
///
/// ### Example
/// ```dart
/// SelectFormField<int>(
///   label: 'Select priority',
///   initialValue: 2,
///   options: const [
///     SelectOption('High', 1),
///     SelectOption('Normal', 2),
///     SelectOption('Low', 3),
///   ],
/// )
/// ```
class SelectFormField<T> extends FormField<T> {
  /// The list of available options for selection.
  final List<SelectOption<T>> options;
  int _selectedIndex = 0;

  /// Creates a [SelectFormField] with the given [options].
  SelectFormField({
    super.key,
    required super.label,
    super.description = '',
    required this.options,
    super.initialValue,
    super.validator,
    super.focusNode,
    super.focused = false,
  }) {
    if (initialValue != null) {
      final idx = options.indexWhere((opt) => opt.value == initialValue);
      if (idx != -1) {
        _selectedIndex = idx;
        value = options[idx].value;
      }
    } else if (options.isNotEmpty) {
      value = options[0].value;
    }
  }

  @override
  int getPreferredHeight() {
    var h = 1; // Label
    if (description.isNotEmpty) h += 1;
    h += options.length; // List of choices
    if (hasError) h += 1;
    h += 1; // Spacer below
    return h;
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (options.isEmpty) return false;

    if (event.type == KeyType.up) {
      _selectedIndex = (_selectedIndex - 1).clamp(0, options.length - 1);
      value = options[_selectedIndex].value;
      if (_state != null && _state!.mounted) {
        _state!.setState(() {});
      }
      return true;
    } else if (event.type == KeyType.down) {
      _selectedIndex = (_selectedIndex + 1).clamp(0, options.length - 1);
      value = options[_selectedIndex].value;
      if (_state != null && _state!.mounted) {
        _state!.setState(() {});
      }
      return true;
    }
    return false;
  }

  @override
  State createState() => _SelectFormFieldState<T>();
}

class _SelectFormFieldState<T> extends FormFieldState<T>
    implements KeyEventHandler {
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return widget.handleKeyEvent(event);
  }

  int get _selectedIndex {
    final selectWidget = widget as SelectFormField<T>;
    final idx = selectWidget.options.indexWhere(
      (opt) => opt.value == selectWidget.value,
    );
    return idx != -1 ? idx : 0;
  }

  @override
  Widget build(BuildContext context) {
    return wrapInteractiveField(
      _SelectFormFieldRenderWidget<T>(widget as SelectFormField<T>, this),
    );
  }
}

class _SelectFormFieldRenderWidget<T> extends StatelessWidget {
  final SelectFormField<T> widget;
  final _SelectFormFieldState<T> state;

  const _SelectFormFieldRenderWidget(this.widget, this.state);

  @override
  Widget build(BuildContext context) {
    final optionItems = <Widget>[];

    for (var i = 0; i < widget.options.length; i++) {
      final option = widget.options[i];
      final isSelected = (i == state._selectedIndex);
      final displayLabel = isSelected
          ? '${widget.focused ? '●' : '○'} ${option.label}'
          : '  ${option.label}';

      final style = isSelected
          ? const Style(
              foreground: CharmColors.charple,
              modifiers: Modifier.bold,
            )
          : const Style(foreground: CharmColors.soda);

      optionItems.add(
        SizedBox(height: 1, child: Text(displayLabel, style: style)),
      );
    }

    return _buildFormFieldLayout(
      field: widget,
      state: state,
      contentHeight: widget.options.length,
      content: Column(optionItems),
    );
  }
}

/// A boolean yes/no confirmation prompt field.
///
/// Toggles its boolean state when the Left/Right arrow keys or Space bar are pressed.
///
/// ### Example
/// ```dart
/// ConfirmFormField(
///   label: 'Agree to terms',
///   initialValue: false,
/// )
/// ```
class ConfirmFormField extends FormField<bool> {
  /// Creates a [ConfirmFormField] for boolean yes/no choice.
  ConfirmFormField({
    super.key,
    required super.label,
    super.description = '',
    super.initialValue = false,
    super.validator,
    super.focusNode,
    super.focused = false,
  });

  @override
  int getPreferredHeight() {
    var h = 1; // Label
    if (description.isNotEmpty) h += 1;
    h += 1; // Yes / No selector
    if (hasError) h += 1;
    h += 1; // Spacer below
    return h;
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (event.type == KeyType.left ||
        event.type == KeyType.right ||
        event.key == ' ') {
      value = !(value ?? false);
      if (_state != null && _state!.mounted) {
        _state!.setState(() {});
      }
      return true;
    }
    return false;
  }

  @override
  State createState() => _ConfirmFormFieldState();
}

class _ConfirmFormFieldState extends FormFieldState<bool>
    implements KeyEventHandler {
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return widget.handleKeyEvent(event);
  }

  @override
  Widget build(BuildContext context) {
    return wrapInteractiveField(
      _ConfirmFormFieldRenderWidget(widget as ConfirmFormField, this),
    );
  }
}

class _ConfirmFormFieldRenderWidget extends StatelessWidget {
  final ConfirmFormField widget;
  final _ConfirmFormFieldState state;

  const _ConfirmFormFieldRenderWidget(this.widget, this.state);

  @override
  Widget build(BuildContext context) {
    final isYes = state.value ?? false;

    final yesStyle = isYes
        ? const Style(
            foreground: CharmColors.pepper,
            background: CharmColors.charple,
            modifiers: Modifier.bold,
          )
        : const Style(foreground: CharmColors.soda);

    final noStyle = !isYes
        ? const Style(
            foreground: CharmColors.pepper,
            background: CharmColors.charple,
            modifiers: Modifier.bold,
          )
        : const Style(foreground: CharmColors.soda);

    return _buildFormFieldLayout(
      field: widget,
      state: state,
      contentHeight: 1,
      content: RichText(
        text: TextSpan(
          children: [
            TextSpan(text: ' [Yes] ', style: yesStyle),
            const TextSpan(text: '   '),
            TextSpan(text: '  No  ', style: noStyle),
          ],
        ),
      ),
    );
  }
}

/// An option in a multi-selection form field.
class MultiSelectOption<T> {
  /// The label displayed for this option.
  final String label;

  /// The underlying value of the option.
  final T value;

  /// Creates a [MultiSelectOption] with a [label] and a [value].
  const MultiSelectOption(this.label, this.value);
}

/// A form field representing multiple-option selection from a list of choices.
///
/// Users navigate the list of options using Up and Down arrow keys, and toggle
/// the selection status of the highlighted option using the Space bar or Enter key.
///
/// ### Example
/// ```dart
/// MultiSelectFormField<String>(
///   label: 'Select tags',
///   initialValue: const ['dart'],
///   options: const [
///     MultiSelectOption('Dart', 'dart'),
///     MultiSelectOption('Flutter', 'flutter'),
///     MultiSelectOption('TUI', 'tui'),
///   ],
/// )
/// ```
class MultiSelectFormField<T> extends FormField<List<T>> {
  /// The list of available options for multiple selection.
  final List<MultiSelectOption<T>> options;
  final List<bool> _selected;
  int _selectedIndex = 0;

  /// Creates a [MultiSelectFormField] with the given [options].
  MultiSelectFormField({
    super.key,
    required super.label,
    super.description = '',
    required this.options,
    List<T>? initialValue,
    super.validator,
    super.focusNode,
    super.focused = false,
  }) : _selected = List.filled(options.length, false) {
    value = initialValue ?? [];
    if (initialValue != null) {
      for (var i = 0; i < options.length; i++) {
        if (initialValue.contains(options[i].value)) {
          _selected[i] = true;
        }
      }
    }
  }

  @override
  int getPreferredHeight() {
    var h = 1; // Label
    if (description.isNotEmpty) h += 1;
    h += options.length; // List of choices
    if (hasError) h += 1;
    h += 1; // Spacer below
    return h;
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (options.isEmpty) return false;

    final currentVal = value ?? [];
    for (var i = 0; i < options.length; i++) {
      _selected[i] = currentVal.contains(options[i].value);
    }

    if (event.type == KeyType.up) {
      _selectedIndex = (_selectedIndex - 1).clamp(0, options.length - 1);
      if (_state != null && _state!.mounted) {
        _state!.setState(() {});
      }
      return true;
    } else if (event.type == KeyType.down) {
      _selectedIndex = (_selectedIndex + 1).clamp(0, options.length - 1);
      if (_state != null && _state!.mounted) {
        _state!.setState(() {});
      }
      return true;
    } else if (event.baseKey == term.TermKey.space ||
        event.baseKey == term.TermKey.enter) {
      _selected[_selectedIndex] = !_selected[_selectedIndex];
      final nextVal = <T>[
        for (var i = 0; i < options.length; i++)
          if (_selected[i]) options[i].value,
      ];
      value = nextVal;
      if (_state != null && _state!.mounted) {
        _state!.setState(() {});
      }
      return true;
    }
    return false;
  }

  @override
  State createState() => _MultiSelectFormFieldState<T>();
}

class _MultiSelectFormFieldState<T> extends FormFieldState<List<T>>
    implements KeyEventHandler {
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return widget.handleKeyEvent(event);
  }

  @override
  Widget build(BuildContext context) {
    return wrapInteractiveField(
      _MultiSelectFormFieldRenderWidget<T>(
        widget as MultiSelectFormField<T>,
        this,
      ),
    );
  }
}

class _MultiSelectFormFieldRenderWidget<T> extends StatelessWidget {
  final MultiSelectFormField<T> widget;
  final _MultiSelectFormFieldState<T> state;

  const _MultiSelectFormFieldRenderWidget(this.widget, this.state);

  @override
  Widget build(BuildContext context) {
    final optionItems = <Widget>[];

    for (var i = 0; i < widget.options.length; i++) {
      final option = widget.options[i];
      final isHighlighted = (i == widget._selectedIndex);
      final isSelected = (widget.value ?? []).contains(option.value);

      final cursor = isHighlighted ? (widget.focused ? '●' : '○') : ' ';
      final checkbox = isSelected ? '[x]' : '[ ]';
      final displayLabel = '$cursor $checkbox ${option.label}';

      final style = isHighlighted
          ? const Style(
              foreground: CharmColors.charple,
              modifiers: Modifier.bold,
            )
          : const Style(foreground: CharmColors.soda);

      optionItems.add(
        SizedBox(height: 1, child: Text(displayLabel, style: style)),
      );
    }

    return _buildFormFieldLayout(
      field: widget,
      state: state,
      contentHeight: widget.options.length,
      content: Column(optionItems),
    );
  }
}
