import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';

/// Who has to give a dog's contact numbers.
///
/// A client must always leave both a day-to-day number and an emergency
/// contact on a dog they create (the booking form) or edit: when a dog is hurt
/// or a pickup goes wrong, staff can only act if a number is on file. The API
/// enforces the same rule for owners (`CLIENT_REQUIRED_DOG_FIELDS`).
///
/// A staff member is only warned. A dog moved over from the paper book often
/// arrives without the numbers, and refusing the save would just mean the dog
/// doesn't get added at all — so [confirmSaveWithoutContacts] asks once and
/// lets them carry on.
///
/// To put another field under the same rule, add it to [dogContactFieldLabels]
/// and wire its controller into the screens' [missingDogContactFields] call.
const Map<String, String> dogContactFieldLabels = {
  'contact_number': 'Contact number',
  'emergency_contact_number': 'Emergency contact number',
};

/// The labels of the client-required fields that are blank, in form order.
List<String> missingDogContactFields({
  required String contactNumber,
  required String emergencyContactNumber,
}) {
  return [
    if (contactNumber.trim().isEmpty) dogContactFieldLabels['contact_number']!,
    if (emergencyContactNumber.trim().isEmpty)
      dogContactFieldLabels['emergency_contact_number']!,
  ];
}

/// Form validator: required for a client, never blocks a staff member.
String? dogContactValidator(String? value, {required bool isStaff}) {
  if (isStaff) return null;
  return (value?.trim().isEmpty ?? true) ? 'Required' : null;
}

/// Staff-only: asks whether to save a dog with the named contact fields
/// blank. Returns true to go ahead, false to go back to the form.
Future<bool> confirmSaveWithoutContacts(
  BuildContext context,
  List<String> missing,
) async {
  if (missing.isEmpty) return true;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Picon(PiconsDuotone.warningCircle, size: 40, color: AppColors.warning),
      title: Text(missing.length == 1 ? 'No ${missing.single.toLowerCase()}' : 'No contact numbers'),
      content: Text(
        '${missing.join(' and ')} ${missing.length == 1 ? 'is' : 'are'} blank. '
        "Clients have to give these, so staff can reach someone if something "
        "happens on a daycare day. Save without ${missing.length == 1 ? 'it' : 'them'}?",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Go back'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Save anyway'),
        ),
      ],
    ),
  );
  return result ?? false;
}
