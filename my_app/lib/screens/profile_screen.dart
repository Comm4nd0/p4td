import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/user_profile.dart';
import '../services/data_service.dart';
import '../services/auth_service.dart';
import '../services/theme_service.dart';

import 'login_screen.dart';
import 'change_password_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final DataService _dataService = ApiDataService();
  final AuthService _authService = AuthService();
  final ImagePicker _picker = ImagePicker();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isUploadingPhoto = false;
  UserProfile? _profile;
  String? _error;

  final _firstNameController = TextEditingController();
  final _addressController = TextEditingController();
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

  Future<void> _loadProfile() async {
    try {
      final profile = await _dataService.getProfile();
      setState(() {
        _profile = profile;
        _firstNameController.text = profile.firstName ?? '';
        _addressController.text = profile.address ?? '';
        _phoneController.text = profile.phoneNumber ?? '';
        _pickupController.text = profile.pickupInstructions ?? '';
        _notifyFeed = profile.notifyFeed;
        _notifyTraffic = profile.notifyTraffic;
        _notifyBookings = profile.notifyBookings;
        _notifyDogUpdates = profile.notifyDogUpdates;
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
        address: _addressController.text,
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

  void _showPhotoOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: PhosphorIcon(PhosphorIconsDuotone.camera),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: PhosphorIcon(PhosphorIconsDuotone.images),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            if (_profile?.profilePhotoUrl != null)
              ListTile(
                leading: PhosphorIcon(PhosphorIconsDuotone.trash, color: Colors.red),
                title: const Text('Remove Photo', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteProfilePhoto();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    await _authService.logout();
    if (mounted) {
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
            PhosphorIcon(PhosphorIconsDuotone.warning, color: Colors.red, size: 28),
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
                obscureText: true,
                enabled: !isDeleting,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  prefixIcon: PhosphorIcon(PhosphorIconsDuotone.lock),
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
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
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
          icon: PhosphorIcon(PhosphorIconsDuotone.sun),
          label: Text('Light'),
        ),
        ButtonSegment(
          value: ThemeMode.system,
          icon: PhosphorIcon(PhosphorIconsDuotone.monitor),
          label: Text('System'),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          icon: PhosphorIcon(PhosphorIconsDuotone.moon),
          label: Text('Dark'),
        ),
      ],
      selected: {themeService.themeMode},
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
                  ? PhosphorIcon(PhosphorIconsDuotone.user, size: 56, color: Colors.grey[600])
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
                  child: const PhosphorIcon(PhosphorIconsDuotone.camera, size: 18, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          IconButton(
            icon: PhosphorIcon(PhosphorIconsDuotone.floppyDisk),
            onPressed: (_isLoading || _isSaving) ? null : _saveProfile,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildProfilePhoto(),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        _profile!.username,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Center(
                      child: Text(
                        _profile!.email,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const Divider(height: 32),
                    TextField(
                      controller: _firstNameController,
                      decoration: const InputDecoration(
                        labelText: 'First Name',
                        border: OutlineInputBorder(),
                        prefixIcon: PhosphorIcon(PhosphorIconsDuotone.identificationCard),
                      ),
                      textCapitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _phoneController,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number',
                        border: OutlineInputBorder(),
                        prefixIcon: PhosphorIcon(PhosphorIconsDuotone.phone),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    if (!_profile!.isStaff) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _addressController,
                        decoration: const InputDecoration(
                          labelText: 'Address',
                          border: OutlineInputBorder(),
                          prefixIcon: PhosphorIcon(PhosphorIconsDuotone.house),
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _pickupController,
                        decoration: const InputDecoration(
                          labelText: 'Pickup Instructions',
                          hintText: 'e.g., Key under the mat, Gate code 1234...',
                          border: OutlineInputBorder(),
                          prefixIcon: PhosphorIcon(PhosphorIconsDuotone.info),
                        ),
                        maxLines: 4,
                      ),
                    ],
                    const Divider(height: 32),
                    Text(
                      'Notifications',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: const Text('Feed Activity'),
                      subtitle: const Text('New posts and comments'),
                      secondary: PhosphorIcon(PhosphorIconsDuotone.rss),
                      value: _notifyFeed,
                      onChanged: (val) => setState(() => _notifyFeed = val),
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (!_profile!.isStaff) ...[
                      SwitchListTile(
                        title: const Text('Traffic Alerts'),
                        subtitle: const Text('Pickup and drop-off delay alerts'),
                        secondary: PhosphorIcon(PhosphorIconsDuotone.path),
                        value: _notifyTraffic,
                        onChanged: (val) => setState(() => _notifyTraffic = val),
                        contentPadding: EdgeInsets.zero,
                      ),
                      SwitchListTile(
                        title: const Text('Booking Updates'),
                        subtitle: const Text('Date changes and boarding requests'),
                        secondary: PhosphorIcon(PhosphorIconsDuotone.calendar),
                        value: _notifyBookings,
                        onChanged: (val) => setState(() => _notifyBookings = val),
                        contentPadding: EdgeInsets.zero,
                      ),
                      SwitchListTile(
                        title: const Text('Dog Updates'),
                        subtitle: const Text('Picked up, at daycare, dropped off'),
                        secondary: PhosphorIcon(PhosphorIconsDuotone.pawPrint),
                        value: _notifyDogUpdates,
                        onChanged: (val) => setState(() => _notifyDogUpdates = val),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                    const Divider(height: 32),
                    Text(
                      'Appearance',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    _buildThemeSelector(),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
                          );
                        },
                        icon: PhosphorIcon(PhosphorIconsDuotone.lock),
                        label: const Text('Change Password'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _logout,
                        icon: PhosphorIcon(PhosphorIconsDuotone.signOut, color: Colors.white),
                        label: const Text('Log Out', style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Divider(),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton(
                        onPressed: _showDeleteAccountDialog,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.grey,
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
