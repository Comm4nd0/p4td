import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/user_profile.dart';
import '../services/data_service.dart';
import '../services/auth_service.dart';

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
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            if (_profile?.profilePhotoUrl != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
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
                  ? Icon(Icons.person, size: 56, color: Colors.grey[600])
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
                  child: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
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
            icon: const Icon(Icons.save),
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
                        prefixIcon: Icon(Icons.badge),
                      ),
                      textCapitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _phoneController,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.phone),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _addressController,
                      decoration: const InputDecoration(
                        labelText: 'Address',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.home),
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
                        prefixIcon: Icon(Icons.info),
                      ),
                      maxLines: 4,
                    ),
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
                        icon: const Icon(Icons.lock_outline),
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
                        icon: const Icon(Icons.logout, color: Colors.white),
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
                  ],
                ),
    );
  }
}
