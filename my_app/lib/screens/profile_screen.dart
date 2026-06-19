import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_colors.dart';
import '../models/user_profile.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../services/auth_service.dart';
import '../services/theme_service.dart';
import '../widgets/app_sheets.dart';
import '../widgets/grouped_section.dart';

import 'login_screen.dart';
import 'home_screen.dart';
import 'change_password_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final DataService _dataService = getIt<DataService>();
  final AuthService _authService = AuthService();
  final ImagePicker _picker = ImagePicker();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isUploadingPhoto = false;
  UserProfile? _profile;
  String? _error;

  List<Account> _accounts = const [];
  int? _activeAccountId;

  final _firstNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _pickupController = TextEditingController();

  // Notification preferences
  bool _notifyFeed = true;
  bool _notifyTraffic = true;
  bool _notifyBookings = true;
  bool _notifyDogUpdates = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _phoneController.dispose();
    _pickupController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await _dataService.getProfile();
      // Make sure the active session is recorded in the device's account
      // list (idempotent — refreshes name/avatar each time profile loads).
      if (profile.userId != null) {
        await _authService.upsertActiveAccount(
          userId: profile.userId!,
          username: profile.username,
          email: profile.email,
          displayName: profile.firstName,
          profilePhotoUrl: profile.profilePhotoUrl,
        );
      }
      final accounts = await _authService.getAccounts();
      final activeId = await _authService.getActiveAccountId();
      setState(() {
        _profile = profile;
        _firstNameController.text = profile.firstName ?? '';
        _phoneController.text = profile.phoneNumber ?? '';
        _pickupController.text = profile.pickupInstructions ?? '';
        _notifyFeed = profile.notifyFeed;
        _notifyTraffic = profile.notifyTraffic;
        _notifyBookings = profile.notifyBookings;
        _notifyDogUpdates = profile.notifyDogUpdates;
        _accounts = accounts;
        _activeAccountId = activeId;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _switchAccount(Account account) async {
    if (account.userId == _activeAccountId) return;
    final next = await _authService.switchAccount(account.userId);
    if (next == null || !mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  Future<void> _addAccount() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginScreen(addingAccount: true)),
    );
  }

  Future<void> _saveProfile() async {
    if (_profile == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final updatedProfile = UserProfile(
        username: _profile!.username,
        email: _profile!.email,
        firstName: _firstNameController.text,
        // The dog profile now owns the pickup address; round-trip the stored
        // profile value so saving here never wipes what older app builds use.
        address: _profile!.address,
        phoneNumber: _phoneController.text,
        pickupInstructions: _pickupController.text,
        notifyFeed: _notifyFeed,
        notifyTraffic: _notifyTraffic,
        notifyBookings: _notifyBookings,
        notifyDogUpdates: _notifyDogUpdates,
      );

      await _dataService.updateProfile(updatedProfile);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (image != null) {
        final bytes = await image.readAsBytes();
        await _uploadProfilePhoto(bytes, image.name);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick image: $e')),
        );
      }
    }
  }

  Future<void> _uploadProfilePhoto(Uint8List imageBytes, String imageName) async {
    setState(() {
      _isUploadingPhoto = true;
    });

    try {
      final updatedProfile = await _dataService.uploadProfilePhoto(imageBytes, imageName);
      setState(() {
        _profile = updatedProfile;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile photo updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photo: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
        });
      }
    }
  }

  Future<void> _deleteProfilePhoto() async {
    setState(() {
      _isUploadingPhoto = true;
    });

    try {
      final updatedProfile = await _dataService.deleteProfilePhoto();
      setState(() {
        _profile = updatedProfile;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile photo removed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove photo: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
        });
      }
    }
  }

  Future<void> _showPhotoOptions() async {
    final choice = await showAppActionSheet<String>(
      context,
      title: 'Profile Photo',
      actions: [
        const AppSheetAction(label: 'Take Photo', value: 'camera'),
        const AppSheetAction(label: 'Choose from Gallery', value: 'gallery'),
        if (_profile?.profilePhotoUrl != null)
          const AppSheetAction(
              label: 'Remove Photo', value: 'remove', isDestructive: true),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'camera':
        _pickImage(ImageSource.camera);
      case 'gallery':
        _pickImage(ImageSource.gallery);
      case 'remove':
        _deleteProfilePhoto();
    }
  }

  Future<void> _logout() async {
    final next = await _authService.logout();
    if (!mounted) return;
    if (next != null) {
      // Another account is now active — stay in the app.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Future<void> _showDeleteAccountDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Picon(PiconsDuotone.warning, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Expanded(child: Text('Delete Account')),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This action is permanent and cannot be undone.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Text('Deleting your account will:'),
            SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('  \u2022  '),
                Expanded(child: Text('Remove all your personal information')),
              ],
            ),
            SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('  \u2022  '),
                Expanded(child: Text('Delete your booking and request history')),
              ],
            ),
            SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('  \u2022  '),
                Expanded(child: Text('Remove your feed posts and comments')),
              ],
            ),
            SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('  \u2022  '),
                Expanded(child: Text('Log you out of the app permanently')),
              ],
            ),
            SizedBox(height: 16),
            Text(
              'Your dogs will NOT be deleted and can still be managed by staff.',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Second step: ask for password confirmation
    final passwordController = TextEditingController();
    bool isDeleting = false;
    bool obscurePassword = true;

    final passwordConfirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Confirm with Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your password to permanently delete your account.'),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                enabled: !isDeleting,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Picon(PiconsDuotone.lock),
                  suffixIcon: IconButton(
                    icon: Picon(
                      obscurePassword ? PiconsDuotone.eye : PiconsDuotone.eyeSlash,
                    ),
                    onPressed: () => setDialogState(() => obscurePassword = !obscurePassword),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isDeleting ? null : () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: isDeleting
                  ? null
                  : () async {
                      if (passwordController.text.isEmpty) return;
                      setDialogState(() => isDeleting = true);
                      final error = await _authService.deleteAccount(passwordController.text);
                      if (error != null) {
                        setDialogState(() => isDeleting = false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(error)),
                          );
                        }
                      } else {
                        if (context.mounted) Navigator.pop(context, true);
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: isDeleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Text('Delete My Account'),
            ),
          ],
        ),
      ),
    );

    passwordController.dispose();

    if (passwordConfirmed == true && mounted) {
      // After deletion, AuthService.deleteAccount() has already signed out
      // the active account. If another account remains, drop into it.
      final stillSignedIn = (await _authService.getToken()) != null;
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => stillSignedIn ? const HomeScreen() : const LoginScreen(),
        ),
        (route) => false,
      );
    }
  }

  Widget _buildThemeSelector() {
    final themeService = ThemeService();
    return SegmentedButton<ThemeMode>(
      segments: const [
        ButtonSegment(
          value: ThemeMode.light,
          icon: Picon(PiconsDuotone.sun),
          label: Text('Light'),
        ),
        ButtonSegment(
          value: ThemeMode.system,
          icon: Picon(PiconsDuotone.monitor),
          label: Text('System'),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          icon: Picon(PiconsDuotone.moon),
          label: Text('Dark'),
        ),
      ],
      selected: {themeService.themeMode},
      showSelectedIcon: false,
      onSelectionChanged: (selected) {
        themeService.setThemeMode(selected.first);
      },
    );
  }

  Widget _buildProfilePhoto() {
    final photoUrl = _profile?.profilePhotoUrl;

    return Center(
      child: GestureDetector(
        onTap: _isUploadingPhoto ? null : _showPhotoOptions,
        child: Stack(
          children: [
            CircleAvatar(
              radius: 56,
              backgroundColor: Colors.grey[300],
              backgroundImage: photoUrl != null
                  ? CachedNetworkImageProvider(photoUrl)
                  : null,
              child: photoUrl == null
                  ? Picon(PiconsDuotone.user, size: 56, color: Colors.grey[600])
                  : null,
            ),
            if (_isUploadingPhoto)
              Positioned.fill(
                child: CircleAvatar(
                  radius: 56,
                  backgroundColor: Colors.black38,
                  child: const CircularProgressIndicator(color: Colors.white),
                ),
              )
            else
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Picon(PiconsDuotone.camera, size: 18, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildAccountTiles() {
    if (_accounts.isEmpty) return const [];
    return _accounts.map((a) {
      final isActive = a.userId == _activeAccountId;
      final label = (a.displayName?.isNotEmpty ?? false) ? a.displayName! : a.username;
      return ListTile(
        leading: CircleAvatar(
          backgroundImage: (a.profilePhotoUrl != null && a.profilePhotoUrl!.isNotEmpty)
              ? CachedNetworkImageProvider(a.profilePhotoUrl!)
              : null,
          child: (a.profilePhotoUrl == null || a.profilePhotoUrl!.isEmpty)
              ? Text(label.isNotEmpty ? label[0].toUpperCase() : '?')
              : null,
        ),
        title: Text(label),
        subtitle: Text(a.email),
        trailing: isActive
            ? Picon(PiconsDuotone.checkCircle,
                color: Theme.of(context).primaryColor)
            : null,
        onTap: isActive ? null : () => _switchAccount(a),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          TextButton(
            onPressed: (_isLoading || _isSaving) ? null : _saveProfile,
            child: Text(_isSaving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    _buildProfilePhoto(),
                    const SizedBox(height: 12),
                    Center(
                      child: Text(
                        _profile!.username,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Center(
                      child: Text(
                        _profile!.email,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    GroupedSection(
                      header: 'Details',
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              TextField(
                                controller: _firstNameController,
                                decoration: const InputDecoration(
                                  labelText: 'First Name',
                                  prefixIcon: Picon(PiconsDuotone.identificationCard),
                                ),
                                textCapitalization: TextCapitalization.words,
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _phoneController,
                                decoration: const InputDecoration(
                                  labelText: 'Phone Number',
                                  prefixIcon: Picon(PiconsDuotone.phone),
                                ),
                                keyboardType: TextInputType.phone,
                              ),
                              if (!_profile!.isStaff) ...[
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _pickupController,
                                  decoration: const InputDecoration(
                                    labelText: 'Pickup Instructions',
                                    hintText: 'e.g., Key under the mat, Gate code 1234...',
                                    prefixIcon: Picon(PiconsDuotone.info),
                                  ),
                                  maxLines: 4,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    GroupedSection(
                      header: 'Accounts',
                      children: [
                        ..._buildAccountTiles(),
                        ListTile(
                          leading: const Picon(PiconsDuotone.userPlus),
                          title: const Text('Add another account'),
                          onTap: _addAccount,
                        ),
                      ],
                    ),
                    GroupedSection(
                      header: 'Notifications',
                      children: [
                        SwitchListTile.adaptive(
                          title: const Text('Feed Activity'),
                          subtitle: const Text('New posts and comments'),
                          secondary: Picon(PiconsDuotone.rss),
                          value: _notifyFeed,
                          onChanged: (val) => setState(() => _notifyFeed = val),
                        ),
                        if (!_profile!.isStaff) ...[
                          SwitchListTile.adaptive(
                            title: const Text('Traffic Alerts'),
                            subtitle: const Text('Pickup and drop-off delay alerts'),
                            secondary: Picon(PiconsDuotone.path),
                            value: _notifyTraffic,
                            onChanged: (val) => setState(() => _notifyTraffic = val),
                          ),
                          SwitchListTile.adaptive(
                            title: const Text('Booking Updates'),
                            subtitle: const Text('Date changes and boarding requests'),
                            secondary: Picon(PiconsDuotone.calendar),
                            value: _notifyBookings,
                            onChanged: (val) => setState(() => _notifyBookings = val),
                          ),
                          SwitchListTile.adaptive(
                            title: const Text('Dog Updates'),
                            subtitle: const Text('Picked up, at daycare, dropped off'),
                            secondary: Picon(PiconsDuotone.pawPrint),
                            value: _notifyDogUpdates,
                            onChanged: (val) => setState(() => _notifyDogUpdates = val),
                          ),
                        ],
                      ],
                    ),
                    GroupedSection(
                      header: 'Appearance',
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(child: _buildThemeSelector()),
                        ),
                      ],
                    ),
                    GroupedSection(
                      children: [
                        ListTile(
                          leading: Picon(PiconsDuotone.lock),
                          title: const Text('Change Password'),
                          trailing: Picon(
                            PiconsDuotone.caretRight,
                            size: 16,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
                            );
                          },
                        ),
                        ListTile(
                          title: const Text(
                            'Log Out',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.error),
                          ),
                          onTap: _logout,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton(
                        onPressed: _showDeleteAccountDialog,
                        style: TextButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        child: const Text('Delete Account'),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
    );
  }
}
