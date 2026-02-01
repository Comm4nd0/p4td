enum BookingStatus { confirmed, pending, cancelled }

class Booking {
  final String id;
  final String dogId;
  final DateTime date;
  final BookingStatus status;
  final String? notes;

  Booking({
    required this.id,
    required this.dogId,
    required this.date,
    required this.status,
    this.notes,
  });
}
