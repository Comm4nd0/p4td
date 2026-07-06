import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../models/staff_permission.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';

/// One entry in the permission catalogue: drives both the toggle rows on each
/// staff card and the "what does each permission allow?" guide sheet, so the
/// two can never drift apart.
class _PermDef {
  final String field;
  final String label;

  /// Short one-liner under the switch.
  final String subtitle;

  /// Full explanation shown in the permission guide.
  final String description;
  final PiconDuotoneData icon;
  final bool Function(StaffPermission) getValue;
  final void Function(StaffPermission, bool) setValue;

  const _PermDef({
    required this.field,
    required this.label,
    required this.subtitle,
    required this.description,
    required this.icon,
    required this.getValue,
    required this.setValue,
  });
}

final List<_PermDef> _permissionCatalogue = [
  _PermDef(
    field: 'can_manage_requests',
    label: 'Manage Requests',
    subtitle: 'Approve/deny date change & boarding requests',
    description:
        'Approve or deny owners\' schedule requests: cancellations, date '
        'moves and extra-day requests. Gets notified when new requests '
        'come in.',
    icon: PiconsDuotone.checkSquare,
    getValue: (s) => s.canManageRequests,
    setValue: (s, v) => s.canManageRequests = v,
  ),
  _PermDef(
    field: 'can_assign_dogs',
    label: 'Assign Dogs',
    subtitle: 'Assign dogs to staff members',
    description:
        'Manage the daily roster on the dashboard: assign dogs to staff '
        'members for pickups, move dogs between staff, and remove dogs '
        'from a day.',
    icon: PiconsDuotone.pawPrint,
    getValue: (s) => s.canAssignDogs,
    setValue: (s, v) => s.canAssignDogs = v,
  ),
  _PermDef(
    field: 'can_add_feed_media',
    label: 'Upload to Feed',
    subtitle: 'Add photos & videos to the feed',
    description:
        'Post photos and videos to the group activity feed that owners '
        'see, and tag the dogs in them.',
    icon: PiconsDuotone.uploadSimple,
    getValue: (s) => s.canAddFeedMedia,
    setValue: (s, v) => s.canAddFeedMedia = v,
  ),
  _PermDef(
    field: 'can_reply_queries',
    label: 'Reply to Queries',
    subtitle: 'Respond to support queries',
    description:
        'View owners\' support queries, reply to them, and mark them '
        'resolved. Can also start a new conversation with an owner from '
        'a dog\'s profile.',
    icon: PiconsDuotone.chatCircleText,
    getValue: (s) => s.canReplyQueries,
    setValue: (s, v) => s.canReplyQueries = v,
  ),
  _PermDef(
    field: 'can_manage_staff',
    label: 'Manage Staff',
    subtitle: 'Set staff working days, approve/deny day-off requests',
    description:
        'Set which days each staff member works and approve or deny '
        'staff day-off requests.',
    icon: PiconsDuotone.calendarCheck,
    getValue: (s) => s.canManageStaff,
    setValue: (s, v) => s.canManageStaff = v,
  ),
  _PermDef(
    field: 'can_view_inquiries',
    label: 'View Inquiries',
    subtitle: 'View & respond to website contact inquiries',
    description:
        'See contact inquiries submitted through the public website, '
        'mark them read/replied, and delete them.',
    icon: PiconsDuotone.envelope,
    getValue: (s) => s.canViewInquiries,
    setValue: (s, v) => s.canViewInquiries = v,
  ),
  _PermDef(
    field: 'can_manage_vehicles',
    label: 'Manage Vehicles',
    subtitle: 'Add/edit fleet vehicles, MOT/service dates & defect statuses',
    description:
        'Add and edit fleet vehicles, keep MOT and service dates up to '
        'date, and update the status of reported vehicle defects. Gets '
        'the MOT/service due reminders.',
    icon: PiconsDuotone.van,
    getValue: (s) => s.canManageVehicles,
    setValue: (s, v) => s.canManageVehicles = v,
  ),
  _PermDef(
    field: 'can_manage_payments',
    label: 'Manage Payments',
    subtitle: 'Invoices, payments, rates & past-day attendance edits',
    description:
        'Generate, review and send monthly invoices, record payments, '
        'set customer rates and billing settings, and reconcile with '
        'Xero. Can also edit past days on a dog\'s schedule calendar to '
        'correct the attendance history that invoices are billed from.',
    icon: PiconsDuotone.currencyGbp,
    getValue: (s) => s.canManagePayments,
    setValue: (s, v) => s.canManagePayments = v,
  ),
  _PermDef(
    field: 'can_manage_boarding',
    label: 'Manage Boarding',
    subtitle: 'Approve/deny and edit boarding requests',
    description:
        'Approve, deny and edit overnight boarding requests, and manage '
        'boarding stays.',
    icon: PiconsDuotone.bed,
    getValue: (s) => s.canManageBoarding,
    setValue: (s, v) => s.canManageBoarding = v,
  ),
];

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

  void _showPermissionGuide() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text(
              'Permission Guide',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'What each permission allows a staff member to do. '
              'Superusers have all permissions automatically.',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            for (final perm in _permissionCatalogue) ...[
              const Divider(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Picon(perm.icon, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          perm.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          perm.description,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[700],
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Permissions'),
        actions: [
          IconButton(
            icon: const Picon(PiconsDuotone.info),
            tooltip: 'Permission guide',
            onPressed: _showPermissionGuide,
          ),
        ],
      ),
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
            for (final perm in _permissionCatalogue)
              _buildSwitch(perm),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildSwitch(_PermDef perm) {
    return SwitchListTile.adaptive(
      title: Text(perm.label),
      subtitle: Text(perm.subtitle, style: const TextStyle(fontSize: 12)),
      secondary: Picon(perm.icon, size: 22),
      value: perm.getValue(widget.staff),
      onChanged: widget.isSaving
          ? null
          : (newValue) => widget.onToggle(
                widget.staff,
                perm.field,
                newValue,
                (v) => setState(() => perm.setValue(widget.staff, v)),
              ),
      dense: true,
    );
  }
}
