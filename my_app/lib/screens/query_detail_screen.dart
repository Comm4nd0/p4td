import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/support_query.dart';
import '../models/support_message.dart';
import '../services/data_service.dart';

class QueryDetailScreen extends StatefulWidget {
  final int queryId;
  final bool isStaff;
  final bool canReplyQueries;

  const QueryDetailScreen({
    super.key,
    required this.queryId,
    required this.isStaff,
    this.canReplyQueries = false,
  });

  @override
  State<QueryDetailScreen> createState() => _QueryDetailScreenState();
}

class _QueryDetailScreenState extends State<QueryDetailScreen> {
  final DataService _dataService = ApiDataService();
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  SupportQuery? _query;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadQuery();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadQuery() async {
    setState(() => _loading = true);
    try {
      final query = await _dataService.getSupportQuery(widget.queryId);
      if (mounted) {
        setState(() {
          _query = query;
          _loading = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load query: $e')),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _query == null) return;

    setState(() => _sending = true);
    try {
      final updated = await _dataService.addQueryMessage(_query!.id, text);
      if (mounted) {
        setState(() {
          _query = updated;
          _sending = false;
        });
        _messageController.clear();
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send message: $e')),
        );
      }
    }
  }

  Future<void> _resolveQuery() async {
    if (_query == null) return;
    try {
      final updated = await _dataService.resolveQuery(_query!.id);
      if (mounted) {
        setState(() => _query = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Query resolved'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resolve: $e')),
        );
      }
    }
  }

  Future<void> _reopenQuery() async {
    if (_query == null) return;
    try {
      final updated = await _dataService.reopenQuery(_query!.id);
      if (mounted) {
        setState(() => _query = updated);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reopen: $e')),
        );
      }
    }
  }

  bool get _canReply {
    if (_query == null) return false;
    if (_query!.status == QueryStatus.resolved) return false;
    if (widget.isStaff) return widget.canReplyQueries;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_query?.subject ?? 'Query'),
        actions: [
          if (_query != null && widget.isStaff && _query!.status == QueryStatus.open)
            IconButton(
              icon: const Icon(Icons.check_circle_outline),
              tooltip: 'Resolve',
              onPressed: _resolveQuery,
            ),
          if (_query != null && _query!.status == QueryStatus.resolved)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reopen',
              onPressed: _reopenQuery,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _query == null
              ? const Center(child: Text('Query not found'))
              : Column(
                  children: [
                    // Query info header
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _query!.subject,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'By ${_query!.ownerName} \u2022 ${DateFormat('d MMM yyyy, HH:mm').format(_query!.createdAt.toLocal())}',
                            style: TextStyle(color: Colors.grey[600], fontSize: 12),
                          ),
                          if (_query!.status == QueryStatus.resolved)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'Resolved by ${_query!.resolvedByName ?? 'staff'}',
                                style: const TextStyle(color: Colors.green, fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Messages
                    Expanded(
                      child: _query!.messages.isEmpty
                          ? Center(
                              child: Text(
                                'No messages yet',
                                style: TextStyle(color: Colors.grey[500]),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(16),
                              itemCount: _query!.messages.length,
                              itemBuilder: (context, index) =>
                                  _buildMessageBubble(_query!.messages[index]),
                            ),
                    ),
                    // Input area
                    if (_canReply)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 4,
                              offset: const Offset(0, -2),
                            ),
                          ],
                        ),
                        child: SafeArea(
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _messageController,
                                  decoration: InputDecoration(
                                    hintText: 'Type a message...',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  ),
                                  maxLines: null,
                                  textInputAction: TextInputAction.send,
                                  onSubmitted: (_) => _sendMessage(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: _sending
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.send),
                                onPressed: _sending ? null : _sendMessage,
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (!_canReply && _query!.status == QueryStatus.resolved)
                      Container(
                        padding: const EdgeInsets.all(16),
                        child: const Text(
                          'This query has been resolved.',
                          style: TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (!_canReply && widget.isStaff && !widget.canReplyQueries && _query!.status == QueryStatus.open)
                      Container(
                        padding: const EdgeInsets.all(16),
                        child: const Text(
                          'You do not have permission to reply to queries.',
                          style: TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _buildMessageBubble(SupportMessage message) {
    final isOwnerMessage = !message.isStaff;
    final alignment = isOwnerMessage ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isOwnerMessage
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(12),
      topRight: const Radius.circular(12),
      bottomLeft: isOwnerMessage ? const Radius.circular(12) : Radius.zero,
      bottomRight: isOwnerMessage ? Radius.zero : const Radius.circular(12),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Row(
            mainAxisAlignment: isOwnerMessage ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (message.isStaff)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.support_agent, size: 14, color: Theme.of(context).colorScheme.primary),
                ),
              Text(
                message.senderName,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color,
              borderRadius: borderRadius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.text),
                const SizedBox(height: 4),
                Text(
                  DateFormat('d MMM, HH:mm').format(message.createdAt.toLocal()),
                  style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
