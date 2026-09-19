import 'dart:async';
import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/support_query.dart';
import '../models/support_message.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';
import '../utils/date_formats.dart';
import '../widgets/dog_picker_sheet.dart';
import '../widgets/page_body.dart';
import 'dog_home_screen.dart';
import 'owner_details_dialog.dart';

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

class _QueryDetailScreenState extends State<QueryDetailScreen> with WidgetsBindingObserver {
  final DataService _dataService = getIt<DataService>();
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  SupportQuery? _query;
  bool _loading = true;
  bool _loadFailed = false;
  bool _sending = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadQuery();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_loadFailed) _loadQuery();
      _startPolling();
    } else if (state == AppLifecycleState.paused) {
      _pollTimer?.cancel();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _pollForMessages());
  }

  Future<void> _pollForMessages() async {
    if (_loading || _sending) return;
    try {
      final updated = await _dataService.getSupportQuery(widget.queryId);
      if (!mounted) return;
      final oldCount = _query?.messages.length ?? 0;
      if (updated.messages.length != oldCount) {
        setState(() => _query = updated);
        _scrollToBottom();
      }
    } catch (_) {
      // Silent failure — next poll will retry
    }
  }

  Future<void> _loadQuery() async {
    setState(() => _loading = true);
    try {
      final query = await _dataService.getSupportQuery(widget.queryId);
      if (mounted) {
        setState(() {
          _query = query;
          _loading = false;
          _loadFailed = false;
        });
        _scrollToBottom();
        // Mark as read when the conversation is opened — clears the owner's
        // unread flag, and for staff the staff-side unread badge. Awaited so
        // the badge refresh on returning home can't race the request.
        try {
          await _dataService.markQueryRead(widget.queryId);
        } catch (_) {
          // The conversation still loaded; the badge just won't clear yet.
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load conversation: $e')),
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
          const SnackBar(content: Text('Conversation resolved'), backgroundColor: AppColors.success),
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

  Future<void> _openOwnerDetails() async {
    final query = _query;
    if (query == null) return;
    try {
      final profile = await _dataService.getOwnerProfile(query.ownerId);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => OwnerDetailsDialog(
          ownerProfile: profile,
          ownerId: query.ownerId,
          isStaff: widget.isStaff,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load client details: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _openDog(QueryOwnerDog dog) async {
    try {
      final fullDog = await _dataService.getDogById(dog.id.toString());
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DogHomeScreen(dog: fullDog, isStaff: widget.isStaff)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open ${dog.name}: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_query?.subject ?? 'Conversation'),
        actions: [
          if (_query != null && widget.isStaff && _query!.status == QueryStatus.open)
            IconButton(
              icon: Picon(PiconsRegular.checkCircle),
              tooltip: 'Resolve',
              onPressed: _resolveQuery,
            ),
          if (_query != null && _query!.status == QueryStatus.resolved)
            IconButton(
              icon: Picon(PiconsDuotone.arrowClockwise),
              tooltip: 'Reopen',
              onPressed: _reopenQuery,
            ),
        ],
      ),
      body: PageBody(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _query == null
              ? const Center(child: Text('Conversation not found'))
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
                          if (widget.isStaff)
                            // Who staff are talking to, and about which dog:
                            // the name opens the client's details, each dog
                            // chip opens that dog's profile.
                            Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 4,
                              children: [
                                InkWell(
                                  onTap: _openOwnerDetails,
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Picon(PiconsDuotone.user, size: 14, color: Theme.of(context).colorScheme.primary),
                                        const SizedBox(width: 4),
                                        Text(
                                          _query!.ownerName,
                                          style: TextStyle(
                                            color: Theme.of(context).colorScheme.primary,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Text(
                                  '\u2022 ${ukDateTime(_query!.createdAt.toLocal())}',
                                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                                ),
                              ],
                            )
                          else
                            Text(
                              'By ${_query!.ownerName} \u2022 ${ukDateTime(_query!.createdAt.toLocal())}',
                              style: TextStyle(color: Colors.grey[600], fontSize: 12),
                            ),
                          if (widget.isStaff && _query!.ownerDogs != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: _query!.ownerDogs!.isEmpty
                                  ? Text(
                                      'No dogs on this account yet',
                                      style: TextStyle(color: Colors.grey[600], fontSize: 12, fontStyle: FontStyle.italic),
                                    )
                                  : Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        for (final dog in _query!.ownerDogs!)
                                          ActionChip(
                                            avatar: DogPickerAvatar(imageUrl: dog.profileImageUrl, radius: 11),
                                            label: Text(dog.name),
                                            labelStyle: const TextStyle(fontSize: 12),
                                            visualDensity: VisualDensity.compact,
                                            onPressed: () => _openDog(dog),
                                          ),
                                      ],
                                    ),
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
                                    : Picon(PiconsDuotone.paperPlaneTilt),
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
                          'This conversation has been resolved.',
                          style: TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (!_canReply && widget.isStaff && !widget.canReplyQueries && _query!.status == QueryStatus.open)
                      Container(
                        padding: const EdgeInsets.all(16),
                        child: const Text(
                          'You do not have permission to reply.',
                          style: TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                )),
    );
  }

  Widget _buildMessageBubble(SupportMessage message) {
    final isOwnerMessage = !message.isStaff;
    final alignment = isOwnerMessage ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final scheme = Theme.of(context).colorScheme;
    final color = isOwnerMessage ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    // The text must be readable on the bubble, not just on the page: the
    // page's body colour on a green bubble was the "black on dark green".
    final textColor = isOwnerMessage ? scheme.onPrimaryContainer : scheme.onSurface;
    final metaColor = textColor.withValues(alpha: 0.7);
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
                  child: Picon(PiconsDuotone.headset, size: 14, color: Theme.of(context).colorScheme.primary),
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
                Text(message.text, style: TextStyle(color: textColor)),
                const SizedBox(height: 4),
                Text(
                  ukDateTime(message.createdAt.toLocal()),
                  style: TextStyle(fontSize: 10, color: metaColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
