import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../../constants/app_colors.dart';
import '../../models/route_plan.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../utils/date_formats.dart';
import '../../widgets/page_body.dart';

/// The dashboard's **Plan Routes** quick action: pick the day's drivers and
/// their van sizes, get a suggested split of the dogs with each run in
/// order, then apply it or walk away. Nothing changes on the board until
/// Apply; applying moves dogs for this day only, never the weekly roster.
/// Pops true when a plan was applied.
class RoutePlanScreen extends StatefulWidget {
  final DateTime date;

  const RoutePlanScreen({super.key, required this.date});

  @override
  State<RoutePlanScreen> createState() => _RoutePlanScreenState();
}

class _RoutePlanScreenState extends State<RoutePlanScreen> {
  final DataService _dataService = getIt<DataService>();

  List<RoutePlanDriver>? _drivers;
  final Set<int> _selected = {};

  /// Dogs each driver's van takes; null is no limit. Steppers rather than a
  /// number field: the keyboard covered Suggest a plan and had no Done key.
  final Map<int, int?> _capacity = {};
  String? _loadError;

  RoutePlan? _plan;
  bool _planning = false;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _loadDrivers();
  }

  Future<void> _loadDrivers() async {
    try {
      final drivers = List.of(await _dataService.getRoutePlanDrivers(date: widget.date));
      if (!mounted) return;
      // Ticked first, then everyone else, each alphabetically (the server
      // already sorts by name).
      drivers.sort((a, b) => (b.selected ? 1 : 0) - (a.selected ? 1 : 0));
      setState(() {
        _drivers = drivers;
        for (final d in drivers) {
          if (d.selected) _selected.add(d.staffMemberId);
          _capacity[d.staffMemberId] = d.capacity;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _suggest() async {
    setState(() => _planning = true);
    try {
      final plan = await _dataService.planRoutes(
        date: widget.date,
        drivers: {
          for (final d in _drivers!)
            if (_selected.contains(d.staffMemberId))
              d.staffMemberId: _capacity[d.staffMemberId],
        },
      );
      if (mounted) setState(() => _plan = plan);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  Future<void> _apply() async {
    final plan = _plan!;
    setState(() => _applying = true);
    try {
      final moved = await _dataService.applyRoutePlan(
        date: widget.date,
        routes: {for (final r in plan.routes) r.staffMemberId: [for (final d in r.dogs) d.dogId]},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(moved == 0
              ? 'Route order saved — no dogs needed moving.'
              : 'Plan applied: $moved dog${moved == 1 ? '' : 's'} moved.'),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _applying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return PopScope(
      // Back from a plan goes back to the driver picker, not off the screen.
      canPop: plan == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && plan != null) setState(() => _plan = null);
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Plan Routes — ${ukDateWithDay(widget.date)}')),
        body: PageBody(child: plan == null ? _buildDriverPicker() : _buildPlan(plan)),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: plan == null
              ? FilledButton.icon(
                  onPressed: _drivers == null || _selected.isEmpty || _planning ? null : _suggest,
                  icon: _planning ? _spinner() : Picon(PiconsDuotone.signpost),
                  label: Text(_planning ? 'Planning…' : 'Suggest a plan'),
                )
              : Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _applying ? null : () => setState(() => _plan = null),
                      child: const Text('Change drivers'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _applying ? null : _apply,
                      child: _applying ? _spinner() : const Text('Apply plan'),
                    ),
                  ),
                ]),
        ),
      ),
    );
  }

  Widget _spinner() =>
      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));

  Widget _buildDriverPicker() {
    if (_loadError != null) return Center(child: Text(_loadError!));
    final drivers = _drivers;
    if (drivers == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Who is driving? The plan shares the day\'s dogs between the ticked drivers, '
          'keeping dogs with their usual driver unless moving them saves real driving. '
          'Set how many dogs each van takes, or take it down to No limit.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        for (final d in drivers) _buildDriverRow(d),
      ],
    );
  }

  Widget _buildDriverRow(RoutePlanDriver d) {
    final details = [
      if (d.vehicleName != null) d.vehicleName!,
      if (d.dogsNow > 0) '${d.dogsNow} dog${d.dogsNow == 1 ? '' : 's'} today',
      if (!d.working) 'not due in',
    ];
    final selected = _selected.contains(d.staffMemberId);
    return Card(
      child: Column(children: [
        CheckboxListTile(
          value: selected,
          onChanged: (v) => setState(() {
            if (v == true) {
              _selected.add(d.staffMemberId);
            } else {
              _selected.remove(d.staffMemberId);
            }
          }),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(d.name),
          subtitle: details.isEmpty ? null : Text(details.join(' · ')),
        ),
        if (selected) _buildCapacityStepper(d),
      ]),
    );
  }

  /// Below 1 is No limit. Coming back up starts from the van's own size, or
  /// the dogs the driver has today, so a big van isn't eight taps from 1.
  Widget _buildCapacityStepper(RoutePlanDriver d) {
    final id = d.staffMemberId;
    final capacity = _capacity[id];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(children: [
        Expanded(child: Text('Dogs in the van', style: Theme.of(context).textTheme.bodyMedium)),
        IconButton(
          tooltip: 'Fewer dogs for ${d.name}',
          onPressed: capacity == null
              ? null
              : () => setState(() => _capacity[id] = capacity > 1 ? capacity - 1 : null),
          icon: Picon(PiconsDuotone.minus),
        ),
        SizedBox(
          width: 64,
          child: Text(
            capacity?.toString() ?? 'No limit',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        IconButton(
          tooltip: 'More dogs for ${d.name}',
          onPressed: () => setState(() {
            _capacity[id] = capacity == null ? d.capacity ?? (d.dogsNow > 0 ? d.dogsNow : 1) : capacity + 1;
          }),
          icon: Picon(PiconsDuotone.plus),
        ),
      ]),
    );
  }

  Widget _buildPlan(RoutePlan plan) {
    final saved = plan.currentMinutes - plan.plannedMinutes;
    final warnings = [
      for (final group in plan.conflicts) '${group.join(' & ')} still share a van — no other split worked.',
      for (final name in plan.overCapacity) "$name's van is over its dog limit — no other split worked.",
      for (final u in plan.unplaced) '${u.name} isn\'t on the plan: ${u.reason.toLowerCase()}.',
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                saved > 0
                    ? 'About ${plan.plannedMinutes} min of driving in all — $saved min less than now.'
                    : 'About ${plan.plannedMinutes} min of driving in all (now ${plan.currentMinutes} min).',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(plan.movedCount == 0
                  ? 'Every dog stays with its driver; only the order changes.'
                  : '${plan.movedCount} dog${plan.movedCount == 1 ? '' : 's'} change driver, for this day only.'),
              const SizedBox(height: 4),
              Text(
                'Drive times are estimates from postcodes, without traffic.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
        ),
        for (final w in warnings)
          Card(
            color: AppColors.warning.withValues(alpha: 0.15),
            child: ListTile(leading: Picon(PiconsDuotone.warning, color: AppColors.warning), title: Text(w)),
          ),
        for (final route in plan.routes) _buildRoute(route),
      ],
    );
  }

  Widget _buildRoute(PlannedRoute route) {
    final load = route.capacity == null ? '${route.load} dogs' : '${route.load}/${route.capacity} dogs';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            title: Text(route.staffMemberName, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(route.dogs.isEmpty
                ? 'No dogs'
                : '$load · about ${route.minutes} min (now ${route.currentMinutes} min)'),
          ),
          for (var i = 0; i < route.dogs.length; i++) _buildDog(i + 1, route.dogs[i]),
        ]),
      ),
    );
  }

  Widget _buildDog(int position, PlannedDog dog) {
    final notes = [
      if (dog.moved) dog.fromStaffMemberName == null ? 'needed a driver' : 'from ${dog.fromStaffMemberName}',
      if (dog.pinned) 'already on the move',
      if (!dog.located) 'no location on file — at the end',
    ];
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 13,
        backgroundColor: dog.moved ? AppColors.info : null,
        child: Text('$position', style: TextStyle(fontSize: 12, color: dog.moved ? Colors.white : null)),
      ),
      title: Text(dog.name, style: dog.moved ? const TextStyle(fontWeight: FontWeight.bold) : null),
      subtitle: notes.isEmpty ? null : Text(notes.join(' · ')),
    );
  }
}
