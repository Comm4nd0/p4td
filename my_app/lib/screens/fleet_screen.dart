import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/vehicle.dart';
import '../services/data_service.dart';
import '../utils/date_formats.dart';
import '../widgets/skeleton_loaders.dart';
import 'add_edit_vehicle_screen.dart';
import 'vehicle_detail_screen.dart';

/// Colour for a server-computed due status ('overdue' | 'due_soon' | 'ok').
Color dueStatusColor(String? status) {
  switch (status) {
    case 'overdue':
      return AppColors.error;
    case 'due_soon':
      return AppColors.warning;
    default:
      return AppColors.success;
  }
}

/// Small pill showing how a MOT/service date is doing, e.g. "MOT overdue".
class DueBadge extends StatelessWidget {
  final String label;
  final String? status;

  const DueBadge({super.key, required this.label, required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == null) return const SizedBox.shrink();
    final color = dueStatusColor(status);
    final text = status == 'overdue'
        ? '$label overdue'
        : status == 'due_soon'
            ? '$label due soon'
            : '$label OK';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11),
      ),
    );
  }
}

class FleetScreen extends StatefulWidget {
  final bool canManageVehicles;

  const FleetScreen({super.key, this.canManageVehicles = false});

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> with WidgetsBindingObserver {
  final DataService _dataService = ApiDataService();
  List<Vehicle> _vehicles = [];
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadVehicles();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _loadFailed) {
      _loadVehicles();
    }
  }

  Future<void> _loadVehicles() async {
    setState(() => _loading = true);
    try {
      final vehicles = await _dataService.getVehicles();
      if (mounted) {
        setState(() {
          _vehicles = vehicles;
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load vehicles: $e')),
        );
      }
    }
  }

  Future<void> _addVehicle() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddEditVehicleScreen()),
    );
    if (result == true) _loadVehicles();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet'),
      ),
      floatingActionButton: widget.canManageVehicles
          ? FloatingActionButton.extended(
              onPressed: _addVehicle,
              icon: Picon(PiconsDuotone.plus),
              label: const Text('Add Vehicle'),
            )
          : null,
      body: _loading
          ? const ListTileSkeletonList()
          : RefreshIndicator.adaptive(
              onRefresh: _loadVehicles,
              child: _vehicles.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.5,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Picon(PiconsDuotone.van, size: 64, color: Colors.grey[400]),
                                const SizedBox(height: 16),
                                Text(
                                  'No vehicles yet',
                                  style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                                ),
                                if (widget.canManageVehicles) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'Tap "Add Vehicle" to get started',
                                    style: TextStyle(color: Colors.grey[500]),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 80),
                      itemCount: _vehicles.length,
                      itemBuilder: (context, index) => _buildVehicleCard(_vehicles[index]),
                    ),
            ),
    );
  }

  Widget _buildVehicleCard(Vehicle vehicle) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => VehicleDetailScreen(
                vehicleId: vehicle.id,
                canManageVehicles: widget.canManageVehicles,
              ),
            ),
          );
          _loadVehicles();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: vehicle.imageUrl != null
                      ? CachedNetworkImage(
                          imageUrl: vehicle.imageUrl!,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _imagePlaceholder(),
                        )
                      : _imagePlaceholder(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            vehicle.name,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        if (vehicle.openDefectCount > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.warning.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${vehicle.openDefectCount} defect${vehicle.openDefectCount == 1 ? '' : 's'}',
                              style: const TextStyle(
                                color: AppColors.warning,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        vehicle.registration,
                        if (vehicle.make != null || vehicle.model != null)
                          [vehicle.make, vehicle.model].where((p) => p != null).join(' '),
                      ].join(' · '),
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                    if (vehicle.status != 'ACTIVE') ...[
                      const SizedBox(height: 2),
                      Text(
                        vehicle.statusLabel,
                        style: const TextStyle(
                          color: AppColors.warning,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (vehicle.motStatus != null)
                          DueBadge(label: 'MOT', status: vehicle.motStatus),
                        if (vehicle.serviceStatus != null)
                          DueBadge(label: 'Service', status: vehicle.serviceStatus),
                      ],
                    ),
                    if (vehicle.motDueDate != null || vehicle.serviceDueDate != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (vehicle.motDueDate != null) 'MOT: ${ukDate(vehicle.motDueDate!)}',
                          if (vehicle.serviceDueDate != null)
                            'Service: ${ukDate(vehicle.serviceDueDate!)}',
                        ].join('  ·  '),
                        style: TextStyle(color: Colors.grey[500], fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _imagePlaceholder() {
    return Container(
      color: Colors.grey[200],
      child: Picon(PiconsDuotone.van, size: 32, color: Colors.grey[400]),
    );
  }
}
