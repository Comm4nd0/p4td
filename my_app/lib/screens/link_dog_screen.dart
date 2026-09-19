import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../widgets/page_body.dart';

/// "Link my dog": for a client whose dog already comes to daycare. They give
/// the dog's name plus the postcode and phone number staff hold for it, and
/// staff match it to the existing dog and approve. The client is never shown
/// any existing dog — staff confirm the match, so nobody can attach someone
/// else's dog to their account. New dogs go through the booking form instead.
class LinkDogScreen extends StatefulWidget {
  const LinkDogScreen({super.key});

  @override
  State<LinkDogScreen> createState() => _LinkDogScreenState();
}

class _LinkDogScreenState extends State<LinkDogScreen> {
  final DataService _dataService = getIt<DataService>();
  final _formKey = GlobalKey<FormState>();
  final _dogNameController = TextEditingController();
  final _postcodeController = TextEditingController();
  final _phoneController = TextEditingController();
  final _notesController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _dogNameController.dispose();
    _postcodeController.dispose();
    _phoneController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      await _dataService.submitDogLinkRequest(
        dogName: _dogNameController.text.trim(),
        postcode: _postcodeController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
        notes: _notesController.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request sent! Staff will link your dog shortly.'),
            backgroundColor: AppColors.success,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Link My Dog')),
      body: PageBody(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primaryLight.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Picon(PiconsDuotone.info, color: AppColors.primary, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'For a dog that already comes to Paws 4 Thought. Tell us '
                        'who they are and staff will attach them to your account. '
                        'Bringing a new dog? Use the New Dog Booking Form instead.',
                        style: TextStyle(color: AppColors.primary, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _dogNameController,
                decoration: const InputDecoration(
                  labelText: "Dog's name",
                  prefixIcon: Picon(PiconsDuotone.pawPrint),
                ),
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: (v) => (v == null || v.trim().isEmpty) ? "Tell us your dog's name" : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _postcodeController,
                decoration: const InputDecoration(
                  labelText: 'Your postcode',
                  helperText: 'The address we collect from — it helps us find the right dog',
                  prefixIcon: Picon(PiconsDuotone.mapPin),
                ),
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Your phone number',
                  helperText: 'The number we have on file for you',
                  prefixIcon: Picon(PiconsDuotone.phone),
                ),
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Anything else that helps (optional)',
                  hintText: 'Breed, usual days, who else brings them in…',
                  prefixIcon: Picon(PiconsDuotone.notePencil),
                  alignLabelWithHint: true,
                ),
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Picon(PiconsDuotone.link, size: 18),
                label: Text(_submitting ? 'Sending…' : 'Send Link Request'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Staff check every request against the dog on our books before '
                'linking it, so it may take a little while.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
