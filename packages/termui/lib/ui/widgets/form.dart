import '../layout.dart';
import '../style.dart';
import '../color.dart';
import '../event.dart' hide Modifier;
import 'text.dart';
import 'text_field.dart';
import 'padding.dart';
import 'rich_text.dart';
import 'left_border.dart';
import '../../terminal/terminal.dart' as term;
import 'prompt_runner.dart';

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
    if (_focused && !val) {
      if (touched) {
        validate();
      }
    }
    _focused = val;
    if (val) {
      touched = true;
    }
  }

  /// Creates a [FormField] with common properties.
  FormField({
    required this.label,
    this.description = '',
    this.initialValue,
    this.validator,
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
    if (validator != null) {
      errorText = validator!(value);
    } else {
      errorText = null;
    }
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
    setState(() {
      if (widget.validator != null) {
        widget.errorText = widget.validator!(widget.value);
      } else {
        widget.errorText = null;
      }
    });
    return widget.errorText == null;
  }

  /// Resets the form field to its [FormField.initialValue] and clears any active errors.
  void reset() {
    setState(() {
      widget.value = widget.initialValue;
      widget.errorText = null;
      widget.touched = false;
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.value == null && widget.initialValue != null) {
      widget.value = widget.initialValue;
    }
    widget._state = this;
  }

  @override
  void didUpdateWidget(covariant FormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget._state = this;
    widget.value = oldWidget.value;
    widget.errorText = oldWidget.errorText;
    widget.touched = oldWidget.touched;
    widget.focused = oldWidget.focused;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Form.of(context)?.registerField(this);
  }

  @override
  void dispose() {
    Form.of(context)?.unregisterField(this);
    if (widget._state == this) {
      widget._state = null;
    }
    super.dispose();
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
      return _state!._fields.any((fs) => fs.widget.focused);
    }
    return fields.any((f) => f.focused);
  }

  /// The child subtree containing form fields. Used in Declarative Mode.
  final Widget? child;

  /// A flat list of form fields. Used in Legacy Mode.
  final List<FormField> fields;

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
    if (fields.isNotEmpty) {
      for (var i = 0; i < fields.length; i++) {
        fields[i].focused = (i == val);
      }
    }
  }

  /// Creates a [Form] to group multiple input fields.
  Form({this.child, this.fields = const []}) {
    if (fields.isNotEmpty) {
      for (var i = 0; i < fields.length; i++) {
        fields[i]._focused = (i == 0);
      }
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

    if (event.key == 'tab' || event.key == '\t') {
      fields[activeFieldIndex].focused = false;
      activeFieldIndex = (activeFieldIndex + 1) % fields.length;
      fields[activeFieldIndex].focused = true;
    } else if (event.key == 'backtab') {
      fields[activeFieldIndex].focused = false;
      activeFieldIndex = (activeFieldIndex - 1 + fields.length) % fields.length;
      fields[activeFieldIndex].focused = true;
    } else if (event.type == KeyType.enter ||
        event.key == '\r' ||
        event.key == '\n' ||
        event.key == 'enter') {
      final currentField = fields[activeFieldIndex];
      currentField.validate();
      if (currentField is! TextAreaFormField) {
        currentField.focused = false;
        activeFieldIndex = (activeFieldIndex + 1) % fields.length;
        fields[activeFieldIndex].focused = true;
      } else {
        currentField.handleKeyEvent(event);
      }
    } else {
      final handled = fields[activeFieldIndex].handleKeyEvent(event);
      if (!handled) {
        if (event.type == KeyType.up) {
          fields[activeFieldIndex].focused = false;
          activeFieldIndex =
              (activeFieldIndex - 1 + fields.length) % fields.length;
          fields[activeFieldIndex].focused = true;
        } else if (event.type == KeyType.down) {
          fields[activeFieldIndex].focused = false;
          activeFieldIndex = (activeFieldIndex + 1) % fields.length;
          fields[activeFieldIndex].focused = true;
        }
      }
    }
  }

  @override
  State createState() => FormState();

  /// Retrieves the closest ancestor [FormState] in the tree.
  static FormState? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<FormScope>();
    return scope?.formState;
  }
}

/// The mutable state of a [Form].
class FormState extends State<Form> implements KeyEventHandler {
  final Set<FormFieldState> _fields = {};

  /// Retrieves the list of currently registered form field states.
  Iterable<FormFieldState> get fields => _fields;

  /// Registers a [FormFieldState] dynamically with this form.
  void registerField(FormFieldState field) {
    _fields.add(field);
  }

  /// Unregisters a [FormFieldState] from this form.
  void unregisterField(FormFieldState field) {
    _fields.remove(field);
  }

  /// Validates all fields registered in this form.
  bool validate() {
    var isValid = true;
    for (final field in widget.fields) {
      if (!field.validate()) {
        isValid = false;
      }
    }
    for (final fieldState in _fields) {
      if (!fieldState.validate()) {
        isValid = false;
      }
    }
    return isValid;
  }

  /// Resets all fields to their initial values.
  void reset() {
    for (final field in widget.fields) {
      field.value = field.initialValue;
      field.errorText = null;
      field.touched = false;
    }
    for (final fieldState in _fields) {
      fieldState.reset();
    }
  }

  /// The index of the currently active form field.
  int get activeFieldIndex {
    if (widget.fields.isNotEmpty) {
      final idx = widget.fields.indexWhere((f) => f.focused);
      return idx != -1 ? idx : 0;
    }
    final list = _fields.toList();
    if (list.isNotEmpty) {
      final idx = list.indexWhere((fs) => fs.widget.focused);
      return idx != -1 ? idx : 0;
    }
    return 0;
  }

  set activeFieldIndex(int val) {
    setState(() {
      if (widget.fields.isNotEmpty) {
        for (var i = 0; i < widget.fields.length; i++) {
          widget.fields[i].focused = (i == val);
        }
        return;
      }
      final list = _fields.toList();
      if (list.isNotEmpty) {
        for (var i = 0; i < list.length; i++) {
          list[i].widget.focused = (i == val);
        }
        return;
      }
    });
  }

  /// Routes a key event to the focused field, handling tab navigation.
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    if (widget.fields.isNotEmpty) {
      final list = widget.fields;
      var activeIdx = list.indexWhere((f) => f.focused);
      if (activeIdx == -1) activeIdx = 0;

      if (event.key == 'tab' || event.key == '\t') {
        setState(() {
          list[activeIdx].focused = false;
          activeIdx = (activeIdx + 1) % list.length;
          list[activeIdx].focused = true;
        });
        return true;
      } else if (event.key == 'backtab') {
        setState(() {
          list[activeIdx].focused = false;
          activeIdx = (activeIdx - 1 + list.length) % list.length;
          list[activeIdx].focused = true;
        });
        return true;
      } else if (event.type == KeyType.enter ||
          event.key == '\r' ||
          event.key == '\n' ||
          event.key == 'enter') {
        final currentField = list[activeIdx];
        currentField.validate();
        if (currentField is! TextAreaFormField) {
          setState(() {
            currentField.focused = false;
            activeIdx = (activeIdx + 1) % list.length;
            list[activeIdx].focused = true;
          });
        } else {
          currentField.handleKeyEvent(event);
          currentField._state?.setState(() {});
        }
        return true;
      } else {
        final handled = list[activeIdx].handleKeyEvent(event);
        list[activeIdx]._state?.setState(() {});
        if (!handled) {
          if (event.type == KeyType.up) {
            setState(() {
              list[activeIdx].focused = false;
              activeIdx = (activeIdx - 1 + list.length) % list.length;
              list[activeIdx].focused = true;
            });
            return true;
          } else if (event.type == KeyType.down) {
            setState(() {
              list[activeIdx].focused = false;
              activeIdx = (activeIdx + 1) % list.length;
              list[activeIdx].focused = true;
            });
            return true;
          }
        }
        return handled;
      }
    }

    if (_fields.isEmpty) return false;

    final list = _fields.toList();
    var activeIdx = list.indexWhere((fs) => fs.widget.focused);
    if (activeIdx == -1) activeIdx = 0;

    if (event.key == 'tab' || event.key == '\t') {
      setState(() {
        list[activeIdx].widget.focused = false;
        activeIdx = (activeIdx + 1) % list.length;
        list[activeIdx].widget.focused = true;
      });
      return true;
    } else if (event.key == 'backtab') {
      setState(() {
        list[activeIdx].widget.focused = false;
        activeIdx = (activeIdx - 1 + list.length) % list.length;
        list[activeIdx].widget.focused = true;
      });
      return true;
    } else if (event.type == KeyType.enter ||
        event.key == '\r' ||
        event.key == '\n' ||
        event.key == 'enter') {
      final currentField = list[activeIdx].widget;
      currentField.validate();
      if (currentField is! TextAreaFormField) {
        setState(() {
          currentField.focused = false;
          activeIdx = (activeIdx + 1) % list.length;
          list[activeIdx].widget.focused = true;
        });
      } else {
        currentField.handleKeyEvent(event);
        list[activeIdx].setState(() {});
      }
      return true;
    } else {
      final handled = list[activeIdx].widget.handleKeyEvent(event);
      list[activeIdx].setState(() {});
      if (!handled) {
        if (event.type == KeyType.up) {
          setState(() {
            list[activeIdx].widget.focused = false;
            activeIdx = (activeIdx - 1 + list.length) % list.length;
            list[activeIdx].widget.focused = true;
          });
          return true;
        } else if (event.type == KeyType.down) {
          setState(() {
            list[activeIdx].widget.focused = false;
            activeIdx = (activeIdx + 1) % list.length;
            list[activeIdx].widget.focused = true;
          });
          return true;
        }
      }
      return handled;
    }
  }

  @override
  void initState() {
    super.initState();
    widget._state = this;
  }

  @override
  void didUpdateWidget(covariant Form oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget._state = this;
    widget._activeFieldIndex = oldWidget._activeFieldIndex;
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
        items.add(SizedBox(height: height, child: wrappedField));
      }
      childWidget = Column(items);
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
    required super.label,
    super.description = '',
    super.initialValue,
    super.validator,
    super.focused = false,
    Style style = Style.empty,
    Style cursorStyle = const Style(modifiers: Modifier.reverse),
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
    if (_state != null) {
      _state!.setState(() {});
    }
    return handled;
  }

  @override
  State createState() => _TextFormFieldState();
}

class _TextFormFieldState extends FormFieldState<String>
    implements KeyEventHandler {
  @override
  void initState() {
    super.initState();
    (widget as TextFormField)._input.controller.addListener(
      _onControllerChanged,
    );
  }

  @override
  void dispose() {
    (widget as TextFormField)._input.controller.removeListener(
      _onControllerChanged,
    );
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldController = oldWidget._input.controller;
    final newController = (widget as TextFormField)._input.controller;
    if (newController != oldController) {
      oldController.removeListener(_onControllerChanged);
      newController.addListener(_onControllerChanged);
    }
  }

  void _onControllerChanged() {
    final newValue = (widget as TextFormField)._input.value;
    widget.value = newValue;
    if (widget.validator != null) {
      final newError = widget.validator!(newValue);
      if (newError != widget.errorText) {
        setState(() {
          widget.errorText = newError;
        });
      }
    } else if (widget.errorText != null) {
      setState(() {
        widget.errorText = null;
      });
    }
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return widget.handleKeyEvent(event);
  }

  @override
  Widget build(BuildContext context) {
    return _TextFormFieldRenderWidget(widget as TextFormField, this);
  }
}

class _TextFormFieldRenderWidget extends StatelessWidget {
  final TextFormField widget;
  final _TextFormFieldState state;

  const _TextFormFieldRenderWidget(this.widget, this.state);

  @override
  Widget build(BuildContext context) {
    widget._input.focused = widget.focused;
    if (widget._input.value != state.value) {
      widget._input.value = state.value ?? '';
    }

    final hasError = state.hasError;
    final errorText = state.errorText;

    final layoutItems = <Widget>[
      SizedBox(
        height: 1,
        child: Text(
          widget.label,
          style: Style(
            foreground: hasError
                ? CharmColors.cherry
                : (widget.focused ? CharmColors.charple : CharmColors.soda),
            modifiers: widget.focused ? Modifier.bold : Modifier.none,
          ),
        ),
      ),
      if (widget.description.isNotEmpty)
        SizedBox(
          height: 1,
          child: Text(
            '  ${widget.description}',
            style: const Style(foreground: CharmColors.squid),
          ),
        ),
      SizedBox(
        height: 1,
        child: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: TextField(
            key: widget._input.key,
            controller: widget._input.controller,
            focused: widget.focused,
            style: widget._input.style,
            cursorStyle: widget._input.cursorStyle,
            placeholder: widget._input.placeholder,
            placeholderStyle: widget._input.placeholderStyle,
            multiline: widget._input.multiline,
            customShortcuts: widget._input.customShortcuts,
            focusNode: widget._input.focusNode,
            onFocusChange: widget._input.onFocusChange,
          ),
        ),
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
    ];

    return Column(layoutItems);
  }
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
    required super.label,
    super.description = '',
    super.initialValue,
    super.validator,
    super.focused = false,
    this.fieldHeight = 3,
    Style style = Style.empty,
    Style cursorStyle = const Style(modifiers: Modifier.reverse),
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
    if (_state != null) {
      _state!.setState(() {});
    }
    return handled;
  }

  @override
  State createState() => _TextAreaFormFieldState();
}

class _TextAreaFormFieldState extends FormFieldState<String>
    implements KeyEventHandler {
  @override
  void initState() {
    super.initState();
    (widget as TextAreaFormField)._input.controller.addListener(
      _onControllerChanged,
    );
  }

  @override
  void dispose() {
    (widget as TextAreaFormField)._input.controller.removeListener(
      _onControllerChanged,
    );
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TextAreaFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldController = oldWidget._input.controller;
    final newController = (widget as TextAreaFormField)._input.controller;
    if (newController != oldController) {
      oldController.removeListener(_onControllerChanged);
      newController.addListener(_onControllerChanged);
    }
  }

  void _onControllerChanged() {
    final newValue = (widget as TextAreaFormField)._input.value;
    widget.value = newValue;
    if (widget.validator != null) {
      final newError = widget.validator!(newValue);
      if (newError != widget.errorText) {
        setState(() {
          widget.errorText = newError;
        });
      }
    } else if (widget.errorText != null) {
      setState(() {
        widget.errorText = null;
      });
    }
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return widget.handleKeyEvent(event);
  }

  @override
  Widget build(BuildContext context) {
    return _TextAreaFormFieldRenderWidget(widget as TextAreaFormField, this);
  }
}

class _TextAreaFormFieldRenderWidget extends StatelessWidget {
  final TextAreaFormField widget;
  final _TextAreaFormFieldState state;

  const _TextAreaFormFieldRenderWidget(this.widget, this.state);

  @override
  Widget build(BuildContext context) {
    widget._input.focused = widget.focused;
    if (widget._input.value != state.value) {
      widget._input.value = state.value ?? '';
    }

    final hasError = state.hasError;
    final errorText = state.errorText;

    final layoutItems = <Widget>[
      SizedBox(
        height: 1,
        child: Text(
          widget.label,
          style: Style(
            foreground: hasError
                ? CharmColors.cherry
                : (widget.focused ? CharmColors.charple : CharmColors.soda),
            modifiers: widget.focused ? Modifier.bold : Modifier.none,
          ),
        ),
      ),
      if (widget.description.isNotEmpty)
        SizedBox(
          height: 1,
          child: Text(
            '  ${widget.description}',
            style: const Style(foreground: CharmColors.squid),
          ),
        ),
      SizedBox(
        height: widget.fieldHeight,
        child: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: TextField(
            key: widget._input.key,
            controller: widget._input.controller,
            focused: widget.focused,
            style: widget._input.style,
            cursorStyle: widget._input.cursorStyle,
            placeholder: widget._input.placeholder,
            placeholderStyle: widget._input.placeholderStyle,
            multiline: widget._input.multiline,
            customShortcuts: widget._input.customShortcuts,
            focusNode: widget._input.focusNode,
            onFocusChange: widget._input.onFocusChange,
          ),
        ),
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
    ];

    return Column(layoutItems);
  }
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
    required super.label,
    super.description = '',
    required this.options,
    super.initialValue,
    super.validator,
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
      if (_state != null) {
        _state!.setState(() {});
      }
      return true;
    } else if (event.type == KeyType.down) {
      _selectedIndex = (_selectedIndex + 1).clamp(0, options.length - 1);
      value = options[_selectedIndex].value;
      if (_state != null) {
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
    return _SelectFormFieldRenderWidget<T>(widget as SelectFormField<T>, this);
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

    final hasError = state.hasError;
    final errorText = state.errorText;

    final layoutItems = <Widget>[
      SizedBox(
        height: 1,
        child: Text(
          widget.label,
          style: Style(
            foreground: hasError
                ? CharmColors.cherry
                : (widget.focused ? CharmColors.charple : CharmColors.soda),
            modifiers: widget.focused ? Modifier.bold : Modifier.none,
          ),
        ),
      ),
      if (widget.description.isNotEmpty)
        SizedBox(
          height: 1,
          child: Text(
            '  ${widget.description}',
            style: const Style(foreground: CharmColors.squid),
          ),
        ),
      SizedBox(
        height: widget.options.length,
        child: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Column(optionItems),
        ),
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
    ];

    return Column(layoutItems);
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
    required super.label,
    super.description = '',
    super.initialValue = false,
    super.validator,
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
      if (_state != null) {
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
    return _ConfirmFormFieldRenderWidget(widget as ConfirmFormField, this);
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

    final hasError = state.hasError;
    final errorText = state.errorText;

    final layoutItems = <Widget>[
      SizedBox(
        height: 1,
        child: Text(
          widget.label,
          style: Style(
            foreground: hasError
                ? CharmColors.cherry
                : (widget.focused ? CharmColors.charple : CharmColors.soda),
            modifiers: widget.focused ? Modifier.bold : Modifier.none,
          ),
        ),
      ),
      if (widget.description.isNotEmpty)
        SizedBox(
          height: 1,
          child: Text(
            '  ${widget.description}',
            style: const Style(foreground: CharmColors.squid),
          ),
        ),
      SizedBox(
        height: 1,
        child: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(text: ' [Yes] ', style: yesStyle),
                const TextSpan(text: '   '),
                TextSpan(text: '  No  ', style: noStyle),
              ],
            ),
          ),
        ),
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
    ];

    return Column(layoutItems);
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
    required super.label,
    super.description = '',
    required this.options,
    List<T>? initialValue,
    super.validator,
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
      if (_state != null) {
        _state!.setState(() {});
      }
      return true;
    } else if (event.type == KeyType.down) {
      _selectedIndex = (_selectedIndex + 1).clamp(0, options.length - 1);
      if (_state != null) {
        _state!.setState(() {});
      }
      return true;
    } else if (event.key == ' ' ||
        event.key == 'space' ||
        event.type == KeyType.enter ||
        event.key == '\r' ||
        event.key == '\n' ||
        event.key == 'enter') {
      _selected[_selectedIndex] = !_selected[_selectedIndex];
      final nextVal = <T>[];
      for (var i = 0; i < options.length; i++) {
        if (_selected[i]) {
          nextVal.add(options[i].value);
        }
      }
      value = nextVal;
      if (_state != null) {
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
    return _MultiSelectFormFieldRenderWidget<T>(
      widget as MultiSelectFormField<T>,
      this,
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

    final hasError = state.hasError;
    final errorText = state.errorText;

    final layoutItems = <Widget>[
      SizedBox(
        height: 1,
        child: Text(
          widget.label,
          style: Style(
            foreground: hasError
                ? CharmColors.cherry
                : (widget.focused ? CharmColors.charple : CharmColors.soda),
            modifiers: widget.focused ? Modifier.bold : Modifier.none,
          ),
        ),
      ),
      if (widget.description.isNotEmpty)
        SizedBox(
          height: 1,
          child: Text(
            '  ${widget.description}',
            style: const Style(foreground: CharmColors.squid),
          ),
        ),
      SizedBox(
        height: widget.options.length,
        child: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Column(optionItems),
        ),
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
    ];

    return Column(layoutItems);
  }
}
