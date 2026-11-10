/// Server timestamps, read one way.
///
/// The API sends every *moment* — `created_at`, `approved_at`, `occurred_at`,
/// `taken_at`, … — with its UTC offset ("2026-06-01T09:30:00+01:00", or a
/// trailing "Z"). `DateTime.parse` turns those into a UTC value, and a UTC
/// value prints UTC hours: in summer every time read an hour early, and
/// anything in the hour after midnight landed on the day before. Each screen
/// used to remember (or forget) to call `.toLocal()`; now the models hand out
/// local time and no screen has to.
///
/// Use these for moments only. A calendar date ("2026-06-01", a day the dog
/// is in) has no offset and must stay the day it says — `parseApiDate` in
/// dog.dart reads those. Passing a date-only string here is harmless (it
/// parses as local midnight and is returned unchanged), but it says the wrong
/// thing about the field.
library;

/// [value] as a local-time [DateTime], or null when it is missing, empty or
/// not a timestamp. Calling `.toLocal()` on the result again changes nothing.
DateTime? parseApiDateTime(dynamic value) {
  if (value == null) return null;
  final text = value.toString();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text)?.toLocal();
}

/// For a timestamp the model cannot do without (`created_at` and the like).
///
/// The server always sends these, but the app and server ship separately and
/// one row with the field missing used to throw and take the whole list — the
/// feed, the inbox — down with it. Such a row is given the earliest possible
/// time instead: it sorts last and is plainly wrong on screen, which is better
/// than an empty screen.
DateTime requireApiDateTime(dynamic value) =>
    parseApiDateTime(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
