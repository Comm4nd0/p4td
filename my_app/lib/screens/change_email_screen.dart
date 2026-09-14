import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../services/auth_service.dart';
import '../services/no_connection_exception.dart';
import '../widgets/page_body.dart';

/// Changes the signed-in user's email address. The email is also how they
/// sign in, so the server asks for the current password and the screen says
/// so up front. Pops with `true` when the address changed.
class ChangeEmailScreen extends StatefulWidget {
  final String currentEmail;

  const ChangeEmailScreen({super.key, required this.currentEmail});

  @override
  State<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<ChangeEmailScreen> {
  final _authService = AuthService();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _changeEmail() async {
    final newEmail = _emailController.text.trim();
    final password = _passwordController.text;

    if (newEmail.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Please fill in both fields.');
      return;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(newEmail)) {
      setState(() => _errorMessage = 'Please enter a valid email address.');
      return;
    }
    if (newEmail.toLowerCase() == widget.currentEmail.toLowerCase()) {
      setState(() => _errorMessage = 'That is already your email address.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    String? error;
    try {
      error = await _authService.changeEmail(newEmail, password);
    } on NoConnectionException {
      error = 'No internet connection. Please try again.';
    }

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Email changed to $newEmail. Use it next time you sign in.')),
      );
      Navigator.of(context).pop(true);
    } else {
      setState(() => _errorMessage = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Change Email'),
      ),
      body: PageBody(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade800),
                  textAlign: TextAlign.center,
                ),
              ),
            Text(
              'You sign in with your email address, so the new one becomes your login too. '
              'Your current address is ${widget.currentEmail}.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'New Email Address',
                prefixIcon: Picon(PiconsDuotone.envelope),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: 'Current Password',
                prefixIcon: Picon(PiconsDuotone.lock),
                suffixIcon: IconButton(
                  icon: Picon(
                    _obscurePassword ? PiconsDuotone.eye : PiconsDuotone.eyeSlash,
                  ),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              onSubmitted: (_) => _isLoading ? null : _changeEmail(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : _changeEmail,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('CHANGE EMAIL'),
            ),
          ],
        ),
      )),
    );
  }
}
