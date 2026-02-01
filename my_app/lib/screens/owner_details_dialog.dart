import 'package:flutter/material.dart';
import '../models/owner_profile.dart';
import '../services/data_service.dart';

class OwnerDetailsDialog extends StatefulWidget {
  final OwnerProfile ownerProfile;
  final int ownerId;
  final bool isStaff;
  final VoidCallback? onUpdated;

  const OwnerDetailsDialog({
    super.key,
    required this.ownerProfile,
    required this.ownerId,
    required this.isStaff,
    this.onUpdated,
  });

  @override
  State<OwnerDetailsDialog> createState() => _OwnerDetailsDialogState();
}

class _OwnerDetailsDialogState extends State<OwnerDetailsDialog> {
  late TextEditingController _addressController;
  late TextEditingController _phoneController;
  late TextEditingController _pickupController;
  bool _isEditing = false;
  bool _isSaving = false;
  final _dataService = ApiDataService();

  @override
  void initState() {
    super.initState();
    _addressController = TextEditingController(text: widget.ownerProfile.address ?? '');
    _phoneController = TextEditingController(text: widget.ownerProfile.phoneNumber ?? '');
    _pickupController = TextEditingController(text: widget.ownerProfile.pickupInstructions ?? '');
  }

  @override
  void dispose() {
    _addressController.dispose();
    _phoneController.dispose();
    _pickupController.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    setState(() => _isSaving = true);
    try {
      await _dataService.updateOwnerProfile(
        widget.ownerId,
        address: _addressController.text.isEmpty ? null : _addressController.text,
        phoneNumber: _phoneController.text.isEmpty ? null : _phoneController.text,
        pickupInstructions: _pickupController.text.isEmpty ? null : _pickupController.text,
      );

      if (mounted) {
        setState(() {
          _isEditing = false;
          _isSaving = false;
        });
        widget.onUpdated?.call();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Owner information updated successfully!')),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Owner Information'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Non-editable fields
            Text(
              'Username',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Text(widget.ownerProfile.username),
            const SizedBox(height: 16),
            Text(
              'Email',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Text(widget.ownerProfile.email),
            const SizedBox(height: 24),
            
            // Editable fields
            if (_isEditing)
              ...[
                TextField(
                  controller: _addressController,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  decoration: const InputDecoration(
                    labelText: 'Phone Number',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pickupController,
                  decoration: const InputDecoration(
                    labelText: 'Pickup Instructions',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
              ]
            else
              ...[
                Text(
                  'Address',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                Text(widget.ownerProfile.address ?? 'Not provided'),
                const SizedBox(height: 12),
                Text(
                  'Phone Number',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                Text(widget.ownerProfile.phoneNumber ?? 'Not provided'),
                const SizedBox(height: 12),
                Text(
                  'Pickup Instructions',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                Text(widget.ownerProfile.pickupInstructions ?? 'Not provided'),
              ],
          ],
        ),
      ),
      actions: [
        if (widget.isStaff && !_isEditing)
          TextButton(
            onPressed: () {
              setState(() => _isEditing = true);
            },
            child: const Text('Edit'),
          ),
        if (_isEditing)
          TextButton(
            onPressed: _isSaving ? null : () {
              setState(() => _isEditing = false);
            },
            child: const Text('Cancel'),
          ),
        if (_isEditing)
          FilledButton(
            onPressed: _isSaving ? null : _saveChanges,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        if (!_isEditing)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
      ],
    );
  }
}
