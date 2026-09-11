import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../models/owner_profile.dart';

/// Picking an owner from the whole client list.
///
/// The list is every account on the app, and it only grows, so a plain
/// dropdown stopped being usable: staff know the person as "Sue" or by the
/// email on the booking form, not by where they sit alphabetically.
/// [showOwnerPicker] is a dialog with a search box that narrows the list as
/// you type any part of the name or email ([OwnerProfile.matches]);
/// [OwnerPickerField] is the form field that opens it and shows who's chosen.

/// The result of [showOwnerPicker]. `null` from the dialog means cancelled;
/// an [OwnerPick] with a null [owner] means "no owner" was chosen.
class OwnerPick {
  final OwnerProfile? owner;
  const OwnerPick(this.owner);
}

Future<OwnerPick?> showOwnerPicker(
  BuildContext context, {
  required List<OwnerProfile> owners,
  int? selectedId,
  bool allowNone = false,
  String title = 'Choose owner',
}) {
  return showDialog<OwnerPick>(
    context: context,
    builder: (ctx) => _OwnerPickerDialog(
      owners: owners,
      selectedId: selectedId,
      allowNone: allowNone,
      title: title,
    ),
  );
}

class _OwnerPickerDialog extends StatefulWidget {
  final List<OwnerProfile> owners;
  final int? selectedId;
  final bool allowNone;
  final String title;

  const _OwnerPickerDialog({
    required this.owners,
    required this.selectedId,
    required this.allowNone,
    required this.title,
  });

  @override
  State<_OwnerPickerDialog> createState() => _OwnerPickerDialogState();
}

class _OwnerPickerDialogState extends State<_OwnerPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = widget.owners.where((o) => o.matches(_query)).toList();
    final showNone = widget.allowNone && _query.trim().isEmpty;
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search by name or email',
                prefixIcon: const Picon(PiconsDuotone.magnifyingGlass),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Picon(PiconsDuotone.x, size: 18),
                        tooltip: 'Clear',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.45,
              ),
              child: matches.isEmpty && !showNone
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No one matches that.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        if (showNone)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Picon(PiconsDuotone.userMinus, color: Colors.grey),
                            title: const Text('No owner', style: TextStyle(color: Colors.grey)),
                            trailing: widget.selectedId == null
                                ? const Picon(PiconsDuotone.check, size: 20)
                                : null,
                            onTap: () => Navigator.pop(context, const OwnerPick(null)),
                          ),
                        for (final owner in matches)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Picon(PiconsDuotone.user),
                            title: Text(owner.displayName),
                            subtitle: owner.email.isEmpty || owner.email == owner.displayName
                                ? null
                                : Text(owner.email, style: const TextStyle(fontSize: 12)),
                            trailing: owner.userId == widget.selectedId
                                ? const Picon(PiconsDuotone.check, size: 20)
                                : null,
                            onTap: () => Navigator.pop(context, OwnerPick(owner)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// A form field showing the chosen owner; tapping it opens [showOwnerPicker].
/// Validates like any other [FormField], so a form's `validate()` covers it.
class OwnerPickerField extends StatelessWidget {
  final List<OwnerProfile> owners;
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool allowNone;
  final String labelText;
  final Widget? prefixIcon;
  final FormFieldValidator<int?>? validator;

  const OwnerPickerField({
    super.key,
    required this.owners,
    required this.value,
    required this.onChanged,
    this.allowNone = false,
    this.labelText = 'Owner',
    this.prefixIcon,
    this.validator,
  });

  OwnerProfile? get _selected {
    for (final o in owners) {
      if (o.userId == value) return o;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FormField<int?>(
      initialValue: value,
      validator: validator,
      // Keep the field's value in step with the parent's state so validation
      // sees what is actually chosen, not what it was at first build.
      key: ValueKey('owner-picker-$value'),
      builder: (state) {
        final selected = _selected;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final pick = await showOwnerPicker(
              context,
              owners: owners,
              selectedId: value,
              allowNone: allowNone,
            );
            if (pick == null) return;
            state.didChange(pick.owner?.userId);
            onChanged(pick.owner?.userId);
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: labelText,
              prefixIcon: prefixIcon,
              suffixIcon: const Picon(PiconsDuotone.magnifyingGlass),
              errorText: state.errorText,
            ),
            isEmpty: selected == null,
            child: selected == null
                ? Text(
                    allowNone ? 'No owner' : 'Tap to search',
                    style: const TextStyle(color: Colors.grey),
                  )
                : Text(
                    selected.email.isEmpty || selected.email == selected.displayName
                        ? selected.displayName
                        : '${selected.displayName} · ${selected.email}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        );
      },
    );
  }
}
