import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
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
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isOffline) {
      setState(() => _isOffline = false);
    }
  }

  /// Basic email shape check — not exhaustive, just enough to catch obvious
  /// typos before hitting the network.
  static final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  Future<void> _login() async {
    if (_isLoading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    // Validate before doing any network work.
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your email and password.';
        _isOffline = false;
      });
      return;
    }
    if (!_emailRegex.hasMatch(email)) {
      setState(() {
        _errorMessage = 'Please enter a valid email address.';
        _isOffline = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _isOffline = false;
      _errorMessage = null;
    });

    try {
      // Email is the username
      final error = await _authService.login(email, password);
      if (!mounted) return;

      // On success the spinner stays until Home replaces this screen: the
      // profile and push-token calls below can take seconds, and a button
      // that had come back to life invited a second sign-in.
      if (error == null) {
        if (mounted) {
          // Fetch the profile so we can record the account in the switcher.
          // Don't block login on failures here — the user is still logged in
          // even if profile lookup fails, the active token is set.
          try {
            final profile = await getIt<DataService>().getProfile();
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
            // Clear the whole stack, not just this screen: the logged-out
            // landing page is still underneath, and a back press (tablet
            // navigation bar, hardware key) would drop the signed-in user
            // onto Log in / Sign up as if they had been logged out. Home is
            // the root once signed in; back from there leaves the app.
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const HomeScreen()),
              (route) => false,
            );
          }
        }
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = error;
        });
      }
    } on NoConnectionException {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isOffline = true;
      });
    } catch (e) {
      // Anything else must not leave the button spinning for good.
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Something went wrong signing in. Please try again.';
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
      // Scrollable: with the keyboard up on a small phone (or large text)
      // the Log In button was clipped below the fold.
      body: SafeArea(child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AutofillGroup(child: Column(
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
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.username, AutofillHints.email],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _login(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Picon(PiconsDuotone.lock),
                    suffixIcon: IconButton(
                      icon: Picon(
                        _obscurePassword ? PiconsDuotone.eye : PiconsDuotone.eyeSlash,
                      ),
                      tooltip: _obscurePassword ? 'Show password' : 'Hide password',
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
            )),
          ),
        ),
      )),
    );
  }
}
