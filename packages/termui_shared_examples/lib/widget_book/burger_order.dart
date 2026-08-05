import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Example demonstrating a complex multi-page form.
class BurgerOrderExample extends WidgetBookExample {
  /// The current stage of the burger order form.
  int burgerStage = 0;

  /// The first form, containing burger type and toppings.
  late Form burgerForm1;

  /// The second form, containing spice level and sides.
  late Form burgerForm2;

  /// The third form, containing customer details.
  late Form burgerForm3;

  @override
  void init() {
    initBurgerForms();
  }

  /// Initializes the forms for each stage of the burger order.
  void initBurgerForms() {
    burgerForm1 = Form(
      fields: [
        SelectFormField<String>(
          label: 'Choose your burger',
          description: 'At Dartaburger we truly have a burger for everyone.',
          options: const [
            SelectOption('Dartaburger Classic', 'Dartaburger Classic'),
            SelectOption('Chickwich', 'Chickwich'),
            SelectOption('Fishburger', 'Fishburger'),
            SelectOption('Dartapossible™ Burger', 'Dartapossible™ Burger'),
          ],
          initialValue: 'Dartaburger Classic',
          validator: (val) {
            if (val == 'Fishburger') {
              return 'no fish today, sorry';
            }
            return null;
          },
        ),
        MultiSelectFormField<String>(
          label: 'Toppings',
          description: 'Choose up to 4 toppings.',
          options: const [
            MultiSelectOption('Lettuce', 'Lettuce'),
            MultiSelectOption('Tomatoes', 'Tomatoes'),
            MultiSelectOption('Charm Sauce', 'Charm Sauce'),
            MultiSelectOption('Jalapeños', 'Jalapeños'),
            MultiSelectOption('Cheese', 'Cheese'),
            MultiSelectOption('Vegan Cheese', 'Vegan Cheese'),
            MultiSelectOption('Nutella', 'Nutella'),
          ],
          initialValue: const ['Lettuce', 'Tomatoes'],
          validator: (val) {
            if (val == null || val.isEmpty) {
              return 'at least one topping is required';
            }
            if (val.length > 4) {
              return 'Choose up to 4.';
            }
            return null;
          },
        ),
      ],
    );

    burgerForm2 = Form(
      fields: [
        SelectFormField<String>(
          label: 'Spice level',
          options: const [
            SelectOption('Mild', 'Mild'),
            SelectOption('Medium', 'Medium'),
            SelectOption('Hot', 'Hot'),
          ],
          initialValue: 'Mild',
        ),
        SelectFormField<String>(
          label: 'Sides',
          description: 'You get one free side with this order.',
          options: const [
            SelectOption('Fries', 'Fries'),
            SelectOption('Disco Fries', 'Disco Fries'),
            SelectOption('R&B Fries', 'R&B Fries'),
            SelectOption('Carrots', 'Carrots'),
          ],
          initialValue: 'Fries',
        ),
      ],
    );

    burgerForm3 = Form(
      fields: [
        TextFormField(
          label: "What's your name?",
          description: 'For when your order is ready.',
          placeholder: 'Margaret Thatcher',
          validator: (val) {
            if (val == 'Frank') {
              return 'no franks, sorry';
            }
            return null;
          },
        ),
        TextAreaFormField(
          label: 'Special Instructions',
          description: 'Anything we should know?',
          placeholder: 'Just put it in the mailbox please',
          fieldHeight: 3,
        ),
        ConfirmFormField(label: 'Would you like 15% off?', initialValue: false),
      ],
    );
  }

  void _focusFirstField(Form form) {
    for (var i = 0; i < form.fields.length; i++) {
      form.fields[i].focused = (i == 0);
    }
    form.activeFieldIndex = 0;
  }

  void _focusLastField(Form form) {
    for (var i = 0; i < form.fields.length; i++) {
      form.fields[i].focused = (i == form.fields.length - 1);
    }
    form.activeFieldIndex = form.fields.length - 1;
  }

  void _focusNextField(Form form) {
    if (form.activeFieldIndex < form.fields.length - 1) {
      form.fields[form.activeFieldIndex].focused = false;
      form.activeFieldIndex++;
      form.fields[form.activeFieldIndex].focused = true;
    }
  }

  String _englishJoin(List<String> items) {
    if (items.isEmpty) return 'nothing';
    if (items.length == 1) return items.first;
    if (items.length == 2) return '${items[0]} and ${items[1]}';
    return '${items.sublist(0, items.length - 1).join(', ')}, and ${items.last}';
  }

  String _getSpiceString(String spice) => switch (spice) {
    'Mild' => 'Mild ',
    'Medium' => 'Medium-Spicy ',
    'Hot' => 'Spicy-Hot ',
    _ => '',
  };

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    if (!focusDemoPane) {
      for (final field in burgerForm1.fields) {
        field.focused = false;
      }
      for (final field in burgerForm2.fields) {
        field.focused = false;
      }
      for (final field in burgerForm3.fields) {
        field.focused = false;
      }
    } else {
      if (burgerStage == 1) {
        final activeIdx = burgerForm1.activeFieldIndex;
        for (var i = 0; i < burgerForm1.fields.length; i++) {
          burgerForm1.fields[i].focused = (i == activeIdx);
        }
      } else if (burgerStage == 2) {
        final activeIdx = burgerForm2.activeFieldIndex;
        for (var i = 0; i < burgerForm2.fields.length; i++) {
          burgerForm2.fields[i].focused = (i == activeIdx);
        }
      } else if (burgerStage == 3) {
        final activeIdx = burgerForm3.activeFieldIndex;
        for (var i = 0; i < burgerForm3.fields.length; i++) {
          burgerForm3.fields[i].focused = (i == activeIdx);
        }
      }
    }

    if (burgerStage == 0) {
      return Column([
        SizedBox(
          height: 1,
          child: Text(
            ' 🍔 Dartaburger™ ',
            style: const Style(
              foreground: CharmColors.pepper,
              background: CharmColors.charple,
              modifiers: Modifier.bold,
            ),
          ),
        ),
        const SizedBox(height: 1, child: Text('')),
        SizedBox(
          height: 4,
          child: Text(
            'Welcome to Dartaburger™.\n\nHow may we take your order?',
            style: const Style(foreground: CharmColors.soda),
          ),
        ),
        const SizedBox(height: 1, child: Text('')),
        SizedBox(
          height: 1,
          child: Text(
            'Press [Enter] to begin...',
            style: const Style(
              foreground: CharmColors.julep,
              modifiers: Modifier.italic,
            ),
          ),
        ),
      ]);
    } else if (burgerStage == 1) {
      return Column([
        SizedBox(
          height: 1,
          child: Text(
            'Stage 1 of 3: Build your burger. Press [Enter] to continue.',
            style: const Style(foreground: CharmColors.squid),
          ),
        ),
        const SizedBox(height: 1, child: Text('')),
        Expanded(
          child: SingleChildScrollView(childLength: 20, child: burgerForm1),
        ),
        const SizedBox(height: 1, child: Text('')),
        SizedBox(
          height: 1,
          child: Row([
            SizedBox(
              width: 6,
              child: Text(
                'Page: ',
                style: const Style(foreground: CharmColors.squid),
              ),
            ),
            Expanded(
              child: Paginator(
                totalPages: 3,
                currentPage: 0,
                activeStyle: const Style(
                  foreground: CharmColors.charple,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
          ]),
        ),
      ]);
    } else if (burgerStage == 2) {
      return Column([
        SizedBox(
          height: 1,
          child: Text(
            'Stage 2 of 3: Choose sides & spice. Press [Enter] to continue.',
            style: const Style(foreground: CharmColors.squid),
          ),
        ),
        const SizedBox(height: 1, child: Text('')),
        Expanded(
          child: SingleChildScrollView(childLength: 15, child: burgerForm2),
        ),
        const SizedBox(height: 1, child: Text('')),
        SizedBox(
          height: 1,
          child: Row([
            SizedBox(
              width: 6,
              child: Text(
                'Page: ',
                style: const Style(foreground: CharmColors.squid),
              ),
            ),
            Expanded(
              child: Paginator(
                totalPages: 3,
                currentPage: 1,
                activeStyle: const Style(
                  foreground: CharmColors.charple,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
          ]),
        ),
      ]);
    } else if (burgerStage == 3) {
      return Column([
        SizedBox(
          height: 1,
          child: Text(
            'Stage 3 of 3: Customer details. Press [Enter] to place order.',
            style: const Style(foreground: CharmColors.squid),
          ),
        ),
        const SizedBox(height: 1, child: Text('')),
        Expanded(
          child: SingleChildScrollView(childLength: 15, child: burgerForm3),
        ),
        const SizedBox(height: 1, child: Text('')),
        SizedBox(
          height: 1,
          child: Row([
            SizedBox(
              width: 6,
              child: Text(
                'Page: ',
                style: const Style(foreground: CharmColors.squid),
              ),
            ),
            Expanded(
              child: Paginator(
                totalPages: 3,
                currentPage: 2,
                activeStyle: const Style(
                  foreground: CharmColors.charple,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
          ]),
        ),
      ]);
    } else {
      // Receipt Stage (4)
      final burgerType = burgerForm1.fields[0].value as String? ?? '';
      final toppings = List<String>.from(
        burgerForm1.fields[1].value as List? ?? [],
      );
      final spice = burgerForm2.fields[0].value as String? ?? 'Mild';
      final side = burgerForm2.fields[1].value as String? ?? '';
      final name = burgerForm3.fields[0].value as String? ?? '';
      final instructions = burgerForm3.fields[1].value as String? ?? '';
      final discount = burgerForm3.fields[2].value as bool? ?? false;

      final toppingsStr = _englishJoin(toppings);
      final spiceStr = _getSpiceString(spice);
      final nameSuffix = name.isNotEmpty ? ', $name' : '';

      return Column([
        SizedBox(
          height: 1,
          child: Text(
            ' 🍔 BURGER RECEIPT ',
            style: const Style(
              foreground: CharmColors.pepper,
              background: CharmColors.charple,
              modifiers: Modifier.bold,
            ),
          ),
        ),
        const SizedBox(height: 1, child: Text('')),
        SizedBox(
          height: 3,
          child: RichText(
            wrap: true,
            text: TextSpan(
              children: [
                const TextSpan(
                  text: 'One ',
                  style: Style(foreground: CharmColors.soda),
                ),
                TextSpan(
                  text: '$spiceStr$burgerType',
                  style: const Style(
                    foreground: CharmColors.blush,
                    modifiers: Modifier.bold,
                  ),
                ),
                const TextSpan(
                  text: ', topped with ',
                  style: Style(foreground: CharmColors.soda),
                ),
                TextSpan(
                  text: toppingsStr,
                  style: const Style(
                    foreground: CharmColors.blush,
                    modifiers: Modifier.bold,
                  ),
                ),
                const TextSpan(
                  text: ' with ',
                  style: Style(foreground: CharmColors.soda),
                ),
                TextSpan(
                  text: side,
                  style: const Style(
                    foreground: CharmColors.blush,
                    modifiers: Modifier.bold,
                  ),
                ),
                const TextSpan(
                  text: ' on the side.',
                  style: Style(foreground: CharmColors.soda),
                ),
              ],
            ),
          ),
        ),
        if (instructions.isNotEmpty) ...[
          const SizedBox(height: 1, child: Text('')),
          SizedBox(
            height: 1,
            child: Text(
              'Special Instructions:',
              style: const Style(
                foreground: CharmColors.squid,
                modifiers: Modifier.bold,
              ),
            ),
          ),
          SizedBox(
            height: 2,
            child: Text(
              '  "$instructions"',
              style: const Style(
                foreground: CharmColors.soda,
                modifiers: Modifier.italic,
              ),
            ),
          ),
        ],
        const SizedBox(height: 1, child: Text('')),
        SizedBox(
          height: 1,
          child: RichText(
            wrap: true,
            text: TextSpan(
              children: [
                TextSpan(
                  text: 'Thanks for your order$nameSuffix!',
                  style: const Style(
                    foreground: CharmColors.julep,
                    modifiers: Modifier.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (discount) ...[
          const SizedBox(
            height: 1,
            child: RichText(
              wrap: true,
              text: TextSpan(
                children: [
                  TextSpan(
                    text: 'Enjoy ',
                    style: Style(foreground: CharmColors.soda),
                  ),
                  TextSpan(
                    text: '15% off',
                    style: Style(
                      foreground: CharmColors.blush,
                      modifiers: Modifier.bold,
                    ),
                  ),
                  TextSpan(
                    text: '.',
                    style: Style(foreground: CharmColors.soda),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 1, child: Text('')),
        SizedBox(
          height: 1,
          child: Text(
            'Press [Enter] to place another order.',
            style: const Style(
              foreground: CharmColors.squid,
              modifiers: Modifier.italic,
            ),
          ),
        ),
      ]);
    }
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    final keyType = event.type;
    final isEnter =
        keyType == ui.KeyType.enter ||
        event.key == '\r' ||
        event.key == '\n' ||
        event.key == 'enter';

    if (event.key == '\t' || event.key == 'backtab') {
      if (burgerStage == 1) {
        if (event.key == 'backtab' && burgerForm1.activeFieldIndex == 0) {
          burgerStage = 0;
          return true;
        } else {
          burgerForm1.handleKeyEvent(event);
          return true;
        }
      } else if (burgerStage == 2) {
        if (event.key == 'backtab' && burgerForm2.activeFieldIndex == 0) {
          burgerStage = 1;
          for (var i = 0; i < burgerForm1.fields.length; i++) {
            burgerForm1.fields[i].focused =
                (i == burgerForm1.fields.length - 1);
          }
          burgerForm1.activeFieldIndex = burgerForm1.fields.length - 1;
          return true;
        } else {
          burgerForm2.handleKeyEvent(event);
          return true;
        }
      } else if (burgerStage == 3) {
        if (event.key == 'backtab' && burgerForm3.activeFieldIndex == 0) {
          burgerStage = 2;
          for (var i = 0; i < burgerForm2.fields.length; i++) {
            burgerForm2.fields[i].focused =
                (i == burgerForm2.fields.length - 1);
          }
          burgerForm2.activeFieldIndex = burgerForm2.fields.length - 1;
          return true;
        } else {
          burgerForm3.handleKeyEvent(event);
          return true;
        }
      }
      return false; // Toggle sidebar/demo focus globally
    }

    if (burgerStage == 0) {
      if (isEnter || event.key == ' ' || keyType == ui.KeyType.right) {
        burgerStage = 1;
        _focusFirstField(burgerForm1);
        return true;
      }
    } else if (burgerStage == 1) {
      if (keyType == ui.KeyType.left) {
        burgerStage = 0;
        return true;
      } else if (keyType == ui.KeyType.right) {
        if (burgerForm1.validate()) {
          burgerStage = 2;
          _focusFirstField(burgerForm2);
        }
        return true;
      } else if (isEnter) {
        if (burgerForm1.activeFieldIndex < burgerForm1.fields.length - 1) {
          _focusNextField(burgerForm1);
        } else {
          if (burgerForm1.validate()) {
            burgerStage = 2;
            _focusFirstField(burgerForm2);
          }
        }
        return true;
      } else {
        burgerForm1.handleKeyEvent(event);
        return true;
      }
    } else if (burgerStage == 2) {
      if (keyType == ui.KeyType.left) {
        burgerStage = 1;
        _focusFirstField(burgerForm1);
        return true;
      } else if (keyType == ui.KeyType.right) {
        if (burgerForm2.validate()) {
          burgerStage = 3;
          _focusFirstField(burgerForm3);
        }
        return true;
      } else if (isEnter) {
        if (burgerForm2.activeFieldIndex < burgerForm2.fields.length - 1) {
          _focusNextField(burgerForm2);
        } else {
          if (burgerForm2.validate()) {
            burgerStage = 3;
            _focusFirstField(burgerForm3);
          }
        }
        return true;
      } else {
        burgerForm2.handleKeyEvent(event);
        return true;
      }
    } else if (burgerStage == 3) {
      if (keyType == ui.KeyType.left &&
          burgerForm3.activeFieldIndex == 0 &&
          (burgerForm3.fields[0].value as String? ?? '').isEmpty) {
        burgerStage = 2;
        _focusFirstField(burgerForm2);
        return true;
      } else if (isEnter) {
        if (burgerForm3.activeFieldIndex < burgerForm3.fields.length - 1) {
          _focusNextField(burgerForm3);
        } else {
          if (burgerForm3.validate()) {
            burgerStage = 4;
          }
        }
        return true;
      } else {
        burgerForm3.handleKeyEvent(event);
        return true;
      }
    } else if (burgerStage == 4) {
      if (isEnter || event.key == ' ') {
        initBurgerForms();
        burgerStage = 0;
        return true;
      } else if (event.key == 'backspace' ||
          event.key == 'backtab' ||
          keyType == ui.KeyType.left) {
        burgerStage = 3;
        _focusLastField(burgerForm3);
        return true;
      }
    }
    return false;
  }

  @override
  Map<String, String> get helpBindings => {
    if (burgerStage > 0 && burgerStage < 4) ...{
      'Tab/Enter': 'Next Field',
      'Shift+Tab': 'Go Back',
      'Left/Right': 'Prev/Next Page',
    } else ...{
      'Enter': burgerStage == 0 ? 'Start Order' : 'Restart',
      if (burgerStage == 4) 'Backspace/Left': 'Go Back',
    },
  };
}
