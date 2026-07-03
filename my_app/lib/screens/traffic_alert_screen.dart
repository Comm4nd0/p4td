import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../models/daily_dog_assignment.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';

/// Lets a driver send a traffic-delay notification to the owners on their own
/// route, choosing exactly which dogs' owners are notified. Defaults to the
/// dogs not yet handled for the relevant leg (pickup in the morning, drop-off
/// in the afternoon).
class TrafficAlertScreen extends StatefulWidget {
  const TrafficAlertScreen({super.key});

  @override
  State<TrafficAlertScreen> createState() => _TrafficAlertScreenState();
}

class _TrafficAlertScreenState extends State<TrafficAlertScreen> {
  final DataService _dataService = getIt<DataService>();
  final TextEditingController _detailController = TextEditingController();

  // 'pickup' | 'dropoff' — matches the backend alert_type values.
  String _leg = 'pickup';
  List<DailyDogAssignment> _all = [];
  final Set<int> _selectedDogIds = {};
  bool _loading = true;
  Object? _loadError;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Default to the leg that's happening now: pickups in the morning,
    // drop-offs in the afternoon. The driver can still switch.
    _leg = DateTime.now().hour < 12 ? 'pickup' : 'dropoff';
    _load();
  }

  @override
  void dispose() {
    _detailController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final list = await _dataService.getMyAssignments();
      if (!mounted) return;
      setState(() {
        _all = list;
        _loading = false;
      });
      _resetSelectionForLeg();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  /// Dogs the staff member physically handles for the selected leg today —
  /// owners who handle that leg themselves get no traffic alert, and neither
  /// do boarding dogs on a day that leg doesn't run (they stay with staff).
  List<DailyDogAssignment> get _visible {
    final list = _leg == 'pickup'
        ? _all.where((a) => a.needsPickup).toList()
        : _all.where((a) => a.needsDropoff).toList();
    list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  /// Pre-check the dogs not yet done for this leg: pickup → still assigned;
  /// drop-off → with team but not yet dropped home. Done dogs start unchecked
  /// but can be toggled back on.
  void _resetSelectionForLeg() {
    _selectedDogIds.clear();
    final pending = _leg == 'pickup'
        ? _visible.where((a) => a.status == AssignmentStatus.assigned)
        : _visible.where((a) => a.status == AssignmentStatus.pickedUp);
    setState(() {
      _selectedDogIds.addAll(pending.map((a) => a.dogId));
    });
  }

  void _onLegChanged(String leg) {
    if (leg == _leg) return;
    setState(() => _leg = leg);
    _resetSelectionForLeg();
  }

  bool get _allSelected =>
      _visible.isNotEmpty && _visible.every((a) => _selectedDogIds.contains(a.dogId));

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        for (final a in _visible) {
          _selectedDogIds.remove(a.dogId);
        }
      } else {
        _selectedDogIds.addAll(_visible.map((a) => a.dogId));
      }
    });
  }

  Future<void> _send() async {
    if (_selectedDogIds.isEmpty) return;
    setState(() => _sending = true);
    try {
      final detail = _detailController.text.trim();
      await _dataService.sendTrafficAlert(
        _leg,
        detail: detail.isNotEmpty ? detail : null,
        dogIds: _selectedDogIds.toList(),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send traffic alert: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Picon(PiconsDuotone.path, color: Colors.orange),
            SizedBox(width: 8),
            Text('Traffic Alert'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? _buildError()
              : _buildBody(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Picon(PiconsDuotone.warning, size: 48, color: Colors.red[400]),
            const SizedBox(height: 12),
            const Text('Could not load your route', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final legLabel = _leg == 'pickup' ? 'pickup' : 'drop-off';
    final visible = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'pickup', label: Text('Pickup'), icon: Picon(PiconsDuotone.arrowUp, size: 18)),
              ButtonSegment(value: 'dropoff', label: Text('Drop-off'), icon: Picon(PiconsDuotone.arrowDown, size: 18)),
            ],
            selected: {_leg},
            onSelectionChanged: (s) => _onLegChanged(s.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text('Notify owners on your $legLabel route',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600])),
              ),
              TextButton(
                onPressed: visible.isEmpty ? null : _toggleSelectAll,
                child: Text(_allSelected ? 'Select none' : 'Select all'),
              ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Picon(PiconsDuotone.path, size: 48, color: Colors.grey[400]),
                        const SizedBox(height: 12),
                        Text('No dogs on your $legLabel route today.',
                            textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600])),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final a = visible[index];
                    return CheckboxListTile(
                      value: _selectedDogIds.contains(a.dogId),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selectedDogIds.add(a.dogId);
                        } else {
                          _selectedDogIds.remove(a.dogId);
                        }
                      }),
                      title: Text(a.dogName),
                      subtitle: Text(a.status.displayName),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _detailController,
            decoration: const InputDecoration(
              labelText: 'Additional detail (optional)',
              hintText: 'e.g. Accident on M1, expect 20 min delay',
            ),
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_sending || _selectedDogIds.isEmpty) ? null : _send,
                icon: _sending
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Picon(PiconsDuotone.path, size: 18),
                label: Text(_sending ? 'Sending…' : 'Send alert (${_selectedDogIds.length})'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
