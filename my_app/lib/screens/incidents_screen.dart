import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/incident.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import 'incident_detail_screen.dart';
import 'log_incident_screen.dart';

/// The staff-only incident log.
///
/// Owners never reach this: every `/api/incidents/` route is staff-gated, and
/// the screen is only ever pushed from staff surfaces. Pass [dogId] to show
/// just one dog's incidents — that's the view the dog profile links to.
class IncidentsScreen extends StatefulWidget {
  final String? dogId;
  final String? dogName;

  const IncidentsScreen({super.key, this.dogId, this.dogName});

  @override
  State<IncidentsScreen> createState() => _IncidentsScreenState();
}

class _IncidentsScreenState extends State<IncidentsScreen> {
  final DataService _dataService = getIt<DataService>();
  List<Incident> _incidents = [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _openOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final incidents = await _dataService.getIncidents(
        dogId: widget.dogId,
        openOnly: _openOnly,
      );
      if (!mounted) return;
      setState(() {
        _incidents = incidents;
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _logIncident() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => LogIncidentScreen(
          initialDogId: widget.dogId,
          initialDogName: widget.dogName,
        ),
      ),
    );
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final open = _incidents.where((i) => !i.isResolved).toList();
    final resolved = _incidents.where((i) => i.isResolved).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.dogName != null ? '${widget.dogName} — Incidents' : 'Incidents'),
        actions: [
          IconButton(
            tooltip: _openOnly ? 'Showing open only' : 'Showing all',
            icon: Picon(
              _openOnly ? PiconsDuotone.funnel : PiconsDuotone.funnelSimple,
              color: _openOnly ? AppColors.primary : null,
            ),
            onPressed: () {
              setState(() {
                _openOnly = !_openOnly;
                _loading = true;
              });
              _load();
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _logIncident,
        icon: Picon(PiconsDuotone.firstAidKit, color: Colors.white),
        label: const Text('Log Incident'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : RefreshIndicator.adaptive(
              onRefresh: _load,
              child: _loadFailed
                  ? ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Text(
                              'Failed to load incidents. Pull down to retry.',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _incidents.isEmpty
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
                                      widget.dogName != null
                                          ? 'No incidents logged for ${widget.dogName}'
                                          : 'No incidents logged',
                                      textAlign: TextAlign.center,
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
                            ...open.map(_buildTile),
                            if (open.isNotEmpty && resolved.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text('Resolved',
                                  style: TextStyle(
                                      color: Colors.grey[600],
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                              const SizedBox(height: 8),
                            ],
                            ...resolved.map(_buildTile),
                          ],
                        ),
            ),
    );
  }

  Widget _buildTile(Incident incident) {
    final statusColor = incidentStatusColor(incident.status);
    final severityColor = incidentSeverityColor(incident.severity);
    final dogs = incident.involvedNames;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Picon(
          incident.isResolved ? PiconsDuotone.checkCircle : PiconsDuotone.firstAidKit,
          color: severityColor,
        ),
        title: Text(incident.title),
        subtitle: Text(
          '${dogs.isNotEmpty ? '${dogs.join(", ")} · ' : ''}'
          '${incident.typeDisplay} · ${ukDate(incident.occurredAt.toLocal())}',
          style: const TextStyle(fontSize: 12),
        ),
        isThreeLine: dogs.length > 2,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            incident.statusDisplay,
            style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => IncidentDetailScreen(incidentId: incident.id),
            ),
          );
          _load();
        },
      ),
    );
  }
}
