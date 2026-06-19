import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/vehicle.dart';
import '../models/vehicle_defect.dart';
import '../models/vehicle_maintenance_record.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import 'add_edit_vehicle_screen.dart';
import 'defect_detail_screen.dart';
import 'fleet_screen.dart';
import 'report_defect_screen.dart';

class VehicleDetailScreen extends StatefulWidget {
  final int vehicleId;
  final bool canManageVehicles;

  const VehicleDetailScreen({
    super.key,
    required this.vehicleId,
    this.canManageVehicles = false,
  });

  @override
  State<VehicleDetailScreen> createState() => _VehicleDetailScreenState();
}

class _VehicleDetailScreenState extends State<VehicleDetailScreen> {
  final DataService _dataService = getIt<DataService>();
  Vehicle? _vehicle;
  List<VehicleDefect> _defects = [];
  List<VehicleMaintenanceRecord> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _dataService.getVehicle(widget.vehicleId),
        _dataService.getVehicleDefects(vehicleId: widget.vehicleId),
        _dataService.getVehicleHistory(widget.vehicleId),
      ]);
      if (mounted) {
        setState(() {
          _vehicle = results[0] as Vehicle;
          _defects = results[1] as List<VehicleDefect>;
          _history = results[2] as List<VehicleMaintenanceRecord>;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load vehicle: $e')),
        );
      }
    }
  }

  Future<void> _editVehicle() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddEditVehicleScreen(vehicle: _vehicle)),
    );
    if (result == true) _loadAll();
  }

  Future<void> _deleteVehicle() async {
    final vehicle = _vehicle;
    if (vehicle == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Vehicle'),
        content: Text(
          'Delete ${vehicle.name} (${vehicle.registration})? This removes its defects and history too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _dataService.deleteVehicle(vehicle.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete vehicle: $e')),
        );
      }
    }
  }

  Future<void> _updateDueDate(String label, String field, DateTime? current) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
      helpText: 'New $label due date',
    );
    if (picked == null || !mounted) return;

    final notesController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Update $label due date'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('New due date: ${ukDate(picked)}'),
            const SizedBox(height: 16),
            TextField(
              controller: notesController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                hintText: 'e.g. Passed MOT, serviced at garage',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final notes = notesController.text.trim();
      await _dataService.updateVehicle(
        widget.vehicleId,
        motDueDate: field == 'mot' ? picked : null,
        serviceDueDate: field == 'service' ? picked : null,
        maintenanceNotes: notes.isEmpty ? null : notes,
      );
      _loadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update $label date: $e')),
        );
      }
    }
  }

  Future<void> _reportDefect() async {
    final vehicle = _vehicle;
    if (vehicle == null) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReportDefectScreen(vehicleId: vehicle.id, vehicleName: vehicle.name),
      ),
    );
    if (result == true) _loadAll();
  }

  @override
  Widget build(BuildContext context) {
    final vehicle = _vehicle;
    return Scaffold(
      appBar: AppBar(
        title: Text(vehicle?.name ?? 'Vehicle'),
        actions: [
          if (widget.canManageVehicles && vehicle != null)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') _editVehicle();
                if (value == 'delete') _deleteVehicle();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      Picon(PiconsDuotone.pencilSimple, size: 20),
                      const SizedBox(width: 8),
                      const Text('Edit'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Picon(PiconsDuotone.trash, size: 20, color: AppColors.error),
                      const SizedBox(width: 8),
                      const Text('Delete', style: TextStyle(color: AppColors.error)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      floatingActionButton: vehicle == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _reportDefect,
              icon: Picon(PiconsDuotone.warning),
              label: const Text('Report Defect'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : vehicle == null
              ? const Center(child: Text('Vehicle not found'))
              : RefreshIndicator.adaptive(
                  onRefresh: _loadAll,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 90),
                    children: [
                      if (vehicle.imageUrl != null)
                        SizedBox(
                          height: 200,
                          child: CachedNetworkImage(
                            imageUrl: vehicle.imageUrl!,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              color: Colors.grey[200],
                              child: Picon(PiconsDuotone.van, size: 64, color: Colors.grey[400]),
                            ),
                          ),
                        ),
                      _buildDetailsCard(vehicle),
                      _buildMaintenanceCard(vehicle),
                      _buildDefectsSection(),
                      if (_history.isNotEmpty) _buildHistorySection(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildDetailsCard(Vehicle vehicle) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    vehicle.registration,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (vehicle.status == 'ACTIVE' ? AppColors.success : AppColors.warning)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    vehicle.statusLabel,
                    style: TextStyle(
                      color: vehicle.status == 'ACTIVE' ? AppColors.success : AppColors.warning,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            if (vehicle.make != null || vehicle.model != null) ...[
              const SizedBox(height: 4),
              Text(
                [vehicle.make, vehicle.model].where((p) => p != null).join(' '),
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
            if (vehicle.notes != null && vehicle.notes!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(vehicle.notes!, style: TextStyle(color: Colors.grey[700])),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMaintenanceCard(Vehicle vehicle) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('MOT & Servicing', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            _buildDueRow('MOT', 'mot', vehicle.motDueDate, vehicle.motStatus),
            const Divider(height: 20),
            _buildDueRow('Service', 'service', vehicle.serviceDueDate, vehicle.serviceStatus),
          ],
        ),
      ),
    );
  }

  Widget _buildDueRow(String label, String field, DateTime? dueDate, String? status) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                dueDate != null ? 'Due ${ukDate(dueDate)}' : 'No date set',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            ],
          ),
        ),
        DueBadge(label: label, status: status),
        if (widget.canManageVehicles) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: Picon(PiconsDuotone.calendar, size: 22),
            tooltip: 'Update $label due date',
            onPressed: () => _updateDueDate(label, field, dueDate),
          ),
        ],
      ],
    );
  }

  Widget _buildDefectsSection() {
    final open = _defects.where((d) => !d.isResolved).toList();
    final resolved = _defects.where((d) => d.isResolved).toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Defects', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          if (_defects.isEmpty)
            Text('No defects reported', style: TextStyle(color: Colors.grey[600])),
          ...open.map(_buildDefectTile),
          ...resolved.map(_buildDefectTile),
        ],
      ),
    );
  }

  Widget _buildDefectTile(VehicleDefect defect) {
    final statusColor = defect.status == 'RESOLVED'
        ? AppColors.success
        : defect.status == 'IN_PROGRESS'
            ? AppColors.warning
            : AppColors.error;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Picon(
          defect.isResolved ? PiconsDuotone.checkCircle : PiconsDuotone.warningCircle,
          color: statusColor,
        ),
        title: Text(defect.title),
        subtitle: Text(
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
              builder: (_) => DefectDetailScreen(
                defectId: defect.id,
                canManageVehicles: widget.canManageVehicles,
              ),
            ),
          );
          _loadAll();
        },
      ),
    );
  }

  Widget _buildHistorySection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Maintenance History', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ..._history.map((record) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Picon(PiconsDuotone.clockCounterClockwise),
                  title: Text(
                    '${record.eventLabel} due date updated'
                    '${record.newDueDate != null ? ' to ${ukDate(record.newDueDate!)}' : ''}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    [
                      if (record.previousDueDate != null)
                        'Previously ${ukDate(record.previousDueDate!)}',
                      if (record.notes != null && record.notes!.trim().isNotEmpty) record.notes!,
                      '${ukDate(record.createdAt.toLocal())}'
                          '${record.createdByName != null ? ' · ${record.createdByName}' : ''}',
                    ].join('\n'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}
