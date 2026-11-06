import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/owner_calendar.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';

/// Subscribes the owner's own calendar app to their dogs' booked days.
Future<void> showCalendarFeedSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const CalendarFeedSheet(),
  );
}

/// Where to send the phone for [link]. iOS hands webcal:// to Apple Calendar;
/// Android has no handler for it, so it goes to Google Calendar's add page.
Uri calendarSubscribeUri(CalendarFeedLink link, TargetPlatform platform) {
  if (platform == TargetPlatform.iOS) return Uri.parse(link.webcalUrl);
  return Uri.https('calendar.google.com', '/calendar/r', {'cid': link.webcalUrl});
}

class CalendarFeedSheet extends StatefulWidget {
  const CalendarFeedSheet({super.key});

  @override
  State<CalendarFeedSheet> createState() => _CalendarFeedSheetState();
}

class _CalendarFeedSheetState extends State<CalendarFeedSheet> {
  final DataService _dataService = getIt<DataService>();

  CalendarFeedLink? _link;
  bool _loading = true;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final link = await _dataService.getCalendarFeedLink();
      if (mounted) setState(() => _link = link);
    } catch (_) {
      if (mounted) setState(() => _message = "Couldn't check your calendar link. Please try again.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    String? message;
    try {
      message = await action();
    } catch (_) {
      message = 'Something went wrong. Please try again.';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _message = message;
      });
    }
  }

  Future<CalendarFeedLink> _ensureLink() async {
    final link = _link ?? await _dataService.createCalendarFeedLink();
    if (mounted) setState(() => _link = link);
    return link;
  }

  Future<String?> _subscribe() async {
    final uri = calendarSubscribeUri(await _ensureLink(), defaultTargetPlatform);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    return opened ? null : "Couldn't open your calendar. Copy the link and add it there instead.";
  }

  Future<String?> _copy() async {
    final link = await _ensureLink();
    await Clipboard.setData(ClipboardData(text: link.url));
    return 'Link copied. In Outlook or another calendar, choose to subscribe from a URL and paste it.';
  }

  Future<void> _turnOff() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off this link?'),
        content: const Text(
          'The link stops working and your calendar stops updating, so remove it there too. '
          'If you add your calendar again you will get a new link.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Turn off')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _dataService.deleteCalendarFeedLink();
      if (mounted) setState(() => _link = null);
      return 'Link turned off.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = !_loading && !_busy;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add to my calendar',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              "See your dogs' daycare and boarding days in Google, Apple or Outlook Calendar. "
              'It updates by itself, but your calendar can take up to a day to catch up, '
              'so check the app for the latest.',
            ),
            const SizedBox(height: 8),
            Text(
              "Anyone with the link can see your dogs' names and booked days, so keep it private.",
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: enabled ? () => _run(_subscribe) : null,
              child: const Text('Add to my calendar'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: enabled ? () => _run(_copy) : null,
              child: const Text('Copy link'),
            ),
            if (_link != null)
              TextButton(
                onPressed: enabled ? _turnOff : null,
                child: const Text('Turn off this link'),
              ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}
