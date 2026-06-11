import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/facility_defect.dart';
import '../services/data_service.dart';
import '../utils/date_formats.dart';
import 'facility_defect_detail_screen.dart';
import 'report_facility_defect_screen.dart';

class FacilityDefectsScreen extends StatefulWidget {
  const FacilityDefectsScreen({super.key});

  @override
  State<FacilityDefectsScreen> createState() => _FacilityDefectsScreenState();
}

class _FacilityDefectsScreenState extends State<FacilityDefectsScreen> {
  final DataService _dataService = ApiDataService();
  List<FacilityDefect> _defects = [];
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _loadDefects();
  }

  Future<void> _loadDefects() async {
    try {
      final defects = await _dataService.getFacilityDefects();
      if (mounted) {
        setState(() {
          _defects = defects;
          _loading = false;
          _loadFailed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _reportDefect() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ReportFacilityDefectScreen()),
    );
    if (created == true) _loadDefects();
  }

  @override
  Widget build(BuildContext context) {
    final open = _defects.where((d) => !d.isResolved).toList();
    final resolved = _defects.where((d) => d.isResolved).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Site Defects'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _reportDefect,
        icon: Picon(PiconsDuotone.warningCircle, color: Colors.white),
        label: const Text('Report Defect'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : RefreshIndicator.adaptive(
              onRefresh: _loadDefects,
              child: _loadFailed
                  ? ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Text(
                              'Failed to load defects. Pull down to retry.',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _defects.isEmpty
                      ? ListView(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Center(
                                child: Column(
                                  children: [
                                    Picon(PiconsDuotone.checkCircle,
                                        size: 48, color: AppColors.success),
                                    const SizedBox(height: 12),
                                    Text(
                                      'No defects reported',
                                      style: TextStyle(color: Colors.grey[600]),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                          children: [
                            ...open.map(_buildDefectTile),
                            ...resolved.map(_buildDefectTile),
                          ],
                        ),
            ),
    );
  }

  Widget _buildDefectTile(FacilityDefect defect) {
    final statusColor = defect.status == 'RESOLVED'
        ? AppColors.success
        : defect.status == 'IN_PROGRESS'
            ? AppColors.warning
            : AppColors.error;
    final hasLocation = defect.location != null && defect.location!.trim().isNotEmpty;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Picon(
          defect.isResolved ? PiconsDuotone.checkCircle : PiconsDuotone.warningCircle,
          color: statusColor,
        ),
        title: Text(defect.title),
        subtitle: Text(
          '${hasLocation ? '${defect.location} · ' : ''}'
          '${defect.severityLabel} severity · ${ukDate(defect.createdAt.toLocal())}'
          '${defect.reportedByName != null ? ' · ${defect.reportedByName}' : ''}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            defect.statusLabel,
            style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FacilityDefectDetailScreen(defectId: defect.id),
            ),
          );
          _loadDefects();
        },
      ),
    );
  }
}
