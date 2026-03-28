import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/contact_inquiry.dart';
import '../services/data_service.dart';

class InquiryDetailScreen extends StatefulWidget {
  final ContactInquiry inquiry;

  const InquiryDetailScreen({super.key, required this.inquiry});

  @override
  State<InquiryDetailScreen> createState() => _InquiryDetailScreenState();
}

class _InquiryDetailScreenState extends State<InquiryDetailScreen> {
  final DataService _dataService = ApiDataService();
  late bool _isRead;
  late bool _isReplied;

  @override
  void initState() {
    super.initState();
    _isRead = widget.inquiry.isRead;
    _isReplied = widget.inquiry.isReplied;
    if (!_isRead) {
      _markAsRead();
    }
  }

  Future<void> _markAsRead() async {
    try {
      await _dataService.markInquiryRead(widget.inquiry.id);
      if (mounted) setState(() => _isRead = true);
    } catch (_) {}
  }

  Future<void> _toggleReadStatus() async {
    try {
      if (_isRead) {
        await _dataService.markInquiryUnread(widget.inquiry.id);
        if (mounted) setState(() => _isRead = false);
      } else {
        await _dataService.markInquiryRead(widget.inquiry.id);
        if (mounted) setState(() => _isRead = true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update status: $e')),
        );
      }
    }
  }

  Future<void> _replyViaEmail() async {
    final inquiry = widget.inquiry;
    final subject = Uri.encodeComponent(
      'Re: ${inquiry.serviceDisplay} Inquiry from ${inquiry.name}',
    );
    final body = Uri.encodeComponent(
      '\n\n--- Original Message ---\n'
      'From: ${inquiry.name}\n'
      'Email: ${inquiry.email}\n'
      'Service: ${inquiry.serviceDisplay}\n'
      'Date: ${DateFormat('d MMM yyyy, HH:mm').format(inquiry.createdAt.toLocal())}\n\n'
      '${inquiry.message}',
    );
    final uri = Uri.parse('mailto:${inquiry.email}?subject=$subject&body=$body');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
      // Mark as replied after opening email client
      if (!_isReplied) {
        try {
          await _dataService.markInquiryReplied(widget.inquiry.id);
          if (mounted) setState(() => _isReplied = true);
        } catch (_) {}
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open email app')),
        );
      }
    }
  }

  Future<void> _deleteInquiry() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Inquiry'),
        content: Text('Delete the inquiry from ${widget.inquiry.name}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _dataService.deleteInquiry(widget.inquiry.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Inquiry deleted')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete inquiry: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final inquiry = widget.inquiry;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inquiry Details'),
        actions: [
          IconButton(
            icon: PhosphorIcon(_isRead ? PhosphorIconsDuotone.envelope : PhosphorIconsDuotone.envelopeOpen),
            tooltip: _isRead ? 'Mark as unread' : 'Mark as read',
            onPressed: _toggleReadStatus,
          ),
          IconButton(
            icon: PhosphorIcon(PhosphorIconsDuotone.trash),
            tooltip: 'Delete inquiry',
            onPressed: _deleteInquiry,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Text(
                            inquiry.name.isNotEmpty ? inquiry.name[0].toUpperCase() : '?',
                            style: TextStyle(
                              color: theme.colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                inquiry.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                              Text(
                                inquiry.email,
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            inquiry.serviceDisplay,
                            style: TextStyle(
                              color: theme.colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (_isReplied) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PhosphorIcon(PhosphorIconsDuotone.arrowUUpLeft, size: 14, color: Colors.green.shade800),
                                const SizedBox(width: 4),
                                Text(
                                  'Replied',
                                  style: TextStyle(
                                    color: Colors.green.shade800,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const Spacer(),
                        PhosphorIcon(PhosphorIconsDuotone.clock, size: 14, color: Colors.grey[500]),
                        const SizedBox(width: 4),
                        Text(
                          DateFormat('d MMM yyyy, HH:mm').format(inquiry.createdAt.toLocal()),
                          style: TextStyle(color: Colors.grey[500], fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Message
            const Text(
              'Message',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  inquiry.message,
                  style: const TextStyle(fontSize: 15, height: 1.6),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Reply button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _replyViaEmail,
                icon: PhosphorIcon(PhosphorIconsDuotone.envelope),
                label: Text(_isReplied ? 'Reply Again via Email' : 'Reply via Email'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
