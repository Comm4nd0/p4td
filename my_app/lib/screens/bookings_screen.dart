import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/booking.dart';
import '../services/data_service.dart';

class BookingsScreen extends StatefulWidget {
  final String dogId;

  const BookingsScreen({super.key, required this.dogId});

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  final DataService _dataService = ApiDataService();
  late Future<List<Booking>> _bookingsFuture;

  @override
  void initState() {
    super.initState();
    _bookingsFuture = _dataService.getBookings(widget.dogId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Booking>>(
      future: _bookingsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('No bookings found.'));
        }

        final bookings = snapshot.data!;
        return ListView.builder(
          padding: const EdgeInsets.only(top: 8),
          itemCount: bookings.length,
          itemBuilder: (context, index) {
            final booking = bookings[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ListTile(
                leading: const Icon(Icons.calendar_today, color: Colors.blue),
                title: Text(
                  DateFormat('EEEE, MMM d, y').format(booking.date),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: booking.notes != null ? Text(booking.notes!) : null,
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _getStatusColor(booking.status),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    booking.status.name.toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Color _getStatusColor(BookingStatus status) {
    switch (status) {
      case BookingStatus.confirmed:
        return Colors.green;
      case BookingStatus.pending:
        return Colors.orange;
      case BookingStatus.cancelled:
        return Colors.red;
    }
    return Colors.grey;
  }
}
