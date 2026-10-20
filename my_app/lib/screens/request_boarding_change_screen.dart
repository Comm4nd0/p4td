import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../models/boarding_request.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/page_body.dart';

/// Owner asks to move the dates of an approved boarding stay — add days or
/// drop them. Nothing changes until a boarding manager approves, so the
/// booking keeps its current dates meanwhile.
///
/// Only days after today can move (the server enforces the same rule): once
/// the dog has arrived the arrival date is fixed, and a new departure must
/// be tomorrow or later.
class RequestBoardingChangeScreen extends StatefulWidget {
  final BoardingRequest booking;

  const RequestBoardingChangeScreen({super.key, required this.booking});

  @override
  State<RequestBoardingChangeScreen> createState() => _RequestBoardingChangeScreenState();
}

class _RequestBoardingChangeScreenState extends State<RequestBoardingChangeScreen> {
  final DataService _dataService = getIt<DataService>();
  final TextEditingController _noteController = TextEditingController();

  late DateTime _start;
  late DateTime _end;
  bool _saving = false;

  BoardingRequest get _booking => widget.booking;

  DateTime get _tomorrow {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1);
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    // Re-open an earlier request where it left off.
    _start = _day(_booking.requestedStartDate ?? _booking.startDate);
    _end = _day(_booking.requestedEndDate ?? _booking.endDate);
    _noteController.text = _booking.changeNote ?? '';
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  bool get _unchanged =>
      _start == _day(_booking.startDate) && _end == _day(_booking.endDate);

  Future<void> _pickStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start.isBefore(_tomorrow) ? _tomorrow : _start,
      firstDate: _tomorrow,
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'New arrival date',
    );
    if (picked == null) return;
    setState(() {
      _start = _day(picked);
      if (_end.isBefore(_start)) _end = _start;
    });
  }

  Future<void> _pickEnd() async {
    final first = _start.isAfter(_tomorrow) ? _start : _tomorrow;
    final picked = await showDatePicker(
      context: context,
      initialDate: _end.isBefore(first) ? first : _end,
      firstDate: first,
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'New departure date',
    );
    if (picked == null) return;
    setState(() => _end = _day(picked));
  }

  Future<void> _submit() async {
    setState(() => _saving = true);
    try {
      await _dataService.requestBoardingChange(
        _booking.id,
        startDate: _start,
        endDate: _end,
        note: _noteController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Change requested — we\'ll let you know once it\'s confirmed')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _nights(DateTime start, DateTime end) {
    final n = end.difference(start).inDays;
    return '$n night${n == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    final started = _booking.hasStarted;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Change Boarding Dates')),
      body: PageBody(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(_booking.dogNames.join(', '),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Booked: ${ukDateWithDay(_booking.startDate)} – ${ukDateWithDay(_booking.endDate)} '
              '(${_nights(_booking.startDate, _booking.endDate)})',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                started
                    ? 'The stay has started, so you can only change the departure date. '
                        'Staff will confirm the change — until then the booking stays as it is.'
                    : 'Pick the new dates. Staff will confirm the change — until then the '
                        'booking stays as it is.',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 24),
            InkWell(
              onTap: started ? null : _pickStart,
              child: InputDecorator(
                decoration: InputDecoration(
                  prefixIcon: const Picon(PiconsDuotone.calendarDots),
                  labelText: 'Arrival',
                  helperText: started ? 'Already arrived — can\'t change' : null,
                  enabled: !started,
                ),
                child: Text(ukDateWithDay(_start)),
              ),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: _pickEnd,
              child: InputDecorator(
                decoration: const InputDecoration(
                  prefixIcon: Picon(PiconsDuotone.calendarDots),
                  labelText: 'Departure',
                ),
                child: Text(ukDateWithDay(_end)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'New stay: ${_nights(_start, _end)}',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: 'Note for staff (optional)',
                hintText: 'e.g. Our flight home moved to Sunday',
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: (_saving || _unchanged) ? null : _submit,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Request Change'),
            ),
          ],
        ),
      ),
    );
  }
}
