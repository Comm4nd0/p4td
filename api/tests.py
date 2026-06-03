from datetime import date, timedelta
from django.test import TestCase
from django.contrib.auth.models import User
from rest_framework.test import APIClient
from .models import (
    Dog, DateChangeRequest, DateChangeRequestHistory,
    BoardingRequest, DailyDogAssignment, DogWeekdayPickup,
    SupportQuery, SupportMessage,
    ClosureDay, DogNote, StaffAvailability, DayOffRequest,
    GroupMedia,
)
from django.utils import timezone


class DateChangeRequestStatusTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Fido')
        self.req = DateChangeRequest.objects.create(dog=self.dog, request_type='CANCEL', original_date='2026-02-10')
        self.client = APIClient()

    def test_non_staff_cannot_change_status(self):
        self.client.login(username='owner', password='pw')
        url = f"/api/date-change-requests/{self.req.id}/change_status/"
        resp = self.client.post(url, {'status': 'APPROVED'}, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_approve(self):
        self.client.login(username='staff', password='pw')
        url = f"/api/date-change-requests/{self.req.id}/change_status/"
        resp = self.client.post(url, {'status': 'APPROVED'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.req.refresh_from_db()
        self.assertEqual(self.req.status, 'APPROVED')
        self.assertIsNotNone(self.req.approved_by)
        self.assertIsNotNone(self.req.approved_at)
        hist = DateChangeRequestHistory.objects.filter(request=self.req).first()
        self.assertIsNotNone(hist)
        self.assertEqual(hist.from_status, 'PENDING')
        self.assertEqual(hist.to_status, 'APPROVED')

    def test_staff_can_deny(self):
        self.client.login(username='staff', password='pw')
        url = f"/api/date-change-requests/{self.req.id}/change_status/"
        resp = self.client.post(url, {'status': 'DENIED'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.req.refresh_from_db()
        self.assertEqual(self.req.status, 'DENIED')

    def test_invalid_status_rejected(self):
        self.client.login(username='staff', password='pw')
        url = f"/api/date-change-requests/{self.req.id}/change_status/"
        resp = self.client.post(url, {'status': 'INVALID'}, format='json')
        self.assertEqual(resp.status_code, 400)


class DateChangeRequestCreateTests(TestCase):
    """Owner-created date changes go to PENDING; staff-created ones auto-approve."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Fido')
        self.client = APIClient()

    def _post(self, **kwargs):
        payload = {'dog': self.dog.id, **kwargs}
        return self.client.post('/api/date-change-requests/', payload, format='json')

    def test_owner_cancel_stays_pending(self):
        self.client.login(username='owner', password='pw')
        resp = self._post(request_type='CANCEL', original_date='2026-05-10')
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'PENDING')
        self.assertIsNone(req.approved_by)

    def test_staff_cancel_auto_approves_and_unassigns(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date='2026-05-10', status='ASSIGNED'
        )
        self.client.login(username='staff', password='pw')
        resp = self._post(request_type='CANCEL', original_date='2026-05-10')
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')
        self.assertEqual(req.approved_by, self.staff)
        self.assertIsNotNone(req.approved_at)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date='2026-05-10').exists()
        )
        hist = DateChangeRequestHistory.objects.filter(request=req).first()
        self.assertIsNotNone(hist)
        self.assertEqual(hist.from_status, 'PENDING')
        self.assertEqual(hist.to_status, 'APPROVED')

    def test_staff_change_auto_approves(self):
        self.client.login(username='staff', password='pw')
        resp = self._post(
            request_type='CHANGE',
            original_date='2026-05-10',
            new_date='2026-05-12',
        )
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')

    def test_staff_change_unassigns_original_date(self):
        # A staff CHANGE should free up the original date (like a cancel); the
        # new date is surfaced separately by the roster queries.
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date='2026-05-10', status='ASSIGNED'
        )
        self.client.login(username='staff', password='pw')
        resp = self._post(
            request_type='CHANGE',
            original_date='2026-05-10',
            new_date='2026-05-12',
        )
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date='2026-05-10').exists()
        )

    def test_staff_add_day_auto_approves(self):
        self.client.login(username='staff', password='pw')
        resp = self._post(request_type='ADD_DAY', new_date='2026-05-15')
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')


class DogCRUDTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.client = APIClient()

    def test_staff_can_create_dog(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/dogs/', {'name': 'Buddy', 'owner': self.owner.id}, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['name'], 'Buddy')

    def test_owner_cannot_create_dog(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/dogs/', {'name': 'Buddy'}, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_owner_sees_own_dogs_only(self):
        other = User.objects.create_user(username='other', password='pw')
        Dog.objects.create(owner=self.owner, name='MyDog')
        Dog.objects.create(owner=other, name='OtherDog')
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/dogs/')
        self.assertEqual(resp.status_code, 200)
        names = [d['name'] for d in resp.data]
        self.assertIn('MyDog', names)
        self.assertNotIn('OtherDog', names)

    def test_staff_sees_all_dogs(self):
        other = User.objects.create_user(username='other', password='pw')
        Dog.objects.create(owner=self.owner, name='Dog1')
        Dog.objects.create(owner=other, name='Dog2')
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/dogs/')
        self.assertEqual(resp.status_code, 200)
        names = [d['name'] for d in resp.data]
        self.assertIn('Dog1', names)
        self.assertIn('Dog2', names)

    def test_staff_can_delete_dog(self):
        dog = Dog.objects.create(owner=self.owner, name='ToDelete')
        self.client.login(username='staff', password='pw')
        resp = self.client.delete(f'/api/dogs/{dog.id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(Dog.objects.filter(id=dog.id).exists())

    def test_owner_cannot_delete_dog(self):
        dog = Dog.objects.create(owner=self.owner, name='KeepMe')
        self.client.login(username='owner', password='pw')
        resp = self.client.delete(f'/api/dogs/{dog.id}/')
        self.assertEqual(resp.status_code, 403)
        self.assertTrue(Dog.objects.filter(id=dog.id).exists())

    def test_update_dog_owner_requires_approval(self):
        """Non-staff dog updates are submitted for approval (202), not applied."""
        dog = Dog.objects.create(owner=self.owner, name='OldName')
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/dogs/{dog.id}/', {'name': 'NewName'}, format='json')
        self.assertEqual(resp.status_code, 202)
        dog.refresh_from_db()
        # Name should NOT have changed yet
        self.assertEqual(dog.name, 'OldName')
        # A change request should have been created
        from .models import DogProfileChangeRequest
        cr = DogProfileChangeRequest.objects.filter(dog=dog, status='PENDING').first()
        self.assertIsNotNone(cr)
        self.assertEqual(cr.proposed_changes.get('name'), 'NewName')

    def test_update_dog_staff_applies_immediately(self):
        """Staff dog updates are applied directly (200)."""
        dog = Dog.objects.create(owner=self.owner, name='OldName')
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(f'/api/dogs/{dog.id}/', {'name': 'NewName'}, format='json')
        self.assertEqual(resp.status_code, 200)
        dog.refresh_from_db()
        self.assertEqual(dog.name, 'NewName')


class DogSpayStatusTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.client = APIClient()

    def test_new_dog_defaults_is_spayed_false(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/dogs/', {'name': 'NewPup', 'owner': self.owner.id}, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(resp.data['is_spayed'])

    def test_owner_can_view_is_spayed(self):
        Dog.objects.create(owner=self.owner, name='Fido', is_spayed=True)
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/dogs/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        self.assertIn('is_spayed', resp.data[0])
        self.assertTrue(resp.data[0]['is_spayed'])

    def test_owner_cannot_change_is_spayed(self):
        """Owner PATCH with is_spayed must not change the dog (not whitelisted)."""
        dog = Dog.objects.create(owner=self.owner, name='Fido', is_spayed=False)
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/dogs/{dog.id}/', {'is_spayed': True}, format='json')
        dog.refresh_from_db()
        self.assertFalse(dog.is_spayed)
        # No change request should be created for is_spayed alone
        from .models import DogProfileChangeRequest
        cr = DogProfileChangeRequest.objects.filter(dog=dog, status='PENDING').first()
        if cr is not None:
            self.assertNotIn('is_spayed', cr.proposed_changes)

    def test_staff_can_change_is_spayed(self):
        dog = Dog.objects.create(owner=self.owner, name='Fido', is_spayed=False)
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(f'/api/dogs/{dog.id}/', {'is_spayed': True}, format='json')
        self.assertEqual(resp.status_code, 200)
        dog.refresh_from_db()
        self.assertTrue(dog.is_spayed)

    def test_unspayed_males_endpoint(self):
        today = timezone.now().date()
        two_years_ago = today - timedelta(days=730)
        six_months_ago = today - timedelta(days=180)

        target = Dog.objects.create(
            owner=self.owner, name='UnspayedAdultMale',
            sex='M', date_of_birth=two_years_ago, is_spayed=False,
        )
        Dog.objects.create(
            owner=self.owner, name='YoungMale',
            sex='M', date_of_birth=six_months_ago, is_spayed=False,
        )
        Dog.objects.create(
            owner=self.owner, name='UnspayedFemale',
            sex='F', date_of_birth=two_years_ago, is_spayed=False,
        )
        Dog.objects.create(
            owner=self.owner, name='SpayedMale',
            sex='M', date_of_birth=two_years_ago, is_spayed=True,
        )
        Dog.objects.create(
            owner=self.owner, name='UnknownDobMale',
            sex='M', date_of_birth=None, is_spayed=False,
        )

        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/dogs/unspayed_males/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['count'], 1)
        names = [d['name'] for d in resp.data['dogs']]
        self.assertEqual(names, ['UnspayedAdultMale'])
        self.assertEqual(resp.data['dogs'][0]['id'], target.id)

    def test_unspayed_males_endpoint_requires_staff(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/dogs/unspayed_males/')
        self.assertEqual(resp.status_code, 403)


class DailyAssignmentTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.staff.profile.can_assign_dogs = True
        self.staff.profile.save()
        self.dog = Dog.objects.create(owner=self.owner, name='Rex', daycare_days=[date.today().isoweekday()])
        self.client = APIClient()

    def test_non_staff_cannot_access_assignments(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/daily-assignments/')
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_view_assignments(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/daily-assignments/')
        self.assertEqual(resp.status_code, 200)

    def test_assign_to_me(self):
        self.client.login(username='staff', password='pw')
        today_str = date.today().isoformat()
        resp = self.client.post('/api/daily-assignments/assign_to_me/', {
            'dog_ids': [self.dog.id],
            'date': today_str,
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertTrue(DailyDogAssignment.objects.filter(
            dog=self.dog, staff_member=self.staff, date=date.today()
        ).exists())

    def test_assign_far_in_the_future(self):
        """Staff can edit the daycare calendar well beyond the old 14-day
        window — there is no upper bound on how far ahead a day can be set."""
        self.client.login(username='staff', password='pw')
        far_date = date.today() + timedelta(days=400)
        resp = self.client.post('/api/daily-assignments/assign_to_me/', {
            'dog_ids': [self.dog.id],
            'date': far_date.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertTrue(DailyDogAssignment.objects.filter(
            dog=self.dog, staff_member=self.staff, date=far_date
        ).exists())

    def test_view_roster_far_in_the_future(self):
        """The roster can be viewed arbitrarily far ahead (no 14-day cap)."""
        self.client.login(username='staff', password='pw')
        far_date = (date.today() + timedelta(days=400)).isoformat()
        resp = self.client.get(f'/api/daily-assignments/today/?date={far_date}')
        self.assertEqual(resp.status_code, 200)

    def test_mark_removed_far_in_the_future(self):
        """Staff can mark a dog as not attending a far-future day."""
        self.client.login(username='staff', password='pw')
        far_date = date.today() + timedelta(days=400)
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id,
            'date': far_date.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 204)
        self.assertTrue(DailyDogAssignment.objects.filter(
            dog=self.dog, date=far_date, status='REMOVED'
        ).exists())

    def test_update_assignment_status(self):
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=date.today()
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/daily-assignments/{assignment.id}/update_status/', {
            'status': 'PICKED_UP',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        assignment.refresh_from_db()
        self.assertEqual(assignment.status, 'PICKED_UP')

    def test_unassigned_dogs(self):
        """Skip on SQLite — JSON contains lookup requires PostgreSQL."""
        from django.db import connection
        if connection.vendor == 'sqlite':
            self.skipTest('JSON contains lookup not supported on SQLite')
        self.client.login(username='staff', password='pw')
        today_str = date.today().isoformat()
        resp = self.client.get(f'/api/daily-assignments/unassigned_dogs/?date={today_str}')
        self.assertEqual(resp.status_code, 200)
        dog_ids = [d['id'] for d in resp.data]
        self.assertIn(self.dog.id, dog_ids)


class WeekdayRosterTests(TestCase):
    """Tests for the persistent DogWeekdayPickup roster and related flows."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff_a = User.objects.create_user(username='staffa', password='pw', is_staff=True, first_name='Alice')
        self.staff_a.profile.can_assign_dogs = True
        self.staff_a.profile.save()
        self.staff_b = User.objects.create_user(username='staffb', password='pw', is_staff=True, first_name='Bob')
        self.staff_b.profile.can_assign_dogs = True
        self.staff_b.profile.save()

        self.today = date.today()
        self.today_weekday = self.today.isoweekday()
        self.dog = Dog.objects.create(
            owner=self.owner,
            name='Rex',
            daycare_days=[self.today_weekday],
            schedule_type='weekly',
        )
        self.client = APIClient()

    # --- roster writes on assign ---

    def test_assign_to_me_creates_roster(self):
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/assign_to_me/', {
            'dog_ids': [self.dog.id],
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertTrue(DogWeekdayPickup.objects.filter(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        ).exists())

    def test_assign_dogs_creates_roster(self):
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/assign_dogs/', {
            'dog_ids': [self.dog.id],
            'staff_member_id': self.staff_b.id,
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        entry = DogWeekdayPickup.objects.get(dog=self.dog, weekday=self.today_weekday)
        self.assertEqual(entry.staff_member, self.staff_b)

    def test_assign_to_me_skips_roster_for_ad_hoc(self):
        self.dog.schedule_type = 'ad_hoc'
        self.dog.save()
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/assign_to_me/', {
            'dog_ids': [self.dog.id],
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(DogWeekdayPickup.objects.filter(dog=self.dog).exists())
        self.assertTrue(DailyDogAssignment.objects.filter(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        ).exists())

    def test_assign_to_me_does_not_clobber_existing_roster(self):
        # staff_a owns the roster
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        self.client.login(username='staffb', password='pw')
        resp = self.client.post('/api/daily-assignments/assign_to_me/', {
            'dog_ids': [self.dog.id],
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        # Roster is unchanged
        entry = DogWeekdayPickup.objects.get(dog=self.dog, weekday=self.today_weekday)
        self.assertEqual(entry.staff_member, self.staff_a)
        # But daily assignment was still created for staff_b
        self.assertTrue(DailyDogAssignment.objects.filter(
            dog=self.dog, staff_member=self.staff_b, date=self.today
        ).exists())

    # --- lazy materialization ---

    def test_today_lazy_materializes_from_roster(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        self.assertEqual(DailyDogAssignment.objects.count(), 0)
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        self.assertEqual(resp.data[0]['dog'], self.dog.id)
        self.assertEqual(resp.data[0]['staff_member'], self.staff_a.id)
        self.assertTrue(DailyDogAssignment.objects.filter(
            dog=self.dog, date=self.today
        ).exists())

    def test_my_assignments_lazy_materializes(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(f'/api/daily-assignments/my_assignments/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)

    def test_today_skips_closed_days(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        ClosureDay.objects.create(date=self.today, closure_type='CLOSED')
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        # No rows materialized on a closed day.
        self.assertFalse(DailyDogAssignment.objects.filter(date=self.today).exists())

    def test_today_skips_dogs_with_cancel_request(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        DateChangeRequest.objects.create(
            dog=self.dog,
            request_type='CANCEL',
            original_date=self.today,
            status='APPROVED',
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(DailyDogAssignment.objects.filter(
            dog=self.dog, date=self.today
        ).exists())

    def test_today_skips_dog_with_change_away_from_date(self):
        # A CHANGE moving away from today should free up today (like a cancel).
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        DateChangeRequest.objects.create(
            dog=self.dog,
            request_type='CHANGE',
            original_date=self.today,
            new_date=self.today + timedelta(days=1),
            status='APPROVED',
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(DailyDogAssignment.objects.filter(
            dog=self.dog, date=self.today
        ).exists())

    def test_unassigned_includes_dog_changed_to_date(self):
        # A CHANGE moving *to* a date should surface the dog as scheduled for
        # that date, even when it's not one of the dog's recurring weekdays.
        from django.db import connection
        if connection.vendor == 'sqlite':
            self.skipTest('JSON contains lookup not supported on SQLite')
        # Pick a target weekday the dog does NOT normally attend.
        target = self.today + timedelta(days=1)
        while target.isoweekday() in self.dog.daycare_days:
            target += timedelta(days=1)
        DateChangeRequest.objects.create(
            dog=self.dog,
            request_type='CHANGE',
            original_date=self.today,
            new_date=target,
            status='APPROVED',
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(
            f'/api/daily-assignments/unassigned_dogs/?date={target.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertIn(self.dog.id, [d['id'] for d in resp.data])

    def test_today_skips_dropped_weekday(self):
        # Roster entry exists but the dog no longer attends on that weekday.
        other_weekday = (self.today_weekday % 7) + 1
        self.dog.daycare_days = [other_weekday]
        self.dog.save()
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(DailyDogAssignment.objects.filter(
            dog=self.dog, date=self.today
        ).exists())

    # --- reassign scope ---

    def test_reassign_just_this_day_does_not_touch_roster(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        # Future row for the same weekday
        future_date = self.today + timedelta(weeks=1)
        future = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=future_date
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post(f'/api/daily-assignments/{assignment.id}/reassign/', {
            'staff_member_id': self.staff_b.id,
            'scope': 'just_this_day',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        assignment.refresh_from_db()
        future.refresh_from_db()
        self.assertEqual(assignment.staff_member, self.staff_b)
        self.assertEqual(future.staff_member, self.staff_a)  # unchanged
        roster = DogWeekdayPickup.objects.get(dog=self.dog, weekday=self.today_weekday)
        self.assertEqual(roster.staff_member, self.staff_a)  # unchanged

    def test_reassign_from_now_on_updates_roster_and_future(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        future = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today + timedelta(weeks=1)
        )
        picked_up_future = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a,
            date=self.today + timedelta(weeks=2),
            status='PICKED_UP',
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post(f'/api/daily-assignments/{assignment.id}/reassign/', {
            'staff_member_id': self.staff_b.id,
            'scope': 'from_now_on',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        assignment.refresh_from_db()
        future.refresh_from_db()
        picked_up_future.refresh_from_db()
        self.assertEqual(assignment.staff_member, self.staff_b)
        self.assertEqual(future.staff_member, self.staff_b)
        self.assertEqual(picked_up_future.staff_member, self.staff_a)  # PICKED_UP untouched
        roster = DogWeekdayPickup.objects.get(dog=self.dog, weekday=self.today_weekday)
        self.assertEqual(roster.staff_member, self.staff_b)

    def test_reassign_invalid_scope(self):
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post(f'/api/daily-assignments/{assignment.id}/reassign/', {
            'staff_member_id': self.staff_b.id,
            'scope': 'forever',
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    # --- unassign scope ---

    def test_unassign_just_this_day_keeps_roster(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        future = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today + timedelta(weeks=1)
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post(f'/api/daily-assignments/{assignment.id}/unassign/', {
            'scope': 'just_this_day',
        }, format='json')
        self.assertEqual(resp.status_code, 204)
        # Assignment is kept but marked as REMOVED (not deleted) so that
        # _materialize_roster_for_date does not re-create it.
        assignment.refresh_from_db()
        self.assertEqual(assignment.status, 'REMOVED')
        self.assertTrue(DailyDogAssignment.objects.filter(pk=future.pk).exists())
        self.assertTrue(DogWeekdayPickup.objects.filter(
            dog=self.dog, weekday=self.today_weekday
        ).exists())

    def test_unassign_from_now_on_clears_roster(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        future = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today + timedelta(weeks=1)
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post(f'/api/daily-assignments/{assignment.id}/unassign/', {
            'scope': 'from_now_on',
        }, format='json')
        self.assertEqual(resp.status_code, 204)
        self.assertFalse(DailyDogAssignment.objects.filter(pk=assignment.pk).exists())
        self.assertFalse(DailyDogAssignment.objects.filter(pk=future.pk).exists())
        self.assertFalse(DogWeekdayPickup.objects.filter(
            dog=self.dog, weekday=self.today_weekday
        ).exists())

    def test_unassigned_dog_returns_to_unassigned_pool(self):
        from django.db import connection
        if connection.vendor == 'sqlite':
            self.skipTest('JSON contains lookup not supported on SQLite')
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        self.client.login(username='staffa', password='pw')
        unassign_resp = self.client.post(
            f'/api/daily-assignments/{assignment.id}/unassign/',
            {'scope': 'just_this_day'}, format='json',
        )
        self.assertEqual(unassign_resp.status_code, 204)

        resp = self.client.get(
            f'/api/daily-assignments/unassigned_dogs/?date={self.today.isoformat()}'
        )
        self.assertEqual(resp.status_code, 200)
        dog_ids = [d['id'] for d in resp.data]
        self.assertIn(self.dog.id, dog_ids)

    def test_reassign_after_unassign_reactivates_row(self):
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        self.client.login(username='staffa', password='pw')
        self.client.post(
            f'/api/daily-assignments/{assignment.id}/unassign/',
            {'scope': 'just_this_day'}, format='json',
        )
        assignment.refresh_from_db()
        self.assertEqual(assignment.status, 'REMOVED')

        resp = self.client.post('/api/daily-assignments/assign_dogs/', {
            'dog_ids': [self.dog.id],
            'staff_member_id': self.staff_b.id,
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)

        rows = DailyDogAssignment.objects.filter(dog=self.dog, date=self.today)
        self.assertEqual(rows.count(), 1)
        revived = rows.get()
        self.assertEqual(revived.pk, assignment.pk)
        self.assertEqual(revived.status, 'ASSIGNED')
        self.assertEqual(revived.staff_member, self.staff_b)

    def test_materialize_roster_does_not_revive_removed(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        self.client.login(username='staffa', password='pw')
        self.client.post(
            f'/api/daily-assignments/{assignment.id}/unassign/',
            {'scope': 'just_this_day'}, format='json',
        )

        resp = self.client.get(
            f'/api/daily-assignments/today/?date={self.today.isoformat()}'
        )
        self.assertEqual(resp.status_code, 200)
        # The REMOVED row is hidden from `today`, and materialization must not
        # insert a duplicate or flip the status back.
        self.assertEqual(len(resp.data), 0)
        rows = DailyDogAssignment.objects.filter(dog=self.dog, date=self.today)
        self.assertEqual(rows.count(), 1)
        self.assertEqual(rows.get().status, 'REMOVED')

    # --- mark_removed (skip a rostered dog without first assigning) ---

    def test_mark_removed_creates_removed_row_for_unassigned_dog(self):
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id,
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 204)
        rows = DailyDogAssignment.objects.filter(dog=self.dog, date=self.today)
        self.assertEqual(rows.count(), 1)
        self.assertEqual(rows.get().status, 'REMOVED')

    def test_mark_removed_hides_dog_from_today_and_unassigned(self):
        from django.db import connection
        self.client.login(username='staffa', password='pw')
        self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id,
            'date': self.today.isoformat(),
        }, format='json')
        today_resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(today_resp.status_code, 200)
        self.assertEqual(today_resp.data, [])
        if connection.vendor != 'sqlite':
            unassigned_resp = self.client.get(
                f'/api/daily-assignments/unassigned_dogs/?date={self.today.isoformat()}'
            )
            self.assertEqual(unassigned_resp.status_code, 200)
            dog_ids = [d['id'] for d in unassigned_resp.data]
            self.assertNotIn(self.dog.id, dog_ids)

    def test_mark_removed_overwrites_existing_assignment(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today, status='ASSIGNED'
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id,
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 204)
        rows = DailyDogAssignment.objects.filter(dog=self.dog, date=self.today)
        self.assertEqual(rows.count(), 1)
        self.assertEqual(rows.get().status, 'REMOVED')

    def test_mark_removed_requires_can_assign_dogs(self):
        no_perm = User.objects.create_user(username='noperm', password='pw', is_staff=True)
        no_perm.profile.can_assign_dogs = False
        no_perm.profile.save()
        self.client.login(username='noperm', password='pw')
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id,
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 403)
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog, date=self.today).exists())

    def test_mark_removed_validates_input(self):
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id,
        }, format='json')
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id,
            'date': 'not-a-date',
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    # --- swap_staff ---

    def _make_swap_scenario(self):
        """Two dogs on today's weekday assigned to staff_a, plus a Wednesday
        boarding-style row for a different weekday."""
        other_weekday = (self.today_weekday % 7) + 1
        other_date = self.today + timedelta(days=1)
        # We want other_date.isoweekday() == other_weekday
        while other_date.isoweekday() != other_weekday:
            other_date += timedelta(days=1)
        dog2 = Dog.objects.create(
            owner=self.owner,
            name='Buddy',
            daycare_days=[self.today_weekday],
            schedule_type='weekly',
        )
        dog3 = Dog.objects.create(
            owner=self.owner,
            name='Max',
            daycare_days=[other_weekday],
            schedule_type='weekly',
        )
        # Today rows
        a_today_rex = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        a_today_buddy = DailyDogAssignment.objects.create(
            dog=dog2, staff_member=self.staff_a, date=self.today
        )
        # Future same-weekday row
        a_future = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today + timedelta(weeks=1)
        )
        # Different weekday row (simulates boarding / add_day)
        a_other_weekday = DailyDogAssignment.objects.create(
            dog=dog3, staff_member=self.staff_a, date=other_date
        )
        # Roster entries
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        DogWeekdayPickup.objects.create(
            dog=dog2, weekday=self.today_weekday, staff_member=self.staff_a
        )
        DogWeekdayPickup.objects.create(
            dog=dog3, weekday=other_weekday, staff_member=self.staff_a
        )
        return {
            'a_today_rex': a_today_rex,
            'a_today_buddy': a_today_buddy,
            'a_future': a_future,
            'a_other_weekday': a_other_weekday,
            'other_weekday': other_weekday,
            'dog2': dog2,
            'dog3': dog3,
        }

    def test_swap_staff_just_this_day(self):
        s = self._make_swap_scenario()
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/swap_staff/', {
            'from_staff_id': self.staff_a.id,
            'to_staff_id': self.staff_b.id,
            'scope': 'just_this_day',
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['assignment_rows_updated'], 2)
        s['a_today_rex'].refresh_from_db()
        s['a_today_buddy'].refresh_from_db()
        s['a_future'].refresh_from_db()
        s['a_other_weekday'].refresh_from_db()
        self.assertEqual(s['a_today_rex'].staff_member, self.staff_b)
        self.assertEqual(s['a_today_buddy'].staff_member, self.staff_b)
        # Future same-weekday untouched for just_this_day
        self.assertEqual(s['a_future'].staff_member, self.staff_a)
        self.assertEqual(s['a_other_weekday'].staff_member, self.staff_a)
        # Roster untouched
        self.assertEqual(
            DogWeekdayPickup.objects.filter(staff_member=self.staff_b).count(), 0
        )

    def test_swap_staff_this_weekday_forever(self):
        s = self._make_swap_scenario()
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/swap_staff/', {
            'from_staff_id': self.staff_a.id,
            'to_staff_id': self.staff_b.id,
            'scope': 'this_weekday_forever',
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        s['a_today_rex'].refresh_from_db()
        s['a_future'].refresh_from_db()
        s['a_other_weekday'].refresh_from_db()
        self.assertEqual(s['a_today_rex'].staff_member, self.staff_b)
        self.assertEqual(s['a_future'].staff_member, self.staff_b)
        # Other weekday untouched
        self.assertEqual(s['a_other_weekday'].staff_member, self.staff_a)
        # Roster: only today's weekday flipped
        self.assertEqual(
            DogWeekdayPickup.objects.filter(
                weekday=self.today_weekday, staff_member=self.staff_b
            ).count(), 2
        )
        self.assertEqual(
            DogWeekdayPickup.objects.filter(
                weekday=s['other_weekday'], staff_member=self.staff_a
            ).count(), 1
        )

    def test_swap_staff_all_weekdays_forever(self):
        s = self._make_swap_scenario()
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/swap_staff/', {
            'from_staff_id': self.staff_a.id,
            'to_staff_id': self.staff_b.id,
            'scope': 'all_weekdays_forever',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        s['a_today_rex'].refresh_from_db()
        s['a_future'].refresh_from_db()
        s['a_other_weekday'].refresh_from_db()
        self.assertEqual(s['a_today_rex'].staff_member, self.staff_b)
        self.assertEqual(s['a_future'].staff_member, self.staff_b)
        self.assertEqual(s['a_other_weekday'].staff_member, self.staff_b)
        # All roster entries flipped
        self.assertEqual(
            DogWeekdayPickup.objects.filter(staff_member=self.staff_a).count(), 0
        )
        self.assertEqual(
            DogWeekdayPickup.objects.filter(staff_member=self.staff_b).count(), 3
        )

    def test_swap_staff_skips_picked_up_rows(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today, status='PICKED_UP'
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/swap_staff/', {
            'from_staff_id': self.staff_a.id,
            'to_staff_id': self.staff_b.id,
            'scope': 'just_this_day',
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['assignment_rows_updated'], 0)
        self.assertTrue(DailyDogAssignment.objects.filter(
            staff_member=self.staff_a, date=self.today, status='PICKED_UP'
        ).exists())

    def test_swap_staff_requires_permission(self):
        self.staff_a.profile.can_assign_dogs = False
        self.staff_a.profile.save()
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/swap_staff/', {
            'from_staff_id': self.staff_a.id,
            'to_staff_id': self.staff_b.id,
            'scope': 'all_weekdays_forever',
        }, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_swap_staff_validates_scope(self):
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/swap_staff/', {
            'from_staff_id': self.staff_a.id,
            'to_staff_id': self.staff_b.id,
            'scope': 'bogus',
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_swap_staff_rejects_same_staff(self):
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/swap_staff/', {
            'from_staff_id': self.staff_a.id,
            'to_staff_id': self.staff_a.id,
            'scope': 'all_weekdays_forever',
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    # --- edge cases ---

    def test_dog_delete_cascades_roster(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        self.dog.delete()
        self.assertFalse(DogWeekdayPickup.objects.filter(weekday=self.today_weekday).exists())

    def test_staff_delete_blocked_when_roster_exists(self):
        from django.db.models.deletion import ProtectedError
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        with self.assertRaises(ProtectedError):
            self.staff_a.delete()

    def test_dog_schedule_type_change_to_ad_hoc_clears_roster(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'schedule_type': 'ad_hoc',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(DogWeekdayPickup.objects.filter(dog=self.dog).exists())

    def test_dog_daycare_days_change_removes_roster_entry(self):
        from django.db import connection
        if connection.vendor == 'sqlite':
            self.skipTest('JSON field updates can be noisy on SQLite')
        # Dog attends Mon and Tue
        self.dog.daycare_days = [1, 2]
        self.dog.save()
        DogWeekdayPickup.objects.create(dog=self.dog, weekday=1, staff_member=self.staff_a)
        DogWeekdayPickup.objects.create(dog=self.dog, weekday=2, staff_member=self.staff_a)
        self.client.login(username='staffa', password='pw')
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'daycare_days': [1],
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(DogWeekdayPickup.objects.filter(dog=self.dog, weekday=1).exists())
        self.assertFalse(DogWeekdayPickup.objects.filter(dog=self.dog, weekday=2).exists())

    def test_weekday_roster_endpoint(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday, staff_member=self.staff_a
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(
            f'/api/daily-assignments/weekday_roster/?weekday={self.today_weekday}'
            f'&staff_member_id={self.staff_a.id}'
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        self.assertEqual(resp.data[0]['dog'], self.dog.id)
        self.assertEqual(resp.data[0]['weekday'], self.today_weekday)


class BoardingRequestTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Bella')
        self.client = APIClient()

    def test_owner_can_create_boarding_request(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
            'special_instructions': 'Needs medication',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'PENDING')

    def test_owner_sees_own_boarding_requests(self):
        other = User.objects.create_user(username='other', password='pw')
        BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        BoardingRequest.objects.create(owner=other, start_date='2026-05-01', end_date='2026-05-05')
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/boarding-requests/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)

    def test_staff_can_approve_boarding(self):
        br = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        br.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{br.id}/change_status/', {
            'status': 'APPROVED',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        br.refresh_from_db()
        self.assertEqual(br.status, 'APPROVED')

    def test_non_staff_cannot_change_boarding_status(self):
        br = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        self.client.login(username='owner', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{br.id}/change_status/', {
            'status': 'APPROVED',
        }, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_invalid_date_range_rejected(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-10',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 400)


class SupportQueryTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.staff.profile.can_reply_queries = True
        self.staff.profile.save()
        self.client = APIClient()

    def test_owner_can_create_query(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/support-queries/', {
            'subject': 'Help needed',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'OPEN')

    def test_owner_sees_own_queries_only(self):
        other = User.objects.create_user(username='other', password='pw')
        SupportQuery.objects.create(owner=self.owner, subject='My query')
        SupportQuery.objects.create(owner=other, subject='Other query')
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/support-queries/')
        self.assertEqual(resp.status_code, 200)
        subjects = [q['subject'] for q in resp.data]
        self.assertIn('My query', subjects)
        self.assertNotIn('Other query', subjects)

    def test_staff_sees_all_queries(self):
        other = User.objects.create_user(username='other', password='pw')
        SupportQuery.objects.create(owner=self.owner, subject='Q1')
        SupportQuery.objects.create(owner=other, subject='Q2')
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/support-queries/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 2)

    def test_staff_can_add_message(self):
        q = SupportQuery.objects.create(owner=self.owner, subject='Test')
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/support-queries/{q.id}/add_message/', {
            'text': 'Staff reply',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(SupportMessage.objects.filter(query=q).count(), 1)

    def test_owner_can_add_message_to_own_query(self):
        q = SupportQuery.objects.create(owner=self.owner, subject='Test')
        self.client.login(username='owner', password='pw')
        resp = self.client.post(f'/api/support-queries/{q.id}/add_message/', {
            'text': 'Owner follow-up',
        }, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_staff_can_resolve_query(self):
        q = SupportQuery.objects.create(owner=self.owner, subject='Test')
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/support-queries/{q.id}/resolve/')
        self.assertEqual(resp.status_code, 200)
        q.refresh_from_db()
        self.assertEqual(q.status, 'RESOLVED')

    def test_unresolved_count(self):
        SupportQuery.objects.create(owner=self.owner, subject='Open1')
        SupportQuery.objects.create(owner=self.owner, subject='Open2')
        SupportQuery.objects.create(owner=self.owner, subject='Resolved', status='RESOLVED')
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/support-queries/unresolved_count/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['count'], 2)


class ClosureDayTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.client = APIClient()

    def test_staff_can_create_closure(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/closure-days/', {
            'date': '2026-12-25',
            'closure_type': 'CLOSED',
            'reason': 'Christmas Day',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['reason'], 'Christmas Day')

    def test_owner_cannot_create_closure(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/closure-days/', {
            'date': '2026-12-25',
            'closure_type': 'CLOSED',
        }, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_anyone_can_list_closures(self):
        ClosureDay.objects.create(date='2026-12-25', closure_type='CLOSED', reason='Christmas')
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/closure-days/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)

    def test_staff_can_delete_closure(self):
        c = ClosureDay.objects.create(date='2026-12-25', closure_type='CLOSED')
        self.client.login(username='staff', password='pw')
        resp = self.client.delete(f'/api/closure-days/{c.id}/')
        self.assertEqual(resp.status_code, 204)
        self.assertFalse(ClosureDay.objects.filter(id=c.id).exists())

    def test_owner_cannot_delete_closure(self):
        c = ClosureDay.objects.create(date='2026-12-25', closure_type='CLOSED')
        self.client.login(username='owner', password='pw')
        resp = self.client.delete(f'/api/closure-days/{c.id}/')
        self.assertEqual(resp.status_code, 403)

    def test_date_range_filter(self):
        ClosureDay.objects.create(date='2026-06-01', closure_type='CLOSED', reason='June')
        ClosureDay.objects.create(date='2026-12-25', closure_type='CLOSED', reason='Christmas')
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/closure-days/?from_date=2026-10-01')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        self.assertEqual(resp.data[0]['reason'], 'Christmas')

    def test_duplicate_date_rejected(self):
        self.client.login(username='staff', password='pw')
        self.client.post('/api/closure-days/', {'date': '2026-12-25', 'closure_type': 'CLOSED'}, format='json')
        resp = self.client.post('/api/closure-days/', {'date': '2026-12-25', 'closure_type': 'REDUCED'}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_reduced_capacity_type(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/closure-days/', {
            'date': '2026-12-24',
            'closure_type': 'REDUCED',
            'reason': 'Christmas Eve - half day',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['closure_type'], 'REDUCED')


class DogNoteTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.dog1 = Dog.objects.create(owner=self.owner, name='Buddy')
        self.dog2 = Dog.objects.create(owner=self.owner, name='Bella')
        self.client = APIClient()

    def test_staff_can_create_note(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/dog-notes/', {
            'dog': self.dog1.id,
            'note_type': 'BEHAVIORAL',
            'text': 'Very energetic during playtime',
            'is_positive': True,
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['text'], 'Very energetic during playtime')

    def test_owner_cannot_create_note(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/dog-notes/', {
            'dog': self.dog1.id,
            'note_type': 'BEHAVIORAL',
            'text': 'Test note',
        }, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_compatibility_note_with_related_dog(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/dog-notes/', {
            'dog': self.dog1.id,
            'related_dog': self.dog2.id,
            'note_type': 'COMPATIBILITY',
            'text': 'Play well together',
            'is_positive': True,
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['related_dog_name'], 'Bella')

    def test_filter_notes_by_dog(self):
        DogNote.objects.create(dog=self.dog1, note_type='BEHAVIORAL', text='Note1', created_by=self.staff)
        DogNote.objects.create(dog=self.dog2, note_type='BEHAVIORAL', text='Note2', created_by=self.staff)
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/dog-notes/?dog_id={self.dog1.id}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        self.assertEqual(resp.data[0]['text'], 'Note1')

    def test_related_dog_notes_appear_in_filter(self):
        DogNote.objects.create(
            dog=self.dog1, related_dog=self.dog2,
            note_type='COMPATIBILITY', text='Gets along', created_by=self.staff,
        )
        self.client.login(username='staff', password='pw')
        # Should appear when filtering by dog2 too (since it's the related dog)
        resp = self.client.get(f'/api/dog-notes/?dog_id={self.dog2.id}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)

    def test_staff_can_delete_note(self):
        note = DogNote.objects.create(dog=self.dog1, note_type='GROUPING', text='Group A', created_by=self.staff)
        self.client.login(username='staff', password='pw')
        resp = self.client.delete(f'/api/dog-notes/{note.id}/')
        self.assertEqual(resp.status_code, 204)
        self.assertFalse(DogNote.objects.filter(id=note.id).exists())

    def test_negative_note(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/dog-notes/', {
            'dog': self.dog1.id,
            'related_dog': self.dog2.id,
            'note_type': 'COMPATIBILITY',
            'text': 'Do not put together - aggressive',
            'is_positive': False,
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(resp.data['is_positive'])

    def test_filter_by_note_type(self):
        DogNote.objects.create(dog=self.dog1, note_type='BEHAVIORAL', text='B1', created_by=self.staff)
        DogNote.objects.create(dog=self.dog1, note_type='GROUPING', text='G1', created_by=self.staff)
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/dog-notes/?note_type=BEHAVIORAL')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        self.assertEqual(resp.data[0]['note_type'], 'BEHAVIORAL')

    def test_staff_can_edit_note(self):
        note = DogNote.objects.create(
            dog=self.dog1, related_dog=self.dog2,
            note_type='COMPATIBILITY', is_positive=True,
            text='Initial text', created_by=self.staff,
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(f'/api/dog-notes/{note.id}/', {
            'text': 'Updated text',
            'is_positive': False,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        note.refresh_from_db()
        self.assertEqual(note.text, 'Updated text')
        self.assertFalse(note.is_positive)

    def test_owner_cannot_edit_note(self):
        note = DogNote.objects.create(
            dog=self.dog1, note_type='BEHAVIORAL',
            text='Original', created_by=self.staff,
        )
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/dog-notes/{note.id}/', {
            'text': 'Hacked',
        }, format='json')
        self.assertEqual(resp.status_code, 403)
        note.refresh_from_db()
        self.assertEqual(note.text, 'Original')

    def test_behavioral_note_does_not_leak_via_related_dog(self):
        # Behavioural notes are unidirectional even when they reference a related dog.
        DogNote.objects.create(
            dog=self.dog1, related_dog=self.dog2,
            note_type='BEHAVIORAL', text='Reacts to Bella', created_by=self.staff,
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/dog-notes/?dog_id={self.dog2.id}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 0)


class CompatibilityConflictTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff_a = User.objects.create_user(
            username='staffa', password='pw', is_staff=True, first_name='Alice',
        )
        self.staff_b = User.objects.create_user(
            username='staffb', password='pw', is_staff=True, first_name='Bob',
        )
        self.dog1 = Dog.objects.create(owner=self.owner, name='Rex')
        self.dog2 = Dog.objects.create(owner=self.owner, name='Buddy')
        self.dog3 = Dog.objects.create(owner=self.owner, name='Max')
        self.today = date.today()
        self.client = APIClient()

    def _assign(self, dog, staff):
        return DailyDogAssignment.objects.create(dog=dog, staff_member=staff, date=self.today)

    def test_flags_two_incompatible_dogs_with_same_staff(self):
        self._assign(self.dog1, self.staff_a)
        self._assign(self.dog2, self.staff_a)
        DogNote.objects.create(
            dog=self.dog1, related_dog=self.dog2,
            note_type='COMPATIBILITY', is_positive=False,
            text='Fights at pickup', created_by=self.staff_a,
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(
            f'/api/daily-assignments/compatibility_conflicts/?date={self.today.isoformat()}'
        )
        self.assertEqual(resp.status_code, 200)
        conflicts = resp.data['conflicts']
        self.assertEqual(len(conflicts), 1)
        names = sorted([conflicts[0]['dog_a_name'], conflicts[0]['dog_b_name']])
        self.assertEqual(names, ['Buddy', 'Rex'])
        self.assertIn('Fights at pickup', conflicts[0]['reasons'])

    def test_no_conflict_when_dogs_with_different_staff(self):
        self._assign(self.dog1, self.staff_a)
        self._assign(self.dog2, self.staff_b)
        DogNote.objects.create(
            dog=self.dog1, related_dog=self.dog2,
            note_type='COMPATIBILITY', is_positive=False,
            text='Fights', created_by=self.staff_a,
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(
            f'/api/daily-assignments/compatibility_conflicts/?date={self.today.isoformat()}'
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['conflicts'], [])

    def test_positive_compatibility_note_does_not_flag(self):
        self._assign(self.dog1, self.staff_a)
        self._assign(self.dog2, self.staff_a)
        DogNote.objects.create(
            dog=self.dog1, related_dog=self.dog2,
            note_type='COMPATIBILITY', is_positive=True,
            text='Play together well', created_by=self.staff_a,
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(
            f'/api/daily-assignments/compatibility_conflicts/?date={self.today.isoformat()}'
        )
        self.assertEqual(resp.data['conflicts'], [])

    def test_removed_assignment_not_counted(self):
        self._assign(self.dog1, self.staff_a)
        removed = self._assign(self.dog2, self.staff_a)
        removed.status = 'REMOVED'
        removed.save()
        DogNote.objects.create(
            dog=self.dog1, related_dog=self.dog2,
            note_type='COMPATIBILITY', is_positive=False,
            text='Fights', created_by=self.staff_a,
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(
            f'/api/daily-assignments/compatibility_conflicts/?date={self.today.isoformat()}'
        )
        self.assertEqual(resp.data['conflicts'], [])

    def test_non_staff_blocked(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/daily-assignments/compatibility_conflicts/')
        self.assertEqual(resp.status_code, 403)


class StaffAvailabilityTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.staff2 = User.objects.create_user(username='staff2', password='pw', is_staff=True)
        self.client = APIClient()

    def test_owner_cannot_access_availability(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/staff-availability/')
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_set_availability(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/staff-availability/set_my_availability/', {
            'availability': [
                {'day_of_week': 1, 'is_available': True, 'note': ''},
                {'day_of_week': 2, 'is_available': False, 'note': 'Day off'},
                {'day_of_week': 3, 'is_available': True, 'note': 'Mornings only'},
            ],
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 3)
        # Verify in DB
        self.assertEqual(StaffAvailability.objects.filter(staff_member=self.staff).count(), 3)

    def test_staff_can_get_own_availability(self):
        StaffAvailability.objects.create(staff_member=self.staff, day_of_week=1, is_available=True)
        StaffAvailability.objects.create(staff_member=self.staff, day_of_week=2, is_available=False)
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/staff-availability/my_availability/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 2)

    def test_set_availability_is_idempotent(self):
        self.client.login(username='staff', password='pw')
        # Set twice for the same day
        self.client.post('/api/staff-availability/set_my_availability/', {
            'availability': [{'day_of_week': 1, 'is_available': True}],
        }, format='json')
        self.client.post('/api/staff-availability/set_my_availability/', {
            'availability': [{'day_of_week': 1, 'is_available': False, 'note': 'Updated'}],
        }, format='json')
        # Should only have 1 record, not 2
        self.assertEqual(StaffAvailability.objects.filter(staff_member=self.staff, day_of_week=1).count(), 1)
        avail = StaffAvailability.objects.get(staff_member=self.staff, day_of_week=1)
        self.assertFalse(avail.is_available)
        self.assertEqual(avail.note, 'Updated')

    def test_coverage_endpoint(self):
        StaffAvailability.objects.create(staff_member=self.staff, day_of_week=1, is_available=True)
        StaffAvailability.objects.create(staff_member=self.staff2, day_of_week=1, is_available=False)
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/staff-availability/coverage/')
        self.assertEqual(resp.status_code, 200)
        monday = resp.data['1']
        self.assertEqual(monday['day_name'], 'Monday')
        available_ids = [s['id'] for s in monday['available']]
        unavailable_ids = [s['id'] for s in monday['unavailable']]
        self.assertIn(self.staff.id, available_ids)
        self.assertIn(self.staff2.id, unavailable_ids)

    def test_coverage_defaults_to_available(self):
        """Staff without explicit availability records should default to available."""
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/staff-availability/coverage/')
        self.assertEqual(resp.status_code, 200)
        # Both staff members should appear as available for all days by default
        monday = resp.data['1']
        available_ids = [s['id'] for s in monday['available']]
        self.assertIn(self.staff.id, available_ids)
        self.assertIn(self.staff2.id, available_ids)

    def test_team_off_lists_approved_time_off_for_all_staff(self):
        """Any staff member can see approved time off (no approval permission needed),
        grouped by date, names only."""
        today = date.today()
        DayOffRequest.objects.create(staff_member=self.staff2, date=today, status='APPROVED')
        self.client.login(username='staff', password='pw')
        resp = self.client.get(
            '/api/staff-availability/team_off/',
            {'start': today.isoformat(), 'end': (today + timedelta(days=7)).isoformat()},
        )
        self.assertEqual(resp.status_code, 200)
        self.assertIn(today.isoformat(), resp.data)
        self.assertEqual(resp.data[today.isoformat()], [self.staff2.first_name or self.staff2.username])

    def test_team_off_excludes_pending_and_denied(self):
        today = date.today()
        DayOffRequest.objects.create(staff_member=self.staff, date=today, status='PENDING')
        DayOffRequest.objects.create(staff_member=self.staff2, date=today, status='DENIED')
        self.client.login(username='staff', password='pw')
        resp = self.client.get(
            '/api/staff-availability/team_off/',
            {'start': today.isoformat(), 'end': today.isoformat()},
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data, {})

    def test_team_off_requires_valid_params(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/staff-availability/team_off/')
        self.assertEqual(resp.status_code, 400)

    def test_team_off_forbidden_for_non_staff(self):
        today = date.today()
        self.client.login(username='owner', password='pw')
        resp = self.client.get(
            '/api/staff-availability/team_off/',
            {'start': today.isoformat(), 'end': today.isoformat()},
        )
        self.assertEqual(resp.status_code, 403)


class UserProfileTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(username='user1', password='pw', first_name='John')
        self.client = APIClient()

    def test_get_profile(self):
        self.client.login(username='user1', password='pw')
        resp = self.client.get('/api/profile/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['username'], 'user1')
        self.assertEqual(resp.data['first_name'], 'John')

    def test_update_profile(self):
        self.client.login(username='user1', password='pw')
        resp = self.client.post('/api/profile/', {
            'phone_number': '07123456789',
            'address': '123 Test St',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.user.profile.refresh_from_db()
        self.assertEqual(self.user.profile.phone_number, '07123456789')
        self.assertEqual(self.user.profile.address, '123 Test St')


class StaffPermissionsManagementTests(TestCase):
    def setUp(self):
        self.superuser = User.objects.create_user(
            username='admin', password='pw', is_staff=True, is_superuser=True
        )
        self.staff = User.objects.create_user(
            username='staff1', password='pw', is_staff=True, first_name='Alice'
        )
        self.other_staff = User.objects.create_user(
            username='staff2', password='pw', is_staff=True, first_name='Bob'
        )
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.client = APIClient()

    def test_list_staff_permissions_requires_superuser(self):
        self.client.login(username='staff1', password='pw')
        resp = self.client.get('/api/profile/list_staff_permissions/')
        self.assertEqual(resp.status_code, 403)

    def test_list_staff_permissions_rejects_owner(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/profile/list_staff_permissions/')
        self.assertEqual(resp.status_code, 403)

    def test_superuser_can_list_staff_permissions(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.get('/api/profile/list_staff_permissions/')
        self.assertEqual(resp.status_code, 200)
        usernames = {entry['username'] for entry in resp.data}
        self.assertIn('admin', usernames)
        self.assertIn('staff1', usernames)
        self.assertIn('staff2', usernames)
        self.assertNotIn('owner', usernames)
        for entry in resp.data:
            for field in (
                'can_manage_requests', 'can_assign_dogs', 'can_reply_queries',
                'can_add_feed_media', 'can_approve_timeoff', 'can_view_inquiries',
                'is_superuser',
            ):
                self.assertIn(field, entry)

    def test_superuser_can_update_staff_permissions(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.post(
            f'/api/profile/update_staff_permissions/?user_id={self.staff.id}',
            {'can_manage_requests': True, 'can_assign_dogs': True},
            format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.staff.profile.refresh_from_db()
        self.assertTrue(self.staff.profile.can_manage_requests)
        self.assertTrue(self.staff.profile.can_assign_dogs)
        self.assertFalse(self.staff.profile.can_reply_queries)

    def test_non_superuser_cannot_update_staff_permissions(self):
        self.client.login(username='staff1', password='pw')
        resp = self.client.post(
            f'/api/profile/update_staff_permissions/?user_id={self.other_staff.id}',
            {'can_manage_requests': True},
            format='json',
        )
        self.assertEqual(resp.status_code, 403)
        self.other_staff.profile.refresh_from_db()
        self.assertFalse(self.other_staff.profile.can_manage_requests)

    def test_update_staff_permissions_requires_user_id(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.post(
            '/api/profile/update_staff_permissions/',
            {'can_manage_requests': True},
            format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_cannot_update_non_staff_user_permissions(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.post(
            f'/api/profile/update_staff_permissions/?user_id={self.owner.id}',
            {'can_manage_requests': True},
            format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_profile_endpoint_exposes_is_superuser(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.get('/api/profile/')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['is_superuser'])

        self.client.login(username='staff1', password='pw')
        resp = self.client.get('/api/profile/')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data['is_superuser'])


class PrivacyAcceptanceTests(TestCase):
    """Sign-up must require Privacy Policy acceptance and record it."""

    def setUp(self):
        self.client = APIClient()

    def _payload(self, **over):
        payload = {
            'username': 'newuser@example.com',
            'email': 'newuser@example.com',
            'password': 'Str0ngPass!23',
            'first_name': 'Ann',
            'last_name': 'Bee',
            'accept_privacy': True,
        }
        payload.update(over)
        return payload

    def test_signup_rejected_when_not_accepted(self):
        resp = self.client.post('/auth/users/', self._payload(accept_privacy=False), format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertIn('accept_privacy', resp.data)
        self.assertFalse(User.objects.filter(username='newuser@example.com').exists())

    def test_signup_rejected_when_flag_missing(self):
        payload = self._payload()
        payload.pop('accept_privacy')
        resp = self.client.post('/auth/users/', payload, format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertFalse(User.objects.filter(username='newuser@example.com').exists())

    def test_signup_records_acceptance(self):
        from api.serializers import PRIVACY_POLICY_VERSION
        resp = self.client.post('/auth/users/', self._payload(), format='json')
        self.assertEqual(resp.status_code, 201)
        user = User.objects.get(username='newuser@example.com')
        self.assertEqual(user.first_name, 'Ann')
        self.assertEqual(user.last_name, 'Bee')
        self.assertIsNotNone(user.profile.accepted_privacy_at)
        self.assertEqual(user.profile.accepted_privacy_version, PRIVACY_POLICY_VERSION)


class FeedTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.client = APIClient()

    def test_owner_cannot_upload_to_feed(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/feed/', {
            'media_type': 'PHOTO',
            'caption': 'Test',
        }, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_anyone_can_view_feed(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/feed/')
        self.assertEqual(resp.status_code, 200)

    def test_feed_is_paginated_and_newest_first(self):
        from datetime import timedelta
        from django.utils import timezone
        # Create more items than one page (page_size=5) with known ordering.
        base = timezone.now()
        for i in range(7):
            media = GroupMedia.objects.create(
                uploaded_by=self.staff, media_type='PHOTO', caption=f'post {i}')
            # Force distinct, increasing created_at so ordering is deterministic.
            GroupMedia.objects.filter(pk=media.pk).update(
                created_at=base + timedelta(minutes=i))

        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/feed/')
        self.assertEqual(resp.status_code, 200)
        # Paginated response shape.
        self.assertIn('results', resp.data)
        self.assertIn('count', resp.data)
        self.assertEqual(resp.data['count'], 7)
        self.assertEqual(len(resp.data['results']), 5)  # first page
        self.assertIsNotNone(resp.data['next'])
        # Newest first: the most recent caption leads the first page.
        self.assertEqual(resp.data['results'][0]['caption'], 'post 6')

        # Second page holds the remaining items.
        resp2 = self.client.get('/api/feed/?page=2')
        self.assertEqual(resp2.status_code, 200)
        self.assertEqual(len(resp2.data['results']), 2)


class PruneFeedMediaTests(TestCase):
    def setUp(self):
        import os
        from django.conf import settings
        from django.core.files.base import ContentFile

        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.media_root = str(settings.MEDIA_ROOT)

        # Ensure directories exist
        for d in ['group_media', os.path.join('group_media', 'thumbnails')]:
            os.makedirs(os.path.join(self.media_root, d), exist_ok=True)

        # Create an old feed item (120 days ago)
        self.old_item = GroupMedia.objects.create(
            uploaded_by=self.staff,
            media_type='PHOTO',
            file=ContentFile(b'old-photo', name='old.jpg'),
        )
        GroupMedia.objects.filter(pk=self.old_item.pk).update(
            created_at=timezone.now() - timedelta(days=120),
        )
        self.old_item.refresh_from_db()

        # Create a recent feed item (10 days ago)
        self.new_item = GroupMedia.objects.create(
            uploaded_by=self.staff,
            media_type='PHOTO',
            file=ContentFile(b'new-photo', name='new.jpg'),
        )
        GroupMedia.objects.filter(pk=self.new_item.pk).update(
            created_at=timezone.now() - timedelta(days=10),
        )
        self.new_item.refresh_from_db()

    def tearDown(self):
        import shutil, os
        from django.conf import settings
        # Clean up test media directory
        for d in ['group_media']:
            path = os.path.join(str(settings.MEDIA_ROOT), d)
            if os.path.isdir(path):
                shutil.rmtree(path)

    def test_old_media_deleted(self):
        from django.core.management import call_command
        call_command('prune_feed_media', days=90)
        self.assertFalse(GroupMedia.objects.filter(pk=self.old_item.pk).exists())

    def test_recent_media_preserved(self):
        from django.core.management import call_command
        call_command('prune_feed_media', days=90)
        self.assertTrue(GroupMedia.objects.filter(pk=self.new_item.pk).exists())

    def test_dry_run_preserves_all(self):
        from django.core.management import call_command
        call_command('prune_feed_media', days=90, dry_run=True)
        self.assertTrue(GroupMedia.objects.filter(pk=self.old_item.pk).exists())
        self.assertTrue(GroupMedia.objects.filter(pk=self.new_item.pk).exists())

    def test_old_media_file_removed_from_disk(self):
        import os
        from django.core.management import call_command
        file_path = os.path.join(self.media_root, self.old_item.file.name)
        self.assertTrue(os.path.exists(file_path))
        call_command('prune_feed_media', days=90)
        self.assertFalse(os.path.exists(file_path))

    def test_orphan_cleanup_removes_unreferenced_files(self):
        import os
        from django.core.management import call_command
        # Create an orphaned file on disk
        orphan_path = os.path.join(self.media_root, 'group_media', 'orphan.jpg')
        with open(orphan_path, 'wb') as f:
            f.write(b'orphan')
        self.assertTrue(os.path.exists(orphan_path))
        call_command('prune_feed_media', days=9999, include_orphans=True)
        self.assertFalse(os.path.exists(orphan_path))

    def test_orphan_cleanup_preserves_referenced_files(self):
        import os
        from django.core.management import call_command
        file_path = os.path.join(self.media_root, self.new_item.file.name)
        self.assertTrue(os.path.exists(file_path))
        call_command('prune_feed_media', days=9999, include_orphans=True)
        self.assertTrue(os.path.exists(file_path))


class AssignmentTransportTests(TestCase):
    """Tests for staff-set owner_brings / owner_collects transport fields."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.staff.profile.can_assign_dogs = True
        self.staff.profile.save()
        self.staff_no_perm = User.objects.create_user(username='staff_np', password='pw', is_staff=True)
        # Explicitly ensure no permissions
        self.staff_no_perm.profile.can_assign_dogs = False
        self.staff_no_perm.profile.can_manage_requests = False
        self.staff_no_perm.profile.save()
        self.today = date.today()
        self.dog = Dog.objects.create(
            owner=self.owner, name='Rex',
            daycare_days=[self.today.isoweekday()],
            schedule_type='weekly',
        )
        self.assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.today,
        )
        self.client = APIClient()
        self.url = f'/api/daily-assignments/{self.assignment.id}/transport/'

    def test_staff_with_can_assign_dogs_can_set_transport(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(self.url, {
            'owner_brings': True,
            'owner_brings_time': '08:30',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assignment.refresh_from_db()
        self.assertTrue(self.assignment.owner_brings)
        self.assertEqual(self.assignment.owner_brings_time.strftime('%H:%M'), '08:30')

    def test_staff_with_can_manage_requests_can_set_transport(self):
        self.staff_no_perm.profile.can_manage_requests = True
        self.staff_no_perm.profile.save()
        self.client.login(username='staff_np', password='pw')
        resp = self.client.patch(self.url, {'owner_brings': True}, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_staff_without_permission_cannot_set_transport(self):
        self.client.login(username='staff_np', password='pw')
        resp = self.client.patch(self.url, {'owner_brings': True}, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_owner_cannot_set_transport(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(self.url, {'owner_brings': True}, format='json')
        self.assertIn(resp.status_code, (401, 403))

    def test_null_override_falls_back_to_dog_default(self):
        self.dog.owner_brings_default = True
        self.dog.save()
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/daily-assignments/')
        self.assertEqual(resp.status_code, 200)
        row = next(a for a in resp.data if a['id'] == self.assignment.id)
        self.assertTrue(row['effective_owner_brings'])
        self.assertIsNone(row['owner_brings'])

    def test_explicit_false_overrides_true_default(self):
        self.dog.owner_brings_default = True
        self.dog.save()
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(self.url, {'owner_brings': False}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assignment.refresh_from_db()
        self.assertFalse(self.assignment.effective_owner_brings)

    def test_time_fields_persist(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(self.url, {
            'owner_brings': True, 'owner_brings_time': '08:15',
            'owner_collects': True, 'owner_collects_time': '17:45',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.owner_brings_time.strftime('%H:%M'), '08:15')
        self.assertEqual(self.assignment.owner_collects_time.strftime('%H:%M'), '17:45')

    def test_invalid_time_format_rejected(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(self.url, {'owner_brings_time': 'nope'}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_clearing_time_with_null(self):
        self.assignment.owner_brings_time = '08:00:00'
        self.assignment.save()
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(self.url, {'owner_brings_time': None}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assignment.refresh_from_db()
        self.assertIsNone(self.assignment.owner_brings_time)

    def test_closure_day_rejected(self):
        ClosureDay.objects.create(date=self.today, closure_type='CLOSED')
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(self.url, {'owner_brings': True}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_owner_cannot_update_owner_brings_default_on_dog(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'owner_brings_default': True,
        }, format='json')
        # Owner can PATCH their dog, but transport defaults are silently
        # stripped for non-staff users.
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertFalse(self.dog.owner_brings_default)

    def test_staff_can_update_owner_brings_default_on_dog(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'owner_brings_default': True,
            'owner_brings_default_time': '08:00',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertTrue(self.dog.owner_brings_default)
        self.assertEqual(self.dog.owner_brings_default_time.strftime('%H:%M'), '08:00')

    def test_materialization_skips_dog_with_owner_brings_default(self):
        # Remove today's assignment so the materializer has a clean state
        self.assignment.delete()
        self.dog.owner_brings_default = True
        self.dog.save()
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today.isoweekday(),
            staff_member=self.staff,
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        dog_ids = [a['dog'] for a in resp.data]
        self.assertNotIn(self.dog.id, dog_ids)
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog, date=self.today).exists())

    def test_materialization_runs_when_owner_brings_default_false(self):
        self.assignment.delete()
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today.isoweekday(),
            staff_member=self.staff,
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(DailyDogAssignment.objects.filter(dog=self.dog, date=self.today).exists())
