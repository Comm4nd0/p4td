import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../services/enquiry_service.dart';
import '../services/no_connection_exception.dart';

/// Public "Send us a message" form, reachable from the logged-out landing
/// page — no account needed. Submissions land in the same inbox staff already
/// manage (website contact inquiries).
class EnquiryScreen extends StatefulWidget {
  /// Pre-selects the service dropdown (API code, e.g. 'daycare') when opened
  /// from a service detail sheet.
  final String? initialService;

  /// Test seam — widget tests inject a stub.
  final EnquiryService? enquiryService;

  const EnquiryScreen({super.key, this.initialService, this.enquiryService});

  @override
  State<EnquiryScreen> createState() => _EnquiryScreenState();
}

class _EnquiryScreenState extends State<EnquiryScreen> {
  final _formKey = GlobalKey<FormState>();
  late final EnquiryService _enquiryService =
      widget.enquiryService ?? EnquiryService();

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _messageController = TextEditingController();
  late String _service = _serviceOptions.any((o) => o.code == widget.initialService)
      ? widget.initialService!
      : 'daycare';

  bool _isLoading = false;
  String? _errorMessage;

  /// Same shape check as the registration screen.
  static final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  // API codes match ContactInquiry.SERVICE_CHOICES on the backend.
  static const _serviceOptions = [
    (code: 'daycare', label: 'Day Care'),
    (code: 'one2one', label: '1-to-1 Training'),
    (code: 'puppy_classes', label: 'Puppy Classes'),
    (code: 'field_hire', label: 'Field Hire'),
    (code: 'other', label: 'Something else'),
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final error = await _enquiryService.submitEnquiry(
        name: _nameController.text,
        email: _emailController.text,
        service: _service,
        message: _messageController.text,
      );
      if (!mounted) return;
      if (error == null) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(const SnackBar(
          content: Text(
              "Thanks! Your message has been sent — we'll be in touch soon."),
        ));
      } else {
        setState(() => _errorMessage = error);
      }
    } on NoConnectionException {
      setState(() => _errorMessage =
          'No internet connection. Please check your connection and try again.');
    } catch (_) {
      setState(() =>
          _errorMessage = 'Could not send your message. Please try again later.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send Us a Message'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "Have a question about day care, training or field hire? "
                "Send us a message and we'll get back to you.",
                style: TextStyle(color: Colors.grey[600], fontSize: 14),
              ),
              const SizedBox(height: 20),
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Your Name',
                  prefixIcon: Picon(PiconsDuotone.user),
                ),
                textCapitalization: TextCapitalization.words,
                maxLength: 100,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Picon(PiconsDuotone.envelope),
                  helperText: "We'll reply to this address",
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (v) {
                  if (v?.trim().isEmpty ?? true) return 'Required';
                  if (!_emailRegex.hasMatch(v!.trim())) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _service,
                decoration: const InputDecoration(
                  labelText: "What's it about?",
                  prefixIcon: Picon(PiconsDuotone.pawPrint),
                ),
                items: [
                  for (final option in _serviceOptions)
                    DropdownMenuItem(value: option.code, child: Text(option.label)),
                ],
                onChanged: (v) => setState(() => _service = v ?? 'daycare'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _messageController,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  alignLabelWithHint: true,
                ),
                minLines: 5,
                maxLines: 10,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Send Message', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
