"""/api/daily-assignments/birthdays/ — the dogs in on a day whose birthday it
is, which the staff dashboard shows so the team takes a photo."""
from datetime import date, timedelta

from django.contrib.auth.models import User
from django.test import TestCase
from rest_framework.test import APIClient

from .models import BoardingRequest, DailyDogAssignment, Dog, GroupMedia
from .views import _is_birthday


def next_weekday(day):
    while day.isoweekday() > 5:
        day += timedelta(days=1)
    return day


class IsBirthdayTests(TestCase):
    def test_same_day_and_month_in_a_later_year(self):
        self.assertTrue(_is_birthday(date(2022, 5, 14), date(2026, 5, 14)))
        self.assertFalse(_is_birthday(date(2022, 5, 14), date(2026, 5, 15)))

    def test_the_day_a_dog_is_born_is_not_a_birthday(self):
        self.assertFalse(_is_birthday(date(2026, 5, 14), date(2026, 5, 14)))

    def test_leap_day_dogs_celebrate_on_the_28th_without_a_29th(self):
        born = date(2024, 2, 29)
        self.assertTrue(_is_birthday(born, date(2027, 2, 28)))
        self.assertFalse(_is_birthday(born, date(2027, 3, 1)))
        self.assertTrue(_is_birthday(born, date(2028, 2, 29)))
        self.assertFalse(_is_birthday(born, date(2028, 2, 28)))

    def test_no_date_of_birth(self):
        self.assertFalse(_is_birthday(None, date(2026, 5, 14)))


class BirthdaysEndpointTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(
            username='staff', password='pw', is_staff=True, first_name='Alice')
        # A weekday, never 29 Feb: the dogs below are born on this month/day.
        self.day = next_weekday(date.today() + timedelta(days=7))
        if (self.day.month, self.day.day) == (2, 29):
            self.day = next_weekday(self.day + timedelta(days=1))
        self.client = APIClient()
        self.client.force_authenticate(self.staff)

    def _dog(self, name, years_old=3, **extra):
        born = self.day.replace(year=self.day.year - years_old) if years_old is not None else None
        return Dog.objects.create(owner=self.owner, name=name, date_of_birth=born, **extra)

    def _assign(self, dog, status='ASSIGNED', staff='default'):
        return DailyDogAssignment.objects.create(
            dog=dog, date=self.day, status=status,
            staff_member=self.staff if staff == 'default' else staff)

    def _get(self, day=None):
        resp = self.client.get(
            f'/api/daily-assignments/birthdays/?date={(day or self.day).isoformat()}')
        self.assertEqual(resp.status_code, 200)
        return resp.data

    def test_lists_a_birthday_dog_that_is_in(self):
        self._assign(self._dog('Rex', years_old=3))
        data = self._get()
        self.assertEqual(data['date'], self.day.isoformat())
        self.assertEqual(len(data['birthdays']), 1)
        row = data['birthdays'][0]
        self.assertEqual(row['dog_name'], 'Rex')
        self.assertEqual(row['age'], 3)
        self.assertEqual(row['staff_member_name'], 'Alice')
        self.assertFalse(row['boarding'])
        self.assertFalse(row['photographed'])

    def test_leaves_out_dogs_not_in_that_day(self):
        self._dog('Home today')                       # birthday, but not booked in
        self._assign(self._dog('Removed'), status='REMOVED')
        other = self._dog('Other day')
        Dog.objects.filter(pk=other.pk).update(
            date_of_birth=other.date_of_birth + timedelta(days=40))
        self._assign(other)                           # in, but not its birthday
        self._assign(self._dog('No date', years_old=None))
        self.assertEqual(self._get()['birthdays'], [])

    def test_unassigned_dog_still_counts_as_in(self):
        self._assign(self._dog('Waiting'), status='UNASSIGNED', staff=None)
        rows = self._get()['birthdays']
        self.assertEqual([r['dog_name'] for r in rows], ['Waiting'])
        self.assertEqual(rows[0]['staff_member_name'], '')

    def test_boarding_dog_is_listed_without_a_board_row(self):
        dog = self._dog('Boarder')
        stay = BoardingRequest.objects.create(
            owner=self.owner, start_date=self.day - timedelta(days=1),
            end_date=self.day + timedelta(days=1), status='APPROVED')
        stay.dogs.add(dog)
        pending = self._dog('Pending boarder')
        ask = BoardingRequest.objects.create(
            owner=self.owner, start_date=self.day, end_date=self.day, status='PENDING')
        ask.dogs.add(pending)
        rows = self._get()['birthdays']
        self.assertEqual([r['dog_name'] for r in rows], ['Boarder'])
        self.assertTrue(rows[0]['boarding'])

    def test_photographed_once_tagged_in_that_days_feed(self):
        today = date.today()
        dog = Dog.objects.create(
            owner=self.owner, name='Star', date_of_birth=today.replace(year=today.year - 2)
            if (today.month, today.day) != (2, 29) else date(today.year - 4, 2, 29))
        DailyDogAssignment.objects.create(
            dog=dog, date=today, status='ASSIGNED', staff_member=self.staff)
        self.assertFalse(self._get(today)['birthdays'][0]['photographed'])
        media = GroupMedia.objects.create(
            uploaded_by=self.staff, media_type='PHOTO', caption='party hat')
        media.tagged_dogs.set([dog])
        self.assertTrue(self._get(today)['birthdays'][0]['photographed'])

    def test_owners_cannot_read_it(self):
        self.client.force_authenticate(self.owner)
        resp = self.client.get('/api/daily-assignments/birthdays/')
        self.assertEqual(resp.status_code, 403)
