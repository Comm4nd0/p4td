import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/dog_profile_change_request.dart';
import '../services/data_service.dart';
import '../constants/app_colors.dart';

/// Staff screen for reviewing pending dog profile change requests.
class DogProfileChangesScreen extends StatefulWidget {
  const DogProfileChangesScreen({super.key});

  @override
  State<DogProfileChangesScreen> createState() => _DogProfileChangesScreenState();
}

class _DogProfileChangesScreenState extends State<DogProfileChangesScreen> {
  final DataService _dataService = ApiDataService();
  List<DogProfileChangeRequest> _requests = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    setState(() { _loading = true; _error = null; });
    try {
      final requests = await _dataService.getDogProfileChangeRequests(status: 'PENDING');
      if (mounted) setState(() { _requests = requests; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _approve(DogProfileChangeRequest cr) async {
    try {
      await _dataService.approveDogProfileChange(cr.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Changes to ${cr.dogName} approved'),
            backgroundColor: Colors.green[700],
          ),
        );
        _loadRequests();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to approve: $e')),
        );
      }
    }
  }

  Future<void> _reject(DogProfileChangeRequest cr) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Changes?'),
        content: Text('Reject the proposed changes to ${cr.dogName}\'s profile?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _dataService.rejectDogProfileChange(cr.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Changes to ${cr.dogName} rejected'),
            backgroundColor: Colors.orange[700],
          ),
        );
        _loadRequests();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reject: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile Change Requests'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Picon(PiconsDuotone.warningCircle, size: 48, color: Colors.red),
                      const SizedBox(height: 8),
                      Text(_error!, style: TextStyle(color: Colors.grey[600])),
                      const SizedBox(height: 16),
                      OutlinedButton(onPressed: _loadRequests, child: const Text('Retry')),
                    ],
                  ),
                )
              : _requests.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Picon(PiconsDuotone.checkCircle, size: 56, color: Colors.green),
                          const SizedBox(height: 12),
                          Text('No pending changes', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadRequests,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _requests.length,
                        itemBuilder: (context, index) => _buildRequestCard(_requests[index]),
                      ),
                    ),
    );
  }

  Widget _buildRequestCard(DogProfileChangeRequest cr) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: dog avatar + name + requester
            Row(
              children: [
                _buildDogAvatar(cr),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(cr.dogName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                        'Requested by ${cr.requestedByName}',
                        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                      ),
                      Text(
                        _formatTimeAgo(cr.createdAt),
                        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Proposed changes
            ..._buildChangesList(cr),
            const SizedBox(height: 16),
            // Action buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _reject(cr),
                    icon: Picon(PiconsDuotone.x, size: 18),
                    label: const Text('Reject'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _approve(cr),
                    icon: Picon(PiconsDuotone.check, size: 18),
                    label: const Text('Approve'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDogAvatar(DogProfileChangeRequest cr) {
    final hasNewImage = cr.proposedImage != null;
    final hasCurrentImage = cr.dogProfileImage != null;

    if (hasNewImage) {
      // Show the proposed new image with a badge
      return Stack(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundImage: NetworkImage(cr.proposedImage!),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.orange,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.edit, size: 12, color: Colors.white),
            ),
          ),
        ],
      );
    }

    if (cr.deleteImage) {
      return CircleAvatar(
        radius: 28,
        backgroundColor: Colors.red[50],
        child: Picon(PiconsDuotone.trash, color: Colors.red, size: 24),
      );
    }

    if (hasCurrentImage) {
      return CircleAvatar(
        radius: 28,
        backgroundImage: NetworkImage(cr.dogProfileImage!),
      );
    }

    return CircleAvatar(
      radius: 28,
      backgroundColor: AppColors.primaryLight.withOpacity(0.2),
      child: Picon(PiconsDuotone.dog, size: 24, color: AppColors.primary),
    );
  }

  List<Widget> _buildChangesList(DogProfileChangeRequest cr) {
    final widgets = <Widget>[];
    final fieldLabels = {
      'name': 'Name',
      'food_instructions': 'Food Instructions',
      'medical_notes': 'Medical / Injuries',
      'daycare_days': 'Daycare Days',
      'schedule_type': 'Schedule Type',
    };

    for (final entry in cr.proposedChanges.entries) {
      final label = fieldLabels[entry.key] ?? entry.key;
      String value;

      if (entry.key == 'daycare_days' && entry.value is List) {
        final dayMap = {1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri'};
        final days = (entry.value as List).map((d) => dayMap[d] ?? '?').toList();
        value = days.isEmpty ? 'None' : days.join(', ');
      } else if (entry.key == 'schedule_type') {
        final typeMap = {'weekly': 'Weekly', 'fortnightly': 'Fortnightly', 'ad_hoc': 'Ad Hoc'};
        value = typeMap[entry.value] ?? entry.value.toString();
      } else {
        value = entry.value?.toString() ?? '(empty)';
        if (value.trim().isEmpty) value = '(empty)';
      }

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 120,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
              ),
              Picon(PiconsDuotone.arrowRight, size: 16, color: Colors.orange),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (cr.proposedImage != null) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(
                width: 120,
                child: Text(
                  'Profile Photo',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
              ),
              Picon(PiconsDuotone.arrowRight, size: 16, color: Colors.orange),
              const SizedBox(width: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: cr.proposedImage!,
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (cr.deleteImage) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(
                width: 120,
                child: Text(
                  'Profile Photo',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
              ),
              Picon(PiconsDuotone.arrowRight, size: 16, color: Colors.red),
              const SizedBox(width: 6),
              Text('Remove', style: TextStyle(color: Colors.red[700], fontSize: 13)),
            ],
          ),
        ),
      );
    }

    return widgets;
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
