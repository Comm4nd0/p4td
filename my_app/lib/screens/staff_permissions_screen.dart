import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../models/staff_permission.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';

class StaffPermissionsScreen extends StatefulWidget {
  const StaffPermissionsScreen({super.key});

  @override
  State<StaffPermissionsScreen> createState() => _StaffPermissionsScreenState();
}

class _StaffPermissionsScreenState extends State<StaffPermissionsScreen> {
  final DataService _dataService = getIt<DataService>();
  List<StaffPermission> _staff = [];
  bool _loading = true;
  final Set<int> _saving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final staff = await _dataService.listStaffPermissions();
      if (mounted) {
        setState(() {
          _staff = staff;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load staff: $e')),
        );
      }
    }
  }

  Future<void> _togglePermission(
    StaffPermission staff,
    String field,
    bool newValue,
    void Function(bool) setLocal,
  ) async {
    setState(() {
      _saving.add(staff.userId);
      setLocal(newValue);
    });
    try {
      final updated = await _dataService.updateStaffPermissions(
        staff.userId,
        {field: newValue},
      );
      if (mounted) {
        setState(() {
          final idx = _staff.indexWhere((s) => s.userId == updated.userId);
          if (idx >= 0) _staff[idx] = updated;
          _saving.remove(staff.userId);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          setLocal(!newValue);
          _saving.remove(staff.userId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Staff Permissions')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator.adaptive(
              onRefresh: _load,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(8),
                itemCount: _staff.length,
                itemBuilder: (context, index) => _StaffPermissionCard(
                  staff: _staff[index],
                  isSaving: _saving.contains(_staff[index].userId),
                  onToggle: _togglePermission,
                ),
              ),
            ),
    );
  }
}

class _StaffPermissionCard extends StatefulWidget {
  final StaffPermission staff;
  final bool isSaving;
  final Future<void> Function(
    StaffPermission staff,
    String field,
    bool newValue,
    void Function(bool) setLocal,
  ) onToggle;

  const _StaffPermissionCard({
    required this.staff,
    required this.isSaving,
    required this.onToggle,
  });

  @override
  State<_StaffPermissionCard> createState() => _StaffPermissionCardState();
}

class _StaffPermissionCardState extends State<_StaffPermissionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.staff;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: s.isSuperuser
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.secondary,
              child: Picon(
                s.isSuperuser
                    ? PiconsDuotone.crown
                    : PiconsDuotone.user,
                color: Colors.white,
                size: 20,
              ),
            ),
            title: Text(
              s.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              s.isSuperuser ? 'Superuser • ${s.email}' : s.email,
              style: const TextStyle(fontSize: 12),
            ),
            trailing: widget.isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Picon(
                    _expanded
                        ? PiconsDuotone.caretUp
                        : PiconsDuotone.caretDown,
                    size: 18,
                  ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            if (s.isSuperuser)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Picon(
                      PiconsDuotone.info,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Superusers have all permissions automatically.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            _buildSwitch(
              label: 'Manage Requests',
              subtitle: 'Approve/deny date change & boarding requests',
              icon: PiconsDuotone.checkSquare,
              value: s.canManageRequests,
              field: 'can_manage_requests',
              setLocal: (v) => s.canManageRequests = v,
            ),
            _buildSwitch(
              label: 'Assign Dogs',
              subtitle: 'Assign dogs to staff members',
              icon: PiconsDuotone.pawPrint,
              value: s.canAssignDogs,
              field: 'can_assign_dogs',
              setLocal: (v) => s.canAssignDogs = v,
            ),
            _buildSwitch(
              label: 'Upload to Feed',
              subtitle: 'Add photos & videos to the feed',
              icon: PiconsDuotone.uploadSimple,
              value: s.canAddFeedMedia,
              field: 'can_add_feed_media',
              setLocal: (v) => s.canAddFeedMedia = v,
            ),
            _buildSwitch(
              label: 'Reply to Queries',
              subtitle: 'Respond to support queries',
              icon: PiconsDuotone.chatCircleText,
              value: s.canReplyQueries,
              field: 'can_reply_queries',
              setLocal: (v) => s.canReplyQueries = v,
            ),
            _buildSwitch(
              label: 'Approve Time Off',
              subtitle: 'Approve/deny staff day-off requests',
              icon: PiconsDuotone.calendarCheck,
              value: s.canApproveTimeoff,
              field: 'can_approve_timeoff',
              setLocal: (v) => s.canApproveTimeoff = v,
            ),
            _buildSwitch(
              label: 'View Inquiries',
              subtitle: 'View & respond to website contact inquiries',
              icon: PiconsDuotone.envelope,
              value: s.canViewInquiries,
              field: 'can_view_inquiries',
              setLocal: (v) => s.canViewInquiries = v,
            ),
            _buildSwitch(
              label: 'Manage Vehicles',
              subtitle: 'Add/edit fleet vehicles, MOT/service dates & defect statuses',
              icon: PiconsDuotone.van,
              value: s.canManageVehicles,
              field: 'can_manage_vehicles',
              setLocal: (v) => s.canManageVehicles = v,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildSwitch({
    required String label,
    required String subtitle,
    required PiconDuotoneData icon,
    required bool value,
    required String field,
    required void Function(bool) setLocal,
  }) {
    return SwitchListTile.adaptive(
      title: Text(label),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      secondary: Picon(icon, size: 22),
      value: value,
      onChanged: widget.isSaving
          ? null
          : (newValue) => widget.onToggle(
                widget.staff,
                field,
                newValue,
                (v) => setState(() => setLocal(v)),
              ),
      dense: true,
    );
  }
}
