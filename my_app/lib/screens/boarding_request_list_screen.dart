import 'package:flutter/material.dart';
import '../models/boarding_request.dart';
import '../services/data_service.dart';
import 'package:intl/intl.dart';

class BoardingRequestListScreen extends StatefulWidget {
  const BoardingRequestListScreen({super.key});

  @override
  State<BoardingRequestListScreen> createState() => _BoardingRequestListScreenState();
}

class _BoardingRequestListScreenState extends State<BoardingRequestListScreen> {
  final DataService _dataService = ApiDataService();
  late Future<List<BoardingRequest>> _requestsFuture;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  void _loadRequests() {
    setState(() {
      _requestsFuture = _dataService.getBoardingRequests();  
    });
  }

  Color _getStatusColor(BoardingRequestStatus status) {
    switch (status) {
      case BoardingRequestStatus.approved:
        return Colors.green;
      case BoardingRequestStatus.denied:
        return Colors.red;
      case BoardingRequestStatus.pending:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Boarding Requests'),
      ),
      body: FutureBuilder<List<BoardingRequest>>(
        future: _requestsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('No boarding requests found'));
          }

          final requests = snapshot.data!;
          return RefreshIndicator(
            onRefresh: () async => _loadRequests(),
            child: ListView.builder(
              itemCount: requests.length,
              itemBuilder: (context, index) {
                final request = requests[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ListTile(
                    title: Text(
                      request.dogNames.join(', '),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${DateFormat('MMM d').format(request.startDate)} - ${DateFormat('MMM d, yyyy').format(request.endDate)}',
                        ),
                        if (request.status != BoardingRequestStatus.pending && request.approvedByName != null)
                          Text(
                            '${request.status == BoardingRequestStatus.approved ? 'Approved' : 'Denied'} by ${request.approvedByName}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                      ],
                    ),
                    trailing: Chip(
                      label: Text(
                        request.status.toString().split('.').last.toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      backgroundColor: _getStatusColor(request.status),
                    ),
                    isThreeLine: true,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
