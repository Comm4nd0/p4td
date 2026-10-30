import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../constants/app_colors.dart';
import '../models/dog_address.dart';
import '../services/data_service.dart';
import 'postcode_lookup_dialog.dart';

/// "Other addresses" on the dog's edit screen: up to [DogAddress.maxPerDog]
/// places the dog can be collected from or taken home to instead of its own
/// address — a grandparent's, a dog-sitter's, an office. The dog's own
/// address above stays the default; staff pick one of these for a day's
/// morning, evening or both in the transport dialog, and the dashboard lists
/// that day as a transport change.
///
/// Each add, edit and delete is saved straight away (`dog-addresses/`), not
/// with the screen's Save button, so the list is always what the server holds.
class AlternativeAddressesSection extends StatefulWidget {
  final String dogId;
  final List<DogAddress> initial;
  final DataService dataService;
  final bool postcodeLookupEnabled;

  const AlternativeAddressesSection({
    super.key,
    required this.dogId,
    required this.initial,
    required this.dataService,
    this.postcodeLookupEnabled = false,
  });

  @override
  State<AlternativeAddressesSection> createState() => _AlternativeAddressesSectionState();
}

class _AlternativeAddressesSectionState extends State<AlternativeAddressesSection> {
  late final List<DogAddress> _addresses = List.of(widget.initial);

  bool get _full => _addresses.length >= DogAddress.maxPerDog;

  Future<void> _edit([DogAddress? existing]) async {
    final saved = await showDogAddressForm(
      context,
      dogId: widget.dogId,
      existing: existing,
      dataService: widget.dataService,
      postcodeLookupEnabled: widget.postcodeLookupEnabled,
    );
    if (saved == null || !mounted) return;
    setState(() {
      final index = _addresses.indexWhere((a) => a.id == saved.id);
      if (index == -1) {
        _addresses.add(saved);
      } else {
        _addresses[index] = saved;
      }
    });
  }

  Future<void> _delete(DogAddress address) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove address?'),
        content: Text('Remove ${address.displayName} from this dog?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.dataService.deleteDogAddress(address.id);
      if (mounted) setState(() => _addresses.removeWhere((a) => a.id == address.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: AppColors.error,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Other addresses', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(
          'The address above is the usual one. Add others here and staff can '
          'collect from or drop off at them on a particular day.',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
        for (final address in _addresses)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Picon(PiconsDuotone.mapPin),
            title: Text(address.label.isEmpty ? 'Alternative address' : address.label),
            subtitle: Text(
              [address.address, if (address.postcode.isNotEmpty) address.postcode].join('\n'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _edit(address),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Picon(PiconsDuotone.trash, color: AppColors.error),
              onPressed: () => _delete(address),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _full ? null : () => _edit(),
            icon: const Picon(PiconsDuotone.plusCircle, size: 20),
            label: Text(_full
                ? 'Up to ${DogAddress.maxPerDog} other addresses'
                : 'Add another address'),
          ),
        ),
      ],
    );
  }
}

/// Add or edit one of a dog's alternative addresses in a bottom sheet;
/// returns the saved [DogAddress], or null if dismissed.
Future<DogAddress?> showDogAddressForm(
  BuildContext context, {
  required String dogId,
  DogAddress? existing,
  required DataService dataService,
  bool postcodeLookupEnabled = false,
}) {
  return showModalBottomSheet<DogAddress>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AddressForm(
      dogId: dogId,
      existing: existing,
      dataService: dataService,
      postcodeLookupEnabled: postcodeLookupEnabled,
    ),
  );
}

/// Add or edit one alternative address; pops the saved [DogAddress].
class _AddressForm extends StatefulWidget {
  final String dogId;
  final DogAddress? existing;
  final DataService dataService;
  final bool postcodeLookupEnabled;

  const _AddressForm({
    required this.dogId,
    required this.existing,
    required this.dataService,
    required this.postcodeLookupEnabled,
  });

  @override
  State<_AddressForm> createState() => _AddressFormState();
}

class _AddressFormState extends State<_AddressForm> {
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late final _address = TextEditingController(text: widget.existing?.address ?? '');
  late final _postcode = TextEditingController(text: widget.existing?.postcode ?? '');
  late final _instructions = TextEditingController(text: widget.existing?.accessInstructions ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _address.dispose();
    _postcode.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _lookUp() async {
    final address = await showPostcodeLookup(context, widget.dataService);
    if (address == null || !mounted) return;
    setState(() => _address.text = address);
  }

  Future<void> _save() async {
    if (_address.text.trim().isEmpty) {
      setState(() => _error = 'Enter the address.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.dataService.saveDogAddress(
        dogId: widget.dogId,
        id: widget.existing?.id,
        label: _label.text.trim(),
        address: _address.text.trim(),
        postcode: _postcode.text.trim().toUpperCase(),
        accessInstructions: _instructions.text.trim(),
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.existing == null ? 'Add another address' : 'Edit address',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'Name (optional)',
                  hintText: "e.g. Grandma's, Office, Dog sitter",
                  prefixIcon: Picon(PiconsDuotone.tag),
                ),
                textCapitalization: TextCapitalization.sentences,
                maxLength: 60,
              ),
              TextField(
                controller: _address,
                decoration: InputDecoration(
                  labelText: 'Address',
                  prefixIcon: const Picon(PiconsDuotone.mapPin),
                  errorText: _error,
                ),
                textCapitalization: TextCapitalization.words,
                maxLines: 3,
              ),
              if (widget.postcodeLookupEnabled)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _lookUp,
                    icon: const Picon(PiconsDuotone.mapPin, size: 18),
                    label: const Text('Look up postcode'),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _postcode,
                decoration: const InputDecoration(
                  labelText: 'Postcode',
                  hintText: 'Places the dog on the pickup map that day',
                  prefixIcon: Picon(PiconsDuotone.mapPin),
                ),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _instructions,
                decoration: const InputDecoration(
                  labelText: 'Pickup instructions here (optional)',
                  hintText: 'Keys, gates, who hands the dog over',
                  prefixIcon: Picon(PiconsDuotone.key),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save address'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
