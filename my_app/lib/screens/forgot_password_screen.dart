import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/password_requirements.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _authService = AuthService();

  // Step tracking: 0 = enter email, 1 = enter OTP, 2 = set new password
  int _step = 0;
  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;

  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  String? _resetToken;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(() => setState(() {}));
  }

  Future<void> _requestOTP() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _errorMessage = 'Please enter your email address.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final error = await _authService.requestPasswordReset(email);

    setState(() {
      _isLoading = false;
      if (error == null) {
        _step = 1;
        _successMessage = 'If an account with that email exists, a reset code has been sent.';
        _errorMessage = null;
      } else {
        _errorMessage = error;
      }
    });
  }

  Future<void> _verifyOTP() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      setState(() => _errorMessage = 'Please enter the 6-digit code.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    final result = await _authService.verifyOTP(_emailController.text.trim(), otp);

    setState(() {
      _isLoading = false;
      if (result['success'] == true) {
        _resetToken = result['reset_token'];
        _step = 2;
        _errorMessage = null;
      } else {
        _errorMessage = result['error'];
      }
    });
  }

  Future<void> _resetPassword() async {
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;

    if (password.isEmpty) {
      setState(() => _errorMessage = 'Please enter a new password.');
      return;
    }
    if (!passwordMeetsRequirements(password)) {
      setState(() => _errorMessage = 'Please meet all password requirements below.');
      return;
    }
    if (password != confirm) {
      setState(() => _errorMessage = 'Passwords do not match.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final error = await _authService.resetPassword(_resetToken!, password);

    setState(() {
      _isLoading = false;
      if (error == null) {
        _successMessage = 'Password reset successfully. You can now log in.';
        _errorMessage = null;
      } else {
        _errorMessage = error;
      }
    });

    if (error == null && mounted) {
      // Show success dialog then navigate back to login
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Password Reset'),
          content: const Text('Your password has been reset successfully. You can now log in with your new password.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).pop(); // Back to login
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reset Password'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Step indicator
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildStepCircle(0, 'Email'),
                  _buildStepLine(0),
                  _buildStepCircle(1, 'Code'),
                  _buildStepLine(1),
                  _buildStepCircle(2, 'Password'),
                ],
              ),
              const SizedBox(height: 32),

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

              if (_successMessage != null && _step == 1)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Text(
                    _successMessage!,
                    style: TextStyle(color: Colors.green.shade800),
                    textAlign: TextAlign.center,
                  ),
                ),

              // Step 0: Enter email
              if (_step == 0) ...[
                const Text(
                  'Enter your email address and we\'ll send you a code to reset your password.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.email),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autofocus: true,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isLoading ? null : _requestOTP,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('SEND RESET CODE'),
                ),
              ],

              // Step 1: Enter OTP
              if (_step == 1) ...[
                const Text(
                  'Enter the 6-digit code sent to your email.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _otpController,
                  decoration: const InputDecoration(
                    labelText: 'Reset Code',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_clock),
                    hintText: '000000',
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, letterSpacing: 8),
                  autofocus: true,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isLoading ? null : _verifyOTP,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('VERIFY CODE'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _isLoading ? null : _requestOTP,
                  child: const Text('Resend code'),
                ),
              ],

              // Step 2: Set new password
              if (_step == 2) ...[
                const Text(
                  'Enter your new password.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'New Password',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                PasswordRequirements(password: _passwordController.text),
                const SizedBox(height: 16),
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm Password',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isLoading ? null : _resetPassword,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('RESET PASSWORD'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepCircle(int step, String label) {
    final isActive = _step >= step;
    return Column(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: isActive ? Theme.of(context).primaryColor : Colors.grey.shade300,
          child: Text(
            '${step + 1}',
            style: TextStyle(
              color: isActive ? Colors.white : Colors.grey.shade600,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? Theme.of(context).primaryColor : Colors.grey,
          ),
        ),
      ],
    );
  }

  Widget _buildStepLine(int afterStep) {
    final isActive = _step > afterStep;
    return Container(
      width: 40,
      height: 2,
      margin: const EdgeInsets.only(bottom: 16),
      color: isActive ? Theme.of(context).primaryColor : Colors.grey.shade300,
    );
  }
}
