import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/no_connection_exception.dart';
import '../widgets/no_connection_widget.dart';
import 'home_screen.dart';
import 'register_screen.dart';
import 'forgot_password_screen.dart';
import '../services/notification_service.dart';

class LoginScreen extends StatefulWidget {
  /// When true, this screen is being used to add another account while the
  /// user is already logged in. On success we pop back instead of replacing
  /// the navigation stack.
  final bool addingAccount;

  const LoginScreen({super.key, this.addingAccount = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();
  bool _isLoading = false;
  bool _isOffline = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isOffline) {
      setState(() => _isOffline = false);
    }
  }

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _isOffline = false;
      _errorMessage = null;
    });

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      // Email is the username
      final error = await _authService.login(email, password);

      setState(() {
        _isLoading = false;
      });

      if (error == null) {
        if (mounted) {
          // Fetch the profile so we can record the account in the switcher.
          // Don't block login on failures here — the user is still logged in
          // even if profile lookup fails, the active token is set.
          try {
            final profile = await ApiDataService().getProfile();
            if (profile.userId != null) {
              await _authService.upsertActiveAccount(
                userId: profile.userId!,
                username: profile.username,
                email: profile.email,
                displayName: profile.firstName,
                profilePhotoUrl: profile.profilePhotoUrl,
              );
            }
          } catch (e) {
            debugPrint("Failed to record account: $e");
          }

          // Register push notification token
          try {
            await NotificationService().updateToken();
          } catch (e) {
            debugPrint("Failed to update token: $e");
            // Don't block login
          }

          if (mounted) {
            if (widget.addingAccount) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const HomeScreen()),
                (route) => false,
              );
            } else {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const HomeScreen()),
              );
            }
          }
        }
      } else {
        setState(() {
          _errorMessage = error;
        });
      }
    } on NoConnectionException {
      setState(() {
        _isLoading = false;
        _isOffline = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isOffline) {
      return Scaffold(
        body: NoConnectionWidget(
          onRetry: () {
            setState(() => _isOffline = false);
          },
        ),
      );
    }

    return Scaffold(
      appBar: widget.addingAccount
          ? AppBar(title: const Text('Add another account'))
          : null,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Image.asset('assets/logo.png', height: 120),
              ),
              const SizedBox(height: 32),
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(color: Colors.red.shade800),
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Picon(PiconsDuotone.envelope),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Picon(PiconsDuotone.lock),
                  suffixIcon: IconButton(
                    icon: Picon(
                      _obscurePassword ? PiconsDuotone.eye : PiconsDuotone.eyeSlash,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                    );
                  },
                  child: const Text('Forgot Password?'),
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _isLoading ? null : _login,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Log In'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RegisterScreen()),
                  );
                },
                child: const Text('Don\'t have an account? Create one'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
