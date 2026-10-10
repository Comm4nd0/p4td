import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/vehicle.dart';
import 'package:paws4thoughtdogs/models/vehicle_maintenance_record.dart';
import 'package:paws4thoughtdogs/screens/add_edit_vehicle_screen.dart';
import 'package:paws4thoughtdogs/screens/fleet_screen.dart';
import 'package:paws4thoughtdogs/screens/vehicle_detail_screen.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/utils/date_formats.dart';

class _FleetService extends MockDataService {
  Vehicle vehicle = Vehicle.fromJson({
    'id': 1,
    'name': 'Blue Van',
    'registration': 'AB12 CDE',
    'mot_due_date': '2027-01-01',
    'service_due_date': '2027-02-01',
    'tax_due_date': '2027-03-01',
    'tax_status': 'due_soon',
  });
  DateTime? savedTaxDate;
  DateTime? savedMotDate;
  DateTime? savedServiceDate;
  String? savedNotes;
  bool created = false;

  @override
  Future<Vehicle> getVehicle(int id) async => vehicle;

  @override
  Future<List<Vehicle>> getVehicles() async => [vehicle];

  @override
  Future<List<VehicleMaintenanceRecord>> getVehicleHistory(
          int vehicleId) async =>
      [
        VehicleMaintenanceRecord.fromJson({
          'id': 1,
          'event_type': 'TAX',
          'new_due_date': '2027-03-01',
          'created_at': '2026-03-01T12:00:00Z',
        }),
      ];

  @override
  Future<Vehicle> createVehicle({
    required String name,
    required String registration,
    String? make,
    String? model,
    String? notes,
    String? status,
    DateTime? motDueDate,
    DateTime? serviceDueDate,
    DateTime? taxDueDate,
    Uint8List? imageBytes,
    String? imageName,
  }) async {
    created = true;
    savedTaxDate = taxDueDate;
    return vehicle;
  }

  @override
  Future<Vehicle> updateVehicle(
    int id, {
    String? name,
    String? registration,
    String? make,
    String? model,
    String? notes,
    String? status,
    DateTime? motDueDate,
    DateTime? serviceDueDate,
    DateTime? taxDueDate,
    String? maintenanceNotes,
    Uint8List? imageBytes,
    String? imageName,
  }) async {
    savedTaxDate = taxDueDate;
    savedMotDate = motDueDate;
    savedServiceDate = serviceDueDate;
    savedNotes = maintenanceNotes;
    return vehicle;
  }
}

void main() {
  late _FleetService service;
  setUp(() {
    service = _FleetService();
    getIt.registerSingleton<DataService>(service);
  });
  tearDown(() => getIt.reset());

  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => screen),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('new vehicles can save a tax date', (tester) async {
    await open(tester, const AddEditVehicleScreen());
    await tester.enterText(find.byType(TextFormField).at(0), 'New Van');
    await tester.enterText(find.byType(TextFormField).at(1), 'CD34 EFG');
    await tapVisible(tester, find.text('Tax due date'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add Vehicle'));
    final now = DateTime.now();
    expect(service.created, isTrue);
    expect(service.savedTaxDate, DateTime(now.year, now.month, now.day));
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing preserves and submits all three dates', (tester) async {
    await open(tester, AddEditVehicleScreen(vehicle: service.vehicle));
    await tester.ensureVisible(find.text('Tax due date'));
    expect(find.text(ukDate(service.vehicle.taxDueDate!)), findsOneWidget);
    await tapVisible(tester, find.text('Save Changes'));
    expect(service.savedTaxDate, service.vehicle.taxDueDate);
    expect(service.savedMotDate, service.vehicle.motDueDate);
    expect(service.savedServiceDate, service.vehicle.serviceDueDate);
    expect(tester.takeException(), isNull);
  });

  testWidgets('managers can set the tax date and record renewal',
      (tester) async {
    await open(tester,
        const VehicleDetailScreen(vehicleId: 1, canManageVehicles: true));
    expect(find.text('Tax due soon'), findsOneWidget);
    await tapVisible(tester, find.byTooltip('Set Tax due date'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Tax renewed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.savedTaxDate, service.vehicle.taxDueDate);
    expect(service.savedMotDate, isNull);
    expect(service.savedServiceDate, isNull);
    expect(service.savedNotes, 'Tax renewed');
    await tapVisible(
        tester, find.byTooltip('Mark Tax done — next due in a year'));
    await tester.tap(find.text('Mark done'));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    expect(service.savedTaxDate, DateTime(now.year + 1, now.month, now.day));
    expect(tester.takeException(), isNull);
  });

  testWidgets('staff can see tax history but cannot edit the date',
      (tester) async {
    await open(tester, const VehicleDetailScreen(vehicleId: 1));
    expect(find.text('Tax due soon'), findsOneWidget);
    expect(find.byTooltip('Set Tax due date'), findsNothing);
    expect(find.byTooltip('Mark Tax done — next due in a year'), findsNothing);
    await tester.ensureVisible(find.text(
        'Tax due date updated to ${ukDate(service.vehicle.taxDueDate!)}'));
    expect(
        find.text(
            'Tax due date updated to ${ukDate(service.vehicle.taxDueDate!)}'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fleet list shows the tax date and due badge', (tester) async {
    await open(tester, const FleetScreen());
    expect(find.text('Tax due soon'), findsOneWidget);
    expect(find.textContaining('Tax: ${ukDate(service.vehicle.taxDueDate!)}'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('older vehicle responses without tax fields still load', () {
    final vehicle =
        Vehicle.fromJson({'id': 2, 'name': 'Old Van', 'registration': 'OLD1'});
    expect(vehicle.taxDueDate, isNull);
    expect(vehicle.taxStatus, isNull);
  });
}
