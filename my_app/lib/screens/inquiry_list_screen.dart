import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/contact_inquiry.dart';
import '../services/data_service.dart';
import 'inquiry_detail_screen.dart';

class InquiryListScreen extends StatefulWidget {
  const InquiryListScreen({super.key});

  @override
  State<InquiryListScreen> createState() => _InquiryListScreenState();
}

class _InquiryListScreenState extends State<InquiryListScreen> {
  final DataService _dataService = ApiDataService();
  List<ContactInquiry> _inquiries = [];
  bool _loading = true;
  bool _loadFailed = false;
  String _filter = 'UNREAD';

  @override
  void initState() {
    super.initState();
    _loadInquiries();
  }

  Future<void> _loadInquiries() async {
    setState(() => _loading = true);
    try {
      final inquiries = await _dataService.getContactInquiries();
      if (mounted) {
        setState(() {
          _inquiries = inquiries;
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
          SnackBar(content: Text('Failed to load inquiries: $e')),
        );
      }
    }
  }

  List<ContactInquiry> get _filteredInquiries {
    if (_filter == 'ALL') return _inquiries;
    return _inquiries.where((i) => !i.isRead).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Website Inquiries'),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _buildFilterChip('UNREAD', 'Unread'),
                const SizedBox(width: 8),
                _buildFilterChip('ALL', 'All'),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filteredInquiries.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.mail_outline, size: 64, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(
                              _filter == 'UNREAD'
                                  ? 'No unread inquiries'
                                  : 'No website inquiries yet',
                              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadInquiries,
                        child: ListView.builder(
                          padding: const EdgeInsets.only(bottom: 16),
                          itemCount: _filteredInquiries.length,
                          itemBuilder: (context, index) =>
                              _buildInquiryCard(_filteredInquiries[index]),
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

  Widget _buildInquiryCard(ContactInquiry inquiry) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => InquiryDetailScreen(inquiry: inquiry),
            ),
          );
          _loadInquiries();
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
                    inquiry.isRead ? Icons.mail_outline : Icons.mark_email_unread,
                    size: 20,
                    color: inquiry.isRead ? Colors.grey : Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      inquiry.name,
                      style: TextStyle(
                        fontWeight: inquiry.isRead ? FontWeight.normal : FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      inquiry.serviceDisplay,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                inquiry.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    inquiry.email,
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  Text(
                    DateFormat('d MMM, HH:mm').format(inquiry.createdAt.toLocal()),
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
