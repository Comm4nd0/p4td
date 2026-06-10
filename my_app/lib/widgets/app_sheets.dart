import 'package:flutter/cupertino.dart';

/// One choice in an [showAppActionSheet].
class AppSheetAction<T> {
  final String label;
  final T value;
  final bool isDestructive;

  const AppSheetAction({
    required this.label,
    required this.value,
    this.isDestructive = false,
  });
}

/// Shows an iOS-style action sheet and returns the chosen action's value,
/// or null if dismissed/cancelled.
Future<T?> showAppActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<AppSheetAction<T>> actions,
  String cancelLabel = 'Cancel',
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (sheetContext) => CupertinoActionSheet(
      title: title != null ? Text(title) : null,
      message: message != null ? Text(message) : null,
      actions: [
        for (final action in actions)
          CupertinoActionSheetAction(
            isDestructiveAction: action.isDestructive,
            onPressed: () => Navigator.pop(sheetContext, action.value),
            child: Text(action.label),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.pop(sheetContext),
        child: Text(cancelLabel),
      ),
    ),
  );
}
