import 'package:flutter/widgets.dart';

/// Disposes controllers that were created for a dialog or sheet, once its
/// exit animation is over.
///
/// A function that builds a dialog around its own `TextEditingController`s
/// has nowhere obvious to dispose them, and most didn't. Disposing the moment
/// the route's future completes is too early — the closing animation still
/// paints the fields — so wait it out. Reading `.text` afterwards stays safe.
void disposeControllersLater(Iterable<ChangeNotifier> controllers) {
  final list = controllers.toList();
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    for (final controller in list) {
      controller.dispose();
    }
  });
}
