import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Shared yes/no confirmation dialog.
///
/// There were 42 structurally identical `showDialog<bool>` blocks across the
/// screens, and the destructive-button colour had already drifted between them
/// (`Colors.red` in some, `AppColors.error` in others). One implementation
/// keeps every confirmation looking and behaving the same, and gives new
/// screens a correct one for free.
///
/// Returns true only when the user explicitly confirms — dismissing by tapping
/// outside or pressing back returns false, never null, so callers do not have
/// to remember the `!= true` idiom.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  /// Styles the confirm button as destructive. Use for anything that deletes,
  /// removes, voids or cannot easily be undone.
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}
