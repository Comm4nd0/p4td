import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/app_colors.dart';
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

  @override
  void initState() {
    super.initState();
    _isRead = widget.inquiry.isRead;
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

  Future<void> _deleteInquiry() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Inquiry'),
        content: const Text('Are you sure you want to delete this inquiry?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _dataService.deleteContactInquiry(widget.inquiry.id);
      if (mounted) {
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
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open email app')),
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
            icon: Icon(_isRead ? Icons.mark_email_unread : Icons.mark_email_read),
            tooltip: _isRead ? 'Mark as unread' : 'Mark as read',
            onPressed: _toggleReadStatus,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
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
                        const Spacer(),
                        Icon(Icons.access_time, size: 14, color: Colors.grey[500]),
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
                icon: const Icon(Icons.email),
                label: const Text('Reply via Email'),
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
