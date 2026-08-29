import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/staff_hr.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import 'staff_member_detail_screen.dart';
import '../widgets/page_body.dart';

/// Manager-only hub for running the team: one card per staff member with
/// their role, holiday position and anything needing attention (pending
/// day-off requests, sickness, expiring training, an appraisal falling due).
/// Tap through for pay, meetings, appraisals and records.
class StaffManagementScreen extends StatefulWidget {
  const StaffManagementScreen({super.key});

  @override
  State<StaffManagementScreen> createState() => _StaffManagementScreenState();
}

class _StaffManagementScreenState extends State<StaffManagementScreen> {
  final DataService _dataService = getIt<DataService>();

  List<TeamMemberOverview> _team = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final team = await _dataService.getStaffTeamOverview();
      if (!mounted) return;
      setState(() {
        // Leavers (employment ended) sink to the bottom rather than vanish.
        _team = [
          ...team.where((m) => m.employmentEndDate == null),
          ...team.where((m) => m.employmentEndDate != null),
        ];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Staff Management')),
      body: PageBody(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : RefreshIndicator.adaptive(
                  onRefresh: _load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: _team.length,
                    itemBuilder: (context, index) =>
                        _buildMemberCard(_team[index]),
                  ),
                )),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                setState(() => _loading = true);
                _load();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemberCard(TeamMemberOverview member) {
    final left = member.employmentEndDate != null;
    final holiday = member.holiday;
    final chips = <Widget>[
      if (left)
        _chip('Left ${_formatDate(member.employmentEndDate!)}',
            AppColors.grey500, PiconsDuotone.signOut)
      else ...[
        if (holiday?.remainingDays != null)
          _chip(
            '${_trimZero(holiday!.remainingDays!)} of ${_trimZero(holiday.allowanceDays ?? 0)} days left',
            AppColors.info,
            PiconsDuotone.sunHorizon,
          ),
        if (member.pendingDayOffRequests > 0)
          _chip(
            '${member.pendingDayOffRequests} day-off request${member.pendingDayOffRequests == 1 ? '' : 's'}',
            AppColors.warning,
            PiconsDuotone.calendarX,
          ),
        if (member.offSickToday)
          _chip('Off sick', AppColors.error, PiconsDuotone.firstAidKit),
        if (member.trainingExpiring > 0)
          _chip(
            'Training expiring',
            AppColors.warning,
            PiconsDuotone.certificate,
          ),
        if (_appraisalDue(member))
          _chip('Appraisal due', AppColors.warning, PiconsDuotone.star),
      ],
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => StaffMemberDetailScreen(
                staffId: member.staffMemberId,
                staffName: member.name,
              ),
            ),
          );
          _load();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: AppColors.primary.withAlpha(30),
                    backgroundImage: member.profilePhoto != null
                        ? NetworkImage(member.profilePhoto!)
                        : null,
                    child: member.profilePhoto == null
                        ? Text(
                            member.name.isNotEmpty
                                ? member.name[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          member.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        if (member.jobTitle.isNotEmpty)
                          Text(
                            member.jobTitle,
                            style: TextStyle(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Picon(
                    PiconsDuotone.caretRight,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (chips.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: chips),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Due when the next review date has passed, or there has never been one.
  bool _appraisalDue(TeamMemberOverview member) {
    if (member.employmentEndDate != null) return false;
    if (member.nextReviewDate != null) {
      return !member.nextReviewDate!.isAfter(DateTime.now());
    }
    return member.lastAppraisalDate == null;
  }

  Widget _chip(String label, Color color, dynamic icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Picon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) => '${d.day}/${d.month}/${d.year}';

  String _trimZero(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
