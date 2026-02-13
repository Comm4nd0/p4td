import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/support_query.dart';
import '../services/data_service.dart';
import 'query_detail_screen.dart';

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

class _QueryListScreenState extends State<QueryListScreen> {
  final DataService _dataService = ApiDataService();
  List<SupportQuery> _queries = [];
  bool _loading = true;
  String _filter = 'OPEN';

  @override
  void initState() {
    super.initState();
    _loadQueries();
  }

  Future<void> _loadQueries() async {
    setState(() => _loading = true);
    try {
      final queries = await _dataService.getSupportQueries();
      if (mounted) {
        setState(() {
          _queries = queries;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load queries: $e')),
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
        title: const Text('New Query'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: subjectController,
                decoration: const InputDecoration(
                  labelText: 'Subject',
                  hintText: 'Brief summary of your question',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: messageController,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  hintText: 'Describe your question in detail',
                  border: OutlineInputBorder(),
                ),
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
            const SnackBar(content: Text('Query submitted'), backgroundColor: Colors.green),
          );
        }
        _loadQueries();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to submit query: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Support Queries'),
      ),
      floatingActionButton: !widget.isStaff
          ? FloatingActionButton.extended(
              onPressed: _showNewQueryDialog,
              icon: const Icon(Icons.add),
              label: const Text('New Query'),
            )
          : null,
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
                ? const Center(child: CircularProgressIndicator())
                : _filteredQueries.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.question_answer, size: 64, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(
                              _filter == 'OPEN'
                                  ? 'No open queries'
                                  : _filter == 'RESOLVED'
                                      ? 'No resolved queries'
                                      : 'No queries yet',
                              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadQueries,
                        child: ListView.builder(
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
                  Icon(
                    isOpen ? Icons.help_outline : Icons.check_circle_outline,
                    size: 20,
                    color: isOpen ? Colors.orange : Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      query.subject,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
                        ? DateFormat('d MMM, HH:mm').format(query.lastMessageAt!.toLocal())
                        : DateFormat('d MMM, HH:mm').format(query.createdAt.toLocal()),
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
