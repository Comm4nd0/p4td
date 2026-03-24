import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants/app_colors.dart';
import '../services/data_service.dart';
import '../services/no_connection_exception.dart';
import '../widgets/no_connection_widget.dart';
import 'staff_notifications_screen.dart';
import 'query_list_screen.dart';
import 'inquiry_list_screen.dart';
import 'boarding_request_list_screen.dart';

class StaffDashboardScreen extends StatefulWidget {
  final bool canManageRequests;
  final bool canReplyQueries;
  final bool canViewInquiries;
  final VoidCallback? onNavigateToFeed;
  final void Function(int? staffId)? onNavigateToDogGroups;

  const StaffDashboardScreen({
    super.key,
    required this.canManageRequests,
    required this.canReplyQueries,
    required this.canViewInquiries,
    this.onNavigateToFeed,
    this.onNavigateToDogGroups,
  });

  @override
  State<StaffDashboardScreen> createState() => StaffDashboardScreenState();
}

class StaffDashboardScreenState extends State<StaffDashboardScreen> {
  final DataService _dataService = ApiDataService();
  Map<String, dynamic>? _stats;
  bool _loading = true;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    if (!mounted) return;
    setState(() {
      _loading = _stats == null;
      _isOffline = false;
    });
    try {
      final stats = await _dataService.getDashboardStats();
      if (mounted) {
        setState(() {
          _stats = stats;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final offline = NoConnectionException.isNetworkError(e);
        setState(() {
          _loading = false;
          _isOffline = offline;
        });
      }
    }
  }

  /// Called externally to refresh stats.
  void refresh() => _loadStats();

  @override
  Widget build(BuildContext context) {
    if (_isOffline) {
      return NoConnectionWidget(onRetry: _loadStats);
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final stats = _stats;
    if (stats == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Failed to load dashboard stats.'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _loadStats,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadStats,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Today's overview header
          Text(
            "Today's Overview",
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 16),

          // Dogs today + total dogs row
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.pets,
                  label: 'Dogs Today',
                  value: '${stats['dogs_today'] ?? 0}',
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  icon: Icons.list_alt,
                  label: 'Total Dogs',
                  value: '${stats['total_dogs'] ?? 0}',
                  color: AppColors.primaryLight,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Assignment stats row
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.assignment_ind,
                  label: 'My Dogs Today',
                  value: '${stats['my_dogs_today'] ?? 0}',
                  color: Colors.teal,
                  onTap: () => widget.onNavigateToDogGroups?.call(stats['my_staff_id'] as int?),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  icon: Icons.assignment_turned_in,
                  label: 'Total Assigned',
                  value: '${stats['total_assigned_today'] ?? 0}',
                  color: Colors.indigo,
                  onTap: () => widget.onNavigateToDogGroups?.call(null),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Media stats header
          Text(
            'Media Uploaded Today',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),

          // Media stats grid
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.photo_library,
                  label: 'Feed Photos',
                  value: '${stats['feed_photos_today'] ?? 0}',
                  color: Colors.teal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  icon: Icons.video_library,
                  label: 'Feed Videos',
                  value: '${stats['feed_videos_today'] ?? 0}',
                  color: Colors.indigo,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _StatCard(
            icon: Icons.perm_media,
            label: 'Total Media Today',
            value: '${stats['total_media_today'] ?? 0}',
            color: AppColors.primaryDark,
            fullWidth: true,
          ),

          const SizedBox(height: 24),

          // Staff working today
          Text(
            'Staff Working Today',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          if ((stats['staff_working_today'] as List?)?.isEmpty ?? true)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    'No staff assigned today',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ),
              ),
            )
          else
            ...((stats['staff_working_today'] as List).map<Widget>((staff) {
              return Card(
                elevation: 1,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.primaryLight,
                    child: Text(
                      (staff['name'] as String).isNotEmpty
                          ? (staff['name'] as String)[0].toUpperCase()
                          : '?',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Text(staff['name'] as String),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '${staff['dog_count']} ${(staff['dog_count'] as int) == 1 ? 'dog' : 'dogs'}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, color: Colors.grey[400]),
                    ],
                  ),
                  onTap: () => widget.onNavigateToDogGroups?.call(staff['id'] as int?),
                ),
              );
            })),

          const SizedBox(height: 24),

          // Boarding today
          Text(
            'Boarding Today',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          if ((stats['boarding_today'] as List?)?.isEmpty ?? true)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    'No boarding today',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ),
              ),
            )
          else
            ...((stats['boarding_today'] as List).map<Widget>((boarding) {
              final dogNames = (boarding['dog_names'] as List).join(', ');
              final ownerName = boarding['owner_name'] as String;
              final startDate = DateTime.parse(boarding['start_date'] as String);
              final endDate = DateTime.parse(boarding['end_date'] as String);
              final status = boarding['status'] as String;
              final specialInstructions = boarding['special_instructions'] as String? ?? '';
              final isApproved = status == 'APPROVED';

              return Card(
                elevation: 1,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isApproved
                        ? Colors.green.withValues(alpha: 0.15)
                        : Colors.orange.withValues(alpha: 0.15),
                    child: Icon(
                      Icons.night_shelter,
                      color: isApproved ? Colors.green : Colors.orange,
                    ),
                  ),
                  title: Text(dogNames, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Owner: $ownerName'),
                      Text(
                        '${DateFormat('MMM d').format(startDate)} - ${DateFormat('MMM d').format(endDate)}',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      if (specialInstructions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            specialInstructions,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isApproved
                              ? Colors.green.withValues(alpha: 0.15)
                              : Colors.orange.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          status,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: isApproved ? Colors.green : Colors.orange,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, color: Colors.grey[400]),
                    ],
                  ),
                  isThreeLine: true,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const BoardingRequestListScreen()),
                    );
                    _loadStats();
                  },
                ),
              );
            })),

          const SizedBox(height: 24),

          // Action items header
          Text(
            'Action Items',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),

          // Pending requests
          _ActionCard(
            icon: Icons.pending_actions,
            label: 'Pending Requests',
            count: stats['pending_requests'] ?? 0,
            color: (stats['pending_requests'] ?? 0) > 0 ? AppColors.warning : null,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StaffNotificationsScreen(
                    canManageRequests: widget.canManageRequests,
                  ),
                ),
              );
              _loadStats();
            },
          ),
          const SizedBox(height: 8),

          // Unresolved queries
          _ActionCard(
            icon: Icons.question_answer,
            label: 'Unresolved Queries',
            count: stats['unresolved_queries'] ?? 0,
            color: (stats['unresolved_queries'] ?? 0) > 0 ? AppColors.info : null,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => QueryListScreen(
                    isStaff: true,
                    canReplyQueries: widget.canReplyQueries,
                  ),
                ),
              );
              _loadStats();
            },
          ),
          const SizedBox(height: 8),

          if (widget.canViewInquiries) ...[
            _ActionCard(
              icon: Icons.mail_outline,
              label: 'Unread Inquiries',
              count: stats['unread_inquiries'] ?? 0,
              color: (stats['unread_inquiries'] ?? 0) > 0 ? AppColors.error : null,
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const InquiryListScreen()),
                );
                _loadStats();
              },
            ),
            const SizedBox(height: 8),
          ],

          // Boarding requests shortcut
          _ActionCard(
            icon: Icons.night_shelter,
            label: 'Boarding Requests',
            count: stats['pending_boarding_requests'] ?? 0,
            color: (stats['pending_boarding_requests'] ?? 0) > 0 ? AppColors.warning : null,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BoardingRequestListScreen()),
              );
              _loadStats();
            },
          ),

          const SizedBox(height: 24),

          // Quick actions
          Text(
            'Quick Actions',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.upload, size: 18),
                label: const Text('Upload to Feed'),
                onPressed: widget.onNavigateToFeed,
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// A card showing a single stat value.
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool fullWidth;
  final VoidCallback? onTap;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.fullWidth = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Row(
            mainAxisAlignment: fullWidth ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A card showing an action item with count and tap handler.
class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final Color? color;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.label,
    required this.count,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardColor = color ?? theme.colorScheme.outline;

    return Card(
      elevation: 1,
      child: ListTile(
        leading: Icon(icon, color: cardColor, size: 28),
        title: Text(label),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: count > 0 ? cardColor.withValues(alpha: 0.15) : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: count > 0 ? cardColor : theme.colorScheme.onSurface,
            ),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
