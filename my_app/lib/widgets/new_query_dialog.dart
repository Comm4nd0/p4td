import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';

/// The owner's "New Message" form: subject + message, sent as a new support
/// query. Shared by the Contact Staff list and the client dashboard's quick
/// action so the two can't drift.
///
/// Returns true when a query was created (the caller reloads its list),
/// false when the form was dismissed or the send failed (already reported
/// with a snackbar).
Future<bool> showNewQueryDialog(BuildContext context) async {
  final subjectController = TextEditingController();
  final messageController = TextEditingController();
  final formKey = GlobalKey<FormState>();

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('New Message'),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: subjectController,
              decoration: const InputDecoration(
                labelText: 'Subject',
                hintText: 'Brief summary',
              ),
              validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: messageController,
              decoration: const InputDecoration(
                labelText: 'Message',
                hintText: 'Your message',
              ),
              maxLines: 4,
              validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (formKey.currentState!.validate()) {
              Navigator.pop(context, true);
            }
          },
          child: const Text('Submit'),
        ),
      ],
    ),
  );

  if (result != true) return false;
  try {
    await getIt<DataService>().createSupportQuery(
      subject: subjectController.text.trim(),
      initialMessage: messageController.text.trim(),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message sent'), backgroundColor: AppColors.success),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: $e')),
      );
    }
    return false;
  }
}
