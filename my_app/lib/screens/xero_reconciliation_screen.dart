import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/xero_contact.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';

/// Xero contact reconciliation for the invoicing transition.
///
/// Long-standing customers were invoiced by hand in Xero, so their contacts
/// already exist there — often under a different email or name than their app
/// account. Pushing an invoice for an unmatched customer would create a
/// duplicate contact, so staff pin the right contact here before flipping a
/// customer to app billing on the Pricing screen.
class XeroReconciliationScreen extends StatefulWidget {
  const XeroReconciliationScreen({super.key});

  @override
  State<XeroReconciliationScreen> createState() =>
      _XeroReconciliationScreenState();
}

class _XeroReconciliationScreenState extends State<XeroReconciliationScreen> {
  final DataService _dataService = getIt<DataService>();
  XeroContactMatches? _matches;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final matches = await _dataService.getXeroContactMatches();
      if (mounted) {
        setState(() {
          _matches = matches;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _showError(Object message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$message'), backgroundColor: AppColors.error),
    );
  }

  Future<void> _pin(XeroCustomerMatch match, XeroContact contact) async {
    setState(() => _busy = true);
    try {
      await _dataService.pinXeroContact(match.customer.userId, contact.contactId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${match.customer.displayName} pinned to "${contact.name}"'),
          backgroundColor: AppColors.success,
        ));
      }
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unpin(XeroCustomerMatch match) async {
    setState(() => _busy = true);
    try {
      await _dataService.pinXeroContact(match.customer.userId, '');
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Candidate picker + free search over the org's Xero contacts.
  Future<void> _chooseContact(XeroCustomerMatch match) async {
    final chosen = await showModalBottomSheet<XeroContact>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ContactPickerSheet(
        match: match,
        search: _dataService.searchXeroContacts,
      ),
    );
    if (chosen != null && mounted) {
      await _pin(match, chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Xero contact matching')),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : RefreshIndicator.adaptive(
              onRefresh: _load,
              child: _buildBody(),
            ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return _message(PiconsDuotone.warning, 'Could not load contact matches',
          _error!);
    }
    final matches = _matches!;
    if (!matches.connected) {
      return _message(
          PiconsDuotone.plugs,
          'Xero is not connected',
          'Connect Xero from Settings first — contact matching needs the '
              'Xero contact list.');
    }
    if (matches.customers.isEmpty) {
      return _message(PiconsDuotone.usersThree, 'No customers found',
          'Customers appear here once they have dogs on their account.');
    }
    // Attention first: ambiguous/none, then confident matches, pinned last.
    const order = {'ambiguous': 0, 'none': 1, 'name': 2, 'email': 3, 'pinned': 4};
    final rows = [...matches.customers]..sort((a, b) {
        final byStatus =
            (order[a.matchStatus] ?? 5).compareTo(order[b.matchStatus] ?? 5);
        if (byStatus != 0) return byStatus;
        return a.customer.displayName
            .toLowerCase()
            .compareTo(b.customer.displayName.toLowerCase());
      });
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Pin each customer to their existing Xero contact so app invoices '
          'attach to it instead of creating a duplicate. Do this before '
          'switching a customer to app billing.',
          style: TextStyle(fontSize: 13, color: Colors.grey[700]),
        ),
        const SizedBox(height: 12),
        ...rows.map(_buildRow),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _message(PiconDuotoneData icon, String title, String detail) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.5,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Picon(icon, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(title,
                      style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                  const SizedBox(height: 8),
                  Text(detail,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  (String, Color) _statusChip(XeroCustomerMatch match) {
    switch (match.matchStatus) {
      case 'pinned':
        return ('Pinned', AppColors.success);
      case 'email':
        return ('Email match', AppColors.info);
      case 'name':
        return ('Name match', AppColors.info);
      case 'ambiguous':
        return ('Several matches', AppColors.warning);
      default:
        return ('No match', AppColors.error);
    }
  }

  Widget _buildRow(XeroCustomerMatch match) {
    final (label, color) = _statusChip(match);
    final contact = match.matchedContact;
    final subtitle = <String>[
      if (match.customer.email.isNotEmpty) match.customer.email,
      if (contact != null)
        'Xero: ${contact.name.isNotEmpty ? contact.name : contact.contactId}'
            '${contact.email.isNotEmpty ? ' <${contact.email}>' : ''}',
      if (match.matchStatus == 'ambiguous')
        '${match.candidates.length} possible contacts — pick the right one',
      if (match.matchStatus == 'none')
        'No Xero contact found — search and pin, or a new contact is created '
            'on first invoice',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        title: Text(match.customer.displayName,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle.join('\n'),
            style: const TextStyle(fontSize: 12)),
        isThreeLine: subtitle.length > 1,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Text(label,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 11)),
        ),
        onTap: _busy ? null : () => _showActions(match),
      ),
    );
  }

  Future<void> _showActions(XeroCustomerMatch match) async {
    final contact = match.matchedContact;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(match.customer.displayName,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: contact != null
                  ? Text('Currently: ${contact.name.isNotEmpty ? contact.name : contact.contactId}')
                  : null,
            ),
            const Divider(height: 1),
            if (!match.isPinned && contact != null)
              ListTile(
                leading: Picon(PiconsDuotone.pushPin, size: 22),
                title: Text('Pin "${contact.name}"'),
                subtitle: const Text('Use this Xero contact for their invoices'),
                onTap: () => Navigator.pop(context, 'pin_match'),
              ),
            ListTile(
              leading: Picon(PiconsDuotone.magnifyingGlass, size: 22),
              title: Text(match.matchStatus == 'ambiguous'
                  ? 'Choose from matches'
                  : 'Search Xero contacts'),
              onTap: () => Navigator.pop(context, 'choose'),
            ),
            if (match.isPinned)
              ListTile(
                leading: Picon(PiconsDuotone.x, size: 22, color: AppColors.error),
                title: const Text('Unpin',
                    style: TextStyle(color: AppColors.error)),
                subtitle: const Text('Fall back to email/name matching'),
                onTap: () => Navigator.pop(context, 'unpin'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'pin_match':
        await _pin(match, contact!);
        break;
      case 'choose':
        await _chooseContact(match);
        break;
      case 'unpin':
        await _unpin(match);
        break;
    }
  }
}

/// Bottom sheet listing a match's candidates with a live search over the
/// org's Xero contacts. Returns the chosen contact.
class _ContactPickerSheet extends StatefulWidget {
  final XeroCustomerMatch match;
  final Future<List<XeroContact>> Function(String query) search;

  const _ContactPickerSheet({required this.match, required this.search});

  @override
  State<_ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<_ContactPickerSheet> {
  List<XeroContact> _results = [];
  bool _searching = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _results = widget.match.candidates;
  }

  Future<void> _runSearch(String query) async {
    setState(() {
      _query = query;
      _searching = true;
    });
    if (query.trim().length < 2) {
      setState(() {
        _results = widget.match.candidates;
        _searching = false;
      });
      return;
    }
    try {
      final results = await widget.search(query.trim());
      if (mounted && query == _query) {
        setState(() {
          _results = results;
          _searching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('Xero contact for ${widget.match.customer.displayName}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  TextField(
                    autofocus: widget.match.candidates.isEmpty,
                    decoration: InputDecoration(
                      hintText: 'Search Xero contacts',
                      prefixIcon: Picon(PiconsDuotone.magnifyingGlass, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onChanged: _runSearch,
                  ),
                ],
              ),
            ),
            if (_searching) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _query.trim().length < 2
                            ? 'Type at least two characters to search'
                            : 'No Xero contacts found',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final contact = _results[index];
                        return ListTile(
                          title: Text(contact.name.isNotEmpty
                              ? contact.name
                              : contact.contactId),
                          subtitle: contact.email.isNotEmpty
                              ? Text(contact.email)
                              : null,
                          onTap: () => Navigator.pop(context, contact),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
