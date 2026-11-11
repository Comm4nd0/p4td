import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/models/dashboard_layout.dart';
import 'package:paws4thoughtdogs/models/dog_birthday.dart';
import 'package:paws4thoughtdogs/screens/dashboard/birthday_section.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('parses a row and words the age', () {
    final b = DogBirthday.fromJson({
      'dog_id': 7,
      'dog_name': 'Rex',
      'dog_profile_image': null,
      'age': 3,
      'boarding': true,
      'staff_member_name': 'Alice',
      'photographed': false,
    });
    expect(b.dogId, 7);
    expect(b.boarding, isTrue);
    expect(b.ordinalAge, '3rd');
    expect(const DogBirthday(dogId: 1, dogName: 'a', age: 1).ordinalAge, '1st');
    expect(const DogBirthday(dogId: 1, dogName: 'a', age: 2).ordinalAge, '2nd');
    expect(const DogBirthday(dogId: 1, dogName: 'a', age: 11).ordinalAge, '11th');
    expect(const DogBirthday(dogId: 1, dogName: 'a', age: 12).ordinalAge, '12th');
  });

  test('a saved layout from before birthdays gets the section before photo tagging', () {
    final order = resolveDashboardLayout(
        ['staff', 'photo_tagging', 'handovers', 'overview']);
    expect(order, contains(DashboardSection.birthdays));
    expect(order.indexOf(DashboardSection.birthdays),
        order.indexOf(DashboardSection.handovers) + 1);
  });

  testWidgets('draws nothing with no birthdays or before loading', (tester) async {
    await tester.pumpWidget(_host(const Column(children: [
      BirthdaySection(birthdays: null, isToday: true),
      BirthdaySection(birthdays: [], isToday: true),
    ])));
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('today asks for the photo and offers the feed', (tester) async {
    var openedFeed = false;
    DogBirthday? tapped;
    await tester.pumpWidget(_host(BirthdaySection(
      birthdays: const [
        DogBirthday(dogId: 1, dogName: 'Rex', age: 3, staffMemberName: 'Alice'),
      ],
      isToday: true,
      onDogTap: (b) => tapped = b,
      onOpenFeed: () => openedFeed = true,
    )));
    expect(find.text("It's Rex's 3rd birthday today"), findsOneWidget);
    expect(find.text('With Alice · Remember a birthday photo'), findsOneWidget);
    await tester.tap(find.text('Post a photo'));
    expect(openedFeed, isTrue);
    await tester.tap(find.text('Rex'));
    expect(tapped?.dogId, 1);
  });

  testWidgets('a photographed dog is ticked off and the button goes', (tester) async {
    await tester.pumpWidget(_host(BirthdaySection(
      birthdays: const [
        DogBirthday(dogId: 1, dogName: 'Rex', age: 3, photographed: true),
      ],
      isToday: true,
      onOpenFeed: () {},
    )));
    expect(find.text('Photo posted'), findsOneWidget);
    expect(find.text('Post a photo'), findsNothing);
  });

  testWidgets('another day only says whose birthday it is', (tester) async {
    await tester.pumpWidget(_host(BirthdaySection(
      birthdays: const [
        DogBirthday(dogId: 1, dogName: 'Rex', age: 3),
        DogBirthday(dogId: 2, dogName: 'Bella', age: 1, boarding: true),
      ],
      isToday: false,
      onOpenFeed: () {},
    )));
    expect(find.text('2 birthdays coming up'), findsOneWidget);
    expect(find.text('Turns 1 · Boarding'), findsOneWidget);
    expect(find.text('Post a photo'), findsNothing);
    expect(find.textContaining('Remember'), findsNothing);
  });
}
