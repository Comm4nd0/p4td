import 'package:flutter/material.dart';
import '../models/user_profile.dart';
import '../services/data_service.dart';
import '../services/auth_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final DataService _dataService = ApiDataService();
  bool _isLoading = true;
  bool _isSaving = false;
  UserProfile? _profile;
  String? _error;

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
        _addressController.text = profile.address ?? '';
        _phoneController.text = profile.phoneNumber ?? '';
        _pickupController.text = profile.pickupInstructions ?? '';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
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
        address: _addressController.text,
        phoneNumber: _phoneController.text,
        pickupInstructions: _pickupController.text,
      );

      await _dataService.updateProfile(updatedProfile);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully')),
        );
        Navigator.pop(context);
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
                    ListTile(
                      leading: const Icon(Icons.person),
                      title: Text(_profile!.username),
                      subtitle: Text(_profile!.email),
                    ),
                    const Divider(),
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
                  ],
                ),
    );
  }
}
