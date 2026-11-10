import 'package:flutter/material.dart';

/// The scrolling body of a form: every field built, whatever is on screen.
///
/// Forms used to sit in a `ListView`, which builds only the children near
/// the viewport. A `FormField` leaves its `Form` when it is scrolled away, so
/// `validate()` — called from the Submit button at the bottom — skipped every
/// required field further up: the booking form went to the server without a
/// phone number and came back as an error naming no field. A `Column` keeps
/// them all registered.
class FormScrollBody extends StatelessWidget {
  const FormScrollBody({
    super.key,
    this.padding = const EdgeInsets.all(16),
    required this.children,
  });

  final EdgeInsetsGeometry padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding,
      child: Column(
        // What a ListView gives its children: the full width.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Validates the form and, when a field fails, scrolls the first failing one
/// into view — otherwise a press on Submit with the problem off the top of
/// the screen looks like a button that does nothing.
bool validateFormAndReveal(GlobalKey<FormState> formKey) {
  final form = formKey.currentState;
  if (form == null) return false;
  final invalid = form.validateGranularly();
  if (invalid.isEmpty) return true;

  // The highest failing field on the page (the set has no useful order).
  FormFieldState<Object?>? first;
  double? firstTop;
  for (final field in invalid) {
    final box = field.context.findRenderObject();
    if (box is! RenderBox || !box.attached) continue;
    final top = box.localToGlobal(Offset.zero).dy;
    if (firstTop == null || top < firstTop) {
      first = field;
      firstTop = top;
    }
  }
  final target = first?.context;
  if (target != null && target.mounted) {
    Scrollable.ensureVisible(
      target,
      alignment: 0.1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
  return false;
}
