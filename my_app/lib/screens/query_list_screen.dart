import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/support_query.dart';
import '../models/owner_profile.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import 'query_detail_screen.dart';
import '../widgets/skeleton_loaders.dart';

class QueryListScreen extends StatefulWidget {
  final bool isStaff;
  final bool canReplyQueries;

  const QueryListScreen({
    super.key,
    required this.isStaff,
    this.canReplyQueries = false,
  });

  @override
  State<QueryListScreen> createState() => _QueryListScreenState();
}

class _QueryListScreenState extends State<QueryListScreen> with WidgetsBindingObserver {
  final DataService _dataService = getIt<DataService>();
  List<SupportQuery> _queries = [];
  bool _loading = true;
  bool _loadFailed = false;
  String _filter = 'OPEN';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadQueries();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _loadFailed) {
      _loadQueries();
    }
  }

  Future<void> _loadQueries() async {
    setState(() => _loading = true);
    try {
      final queries = await _dataService.getSupportQueries();
      if (mounted) {
        setState(() {
          _queries = queries;
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
          SnackBar(content: Text('Failed to load messages: $e')),
        );
      }
    }
  }

  List<SupportQuery> get _filteredQueries {
    if (_filter == 'ALL') return _queries;
    return _queries.where((q) =>
      _filter == 'OPEN'
        ? q.status == QueryStatus.open
        : q.status == QueryStatus.resolved
    ).toList();
  }

  Future<void> _showNewQueryDialog() async {
    final subjectController = TextEditingController();
    final messageController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Message'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: subjectController,
                decoration: const InputDecoration(
                  labelText: 'Subject',
                  hintText: 'Brief summary',                ),
                validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: messageController,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  hintText: 'Your message',                ),
                maxLines: 4,
                validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        await _dataService.createSupportQuery(
          subject: subjectController.text.trim(),
          initialMessage: messageController.text.trim(),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Message sent'), backgroundColor: AppColors.success),
          );
        }
        _loadQueries();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to send message: $e')),
          );
        }
      }
    }
  }

  Future<void> _showStaffNewQueryDialog() async {
    // First, load the list of owners
    List<OwnerProfile>? owners;
    try {
      owners = await _dataService.getOwners();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load owners: $e')),
        );
      }
      return;
    }

    if (!mounted || owners.isEmpty) return;

    _showStaffQueryForm(owners);
  }

  Future<void> _showStaffQueryForm(List<OwnerProfile> owners, {OwnerProfile? preselectedOwner}) async {
    final subjectController = TextEditingController();
    final messageController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    OwnerProfile? selectedOwner = preselectedOwner;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Message Owner'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (preselectedOwner == null)
                    DropdownButtonFormField<OwnerProfile>(
                      decoration: const InputDecoration(
                        labelText: 'Owner',                      ),
                      value: selectedOwner,
                      items: owners.map((owner) => DropdownMenuItem(
                        value: owner,
                        child: Text(owner.username),
                      )).toList(),
                      onChanged: (value) => setDialogState(() => selectedOwner = value),
                      validator: (v) => v == null ? 'Please select an owner' : null,
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'To: ${preselectedOwner.username}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: subjectController,
                    decoration: const InputDecoration(
                      labelText: 'Subject',
                      hintText: 'Brief summary',                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: messageController,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      hintText: 'Your message to the owner',                    ),
                    maxLines: 4,
                    validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(context, true);
                }
              },
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );

    if (result == true && selectedOwner != null) {
      try {
        final query = await _dataService.createStaffQuery(
          ownerId: selectedOwner!.userId,
          subject: subjectController.text.trim(),
          initialMessage: messageController.text.trim(),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Message sent'), backgroundColor: AppColors.success),
          );
          // Navigate directly into the new query
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => QueryDetailScreen(
                queryId: query.id,
                isStaff: widget.isStaff,
                canReplyQueries: widget.canReplyQueries,
              ),
            ),
          );
        }
        _loadQueries();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to send message: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact Staff'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: widget.isStaff ? _showStaffNewQueryDialog : _showNewQueryDialog,
        icon: Picon(PiconsDuotone.plus),
        label: Text(widget.isStaff ? 'Message Owner' : 'New Message'),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _buildFilterChip('OPEN', 'Open'),
                const SizedBox(width: 8),
                _buildFilterChip('RESOLVED', 'Resolved'),
                const SizedBox(width: 8),
                _buildFilterChip('ALL', 'All'),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const ListTileSkeletonList()
                : RefreshIndicator.adaptive(
                    onRefresh: _loadQueries,
                    child: _filteredQueries.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.5,
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Picon(PiconsDuotone.chats, size: 64, color: Colors.grey[400]),
                                  const SizedBox(height: 16),
                                  Text(
                                    _filter == 'OPEN'
                                        ? 'No open conversations'
                                        : _filter == 'RESOLVED'
                                            ? 'No resolved conversations'
                                            : 'No conversations yet',
                                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 80),
                          itemCount: _filteredQueries.length,
                          itemBuilder: (context, index) =>
                              _buildQueryCard(_filteredQueries[index]),
                        ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    return FilterChip(
      label: Text(label),
      selected: _filter == value,
      onSelected: (_) => setState(() => _filter = value),
    );
  }

  Widget _buildQueryCard(SupportQuery query) {
    final isOpen = query.status == QueryStatus.open;
    final hasUnread =
        widget.isStaff ? query.staffHasUnread : query.hasUnreadReply;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => QueryDetailScreen(
                queryId: query.id,
                isStaff: widget.isStaff,
                canReplyQueries: widget.canReplyQueries,
              ),
            ),
          );
          _loadQueries();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Picon(
                    isOpen ? PiconsDuotone.question : PiconsDuotone.checkCircle,
                    size: 20,
                    color: isOpen ? Colors.orange : Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      query.subject,
                      style: TextStyle(
                        fontWeight: hasUnread ? FontWeight.w800 : FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (hasUnread)
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: const BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: (isOpen ? Colors.orange : Colors.green).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: (isOpen ? Colors.orange : Colors.green).withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      isOpen ? 'Open' : 'Resolved',
                      style: TextStyle(
                        color: isOpen ? Colors.orange : Colors.green,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (widget.isStaff)
                Text(
                  'From: ${query.ownerName}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${query.messageCount} message${query.messageCount == 1 ? '' : 's'}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  Text(
                    query.lastMessageAt != null
                        ? ukDateTime(query.lastMessageAt!.toLocal())
                        : ukDateTime(query.createdAt.toLocal()),
                    style: TextStyle(color: Colors.grey[500], fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
