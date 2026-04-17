import 'package:intl/intl.dart';

final DateFormat _ukDate = DateFormat('dd/MM/yy');
final DateFormat _ukDateTime = DateFormat('dd/MM/yy HH:mm');
final DateFormat _ukDateWithDay = DateFormat('EEE dd/MM/yy');
final DateFormat _ukDateTimeWithDay = DateFormat('EEE dd/MM/yy HH:mm');

String ukDate(DateTime d) => _ukDate.format(d);
String ukDateTime(DateTime d) => _ukDateTime.format(d);
String ukDateWithDay(DateTime d) => _ukDateWithDay.format(d);
String ukDateTimeWithDay(DateTime d) => _ukDateTimeWithDay.format(d);
