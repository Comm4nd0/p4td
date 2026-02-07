import 'package:flutter/material.dart';
import '../models/boarding_request.dart';
import '../services/data_service.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

class BoardingRequestListScreen extends StatefulWidget {
  const BoardingRequestListScreen({super.key});

  @override
  State<BoardingRequestListScreen> createState() => _BoardingRequestListScreenState();
}

class _BoardingRequestListScreenState extends State<BoardingRequestListScreen> {
  final DataService _dataService = ApiDataService();
  late Future<List<BoardingRequest>> _requestsFuture;
  
  // Calendar state
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, List<BoardingRequest>> _events = {};

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    _loadRequests();
  }

  void _loadRequests() {
    setState(() {
      _requestsFuture = _dataService.getBoardingRequests().then((requests) {
        _processEvents(requests);
        return requests;
      });
    });
  }

  void _processEvents(List<BoardingRequest> requests) {
    _events = {};
    for (var request in requests) {
      if (request.status == BoardingRequestStatus.denied) continue; // Skip denied requests
      
      // Create events for each day of the request
      // Iterate from start to end date
      for (var day = request.startDate; 
           day.isBefore(request.endDate.add(const Duration(days: 1))); 
           day = day.add(const Duration(days: 1))) {
        
        final dateKey = DateTime(day.year, day.month, day.day);
        if (_events[dateKey] == null) {
          _events[dateKey] = [];
        }
        _events[dateKey]!.add(request);
      }
    }
  }

  List<BoardingRequest> _getEventsForDay(DateTime day) {
    return _events[DateTime(day.year, day.month, day.day)] ?? [];
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My Boarding Requests'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.list), text: 'List'),
              Tab(icon: Icon(Icons.calendar_month), text: 'Calendar'),
            ],
          ),
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
            
            return TabBarView(
              children: [
                _buildListView(requests),
                _buildCalendarView(requests),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildListView(List<BoardingRequest> requests) {
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
  }

  Widget _buildCalendarView(List<BoardingRequest> allRequests) {
    final selectedEvents = _selectedDay == null ? [] : _getEventsForDay(_selectedDay!);

    return Column(
      children: [
        TableCalendar<BoardingRequest>(
          firstDay: DateTime.utc(2020, 10, 16),
          lastDay: DateTime.utc(2030, 3, 14),
          focusedDay: _focusedDay,
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          onDaySelected: (selectedDay, focusedDay) {
            setState(() {
              _selectedDay = selectedDay;
              _focusedDay = focusedDay;
            });
          },
          eventLoader: _getEventsForDay,
          calendarFormat: CalendarFormat.month,
          startingDayOfWeek: StartingDayOfWeek.monday,
          calendarStyle: const CalendarStyle(
            markerSize: 8,
          ),
          calendarBuilders: CalendarBuilders(
            markerBuilder: (context, day, events) {
              if (events.isEmpty) return null;
              
              // Sort events by status priority for visual indication if multiple
              // Priority: Approved (Green) > Pending (Orange) > Denied (Red)
              
              final hasApproved = events.any((e) => e.status == BoardingRequestStatus.approved);
              final hasPending = events.any((e) => e.status == BoardingRequestStatus.pending);
              
              Color markerColor;
              if (hasApproved) {
                markerColor = Colors.green;
              } else if (hasPending) {
                markerColor = Colors.orange;
              } else {
                markerColor = Colors.red;
              }

              return Positioned(
                bottom: 1,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: markerColor,
                  ),
                  width: 7.0,
                  height: 7.0,
                ),
              );
            },
          ),
        ),
        const Divider(),
        Expanded(
          child: selectedEvents.isEmpty
              ? const Center(child: Text('No bookings for this day'))
              : ListView.builder(
                  itemCount: selectedEvents.length,
                  itemBuilder: (context, index) {
                    final request = selectedEvents[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: ListTile(
                        leading: Icon(Icons.pets, color: _getStatusColor(request.status)),
                        title: Text(request.dogNames.join(', ')),
                        subtitle: Text(request.status.toString().split('.').last.toUpperCase()),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                           // Could navigate to detail view if needed
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
