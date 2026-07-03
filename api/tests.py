from datetime import date, timedelta
from unittest.mock import patch
from django.test import TestCase, Client, override_settings
from django.contrib.auth.models import User
from django.core.management import call_command
from rest_framework.test import APIClient
from .models import (
    Dog, DateChangeRequest, DateChangeRequestHistory,
    BoardingRequest, BoardingRequestHistory, DailyDogAssignment, DogWeekdayPickup,
    SupportQuery, SupportMessage,
    ClosureDay, DogNote, StaffAvailability, DayOffRequest,
    GroupMedia, IntakeRequest,
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


class DateChangeMoveTests(TestCase):
    """Approving a CHANGE frees the old day and surfaces the dog in the
    unassigned list for the new day (staff pick the driver). A move must never
    leave the dog REMOVED from the old day with nothing on the new day, nor be
    silently blocked by a stale removal on the new day."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.driver = User.objects.create_user(username='driver', password='pw', is_staff=True)
        # daycare_days empty + no weekday roster -> the dog only attends the new
        # day because of the approved CHANGE, so it can't be auto-materialised.
        self.dog = Dog.objects.create(owner=self.owner, name='Henry')
        self.original = date.today() + timedelta(days=7)
        self.new = date.today() + timedelta(days=8)
        self.client = APIClient()

    def _staff_change(self):
        self.client.login(username='staff', password='pw')
        return self.client.post('/api/date-change-requests/', {
            'dog': self.dog.id,
            'request_type': 'CHANGE',
            'original_date': self.original.isoformat(),
            'new_date': self.new.isoformat(),
        }, format='json')

    def _assert_in_unassigned(self, target):
        # The unassigned_dogs query uses a JSON `contains` lookup that SQLite
        # (the test DB) doesn't support; only assert membership on Postgres.
        from django.db import connection
        if connection.vendor == 'sqlite':
            return
        self.client.login(username='staff', password='pw')
        resp = self.client.get(
            f'/api/daily-assignments/unassigned_dogs/?date={target.isoformat()}'
        )
        self.assertEqual(resp.status_code, 200)
        self.assertIn(self.dog.id, [d['id'] for d in resp.data])

    def test_staff_change_frees_old_day_and_unassigns_new_day(self):
        # Henry had a driver on the original day.
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.driver, date=self.original, status='ASSIGNED'
        )
        resp = self._staff_change()
        self.assertEqual(resp.status_code, 201)
        # Original day is freed.
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.original).exists()
        )
        # New day is NOT auto-assigned — the dog goes to the unassigned list.
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.new).exists()
        )
        self._assert_in_unassigned(self.new)

    def test_staff_change_clears_stale_removal_on_new_day(self):
        # The dog was previously REMOVED from the target day; the move must clear
        # that marker, otherwise the dog never surfaces anywhere for the new day.
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.driver, date=self.new, status='REMOVED'
        )
        resp = self._staff_change()
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.new).exists()
        )
        self._assert_in_unassigned(self.new)

    def test_approve_owner_change_unassigns_new_day(self):
        # Owner-created CHANGE stays pending, then staff approve via change_status.
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/date-change-requests/', {
            'dog': self.dog.id,
            'request_type': 'CHANGE',
            'original_date': self.original.isoformat(),
            'new_date': self.new.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        req_id = resp.data['id']

        self.client.logout()
        self.client.login(username='staff', password='pw')
        resp = self.client.post(
            f'/api/date-change-requests/{req_id}/change_status/',
            {'status': 'APPROVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.new).exists()
        )
        self._assert_in_unassigned(self.new)


class DogCancelledDatesTests(TestCase):
    """The dog serializer surfaces upcoming staff-removed days so the profile can
    drop them from the recurring-schedule view (matching the dashboard)."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Fido')
        self.client = APIClient()

    def test_future_removed_date_listed_for_owner(self):
        future = date.today() + timedelta(days=5)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=future, status='REMOVED'
        )
        self.client.login(username='owner', password='pw')
        resp = self.client.get(f'/api/dogs/{self.dog.id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertIn(future.isoformat(), resp.data['cancelled_dates'])

    def test_active_and_past_assignments_excluded(self):
        future_active = date.today() + timedelta(days=5)
        past_removed = date.today() - timedelta(days=5)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=future_active, status='ASSIGNED'
        )
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=past_removed, status='REMOVED'
        )
        self.client.login(username='owner', password='pw')
        resp = self.client.get(f'/api/dogs/{self.dog.id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['cancelled_dates'], [])


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


class OptInPaginationTests(TestCase):
    """Opt-in pagination (B6): the now-paginated list endpoints return a bare
    list by default (back-compat) and a paginated dict only when ?page is sent."""

    def setUp(self):
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.client = APIClient()
        for i in range(5):
            Dog.objects.create(owner=self.staff, name=f'Dog{i}')

    def test_no_page_param_returns_bare_list(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/dogs/')
        self.assertEqual(resp.status_code, 200)
        # Bare list, not a paginated envelope — old clients/tests unaffected.
        self.assertIsInstance(resp.data, list)
        self.assertEqual(len(resp.data), 5)

    def test_opt_in_pagination_pages_through_all_items(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/dogs/?page=1&page_size=2')
        self.assertEqual(resp.status_code, 200)
        # Paginated envelope when the client opts in.
        self.assertIn('results', resp.data)
        self.assertIn('next', resp.data)
        self.assertIn('count', resp.data)
        self.assertEqual(resp.data['count'], 5)
        self.assertEqual(len(resp.data['results']), 2)
        self.assertIsNotNone(resp.data['next'])

        # Follow the pages to collect everything.
        collected = list(resp.data['results'])
        next_url = resp.data['next']
        while next_url:
            page = self.client.get(next_url)
            self.assertEqual(page.status_code, 200)
            collected.extend(page.data['results'])
            next_url = page.data['next']
        self.assertEqual(len(collected), 5)


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
        self.assertIn('profile_image', resp.data['dogs'][0])
        self.assertIsNone(resp.data['dogs'][0]['profile_image'])

    def test_unspayed_males_endpoint_requires_staff(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/dogs/unspayed_males/')
        self.assertEqual(resp.status_code, 403)


class DogAddressTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.client = APIClient()

    def test_staff_can_set_dog_address(self):
        dog = Dog.objects.create(owner=self.owner, name='Rex')
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(f'/api/dogs/{dog.id}/', {'address': '12 High St, Reading'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['address'], '12 High St, Reading')
        dog.refresh_from_db()
        self.assertEqual(dog.address, '12 High St, Reading')

    def test_owner_address_change_requires_approval(self):
        dog = Dog.objects.create(owner=self.owner, name='Rex')
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/dogs/{dog.id}/', {'address': '5 New Road, Slough'}, format='json')
        self.assertEqual(resp.status_code, 202)
        dog.refresh_from_db()
        self.assertIsNone(dog.address)
        from .models import DogProfileChangeRequest
        cr = DogProfileChangeRequest.objects.filter(dog=dog, status='PENDING').first()
        self.assertIsNotNone(cr)
        self.assertEqual(cr.proposed_changes.get('address'), '5 New Road, Slough')

    def test_approving_address_change_applies_it(self):
        dog = Dog.objects.create(owner=self.owner, name='Rex')
        self.client.login(username='owner', password='pw')
        self.client.patch(f'/api/dogs/{dog.id}/', {'address': '5 New Road, Slough'}, format='json')
        from .models import DogProfileChangeRequest
        cr = DogProfileChangeRequest.objects.get(dog=dog, status='PENDING')

        self.client.logout()
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/dog-profile-changes/{cr.id}/approve/')
        self.assertEqual(resp.status_code, 200)
        dog.refresh_from_db()
        self.assertEqual(dog.address, '5 New Road, Slough')
        cr.refresh_from_db()
        self.assertEqual(cr.status, 'APPROVED')

    def test_address_in_dog_list(self):
        Dog.objects.create(owner=self.owner, name='Rex', address='1 Park Lane')
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/dogs/')
        self.assertEqual(resp.status_code, 200)
        self.assertIn('address', resp.data[0])
        self.assertEqual(resp.data[0]['address'], '1 Park Lane')

    def test_assignment_owner_address_sources_dog_address(self):
        """The pickup list's owner_address comes from the dog, not the owner profile."""
        self.owner.profile.address = 'Profile Addr'
        self.owner.profile.save()
        dog = Dog.objects.create(owner=self.owner, name='Rex', address='Dog Addr')
        DailyDogAssignment.objects.create(dog=dog, staff_member=self.staff, date=date.today())
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/daily-assignments/')
        self.assertEqual(resp.status_code, 200)
        record = next(a for a in resp.data if a['dog'] == dog.id)
        self.assertEqual(record['owner_address'], 'Dog Addr')

    def test_assignment_owner_address_no_profile_fallback(self):
        """A dog without an address yields no address, even if the owner profile has one."""
        self.owner.profile.address = 'Profile Addr'
        self.owner.profile.save()
        dog = Dog.objects.create(owner=self.owner, name='Rex')
        DailyDogAssignment.objects.create(dog=dog, staff_member=self.staff, date=date.today())
        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/daily-assignments/')
        self.assertEqual(resp.status_code, 200)
        record = next(a for a in resp.data if a['dog'] == dog.id)
        self.assertIsNone(record['owner_address'])


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


class BoardingTransportLegTests(TestCase):
    """Boarding dogs only travel on the edges of a stay: staff pick them up
    on the first day (no evening drop-off — they sleep over) and drop them
    home on the last day (no morning pickup — they woke up with staff).
    Owner-handled legs stay owner-handled throughout."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Rex')
        self.client = APIClient()
        self.client.login(username='staff', password='pw')
        self.day1 = date.today()
        self.day2 = self.day1 + timedelta(days=1)
        self.day3 = self.day1 + timedelta(days=2)

    def _board(self, start, end, dog=None):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date=start, end_date=end, status='APPROVED')
        br.dogs.add(dog or self.dog)
        return br

    def _assign(self, on_date, dog=None):
        return DailyDogAssignment.objects.create(
            dog=dog or self.dog, staff_member=self.staff, date=on_date)

    def _fetch(self, on_date, dog=None):
        resp = self.client.get(f'/api/daily-assignments/today/?date={on_date.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        dog_id = (dog or self.dog).id
        return next(a for a in resp.data if a['dog'] == dog_id)

    def test_staff_transported_boarding_stay(self):
        self._board(self.day1, self.day3)
        for d in (self.day1, self.day2, self.day3):
            self._assign(d)

        first = self._fetch(self.day1)
        self.assertTrue(first['is_boarding'])
        self.assertTrue(first['boarding_first_day'])
        self.assertFalse(first['boarding_last_day'])
        self.assertTrue(first['needs_pickup'])
        self.assertFalse(first['needs_dropoff'])

        middle = self._fetch(self.day2)
        self.assertTrue(middle['is_boarding'])
        self.assertFalse(middle['boarding_first_day'])
        self.assertFalse(middle['boarding_last_day'])
        self.assertFalse(middle['needs_pickup'])
        self.assertFalse(middle['needs_dropoff'])

        last = self._fetch(self.day3)
        self.assertTrue(last['is_boarding'])
        self.assertFalse(last['boarding_first_day'])
        self.assertTrue(last['boarding_last_day'])
        self.assertFalse(last['needs_pickup'])
        self.assertTrue(last['needs_dropoff'])

    def test_owner_handled_legs_stay_owner_handled(self):
        self.dog.owner_brings_default = True
        self.dog.owner_collects_default = True
        self.dog.save()
        self._board(self.day1, self.day3)
        for d in (self.day1, self.day3):
            self._assign(d)

        first = self._fetch(self.day1)
        self.assertFalse(first['needs_pickup'])
        self.assertFalse(first['needs_dropoff'])

        last = self._fetch(self.day3)
        self.assertFalse(last['needs_pickup'])
        self.assertFalse(last['needs_dropoff'])

    def test_single_day_boarding_needs_both_legs(self):
        self._board(self.day1, self.day1)
        self._assign(self.day1)
        row = self._fetch(self.day1)
        self.assertTrue(row['boarding_first_day'])
        self.assertTrue(row['boarding_last_day'])
        self.assertTrue(row['needs_pickup'])
        self.assertTrue(row['needs_dropoff'])

    def test_back_to_back_requests_count_as_one_stay(self):
        # One request ends day2, the next starts day3 — the dog never goes
        # home in between, so day2 is not a "last day" and day3 not a "first".
        self._board(self.day1, self.day2)
        self._board(self.day3, self.day3 + timedelta(days=2))
        for d in (self.day2, self.day3):
            self._assign(d)

        end_of_first = self._fetch(self.day2)
        self.assertFalse(end_of_first['boarding_last_day'])
        self.assertFalse(end_of_first['needs_dropoff'])

        start_of_second = self._fetch(self.day3)
        self.assertFalse(start_of_second['boarding_first_day'])
        self.assertFalse(start_of_second['needs_pickup'])

    def test_non_boarding_dog_unaffected(self):
        self._assign(self.day1)
        row = self._fetch(self.day1)
        self.assertFalse(row['is_boarding'])
        self.assertFalse(row['boarding_first_day'])
        self.assertFalse(row['boarding_last_day'])
        self.assertTrue(row['needs_pickup'])
        self.assertTrue(row['needs_dropoff'])

    def test_single_object_fallback_without_context(self):
        # Retrieving one assignment serializes without the bulk boarding
        # context — the per-row fallback must agree with the roster view.
        self._board(self.day1, self.day3)
        assignment = self._assign(self.day2)
        resp = self.client.get(f'/api/daily-assignments/{assignment.id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['is_boarding'])
        self.assertFalse(resp.data['boarding_first_day'])
        self.assertFalse(resp.data['boarding_last_day'])
        self.assertFalse(resp.data['needs_pickup'])
        self.assertFalse(resp.data['needs_dropoff'])

    def test_model_helpers_match(self):
        self._board(self.day1, self.day3)
        first = self._assign(self.day1)
        last = self._assign(self.day3)
        self.assertTrue(first.needs_staff_pickup)
        self.assertFalse(first.needs_staff_dropoff)
        self.assertFalse(last.needs_staff_pickup)
        self.assertTrue(last.needs_staff_dropoff)


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
        # Assignment is kept but marked as UNASSIGNED (not deleted) so that
        # _materialize_roster_for_date does not re-create it. It must NOT be
        # REMOVED — that means "not attending today" and made the dog vanish
        # from the board entirely.
        assignment.refresh_from_db()
        self.assertEqual(assignment.status, 'UNASSIGNED')
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

    def test_unassign_just_this_day_hides_dog_from_staff_roster(self):
        """An unassigned dog must leave the staff member's column but stay on
        the day (regression: it was marked REMOVED and disappeared from the
        whole board). Runs on SQLite, unlike the unassigned-pool test."""
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post(
            f'/api/daily-assignments/{assignment.id}/unassign/',
            {'scope': 'just_this_day'}, format='json',
        )
        self.assertEqual(resp.status_code, 204)

        # Gone from the day roster listing...
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertNotIn(self.dog.id, [a['dog'] for a in resp.data])

        # ...but NOT removed from the day: the row still marks it attending.
        assignment.refresh_from_db()
        self.assertEqual(assignment.status, 'UNASSIGNED')

    def test_mark_removed_after_unassign_still_removes(self):
        """Remove-from-day on an unassigned dog flips UNASSIGNED → REMOVED."""
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today, status='UNASSIGNED'
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id,
            'date': self.today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 204)
        assignment.refresh_from_db()
        self.assertEqual(assignment.status, 'REMOVED')

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
        self.assertEqual(assignment.status, 'UNASSIGNED')

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
        # The UNASSIGNED row is hidden from `today`, and materialization must
        # not insert a duplicate or flip the status back to ASSIGNED.
        self.assertEqual(len(resp.data), 0)
        rows = DailyDogAssignment.objects.filter(dog=self.dog, date=self.today)
        self.assertEqual(rows.count(), 1)
        self.assertEqual(rows.get().status, 'UNASSIGNED')

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

    # --- persistent route-order memory (F1) ---

    def _make_dog(self, name, staff):
        dog = Dog.objects.create(
            owner=self.owner, name=name,
            daycare_days=[self.today_weekday], schedule_type='weekly',
        )
        DogWeekdayPickup.objects.create(
            dog=dog, weekday=self.today_weekday, staff_member=staff,
        )
        assignment = DailyDogAssignment.objects.create(
            dog=dog, staff_member=staff, date=self.today,
        )
        return dog, assignment

    def test_reorder_writes_back_to_weekday_roster(self):
        dog1, a1 = self._make_dog('Ace', self.staff_a)
        dog2, a2 = self._make_dog('Buddy', self.staff_a)
        self.client.login(username='staffa', password='pw')
        # Reverse the order: dog2 first, dog1 second.
        resp = self.client.post('/api/daily-assignments/reorder/', {
            'assignment_ids': [a2.id, a1.id],
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        roster1 = DogWeekdayPickup.objects.get(dog=dog1, weekday=self.today_weekday)
        roster2 = DogWeekdayPickup.objects.get(dog=dog2, weekday=self.today_weekday)
        self.assertEqual(roster2.sort_order, 0)
        self.assertEqual(roster1.sort_order, 1)

    def test_reorder_writeback_skips_dog_without_roster(self):
        # Assignment exists but the dog has no DogWeekdayPickup row (ad-hoc).
        dog = Dog.objects.create(
            owner=self.owner, name='Loner',
            daycare_days=[self.today_weekday], schedule_type='ad_hoc',
        )
        assignment = DailyDogAssignment.objects.create(
            dog=dog, staff_member=self.staff_a, date=self.today,
        )
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/reorder/', {
            'assignment_ids': [assignment.id],
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(DogWeekdayPickup.objects.filter(dog=dog).exists())

    def test_reorder_writeback_ignores_non_roster_staff(self):
        # Roster says staff_a owns the route, but today's assignment was
        # reassigned to staff_b. The roster default must stay with staff_a.
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday,
            staff_member=self.staff_a, sort_order=5,
        )
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_b, date=self.today,
        )
        self.client.login(username='staffb', password='pw')
        resp = self.client.post('/api/daily-assignments/reorder/', {
            'assignment_ids': [assignment.id],
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        assignment.refresh_from_db()
        self.assertEqual(assignment.sort_order, 0)
        roster = DogWeekdayPickup.objects.get(dog=self.dog, weekday=self.today_weekday)
        self.assertEqual(roster.sort_order, 5)

    def test_materialization_copies_roster_sort_order(self):
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today_weekday,
            staff_member=self.staff_a, sort_order=7,
        )
        self.assertEqual(DailyDogAssignment.objects.count(), 0)
        self.client.login(username='staffa', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.today)
        self.assertEqual(assignment.sort_order, 7)

    def test_reorder_writeback_round_trip(self):
        # Reorder, then drop the day's rows and re-materialize — the remembered
        # order from the roster must be preserved.
        dog1, a1 = self._make_dog('Ace', self.staff_a)
        dog2, a2 = self._make_dog('Buddy', self.staff_a)
        self.client.login(username='staffa', password='pw')
        resp = self.client.post('/api/daily-assignments/reorder/', {
            'assignment_ids': [a2.id, a1.id],
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        # Simulate a fresh day: delete the materialized rows, then re-fetch.
        DailyDogAssignment.objects.filter(date=self.today).delete()
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        new1 = DailyDogAssignment.objects.get(dog=dog1, date=self.today)
        new2 = DailyDogAssignment.objects.get(dog=dog2, date=self.today)
        self.assertEqual(new2.sort_order, 0)
        self.assertEqual(new1.sort_order, 1)


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

    def test_status_change_sends_single_owner_notification(self):
        # A viewset call and a model signal used to each push on status
        # change, so the owner got two notifications per approve/deny.
        br = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        br.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        with patch('api.notifications.send_push_notification') as mock_push:
            resp = self.client.post(f'/api/boarding-requests/{br.id}/change_status/', {
                'status': 'APPROVED',
            }, format='json')
        self.assertEqual(resp.status_code, 200)
        owner_pushes = [c for c in mock_push.call_args_list if c.args[0] == self.owner]
        self.assertEqual(len(owner_pushes), 1)
        args, kwargs = owner_pushes[0]
        self.assertEqual(kwargs.get('category'), 'bookings')
        self.assertEqual(args[3]['type'], 'boarding_request_update')

    # --- editing bookings ---

    def test_owner_can_edit_pending_boarding(self):
        br = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        br.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/boarding-requests/{br.id}/', {
            'start_date': '2026-04-02',
            'end_date': '2026-04-06',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        br.refresh_from_db()
        self.assertEqual(str(br.start_date), '2026-04-02')
        self.assertEqual(str(br.end_date), '2026-04-06')

    def test_owner_cannot_edit_approved_boarding(self):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED')
        br.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/boarding-requests/{br.id}/', {
            'end_date': '2026-04-07',
        }, format='json')
        self.assertEqual(resp.status_code, 403)
        br.refresh_from_db()
        self.assertEqual(str(br.end_date), '2026-04-05')

    def test_staff_can_edit_approved_boarding(self):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED')
        br.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        resp = self.client.patch(f'/api/boarding-requests/{br.id}/', {
            'start_date': '2026-04-03',
            'end_date': '2026-04-08',
            'special_instructions': 'Bring her blanket',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        br.refresh_from_db()
        self.assertEqual(str(br.start_date), '2026-04-03')
        self.assertEqual(str(br.end_date), '2026-04-08')
        self.assertEqual(br.special_instructions, 'Bring her blanket')

    # --- staff auto-approval + boarding-with staff (new) ---

    def test_staff_created_boarding_auto_approves(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'owner': self.owner.id,
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'APPROVED')
        br = BoardingRequest.objects.get(id=resp.data['id'])
        self.assertEqual(br.approved_by, self.staff)
        self.assertIsNotNone(br.approved_at)
        hist = BoardingRequestHistory.objects.filter(request=br).first()
        self.assertIsNotNone(hist)
        self.assertEqual(hist.from_status, 'PENDING')
        self.assertEqual(hist.to_status, 'APPROVED')

    def test_owner_created_boarding_stays_pending(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'PENDING')

    def test_approve_with_assigned_staff_sets_boarding_with(self):
        carer = User.objects.create_user(username='carer', password='pw', is_staff=True, first_name='Cara')
        br = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        br.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{br.id}/change_status/', {
            'status': 'APPROVED',
            'assigned_staff_id': carer.id,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['assigned_staff'], carer.id)
        self.assertEqual(resp.data['assigned_staff_name'], 'Cara')
        br.refresh_from_db()
        self.assertEqual(br.assigned_staff, carer)

    # --- duplicate booking flag ---

    def test_duplicate_boarding_same_dates_rejected(self):
        existing = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        existing.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertIn('Bella', str(resp.data))

    def test_overlapping_boarding_rejected(self):
        existing = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED',
        )
        existing.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        # Overlaps on 2026-04-05 only.
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-05',
            'end_date': '2026-04-08',
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_staff_created_duplicate_rejected(self):
        existing = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        existing.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'owner': self.owner.id,
            'start_date': '2026-04-03',
            'end_date': '2026-04-06',
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_denied_boarding_does_not_block_rebooking(self):
        existing = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='DENIED',
        )
        existing.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 201)

    def test_non_overlapping_boarding_allowed(self):
        existing = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        existing.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-06',
            'end_date': '2026-04-10',
        }, format='json')
        self.assertEqual(resp.status_code, 201)

    def test_other_dog_not_blocked_by_duplicate(self):
        other_dog = Dog.objects.create(owner=self.owner, name='Rex')
        existing = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        existing.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [other_dog.id],
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 201)

    def test_update_own_request_does_not_self_conflict(self):
        br = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        br.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/boarding-requests/{br.id}/', {
            'end_date': '2026-04-06',
        }, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_approving_overlapping_pending_request_rejected(self):
        approved = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED',
        )
        approved.dogs.add(self.dog)
        pending = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-03', end_date='2026-04-07')
        pending.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{pending.id}/change_status/', {
            'status': 'APPROVED',
        }, format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertIn('Bella', resp.data['detail'])
        pending.refresh_from_db()
        self.assertEqual(pending.status, 'PENDING')

    def test_approving_non_overlapping_pending_request_allowed(self):
        approved = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED',
        )
        approved.dogs.add(self.dog)
        pending = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-06', end_date='2026-04-09')
        pending.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{pending.id}/change_status/', {
            'status': 'APPROVED',
        }, format='json')
        self.assertEqual(resp.status_code, 200)

    # --- deleting bookings (duplicate cleanup) ---

    def test_staff_can_delete_any_boarding_request(self):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED',
        )
        br.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        resp = self.client.delete(f'/api/boarding-requests/{br.id}/')
        self.assertEqual(resp.status_code, 204)
        self.assertFalse(BoardingRequest.objects.filter(id=br.id).exists())

    def test_owner_can_withdraw_own_pending_request(self):
        br = BoardingRequest.objects.create(owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        br.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.delete(f'/api/boarding-requests/{br.id}/')
        self.assertEqual(resp.status_code, 204)
        self.assertFalse(BoardingRequest.objects.filter(id=br.id).exists())

    def test_owner_cannot_delete_approved_booking(self):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED',
        )
        br.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.delete(f'/api/boarding-requests/{br.id}/')
        self.assertEqual(resp.status_code, 403)
        self.assertTrue(BoardingRequest.objects.filter(id=br.id).exists())

    def test_owner_cannot_delete_others_requests(self):
        other = User.objects.create_user(username='other2', password='pw')
        br = BoardingRequest.objects.create(owner=other, start_date='2026-04-01', end_date='2026-04-05')
        self.client.login(username='owner', password='pw')
        resp = self.client.delete(f'/api/boarding-requests/{br.id}/')
        self.assertEqual(resp.status_code, 404)
        self.assertTrue(BoardingRequest.objects.filter(id=br.id).exists())

    def test_assign_staff_action_reassigns_and_clears(self):
        carer = User.objects.create_user(username='carer', password='pw', is_staff=True)
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED',
        )
        br.dogs.add(self.dog)
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{br.id}/assign_staff/', {
            'assigned_staff_id': carer.id,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        br.refresh_from_db()
        self.assertEqual(br.assigned_staff, carer)
        # Passing null clears the assignment.
        resp = self.client.post(f'/api/boarding-requests/{br.id}/assign_staff/', {
            'assigned_staff_id': None,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        br.refresh_from_db()
        self.assertIsNone(br.assigned_staff)

    def test_non_staff_cannot_assign_boarding_staff(self):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05', status='APPROVED',
        )
        self.client.login(username='owner', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{br.id}/assign_staff/', {
            'assigned_staff_id': self.staff.id,
        }, format='json')
        self.assertIn(resp.status_code, (401, 403))


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
        # Staff badge counts open queries with unread owner messages, not all
        # open queries (an open but fully-read conversation shows no badge).
        SupportQuery.objects.create(owner=self.owner, subject='Open unread 1', staff_has_unread=True)
        SupportQuery.objects.create(owner=self.owner, subject='Open unread 2', staff_has_unread=True)
        SupportQuery.objects.create(owner=self.owner, subject='Open read')
        SupportQuery.objects.create(owner=self.owner, subject='Resolved', status='RESOLVED', staff_has_unread=True)
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
        # The coverage endpoint reads is_available_daycare; set it alongside
        # is_available, mirroring what set_my_availability writes.
        StaffAvailability.objects.create(
            staff_member=self.staff, day_of_week=1,
            is_available=True, is_available_daycare=True,
        )
        StaffAvailability.objects.create(
            staff_member=self.staff2, day_of_week=1,
            is_available=False, is_available_daycare=False,
        )
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

    # ── available_staff: only approved time off greys staff out ──────────

    def test_available_staff_ignores_weekly_working_pattern(self):
        """A regular non-working weekday must NOT make a staff member
        unavailable to assign — only approved time off does."""
        today = date.today()
        StaffAvailability.objects.create(
            staff_member=self.staff, day_of_week=today.isoweekday(),
            is_available=False, is_available_daycare=False,
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/staff-availability/available_staff/{today.isoformat()}/')
        self.assertEqual(resp.status_code, 200)
        ids = [s['id'] for s in resp.data]
        self.assertIn(self.staff.id, ids)

    def test_available_staff_excludes_approved_day_off(self):
        today = date.today()
        DayOffRequest.objects.create(staff_member=self.staff, date=today, status='APPROVED')
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/staff-availability/available_staff/{today.isoformat()}/')
        self.assertEqual(resp.status_code, 200)
        ids = [s['id'] for s in resp.data]
        self.assertNotIn(self.staff.id, ids)
        self.assertIn(self.staff2.id, ids)

    def test_available_staff_ignores_pending_or_denied_day_off(self):
        today = date.today()
        DayOffRequest.objects.create(staff_member=self.staff, date=today, status='PENDING')
        DayOffRequest.objects.create(staff_member=self.staff2, date=today, status='DENIED')
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/staff-availability/available_staff/{today.isoformat()}/')
        self.assertEqual(resp.status_code, 200)
        ids = [s['id'] for s in resp.data]
        self.assertIn(self.staff.id, ids)
        self.assertIn(self.staff2.id, ids)


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

    # --- staff identity colour ---

    def test_set_staff_color(self):
        self.client.login(username='user1', password='pw')
        resp = self.client.post('/api/profile/', {'staff_color': '#e53935'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.user.profile.refresh_from_db()
        # Stored normalised to uppercase.
        self.assertEqual(self.user.profile.staff_color, '#E53935')
        self.assertEqual(resp.data['staff_color'], '#E53935')

    def test_clear_staff_color(self):
        self.user.profile.staff_color = '#E53935'
        self.user.profile.save()
        self.client.login(username='user1', password='pw')
        resp = self.client.post('/api/profile/', {'staff_color': ''}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.user.profile.refresh_from_db()
        self.assertEqual(self.user.profile.staff_color, '')

    def test_invalid_staff_color_rejected(self):
        self.client.login(username='user1', password='pw')
        for bad in ['red', '#12345', '#GGGGGG', 'E53935']:
            resp = self.client.post('/api/profile/', {'staff_color': bad}, format='json')
            self.assertEqual(resp.status_code, 400, f'{bad} should be rejected')

    def test_staff_members_includes_color(self):
        staff = User.objects.create_user(username='colourstaff', password='pw', is_staff=True)
        staff.profile.staff_color = '#1E88E5'
        staff.profile.save()
        plain = User.objects.create_user(username='plainstaff', password='pw', is_staff=True)
        self.client.login(username='colourstaff', password='pw')
        resp = self.client.get('/api/daily-assignments/staff_members/')
        self.assertEqual(resp.status_code, 200)
        by_id = {s['id']: s for s in resp.data}
        self.assertEqual(by_id[staff.id]['staff_color'], '#1E88E5')
        self.assertEqual(by_id[plain.id]['staff_color'], '')


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

    def test_materialization_skips_dog_when_owner_handles_both_legs(self):
        # Remove today's assignment so the materializer has a clean state
        self.assignment.delete()
        # Owner handles BOTH legs — no staff route ever touches this dog.
        self.dog.owner_brings_default = True
        self.dog.owner_collects_default = True
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

    def test_materialization_includes_dog_when_owner_brings_only(self):
        # Owner drops off in the morning but STAFF drop home — the dog must be
        # on the route so staff can run the drop-off leg.
        self.assignment.delete()
        self.dog.owner_brings_default = True
        self.dog.owner_collects_default = False
        self.dog.save()
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today.isoweekday(),
            staff_member=self.staff,
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(DailyDogAssignment.objects.filter(dog=self.dog, date=self.today).exists())

    def test_materialization_includes_dog_when_owner_collects_only(self):
        # Staff pick up in the morning but OWNER collects — the dog must be on
        # the route so staff can run the pickup leg.
        self.assignment.delete()
        self.dog.owner_brings_default = False
        self.dog.owner_collects_default = True
        self.dog.save()
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=self.today.isoweekday(),
            staff_member=self.staff,
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/daily-assignments/today/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(DailyDogAssignment.objects.filter(dog=self.dog, date=self.today).exists())

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


# Use non-manifest static storage so admin templates render in tests without a
# collectstatic-built manifest (production uses whitenoise's manifest storage).
@override_settings(STORAGES={
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
})
class AdminNullOwnerTests(TestCase):
    """Regression: admin change-list pages must not 500 when a dog has no owner.

    Deleting an owner account sets Dog.owner to NULL (on_delete=SET_NULL). The
    Dog / Daily Assignment / Date Change admin pages previously crashed because
    their "owner" column dereferenced a None user.
    """

    def setUp(self):
        self.admin = User.objects.create_superuser(username='admin', password='pw')
        # A dog whose owner has been removed (owner is NULL), plus related rows
        # whose admin pages also surface the owner.
        self.orphan_dog = Dog.objects.create(owner=None, name='Orphan')
        self.staff = User.objects.create_user(username='walker', password='pw', is_staff=True)
        DailyDogAssignment.objects.create(
            dog=self.orphan_dog, staff_member=self.staff, date=date.today())
        DateChangeRequest.objects.create(
            dog=self.orphan_dog, request_type='CANCEL', original_date=date.today())
        self.client = Client()
        self.client.force_login(self.admin)

    def test_dog_changelist_ok_with_null_owner(self):
        resp = self.client.get('/admin/api/dog/')
        self.assertEqual(resp.status_code, 200)

    def test_daily_assignment_changelist_ok_with_null_owner(self):
        resp = self.client.get('/admin/api/dailydogassignment/')
        self.assertEqual(resp.status_code, 200)

    def test_date_change_changelist_ok_with_null_owner(self):
        resp = self.client.get('/admin/api/datechangerequest/')
        self.assertEqual(resp.status_code, 200)


class DogAssignOwnerTests(TestCase):
    """The /assign/ endpoint must be able to clear a dog's primary owner.

    The app sends an explicit ``{"owner": null}`` to remove the owner; omitting
    the key entirely must leave the existing owner untouched.
    """

    def setUp(self):
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.dog = Dog.objects.create(owner=self.owner, name='Rex')
        self.client = APIClient()

    def test_staff_can_clear_primary_owner(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/dogs/{self.dog.id}/assign/', {'owner': None}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertIsNone(self.dog.owner)

    def test_omitting_owner_leaves_it_unchanged(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/dogs/{self.dog.id}/assign/', {'additional_owners': []}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.owner, self.owner)

    def test_non_staff_cannot_assign(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post(f'/api/dogs/{self.dog.id}/assign/', {'owner': None}, format='json')
        self.assertEqual(resp.status_code, 403)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.owner, self.owner)


class VaccinationRecordTests(TestCase):
    def setUp(self):
        from .models import VaccinationRecord  # noqa: F401 (model import sanity)
        self.owner = User.objects.create_user(username='vaxowner', password='pw')
        self.other = User.objects.create_user(username='vaxother', password='pw')
        self.staff = User.objects.create_user(username='vaxstaff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Fido')
        self.other_dog = Dog.objects.create(owner=self.other, name='Rex')
        self.client = APIClient()

    def _payload(self, **kwargs):
        base = {
            'dog': self.dog.id,
            'name': 'DHP',
            'date_administered': (date.today() - timedelta(days=10)).isoformat(),
            'expiry_date': (date.today() + timedelta(days=355)).isoformat(),
        }
        base.update(kwargs)
        return base

    def test_staff_can_create_record(self):
        self.client.login(username='vaxstaff', password='pw')
        resp = self.client.post('/api/vaccinations/', self._payload(), format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'up_to_date')

    def test_owner_cannot_create_record(self):
        self.client.login(username='vaxowner', password='pw')
        resp = self.client.post('/api/vaccinations/', self._payload(), format='json')
        self.assertEqual(resp.status_code, 403)

    def test_owner_sees_only_own_dogs_records(self):
        from .models import VaccinationRecord
        VaccinationRecord.objects.create(
            dog=self.dog, name='DHP',
            date_administered=date.today() - timedelta(days=10),
            expiry_date=date.today() + timedelta(days=355),
        )
        VaccinationRecord.objects.create(
            dog=self.other_dog, name='Rabies',
            date_administered=date.today() - timedelta(days=10),
            expiry_date=date.today() + timedelta(days=355),
        )
        self.client.login(username='vaxowner', password='pw')
        resp = self.client.get('/api/vaccinations/')
        self.assertEqual(resp.status_code, 200)
        names = {r['name'] for r in resp.data}
        self.assertEqual(names, {'DHP'})

    def test_expiry_must_be_after_administered(self):
        self.client.login(username='vaxstaff', password='pw')
        resp = self.client.post(
            '/api/vaccinations/',
            self._payload(expiry_date=(date.today() - timedelta(days=20)).isoformat()),
            format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_status_property(self):
        from .models import VaccinationRecord
        expired = VaccinationRecord.objects.create(
            dog=self.dog, name='A',
            date_administered=date.today() - timedelta(days=400),
            expiry_date=date.today() - timedelta(days=1),
        )
        soon = VaccinationRecord.objects.create(
            dog=self.dog, name='B',
            date_administered=date.today() - timedelta(days=350),
            expiry_date=date.today() + timedelta(days=10),
        )
        fine = VaccinationRecord.objects.create(
            dog=self.dog, name='C',
            date_administered=date.today() - timedelta(days=10),
            expiry_date=date.today() + timedelta(days=200),
        )
        self.assertEqual(expired.status, 'expired')
        self.assertEqual(soon.status, 'expiring_soon')
        self.assertEqual(fine.status, 'up_to_date')

    def test_reminder_command_sends_once(self):
        import io
        from django.core.management import call_command
        from .models import VaccinationRecord
        VaccinationRecord.objects.create(
            dog=self.dog, name='Expired',
            date_administered=date.today() - timedelta(days=400),
            expiry_date=date.today() - timedelta(days=2),
        )
        VaccinationRecord.objects.create(
            dog=self.dog, name='Soon',
            date_administered=date.today() - timedelta(days=350),
            expiry_date=date.today() + timedelta(days=5),
        )
        VaccinationRecord.objects.create(
            dog=self.dog, name='Fine',
            date_administered=date.today() - timedelta(days=10),
            expiry_date=date.today() + timedelta(days=300),
        )
        out = io.StringIO()
        call_command('send_vaccination_reminders', stdout=out)
        self.assertIn('Sent 2', out.getvalue())
        out = io.StringIO()
        call_command('send_vaccination_reminders', stdout=out)
        self.assertIn('Sent 0', out.getvalue())

    def test_editing_expiry_rearms_reminders(self):
        from .models import VaccinationRecord
        record = VaccinationRecord.objects.create(
            dog=self.dog, name='DHP',
            date_administered=date.today() - timedelta(days=400),
            expiry_date=date.today() - timedelta(days=2),
            reminder_30_sent=True, reminder_7_sent=True, expired_notice_sent=True,
        )
        self.client.login(username='vaxstaff', password='pw')
        resp = self.client.patch(
            f'/api/vaccinations/{record.id}/',
            {
                'date_administered': date.today().isoformat(),
                'expiry_date': (date.today() + timedelta(days=365)).isoformat(),
            },
            format='json',
        )
        self.assertEqual(resp.status_code, 200)
        record.refresh_from_db()
        self.assertFalse(record.reminder_30_sent)
        self.assertFalse(record.reminder_7_sent)
        self.assertFalse(record.expired_notice_sent)


class OwnerCalendarTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='calowner', password='pw')
        self.other = User.objects.create_user(username='calother', password='pw')
        self.target = date.today() + timedelta(days=14)
        self.weekday = self.target.isoweekday()
        self.dog = Dog.objects.create(
            owner=self.owner, name='Fido', daycare_days=[self.weekday],
        )
        self.other_dog = Dog.objects.create(
            owner=self.other, name='Rex', daycare_days=[self.weekday],
        )
        self.client = APIClient()
        self.client.login(username='calowner', password='pw')

    def _day(self):
        resp = self.client.get(
            f'/api/dogs/calendar/?start={self.target}&end={self.target}'
        )
        self.assertEqual(resp.status_code, 200)
        return resp.data['days'][0]

    def test_weekly_dog_appears_on_scheduled_day(self):
        day = self._day()
        self.assertEqual([d['name'] for d in day['dogs']], ['Fido'])

    def test_only_own_dogs_listed(self):
        day = self._day()
        names = [d['name'] for d in day['dogs']]
        self.assertNotIn('Rex', names)

    def test_cancelled_day_removed(self):
        DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL',
            original_date=self.target, status='APPROVED',
        )
        day = self._day()
        self.assertEqual(day['dogs'], [])

    def test_add_day_appears(self):
        extra = self.target + timedelta(days=1)
        DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY',
            new_date=extra, status='APPROVED',
        )
        resp = self.client.get(f'/api/dogs/calendar/?start={extra}&end={extra}')
        day = resp.data['days'][0]
        self.assertEqual([d['name'] for d in day['dogs']], ['Fido'])

    def test_closure_marked_and_no_dogs(self):
        ClosureDay.objects.create(date=self.target, closure_type='CLOSED', reason='Bank Holiday')
        day = self._day()
        self.assertEqual(day['closure']['closure_type'], 'CLOSED')
        self.assertEqual(day['dogs'], [])

    def test_full_day_marked(self):
        from .models import DaycareSettings
        settings_obj = DaycareSettings.load()
        settings_obj.default_daily_capacity = 1
        settings_obj.save()
        day = self._day()  # two dogs scheduled, capacity 1
        self.assertTrue(day['is_full'])
        self.assertEqual(day['capacity'], 1)
        self.assertEqual(day['spots_left'], 0)


class CapacityEnforcementTests(TestCase):
    def setUp(self):
        from .models import DaycareSettings
        self.owner = User.objects.create_user(username='capowner', password='pw')
        self.staff = User.objects.create_user(username='capstaff', password='pw', is_staff=True)
        self.target = date.today() + timedelta(days=14)
        self.weekday = self.target.isoweekday()
        # dog1 fills the single slot via its weekly schedule
        self.dog1 = Dog.objects.create(owner=self.owner, name='Fido', daycare_days=[self.weekday])
        self.dog2 = Dog.objects.create(owner=self.owner, name='Rex', schedule_type='ad_hoc')
        settings_obj = DaycareSettings.load()
        settings_obj.default_daily_capacity = 1
        settings_obj.save()
        self.client = APIClient()

    def test_staff_add_day_blocked_when_full(self):
        self.client.login(username='capstaff', password='pw')
        resp = self.client.post('/api/date-change-requests/', {
            'dog': self.dog2.id, 'request_type': 'ADD_DAY', 'new_date': self.target.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertIn('full', str(resp.data).lower())

    def test_staff_add_day_with_override(self):
        self.client.login(username='capstaff', password='pw')
        resp = self.client.post('/api/date-change-requests/', {
            'dog': self.dog2.id, 'request_type': 'ADD_DAY',
            'new_date': self.target.isoformat(), 'override_capacity': True,
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')

    def test_approval_blocked_when_full_then_override(self):
        req = DateChangeRequest.objects.create(
            dog=self.dog2, request_type='ADD_DAY', new_date=self.target,
        )
        self.client.login(username='capstaff', password='pw')
        url = f'/api/date-change-requests/{req.id}/change_status/'
        resp = self.client.post(url, {'status': 'APPROVED'}, format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.data.get('code'), 'capacity_full')
        resp = self.client.post(url, {'status': 'APPROVED', 'override_capacity': True}, format='json')
        self.assertEqual(resp.status_code, 200)
        req.refresh_from_db()
        self.assertEqual(req.status, 'APPROVED')

    def test_owner_request_not_capacity_checked_at_creation(self):
        self.client.login(username='capowner', password='pw')
        resp = self.client.post('/api/date-change-requests/', {
            'dog': self.dog2.id, 'request_type': 'ADD_DAY', 'new_date': self.target.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'PENDING')

    def test_reduced_closure_capacity_override(self):
        from .models import DaycareSettings
        settings_obj = DaycareSettings.load()
        settings_obj.default_daily_capacity = None  # unlimited by default
        settings_obj.save()
        ClosureDay.objects.create(
            date=self.target, closure_type='REDUCED', capacity_override=1,
        )
        self.client.login(username='capstaff', password='pw')
        resp = self.client.post('/api/date-change-requests/', {
            'dog': self.dog2.id, 'request_type': 'ADD_DAY', 'new_date': self.target.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 400)


class WaitlistTests(TestCase):
    def setUp(self):
        from .models import DaycareSettings
        self.owner1 = User.objects.create_user(username='wlowner1', password='pw')
        self.owner2 = User.objects.create_user(username='wlowner2', password='pw')
        self.staff = User.objects.create_user(username='wlstaff', password='pw', is_staff=True)
        self.target = date.today() + timedelta(days=14)
        self.weekday = self.target.isoweekday()
        self.dog1 = Dog.objects.create(owner=self.owner1, name='Fido', daycare_days=[self.weekday])
        self.dog2 = Dog.objects.create(owner=self.owner2, name='Rex', schedule_type='ad_hoc')
        settings_obj = DaycareSettings.load()
        settings_obj.default_daily_capacity = 1
        settings_obj.save()
        self.client = APIClient()

    def test_owner_joins_waitlist(self):
        self.client.login(username='wlowner2', password='pw')
        resp = self.client.post('/api/waitlist/', {
            'dog': self.dog2.id, 'date': self.target.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'WAITING')
        # joining again is idempotent
        resp = self.client.post('/api/waitlist/', {
            'dog': self.dog2.id, 'date': self.target.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_cannot_join_for_others_dog(self):
        self.client.login(username='wlowner2', password='pw')
        resp = self.client.post('/api/waitlist/', {
            'dog': self.dog1.id, 'date': self.target.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_already_booked_rejected(self):
        self.client.login(username='wlowner1', password='pw')
        resp = self.client.post('/api/waitlist/', {
            'dog': self.dog1.id, 'date': self.target.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_cancel_approval_notifies_waitlist(self):
        from .models import WaitlistEntry
        entry = WaitlistEntry.objects.create(
            dog=self.dog2, date=self.target, requested_by=self.owner2,
        )
        cancel = DateChangeRequest.objects.create(
            dog=self.dog1, request_type='CANCEL', original_date=self.target,
        )
        self.client.login(username='wlstaff', password='pw')
        resp = self.client.post(
            f'/api/date-change-requests/{cancel.id}/change_status/',
            {'status': 'APPROVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        entry.refresh_from_db()
        self.assertEqual(entry.status, 'NOTIFIED')
        self.assertIsNotNone(entry.notified_at)

    def test_leave_waitlist(self):
        from .models import WaitlistEntry
        entry = WaitlistEntry.objects.create(
            dog=self.dog2, date=self.target, requested_by=self.owner2,
        )
        self.client.login(username='wlowner2', password='pw')
        resp = self.client.delete(f'/api/waitlist/{entry.id}/')
        self.assertEqual(resp.status_code, 204)
        self.assertFalse(WaitlistEntry.objects.filter(id=entry.id).exists())


def _test_image_file(name='test.jpg'):
    """A small in-memory JPEG for upload tests."""
    import io as _io
    from PIL import Image
    from django.core.files.uploadedfile import SimpleUploadedFile
    buf = _io.BytesIO()
    Image.new('RGB', (50, 50), color='red').save(buf, format='JPEG')
    return SimpleUploadedFile(name, buf.getvalue(), content_type='image/jpeg')


class FleetVehicleTests(TestCase):
    def setUp(self):
        from .models import Vehicle  # noqa: F401 (model import sanity)
        self.owner = User.objects.create_user(username='fleetowner', password='pw')
        self.staff = User.objects.create_user(username='fleetstaff', password='pw', is_staff=True)
        self.manager = User.objects.create_user(username='fleetmanager', password='pw', is_staff=True)
        self.manager.profile.can_manage_vehicles = True
        self.manager.profile.save()
        self.client = APIClient()

    def _create_vehicle(self, **kwargs):
        from .models import Vehicle
        base = {'name': 'Blue Van', 'registration': 'AB12 CDE'}
        base.update(kwargs)
        return Vehicle.objects.create(**base)

    def test_non_staff_cannot_list_vehicles(self):
        self.client.login(username='fleetowner', password='pw')
        resp = self.client.get('/api/vehicles/')
        self.assertEqual(resp.status_code, 403)

    def test_staff_can_list_vehicles(self):
        self._create_vehicle()
        self.client.login(username='fleetstaff', password='pw')
        resp = self.client.get('/api/vehicles/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        self.assertEqual(resp.data[0]['registration'], 'AB12 CDE')

    def test_plain_staff_cannot_create_vehicle(self):
        self.client.login(username='fleetstaff', password='pw')
        resp = self.client.post('/api/vehicles/', {'name': 'Van', 'registration': 'XY99 ZZZ'}, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_manager_can_create_vehicle(self):
        self.client.login(username='fleetmanager', password='pw')
        resp = self.client.post(
            '/api/vehicles/',
            {
                'name': 'Red Van', 'registration': 'XY99 ZZZ',
                'mot_due_date': (date.today() + timedelta(days=200)).isoformat(),
            },
            format='json',
        )
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['mot_status'], 'ok')
        self.assertEqual(resp.data['status'], 'ACTIVE')

    def test_plain_staff_cannot_delete_vehicle(self):
        vehicle = self._create_vehicle()
        self.client.login(username='fleetstaff', password='pw')
        resp = self.client.delete(f'/api/vehicles/{vehicle.id}/')
        self.assertEqual(resp.status_code, 403)

    def test_updating_dates_creates_history_and_rearms_flags(self):
        from .models import VehicleMaintenanceRecord
        vehicle = self._create_vehicle(
            mot_due_date=date.today() - timedelta(days=5),
            mot_reminder_30_sent=True, mot_reminder_7_sent=True, mot_overdue_notice_sent=True,
        )
        self.client.login(username='fleetmanager', password='pw')
        new_mot = date.today() + timedelta(days=365)
        resp = self.client.patch(
            f'/api/vehicles/{vehicle.id}/',
            {'mot_due_date': new_mot.isoformat(), 'maintenance_notes': 'Passed MOT'},
            format='json',
        )
        self.assertEqual(resp.status_code, 200)
        vehicle.refresh_from_db()
        self.assertFalse(vehicle.mot_reminder_30_sent)
        self.assertFalse(vehicle.mot_reminder_7_sent)
        self.assertFalse(vehicle.mot_overdue_notice_sent)
        records = VehicleMaintenanceRecord.objects.filter(vehicle=vehicle)
        self.assertEqual(records.count(), 1)
        record = records.first()
        self.assertEqual(record.event_type, 'MOT')
        self.assertEqual(record.new_due_date, new_mot)
        self.assertEqual(record.notes, 'Passed MOT')
        self.assertEqual(record.created_by, self.manager)

        history = self.client.get(f'/api/vehicles/{vehicle.id}/history/')
        self.assertEqual(history.status_code, 200)
        self.assertEqual(len(history.data), 1)

    def test_date_status_properties(self):
        overdue = self._create_vehicle(
            registration='OV1', mot_due_date=date.today() - timedelta(days=1))
        soon = self._create_vehicle(
            registration='SN1', mot_due_date=date.today() + timedelta(days=10))
        fine = self._create_vehicle(
            registration='OK1', mot_due_date=date.today() + timedelta(days=200))
        none_set = self._create_vehicle(registration='NA1')
        self.assertEqual(overdue.mot_status, 'overdue')
        self.assertEqual(soon.mot_status, 'due_soon')
        self.assertEqual(fine.mot_status, 'ok')
        self.assertIsNone(none_set.mot_status)


class VehicleDefectTests(TestCase):
    def setUp(self):
        from .models import Vehicle
        self.owner = User.objects.create_user(username='defowner', password='pw')
        self.staff = User.objects.create_user(username='defstaff', password='pw', is_staff=True)
        self.manager = User.objects.create_user(username='defmanager', password='pw', is_staff=True)
        self.manager.profile.can_manage_vehicles = True
        self.manager.profile.save()
        self.vehicle = Vehicle.objects.create(name='Blue Van', registration='AB12 CDE')
        self.client = APIClient()

    def _create_defect(self, **kwargs):
        from .models import VehicleDefect
        base = {'vehicle': self.vehicle, 'title': 'Cracked mirror', 'reported_by': self.staff}
        base.update(kwargs)
        return VehicleDefect.objects.create(**base)

    # --- comments ---

    def test_staff_can_comment_on_vehicle_defect(self):
        defect = self._create_defect()
        self.client.login(username='defstaff', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/comment/',
            {'text': 'Part ordered, awaiting delivery'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data['comments']), 1)
        self.assertEqual(resp.data['comments'][0]['text'], 'Part ordered, awaiting delivery')
        self.assertEqual(resp.data['comments'][0]['user_name'], 'defstaff')

    def test_vehicle_defect_comment_requires_text(self):
        defect = self._create_defect()
        self.client.login(username='defstaff', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/comment/', {'text': '   '}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_non_staff_cannot_comment_on_vehicle_defect(self):
        defect = self._create_defect()
        self.client.login(username='defowner', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/comment/', {'text': 'hello'}, format='json',
        )
        self.assertIn(resp.status_code, (401, 403))

    @patch('api.notifications.send_push_notification')
    def test_vehicle_comment_notifies_reporter_when_other_staff_comments(self, mock_push):
        defect = self._create_defect(reported_by=self.staff)
        self.client.login(username='defmanager', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/comment/', {'text': 'Booked in for Friday'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        notified = {c.args[0].id for c in mock_push.call_args_list}
        self.assertIn(self.staff.id, notified)

    @patch('api.notifications.send_push_notification')
    def test_vehicle_comment_does_not_notify_self(self, mock_push):
        defect = self._create_defect(reported_by=self.staff)
        self.client.login(username='defstaff', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/comment/', {'text': 'Self note'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        notified = {c.args[0].id for c in mock_push.call_args_list}
        self.assertNotIn(self.staff.id, notified)

    def test_any_staff_can_report_defect_with_images(self):
        from .models import VehicleDefect, VehicleDefectImage
        self.client.login(username='defstaff', password='pw')
        resp = self.client.post(
            '/api/vehicle-defects/',
            {
                'vehicle': self.vehicle.id,
                'title': 'Cracked mirror',
                'description': 'Nearside wing mirror cracked',
                'severity': 'HIGH',
                'images': [_test_image_file('one.jpg'), _test_image_file('two.jpg')],
            },
            format='multipart',
        )
        self.assertEqual(resp.status_code, 201)
        defect = VehicleDefect.objects.get(pk=resp.data['id'])
        self.assertEqual(defect.reported_by, self.staff)
        self.assertEqual(defect.status, 'REPORTED')
        self.assertEqual(VehicleDefectImage.objects.filter(defect=defect).count(), 2)
        self.assertEqual(len(resp.data['images']), 2)

    def test_non_staff_cannot_report_defect(self):
        self.client.login(username='defowner', password='pw')
        resp = self.client.post(
            '/api/vehicle-defects/',
            {'vehicle': self.vehicle.id, 'title': 'Scratch'},
            format='json',
        )
        self.assertEqual(resp.status_code, 403)

    def test_any_staff_can_add_images_later(self):
        from .models import VehicleDefectImage
        defect = self._create_defect()
        self.client.login(username='defstaff', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/add_images/',
            {'images': [_test_image_file()]},
            format='multipart',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(VehicleDefectImage.objects.filter(defect=defect).count(), 1)

    def test_plain_staff_cannot_change_status(self):
        defect = self._create_defect()
        self.client.login(username='defstaff', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/change_status/',
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 403)

    def test_manager_change_status_sets_resolved_fields(self):
        defect = self._create_defect()
        self.client.login(username='defmanager', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/change_status/',
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        defect.refresh_from_db()
        self.assertEqual(defect.status, 'RESOLVED')
        self.assertEqual(defect.resolved_by, self.manager)
        self.assertIsNotNone(defect.resolved_at)

        # Reopening clears the resolved stamp
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/change_status/',
            {'status': 'IN_PROGRESS'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        defect.refresh_from_db()
        self.assertIsNone(defect.resolved_by)
        self.assertIsNone(defect.resolved_at)

    def test_invalid_status_rejected(self):
        defect = self._create_defect()
        self.client.login(username='defmanager', password='pw')
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/change_status/',
            {'status': 'BROKEN'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_filter_by_vehicle_and_status(self):
        from .models import Vehicle
        other_vehicle = Vehicle.objects.create(name='Red Van', registration='XX11 YYY')
        self._create_defect(title='Mirror')
        self._create_defect(vehicle=other_vehicle, title='Tyre', status='RESOLVED')
        self.client.login(username='defstaff', password='pw')
        resp = self.client.get(f'/api/vehicle-defects/?vehicle={self.vehicle.id}')
        self.assertEqual([d['title'] for d in resp.data], ['Mirror'])
        resp = self.client.get('/api/vehicle-defects/?status=RESOLVED')
        self.assertEqual([d['title'] for d in resp.data], ['Tyre'])

    def test_unresolved_count(self):
        self._create_defect(title='Mirror')
        self._create_defect(title='Tyre', status='IN_PROGRESS')
        self._create_defect(title='Done', status='RESOLVED')
        self.client.login(username='defstaff', password='pw')
        resp = self.client.get('/api/vehicle-defects/unresolved_count/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['count'], 2)

    def test_unresolved_count_requires_staff(self):
        self.client.login(username='defowner', password='pw')
        resp = self.client.get('/api/vehicle-defects/unresolved_count/')
        self.assertEqual(resp.status_code, 403)


class FacilityDefectTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='fdefowner', password='pw')
        self.staff = User.objects.create_user(username='fdefstaff', password='pw', is_staff=True)
        self.other_staff = User.objects.create_user(username='fdefstaff2', password='pw', is_staff=True)
        self.client = APIClient()

    def _create_defect(self, **kwargs):
        from .models import FacilityDefect
        base = {'title': 'Broken gate', 'reported_by': self.staff}
        base.update(kwargs)
        return FacilityDefect.objects.create(**base)

    # --- comments ---

    def test_staff_can_comment_on_facility_defect(self):
        defect = self._create_defect()
        self.client.login(username='fdefstaff', password='pw')
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/comment/',
            {'text': 'Contractor booked for Tuesday'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data['comments']), 1)
        self.assertEqual(resp.data['comments'][0]['text'], 'Contractor booked for Tuesday')

    def test_facility_defect_comment_requires_text(self):
        defect = self._create_defect()
        self.client.login(username='fdefstaff', password='pw')
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/comment/', {'text': ''}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    @patch('api.notifications.send_push_notification')
    def test_facility_comment_notifies_reporter_when_other_staff_comments(self, mock_push):
        defect = self._create_defect(reported_by=self.staff)
        self.client.login(username='fdefstaff2', password='pw')
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/comment/', {'text': 'Ordered a new latch'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        notified = {c.args[0].id for c in mock_push.call_args_list}
        self.assertIn(self.staff.id, notified)

    def test_any_staff_can_report_defect_with_images(self):
        from .models import FacilityDefect, FacilityDefectImage
        self.client.login(username='fdefstaff', password='pw')
        resp = self.client.post(
            '/api/facility-defects/',
            {
                'title': 'Broken gate',
                'location': 'Main paddock',
                'description': 'Latch has snapped off',
                'severity': 'HIGH',
                'images': [_test_image_file('one.jpg'), _test_image_file('two.jpg')],
            },
            format='multipart',
        )
        self.assertEqual(resp.status_code, 201)
        defect = FacilityDefect.objects.get(pk=resp.data['id'])
        self.assertEqual(defect.reported_by, self.staff)
        self.assertEqual(defect.status, 'REPORTED')
        self.assertEqual(defect.location, 'Main paddock')
        self.assertEqual(FacilityDefectImage.objects.filter(defect=defect).count(), 2)
        self.assertEqual(len(resp.data['images']), 2)
        for image in resp.data['images']:
            self.assertTrue(image['thumbnail'])

    def test_non_staff_cannot_report_or_list_defects(self):
        self.client.login(username='fdefowner', password='pw')
        resp = self.client.post(
            '/api/facility-defects/',
            {'title': 'Broken gate'}, format='json',
        )
        self.assertEqual(resp.status_code, 403)
        resp = self.client.get('/api/facility-defects/')
        self.assertEqual(resp.status_code, 403)

    def test_any_staff_can_add_images_later(self):
        from .models import FacilityDefectImage
        defect = self._create_defect()
        self.client.login(username='fdefstaff2', password='pw')
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/add_images/',
            {'images': [_test_image_file()]},
            format='multipart',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(FacilityDefectImage.objects.filter(defect=defect).count(), 1)

    def test_any_staff_can_change_status(self):
        defect = self._create_defect()
        self.client.login(username='fdefstaff2', password='pw')
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/change_status/',
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        defect.refresh_from_db()
        self.assertEqual(defect.status, 'RESOLVED')
        self.assertEqual(defect.resolved_by, self.other_staff)
        self.assertIsNotNone(defect.resolved_at)

        # Reopening clears the resolved stamp
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/change_status/',
            {'status': 'IN_PROGRESS'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        defect.refresh_from_db()
        self.assertIsNone(defect.resolved_by)
        self.assertIsNone(defect.resolved_at)

    def test_non_staff_cannot_change_status(self):
        defect = self._create_defect()
        self.client.login(username='fdefowner', password='pw')
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/change_status/',
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 403)

    def test_invalid_status_rejected(self):
        defect = self._create_defect()
        self.client.login(username='fdefstaff', password='pw')
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/change_status/',
            {'status': 'BROKEN'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_status_not_writable_via_create_or_patch(self):
        self.client.login(username='fdefstaff', password='pw')
        resp = self.client.post(
            '/api/facility-defects/',
            {'title': 'Broken gate', 'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'REPORTED')

        resp = self.client.patch(
            f"/api/facility-defects/{resp.data['id']}/",
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'REPORTED')

    def test_filter_by_status(self):
        self._create_defect(title='Gate')
        self._create_defect(title='Fence', status='RESOLVED')
        self.client.login(username='fdefstaff', password='pw')
        resp = self.client.get('/api/facility-defects/?status=RESOLVED')
        self.assertEqual([d['title'] for d in resp.data], ['Fence'])

    def test_unresolved_count(self):
        self._create_defect(title='Gate')
        self._create_defect(title='Fence', status='IN_PROGRESS')
        self._create_defect(title='Door', status='RESOLVED')
        self.client.login(username='fdefstaff', password='pw')
        resp = self.client.get('/api/facility-defects/unresolved_count/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['count'], 2)

    def test_unresolved_count_requires_staff(self):
        self.client.login(username='fdefowner', password='pw')
        resp = self.client.get('/api/facility-defects/unresolved_count/')
        self.assertEqual(resp.status_code, 403)


class FleetReminderCommandTests(TestCase):
    def setUp(self):
        self.manager = User.objects.create_user(username='remmanager', password='pw', is_staff=True)
        self.manager.profile.can_manage_vehicles = True
        self.manager.profile.save()

    def test_reminder_command_sends_once(self):
        import io
        from django.core.management import call_command
        from .models import Vehicle
        Vehicle.objects.create(
            name='Overdue Van', registration='OV1',
            mot_due_date=date.today() - timedelta(days=2),
        )
        Vehicle.objects.create(
            name='Soon Van', registration='SN1',
            service_due_date=date.today() + timedelta(days=5),
        )
        Vehicle.objects.create(
            name='Fine Van', registration='OK1',
            mot_due_date=date.today() + timedelta(days=300),
            service_due_date=date.today() + timedelta(days=300),
        )
        out = io.StringIO()
        call_command('send_fleet_reminders', stdout=out)
        self.assertIn('Sent 2', out.getvalue())
        out = io.StringIO()
        call_command('send_fleet_reminders', stdout=out)
        self.assertIn('Sent 0', out.getvalue())

    def test_thirty_day_window_sends(self):
        import io
        from django.core.management import call_command
        from .models import Vehicle
        vehicle = Vehicle.objects.create(
            name='Month Van', registration='MV1',
            mot_due_date=date.today() + timedelta(days=20),
        )
        out = io.StringIO()
        call_command('send_fleet_reminders', stdout=out)
        self.assertIn('Sent 1', out.getvalue())
        vehicle.refresh_from_db()
        self.assertTrue(vehicle.mot_reminder_30_sent)
        self.assertFalse(vehicle.mot_reminder_7_sent)


class SupportStaffUnreadTests(TestCase):
    """The Contact Staff badge for staff must reflect unread owner messages,
    not simply the number of open queries."""

    def setUp(self):
        from .models import SupportQuery
        self.owner = User.objects.create_user(username='quowner', password='pw')
        self.staff = User.objects.create_user(username='qustaff', password='pw', is_staff=True)
        self.staff.profile.can_reply_queries = True
        self.staff.profile.save()
        self.client = APIClient()

    def _unresolved_count(self):
        resp = self.client.get('/api/support-queries/unresolved_count/')
        self.assertEqual(resp.status_code, 200)
        return resp.data['count']

    def test_open_read_query_shows_no_staff_badge(self):
        from .models import SupportQuery
        SupportQuery.objects.create(owner=self.owner, subject='Old question')
        self.client.login(username='qustaff', password='pw')
        self.assertEqual(self._unresolved_count(), 0)

    def test_owner_created_query_is_unread_for_staff(self):
        self.client.login(username='quowner', password='pw')
        resp = self.client.post(
            '/api/support-queries/',
            {'subject': 'Help', 'initial_message': 'My dog ate my homework'},
            format='json',
        )
        self.assertEqual(resp.status_code, 201)
        self.client.login(username='qustaff', password='pw')
        self.assertEqual(self._unresolved_count(), 1)

    def test_owner_message_marks_unread_and_staff_reply_clears(self):
        from .models import SupportQuery
        query = SupportQuery.objects.create(owner=self.owner, subject='Help')
        self.client.login(username='quowner', password='pw')
        self.client.post(f'/api/support-queries/{query.id}/add_message/', {'text': 'Hello?'}, format='json')

        self.client.login(username='qustaff', password='pw')
        self.assertEqual(self._unresolved_count(), 1)
        self.client.post(f'/api/support-queries/{query.id}/add_message/', {'text': 'On it!'}, format='json')
        self.assertEqual(self._unresolved_count(), 0)
        query.refresh_from_db()
        self.assertTrue(query.has_unread_reply)  # owner-side flag unaffected

    def test_staff_mark_read_clears_badge(self):
        from .models import SupportQuery
        query = SupportQuery.objects.create(owner=self.owner, subject='Help', staff_has_unread=True)
        self.client.login(username='qustaff', password='pw')
        self.assertEqual(self._unresolved_count(), 1)
        resp = self.client.post(f'/api/support-queries/{query.id}/mark_read/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(self._unresolved_count(), 0)

    def test_owner_unread_behaviour_unchanged(self):
        from .models import SupportQuery
        query = SupportQuery.objects.create(owner=self.owner, subject='Help')
        self.client.login(username='qustaff', password='pw')
        self.client.post(f'/api/support-queries/{query.id}/add_message/', {'text': 'Reply'}, format='json')

        self.client.login(username='quowner', password='pw')
        self.assertEqual(self._unresolved_count(), 1)
        self.client.post(f'/api/support-queries/{query.id}/mark_read/')
        self.assertEqual(self._unresolved_count(), 0)


class FeedReactionResponseTests(TestCase):
    """The react endpoint must return post-toggle state so the app can update
    the feed item without a refresh."""

    def setUp(self):
        from django.core.files.base import ContentFile
        self.staff = User.objects.create_user(username='reactstaff', password='pw', is_staff=True)
        self.media = GroupMedia.objects.create(
            uploaded_by=self.staff,
            media_type='PHOTO',
            file=ContentFile(b'photo', name='react-test.jpg'),
        )
        self.client = APIClient()
        self.client.login(username='reactstaff', password='pw')

    def test_react_response_includes_new_reaction(self):
        resp = self.client.post(f'/api/feed/{self.media.id}/react/', {'emoji': '❤️'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['reactions'], {'❤️': 1})
        self.assertEqual(resp.data['user_reaction'], '❤️')

    def test_react_response_reflects_toggle_off(self):
        self.client.post(f'/api/feed/{self.media.id}/react/', {'emoji': '❤️'}, format='json')
        resp = self.client.post(f'/api/feed/{self.media.id}/react/', {'emoji': '❤️'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['reactions'], {})
        self.assertIsNone(resp.data['user_reaction'])

    def test_react_response_reflects_swapped_reaction(self):
        self.client.post(f'/api/feed/{self.media.id}/react/', {'emoji': '❤️'}, format='json')
        resp = self.client.post(f'/api/feed/{self.media.id}/react/', {'emoji': '😀'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['reactions'], {'😀': 1})
        self.assertEqual(resp.data['user_reaction'], '😀')

    def test_comment_response_includes_new_comment(self):
        resp = self.client.post(f'/api/feed/{self.media.id}/comment/', {'text': 'Cute!'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data['comments']), 1)
        self.assertEqual(resp.data['comments'][0]['text'], 'Cute!')


# postcodes.io /postcodes/{postcode} style payload used to mock the geocoder.
POSTCODES_IO_PAYLOAD = {
    'status': 200,
    'result': {'postcode': 'SL7 2HE', 'latitude': 51.555465, 'longitude': -0.845921},
}


class GeocodingTests(TestCase):
    """Address geocoding for the staff pickup map (api/geocoding.py)."""

    def test_extract_postcode_variants(self):
        from api.geocoding import extract_postcode
        self.assertEqual(
            extract_postcode('Chiltern View, Henley Road, Medmenham, SL7 2HE'), 'SL7 2HE')
        self.assertEqual(extract_postcode('12 High St, Reading, rg1 1aa'), 'RG1 1AA')
        self.assertIsNone(extract_postcode('No postcode here'))
        self.assertIsNone(extract_postcode(''))
        self.assertIsNone(extract_postcode(None))

    @patch('api.geocoding._fetch_postcodes_io', return_value=POSTCODES_IO_PAYLOAD)
    def test_geocode_address_returns_postcode_centroid(self, mock_fetch):
        from api.geocoding import geocode_address
        lat, lng, source = geocode_address('Chiltern View, Henley Road, Medmenham, SL7 2HE')
        self.assertEqual(source, 'postcode')
        self.assertAlmostEqual(lat, 51.555465)
        self.assertAlmostEqual(lng, -0.845921)
        # Geocodes by postcode only — building/street are ignored.
        mock_fetch.assert_called_once_with('SL7 2HE')

    def test_geocode_address_no_postcode_fails(self):
        from api.geocoding import geocode_address
        self.assertEqual(geocode_address('Just a name, no postcode'), (None, None, 'failed'))

    @patch('api.geocoding._fetch_postcodes_io')
    def test_geocode_address_provider_error_fails(self, mock_fetch):
        from api.geocoding import geocode_address, PostcodeLookupError
        mock_fetch.side_effect = PostcodeLookupError('boom')
        self.assertEqual(geocode_address('1 High St, SL7 2HE'), (None, None, 'failed'))

    @patch('api.geocoding._fetch_postcodes_io',
           return_value={'status': 200, 'result': {'latitude': None, 'longitude': None}})
    def test_geocode_address_terminated_postcode_fails(self, mock_fetch):
        from api.geocoding import geocode_address
        self.assertEqual(geocode_address('1 High St, SL7 2HE'), (None, None, 'failed'))

    @patch('api.geocoding._fetch_postcodes_io', return_value=POSTCODES_IO_PAYLOAD)
    def test_geocode_dog_sets_and_caches(self, mock_fetch):
        from api.geocoding import geocode_dog
        owner = User.objects.create_user(username='o1', password='pw')
        dog = Dog.objects.create(
            owner=owner, name='Rex',
            address='Chiltern View, Henley Road, Medmenham, SL7 2HE')
        self.assertTrue(geocode_dog(dog))
        dog.refresh_from_db()
        self.assertEqual(dog.geocode_source, 'postcode')
        self.assertIsNotNone(dog.latitude)
        # The staleness marker is the effective postcode, not the full address.
        self.assertEqual(dog.geocoded_address, 'SL7 2HE')
        # Idempotent: unchanged postcode → no second provider call.
        self.assertEqual(mock_fetch.call_count, 1)
        self.assertFalse(geocode_dog(dog))
        self.assertEqual(mock_fetch.call_count, 1)

    @patch('api.geocoding._fetch_postcodes_io', return_value=POSTCODES_IO_PAYLOAD)
    def test_geocode_dog_prefers_structured_postcode(self, mock_fetch):
        from api.geocoding import geocode_dog
        owner = User.objects.create_user(username='o6', password='pw')
        # Address carries a different postcode; the structured field wins.
        dog = Dog.objects.create(
            owner=owner, name='Rex', address='1 Somewhere, RG1 1AA', postcode='SL7 2HE')
        geocode_dog(dog)
        mock_fetch.assert_called_once_with('SL7 2HE')
        dog.refresh_from_db()
        self.assertEqual(dog.geocode_source, 'postcode')
        self.assertEqual(dog.geocoded_address, 'SL7 2HE')

    @patch('api.geocoding._fetch_postcodes_io', return_value=POSTCODES_IO_PAYLOAD)
    def test_setting_postcode_via_api_geocodes(self, mock_fetch):
        staff = User.objects.create_user(username='s7', password='pw', is_staff=True)
        owner = User.objects.create_user(username='o7', password='pw')
        dog = Dog.objects.create(owner=owner, name='Rex')
        client = APIClient()
        client.login(username='s7', password='pw')
        resp = client.patch(f'/api/dogs/{dog.id}/', {'postcode': 'SL7 2HE'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['postcode'], 'SL7 2HE')
        dog.refresh_from_db()
        self.assertIsNotNone(dog.latitude)
        self.assertEqual(dog.geocode_source, 'postcode')

    @patch('api.geocoding._fetch_postcodes_io', return_value=POSTCODES_IO_PAYLOAD)
    def test_geocode_dog_clears_when_address_removed(self, mock_fetch):
        from api.geocoding import geocode_dog
        owner = User.objects.create_user(username='o2', password='pw')
        dog = Dog.objects.create(owner=owner, name='Rex', address='Chiltern View, SL7 2HE')
        geocode_dog(dog)
        dog.refresh_from_db()
        self.assertIsNotNone(dog.latitude)
        dog.address = ''
        self.assertTrue(geocode_dog(dog))
        dog.refresh_from_db()
        self.assertIsNone(dog.latitude)
        self.assertEqual(dog.geocode_source, '')

    def test_serializers_expose_coordinates(self):
        owner = User.objects.create_user(username='o3', password='pw')
        staff = User.objects.create_user(username='s3', password='pw', is_staff=True)
        dog = Dog.objects.create(
            owner=owner, name='Rex', address='Chiltern View, SL7 2HE', postcode='SL7 2HE',
            latitude=51.555465, longitude=-0.845921, geocode_source='postcode')
        DailyDogAssignment.objects.create(dog=dog, staff_member=staff, date=date.today())
        client = APIClient()
        client.login(username='s3', password='pw')

        resp = client.get('/api/dogs/')
        rec = next(d for d in resp.data if d['id'] == dog.id)
        self.assertAlmostEqual(rec['latitude'], 51.555465)
        self.assertAlmostEqual(rec['longitude'], -0.845921)
        self.assertEqual(rec['geocode_source'], 'postcode')
        self.assertEqual(rec['postcode'], 'SL7 2HE')

        resp = client.get('/api/daily-assignments/')
        a = next(x for x in resp.data if x['dog'] == dog.id)
        self.assertAlmostEqual(a['latitude'], 51.555465)
        self.assertAlmostEqual(a['longitude'], -0.845921)

    @patch('api.geocoding._fetch_postcodes_io', return_value=POSTCODES_IO_PAYLOAD)
    def test_geocode_dogs_command(self, mock_fetch):
        owner = User.objects.create_user(username='o4', password='pw')
        d1 = Dog.objects.create(owner=owner, name='A', address='Chiltern View, SL7 2HE')
        d2 = Dog.objects.create(owner=owner, name='B')  # no address → not a candidate
        call_command('geocode_dogs', sleep=0, verbosity=0)
        d1.refresh_from_db()
        self.assertEqual(d1.geocode_source, 'postcode')
        self.assertIsNotNone(d1.latitude)
        d2.refresh_from_db()
        self.assertIsNone(d2.latitude)

    @patch('api.geocoding._fetch_postcodes_io', return_value=POSTCODES_IO_PAYLOAD)
    def test_geocode_dogs_dry_run_makes_no_changes(self, mock_fetch):
        owner = User.objects.create_user(username='o5', password='pw')
        d1 = Dog.objects.create(owner=owner, name='A', address='Chiltern View, SL7 2HE')
        call_command('geocode_dogs', dry_run=True, verbosity=0)
        d1.refresh_from_db()
        self.assertIsNone(d1.latitude)
        mock_fetch.assert_not_called()


# A password that passes Django's default validators (length, not too common,
# not all numeric) — reused across the account-security tests below.
STRONG_PW = 'Str0ngNewP@ss99'


class PasswordAndAccountSecurityTests(TestCase):
    """B46 — OTP reset flow, change_password (old-password + token rotation),
    and delete_account (password gate + co-owner promotion / NULL owner)."""

    def setUp(self):
        from django.core.cache import cache
        # Anon reset endpoints are throttled per-IP; the throttle cache survives
        # between tests in-process, so clear it to keep each case independent.
        cache.clear()
        self.user = User.objects.create_user(
            username='resetme', email='resetme@example.com', password='OldPass123!',
            first_name='Rita',
        )
        self.client = APIClient()

    # ── request reset (enumeration-safe) ────────────────────────────────

    def test_request_reset_known_email_sends_mail(self):
        from django.core import mail
        from api.models import PasswordResetOTP
        resp = self.client.post(
            '/api/password/reset/request/',
            {'email': 'resetme@example.com'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(mail.outbox[0].to, ['resetme@example.com'])
        self.assertTrue(PasswordResetOTP.objects.filter(user=self.user).exists())

    def test_request_reset_unknown_email_is_200_but_silent(self):
        from django.core import mail
        resp = self.client.post(
            '/api/password/reset/request/',
            {'email': 'nobody@example.com'}, format='json',
        )
        # Same 200 as the known case (no account enumeration), but no mail.
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(mail.outbox), 0)

    # ── verify OTP ──────────────────────────────────────────────────────

    def _make_otp(self, **over):
        from api.models import PasswordResetOTP
        defaults = {
            'user': self.user,
            'otp': '123456',
            'expires_at': timezone.now() + timedelta(minutes=15),
        }
        defaults.update(over)
        return PasswordResetOTP.objects.create(**defaults)

    def test_verify_otp_success_returns_token(self):
        self._make_otp()
        resp = self.client.post(
            '/api/password/reset/verify/',
            {'email': 'resetme@example.com', 'otp': '123456'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data.get('reset_token'))

    def test_verify_otp_expired_rejected(self):
        self._make_otp(expires_at=timezone.now() - timedelta(minutes=1))
        resp = self.client.post(
            '/api/password/reset/verify/',
            {'email': 'resetme@example.com', 'otp': '123456'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_verify_otp_wrong_code_rejected(self):
        self._make_otp()
        resp = self.client.post(
            '/api/password/reset/verify/',
            {'email': 'resetme@example.com', 'otp': '000000'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    # ── reset password (consumes the token once) ────────────────────────

    def test_reset_password_changes_password_and_consumes_token(self):
        otp = self._make_otp()
        token = otp.generate_reset_token()
        resp = self.client.post(
            '/api/password/reset/confirm/',
            {'reset_token': token, 'new_password': STRONG_PW}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(STRONG_PW))
        otp.refresh_from_db()
        self.assertTrue(otp.is_used)

        # A second use of the same token is rejected.
        resp2 = self.client.post(
            '/api/password/reset/confirm/',
            {'reset_token': token, 'new_password': 'An0therP@ss77'}, format='json',
        )
        self.assertEqual(resp2.status_code, 400)

    # ── change password (authenticated, requires old password) ──────────

    def _token_for(self, user):
        from rest_framework.authtoken.models import Token
        return Token.objects.create(user=user).key

    def test_change_password_wrong_old_password_rejected(self):
        self.client.force_authenticate(self.user)
        resp = self.client.post(
            '/api/password/change/',
            {'old_password': 'WRONG', 'new_password': STRONG_PW}, format='json',
        )
        self.assertEqual(resp.status_code, 400)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password('OldPass123!'))

    def test_change_password_rotates_token(self):
        old_token = self._token_for(self.user)
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f'Token {old_token}')
        resp = client.post(
            '/api/password/change/',
            {'old_password': 'OldPass123!', 'new_password': STRONG_PW}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        new_token = resp.data.get('token')
        self.assertTrue(new_token)
        self.assertNotEqual(new_token, old_token)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(STRONG_PW))

        # The old token no longer authenticates (it was deleted).
        stale = APIClient()
        stale.credentials(HTTP_AUTHORIZATION=f'Token {old_token}')
        self.assertEqual(stale.get('/api/profile/').status_code, 401)
        # The new token does.
        fresh = APIClient()
        fresh.credentials(HTTP_AUTHORIZATION=f'Token {new_token}')
        self.assertEqual(fresh.get('/api/profile/').status_code, 200)

    # ── delete account (password gate + dog ownership handling) ─────────

    def test_delete_account_wrong_password_keeps_user(self):
        self.client.force_authenticate(self.user)
        resp = self.client.post(
            '/api/account/delete/', {'password': 'WRONG'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)
        self.assertTrue(User.objects.filter(pk=self.user.pk).exists())

    def test_delete_account_promotes_co_owner_and_nulls_solely_owned(self):
        co_owner = User.objects.create_user(username='coowner', password='pw')
        solo_dog = Dog.objects.create(owner=self.user, name='Solo')
        shared_dog = Dog.objects.create(owner=self.user, name='Shared')
        shared_dog.additional_owners.add(co_owner)

        self.client.force_authenticate(self.user)
        resp = self.client.post(
            '/api/account/delete/', {'password': 'OldPass123!'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(User.objects.filter(pk=self.user.pk).exists())

        # Solely-owned dog persists with a NULL owner (SET_NULL).
        solo_dog.refresh_from_db()
        self.assertIsNone(solo_dog.owner)

        # Co-owned dog: the remaining co-owner is promoted to primary owner and
        # removed from the additional_owners set.
        shared_dog.refresh_from_db()
        self.assertEqual(shared_dog.owner, co_owner)
        self.assertNotIn(co_owner, shared_dog.additional_owners.all())


class DeviceTokenViewSetTests(TestCase):
    """B47 — DeviceToken create/dedupe/reassign and per-user scoping."""

    def setUp(self):
        self.user_a = User.objects.create_user(username='dta', password='pw')
        self.user_b = User.objects.create_user(username='dtb', password='pw')
        self.client = APIClient()

    def test_first_post_creates(self):
        from api.models import DeviceToken
        self.client.force_authenticate(self.user_a)
        resp = self.client.post(
            '/api/device-tokens/', {'token': 'tok-1', 'device_type': 'ANDROID'}, format='json',
        )
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(DeviceToken.objects.filter(token='tok-1', user=self.user_a).count(), 1)

    def test_same_user_repost_is_idempotent(self):
        from api.models import DeviceToken
        self.client.force_authenticate(self.user_a)
        self.client.post('/api/device-tokens/', {'token': 'tok-1'}, format='json')
        resp = self.client.post('/api/device-tokens/', {'token': 'tok-1'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(DeviceToken.objects.filter(token='tok-1').count(), 1)

    def test_different_user_repost_reassigns_ownership(self):
        from api.models import DeviceToken
        DeviceToken.objects.create(user=self.user_a, token='tok-1')
        self.client.force_authenticate(self.user_b)
        resp = self.client.post('/api/device-tokens/', {'token': 'tok-1'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(DeviceToken.objects.filter(token='tok-1').count(), 1)
        self.assertEqual(DeviceToken.objects.get(token='tok-1').user, self.user_b)

    def test_list_only_returns_callers_tokens(self):
        from api.models import DeviceToken
        DeviceToken.objects.create(user=self.user_a, token='a-tok')
        DeviceToken.objects.create(user=self.user_b, token='b-tok')
        self.client.force_authenticate(self.user_a)
        resp = self.client.get('/api/device-tokens/')
        self.assertEqual(resp.status_code, 200)
        tokens = [t['token'] for t in resp.data]
        self.assertEqual(tokens, ['a-tok'])


class DaycareSettingsEndpointTests(TestCase):
    """B48 — daycare_settings GET open to any authed user; PATCH gated."""

    def setUp(self):
        self.owner = User.objects.create_user(username='dsowner', password='pw')
        self.staff = User.objects.create_user(username='dsstaff', password='pw', is_staff=True)
        self.manager = User.objects.create_user(username='dsmgr', password='pw', is_staff=True)
        self.manager.profile.can_manage_requests = True
        self.manager.profile.save()
        self.superuser = User.objects.create_user(
            username='dsadmin', password='pw', is_staff=True, is_superuser=True,
        )
        self.client = APIClient()

    def _capacity(self):
        from api.models import DaycareSettings
        return DaycareSettings.load().default_daily_capacity

    def test_get_allowed_for_any_authed_user(self):
        self.client.force_authenticate(self.owner)
        resp = self.client.get('/api/daycare-settings/')
        self.assertEqual(resp.status_code, 200)
        self.assertIn('default_daily_capacity', resp.data)

    def test_plain_owner_patch_forbidden(self):
        self.client.force_authenticate(self.owner)
        resp = self.client.patch(
            '/api/daycare-settings/', {'default_daily_capacity': 5}, format='json',
        )
        self.assertEqual(resp.status_code, 403)

    def test_plain_staff_patch_forbidden(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.patch(
            '/api/daycare-settings/', {'default_daily_capacity': 5}, format='json',
        )
        self.assertEqual(resp.status_code, 403)

    def test_superuser_patch_sets_capacity(self):
        self.client.force_authenticate(self.superuser)
        resp = self.client.patch(
            '/api/daycare-settings/', {'default_daily_capacity': 7}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(self._capacity(), 7)

    def test_manager_with_can_manage_requests_patch_sets_capacity(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.patch(
            '/api/daycare-settings/', {'default_daily_capacity': 9}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(self._capacity(), 9)

    def test_zero_means_unlimited(self):
        self.client.force_authenticate(self.superuser)
        resp = self.client.patch(
            '/api/daycare-settings/', {'default_daily_capacity': 0}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertIsNone(self._capacity())

    def test_null_means_unlimited(self):
        self.client.force_authenticate(self.superuser)
        resp = self.client.patch(
            '/api/daycare-settings/', {'default_daily_capacity': None}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assertIsNone(self._capacity())

    def test_negative_rejected(self):
        self.client.force_authenticate(self.superuser)
        resp = self.client.patch(
            '/api/daycare-settings/', {'default_daily_capacity': -3}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_non_numeric_rejected(self):
        self.client.force_authenticate(self.superuser)
        resp = self.client.patch(
            '/api/daycare-settings/', {'default_daily_capacity': 'lots'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)


class IDORTests(TestCase):
    """B49 — owner A must not reach owner B's records by id (404, not 200)."""

    def setUp(self):
        self.a = User.objects.create_user(username='ownera', password='pw')
        self.b = User.objects.create_user(username='ownerb', password='pw')
        self.b_dog = Dog.objects.create(owner=self.b, name='BDog')
        self.client = APIClient()
        self.client.force_authenticate(self.a)

    def test_cannot_retrieve_others_dog(self):
        resp = self.client.get(f'/api/dogs/{self.b_dog.id}/')
        self.assertEqual(resp.status_code, 404)

    def test_cannot_patch_others_dog(self):
        resp = self.client.patch(
            f'/api/dogs/{self.b_dog.id}/', {'name': 'Hacked'}, format='json',
        )
        self.assertEqual(resp.status_code, 404)
        self.b_dog.refresh_from_db()
        self.assertEqual(self.b_dog.name, 'BDog')

    def test_cannot_retrieve_others_support_query(self):
        query = SupportQuery.objects.create(owner=self.b, subject='Private')
        resp = self.client.get(f'/api/support-queries/{query.id}/')
        self.assertEqual(resp.status_code, 404)

    def test_cannot_add_message_to_others_support_query(self):
        query = SupportQuery.objects.create(owner=self.b, subject='Private')
        resp = self.client.post(
            f'/api/support-queries/{query.id}/add_message/', {'text': 'sneaky'}, format='json',
        )
        self.assertEqual(resp.status_code, 404)
        self.assertEqual(SupportMessage.objects.filter(query=query).count(), 0)

    def test_cannot_retrieve_others_boarding_request(self):
        br = BoardingRequest.objects.create(
            owner=self.b, start_date='2026-04-01', end_date='2026-04-05',
        )
        resp = self.client.get(f'/api/boarding-requests/{br.id}/')
        self.assertEqual(resp.status_code, 404)

    def test_cannot_retrieve_others_date_change_request(self):
        dcr = DateChangeRequest.objects.create(
            dog=self.b_dog, request_type='CANCEL', original_date='2026-05-10',
        )
        resp = self.client.get(f'/api/date-change-requests/{dcr.id}/')
        self.assertEqual(resp.status_code, 404)


class OwnerProfileStaffEndpointTests(TestCase):
    """B50 — get_owner / update_owner are staff-only and id-validated."""

    def setUp(self):
        self.owner = User.objects.create_user(username='gpowner', password='pw')
        self.target = User.objects.create_user(
            username='gptarget', password='pw', first_name='Tara',
        )
        self.staff = User.objects.create_user(username='gpstaff', password='pw', is_staff=True)
        self.client = APIClient()

    def test_non_staff_forbidden(self):
        self.client.force_authenticate(self.owner)
        resp = self.client.get(f'/api/profile/get_owner/?user_id={self.target.id}')
        self.assertEqual(resp.status_code, 403)

    def test_staff_missing_user_id_400(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.get('/api/profile/get_owner/')
        self.assertEqual(resp.status_code, 400)

    def test_staff_unknown_id_404(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.get('/api/profile/get_owner/?user_id=999999')
        self.assertEqual(resp.status_code, 404)

    def test_staff_valid_id_reads(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.get(f'/api/profile/get_owner/?user_id={self.target.id}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['user_id'], self.target.id)
        self.assertEqual(resp.data['first_name'], 'Tara')

    def test_staff_update_persists(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.post(
            f'/api/profile/update_owner/?user_id={self.target.id}',
            {'phone_number': '07999000111', 'address': '7 Walk Lane'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.target.profile.refresh_from_db()
        self.assertEqual(self.target.profile.phone_number, '07999000111')
        self.assertEqual(self.target.profile.address, '7 Walk Lane')

    def test_update_owner_non_staff_forbidden(self):
        self.client.force_authenticate(self.owner)
        resp = self.client.post(
            f'/api/profile/update_owner/?user_id={self.target.id}',
            {'phone_number': '07000000000'}, format='json',
        )
        self.assertEqual(resp.status_code, 403)


class PostcodeLookupTests(TestCase):
    """B51 — postcode_lookup proxy: auth, key, and provider error mapping."""

    def setUp(self):
        self.user = User.objects.create_user(username='pcuser', password='pw')
        self.client = APIClient()

    def test_requires_authentication(self):
        resp = self.client.get('/api/postcode/lookup/?postcode=SL7 2HE')
        self.assertIn(resp.status_code, (401, 403))

    @override_settings(POSTCODE_LOOKUP_API_KEY='k', POSTCODE_LOOKUP_PROVIDER='getaddress')
    def test_missing_postcode_400(self):
        self.client.force_authenticate(self.user)
        resp = self.client.get('/api/postcode/lookup/')
        self.assertEqual(resp.status_code, 400)

    @override_settings(POSTCODE_LOOKUP_API_KEY='')
    def test_no_key_503(self):
        self.client.force_authenticate(self.user)
        resp = self.client.get('/api/postcode/lookup/?postcode=SL7 2HE')
        self.assertEqual(resp.status_code, 503)

    @override_settings(POSTCODE_LOOKUP_API_KEY='k', POSTCODE_LOOKUP_PROVIDER='getaddress')
    @patch('api.views.lookup_addresses')
    def test_not_found_404(self, mock_lookup):
        from api.geocoding import PostcodeNotFound
        mock_lookup.side_effect = PostcodeNotFound()
        self.client.force_authenticate(self.user)
        resp = self.client.get('/api/postcode/lookup/?postcode=SL7 2HE')
        self.assertEqual(resp.status_code, 404)

    @override_settings(POSTCODE_LOOKUP_API_KEY='k', POSTCODE_LOOKUP_PROVIDER='getaddress')
    @patch('api.views.lookup_addresses')
    def test_provider_error_502(self, mock_lookup):
        from api.geocoding import PostcodeLookupError
        mock_lookup.side_effect = PostcodeLookupError('upstream boom')
        self.client.force_authenticate(self.user)
        resp = self.client.get('/api/postcode/lookup/?postcode=SL7 2HE')
        self.assertEqual(resp.status_code, 502)

    @override_settings(POSTCODE_LOOKUP_API_KEY='k', POSTCODE_LOOKUP_PROVIDER='getaddress')
    @patch('api.views.lookup_addresses')
    def test_success_200(self, mock_lookup):
        mock_lookup.return_value = [
            {'formatted': '1 High St, RG1 1AA', 'lines': ['1 High St'], 'postcode': 'RG1 1AA'},
        ]
        self.client.force_authenticate(self.user)
        resp = self.client.get('/api/postcode/lookup/?postcode=rg1 1aa')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['postcode'], 'RG1 1AA')
        self.assertEqual(len(resp.data['addresses']), 1)


class SchedulingActionsTests(TestCase):
    """B52 — auto_assign / suggested_assignments / reorder / send_traffic_alert."""

    def setUp(self):
        self.owner = User.objects.create_user(username='schowner', password='pw')
        self.staff_a = User.objects.create_user(
            username='scha', password='pw', is_staff=True, first_name='Alice',
        )
        self.staff_a.profile.can_assign_dogs = True
        self.staff_a.profile.save()
        self.staff_b = User.objects.create_user(
            username='schb', password='pw', is_staff=True, first_name='Bob',
        )
        self.today = date.today()
        self.weekday = self.today.isoweekday()
        self.dog = Dog.objects.create(
            owner=self.owner, name='Rex', daycare_days=[self.weekday], schedule_type='weekly',
        )
        self.client = APIClient()

    def test_auto_assign_requires_can_assign_dogs(self):
        self.client.force_authenticate(self.staff_b)  # no can_assign_dogs
        resp = self.client.post(
            '/api/daily-assignments/auto_assign/',
            {'date': self.today.isoformat()}, format='json',
        )
        self.assertEqual(resp.status_code, 403)

    def test_auto_assign_uses_same_weekday_history(self):
        from django.db import connection
        if connection.vendor == 'sqlite':
            self.skipTest('daycare_days JSON contains lookup needs PostgreSQL')
        # Last week's same-weekday assignment to staff_b should repeat.
        last_week = self.today - timedelta(weeks=1)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_b, date=last_week,
        )
        self.client.force_authenticate(self.staff_a)
        resp = self.client.post(
            '/api/daily-assignments/auto_assign/',
            {'date': self.today.isoformat()}, format='json',
        )
        self.assertEqual(resp.status_code, 201)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.today)
        self.assertEqual(assignment.staff_member, self.staff_b)

    def test_auto_assign_frequency_fallback(self):
        from django.db import connection
        if connection.vendor == 'sqlite':
            self.skipTest('daycare_days JSON contains lookup needs PostgreSQL')
        # No same-weekday history; staff_b appears more often overall, so the
        # frequency fallback should pick them.
        other_weekday_date = self.today - timedelta(days=1)
        while other_weekday_date.isoweekday() == self.weekday:
            other_weekday_date -= timedelta(days=1)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_b, date=other_weekday_date,
        )
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_b, date=other_weekday_date - timedelta(weeks=1),
        )
        self.client.force_authenticate(self.staff_a)
        resp = self.client.post(
            '/api/daily-assignments/auto_assign/',
            {'date': self.today.isoformat()}, format='json',
        )
        self.assertEqual(resp.status_code, 201)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.today)
        self.assertEqual(assignment.staff_member, self.staff_b)

    def test_suggested_assignments_reports_source(self):
        last_week = self.today - timedelta(weeks=1)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_b, date=last_week,
        )
        self.client.force_authenticate(self.staff_a)
        resp = self.client.get(
            f'/api/daily-assignments/suggested_assignments/?date={self.today.isoformat()}'
        )
        self.assertEqual(resp.status_code, 200)
        # The view keys suggestions by integer dog id (resp.data is the raw dict
        # before JSON string-key coercion).
        entry = resp.data[self.dog.id]
        self.assertEqual(entry['staff_member_id'], self.staff_b.id)
        self.assertEqual(entry['source'], 'same_weekday')

    def test_reorder_persists_sort_order(self):
        a1 = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today,
        )
        dog2 = Dog.objects.create(owner=self.owner, name='Buddy')
        a2 = DailyDogAssignment.objects.create(
            dog=dog2, staff_member=self.staff_a, date=self.today,
        )
        self.client.force_authenticate(self.staff_a)
        resp = self.client.post(
            '/api/daily-assignments/reorder/',
            {'assignment_ids': [a2.id, a1.id]}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        a1.refresh_from_db()
        a2.refresh_from_db()
        self.assertEqual(a2.sort_order, 0)
        self.assertEqual(a1.sort_order, 1)

    def test_reorder_rejects_empty(self):
        self.client.force_authenticate(self.staff_a)
        resp = self.client.post(
            '/api/daily-assignments/reorder/', {'assignment_ids': []}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    def test_reorder_rejects_non_list(self):
        self.client.force_authenticate(self.staff_a)
        resp = self.client.post(
            '/api/daily-assignments/reorder/', {'assignment_ids': 'nope'}, format='json',
        )
        self.assertEqual(resp.status_code, 400)

    @patch('api.notifications.send_traffic_alert')
    def test_send_traffic_alert_invalid_type_400(self, mock_alert):
        self.client.force_authenticate(self.staff_a)
        resp = self.client.post(
            '/api/daily-assignments/send_traffic_alert/',
            {'alert_type': 'sideways', 'date': self.today.isoformat()}, format='json',
        )
        self.assertEqual(resp.status_code, 400)
        mock_alert.assert_not_called()

    @patch('api.notifications.send_traffic_alert')
    def test_send_traffic_alert_valid_type_ok(self, mock_alert):
        self.client.force_authenticate(self.staff_a)
        resp = self.client.post(
            '/api/daily-assignments/send_traffic_alert/',
            {'alert_type': 'pickup', 'date': self.today.isoformat()}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        mock_alert.assert_called_once()


class DefectStatusNotificationTests(TestCase):
    """B53 — a defect status change notifies the reporter only when changed by
    someone else; never the actor themselves."""

    def setUp(self):
        from api.models import Vehicle
        self.reporter = User.objects.create_user(
            username='reporter', password='pw', is_staff=True,
        )
        self.manager = User.objects.create_user(
            username='defmgr', password='pw', is_staff=True,
        )
        self.manager.profile.can_manage_vehicles = True
        self.manager.profile.save()
        self.vehicle = Vehicle.objects.create(name='Blue Van', registration='AB12 CDE')
        self.client = APIClient()

    # ── vehicle defects ─────────────────────────────────────────────────

    @patch('api.notifications.send_push_notification')
    def test_vehicle_status_change_by_other_notifies_reporter(self, mock_push):
        from api.models import VehicleDefect
        defect = VehicleDefect.objects.create(
            vehicle=self.vehicle, title='Cracked mirror', reported_by=self.reporter,
        )
        self.client.force_authenticate(self.manager)
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/change_status/',
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        mock_push.assert_called_once()
        self.assertEqual(mock_push.call_args.args[0], self.reporter)

    @patch('api.notifications.send_push_notification')
    def test_vehicle_status_change_by_reporter_does_not_notify(self, mock_push):
        from api.models import VehicleDefect
        # Reporter is also a vehicle manager so they may change the status.
        self.reporter.profile.can_manage_vehicles = True
        self.reporter.profile.save()
        defect = VehicleDefect.objects.create(
            vehicle=self.vehicle, title='Cracked mirror', reported_by=self.reporter,
        )
        self.client.force_authenticate(self.reporter)
        resp = self.client.post(
            f'/api/vehicle-defects/{defect.id}/change_status/',
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        mock_push.assert_not_called()

    # ── facility defects ────────────────────────────────────────────────

    @patch('api.notifications.send_push_notification')
    def test_facility_status_change_by_other_notifies_reporter(self, mock_push):
        from api.models import FacilityDefect
        other_staff = User.objects.create_user(
            username='fdother', password='pw', is_staff=True,
        )
        defect = FacilityDefect.objects.create(title='Broken gate', reported_by=self.reporter)
        self.client.force_authenticate(other_staff)
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/change_status/',
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        mock_push.assert_called_once()
        self.assertEqual(mock_push.call_args.args[0], self.reporter)

    @patch('api.notifications.send_push_notification')
    def test_facility_status_change_by_reporter_does_not_notify(self, mock_push):
        from api.models import FacilityDefect
        defect = FacilityDefect.objects.create(title='Broken gate', reported_by=self.reporter)
        self.client.force_authenticate(self.reporter)
        resp = self.client.post(
            f'/api/facility-defects/{defect.id}/change_status/',
            {'status': 'RESOLVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        mock_push.assert_not_called()


class TrafficAlertRecipientTests(TestCase):
    """F4 — send_traffic_alert recipient targeting: explicit dog_ids are
    authoritative (notify regardless of pending status) while still excluding
    the owner-handled leg; with no dog_ids the status default still applies."""

    def setUp(self):
        self.owner_a = User.objects.create_user(username='owner_a', password='pw')
        self.owner_b = User.objects.create_user(username='owner_b', password='pw')
        self.staff = User.objects.create_user(username='driver', password='pw', is_staff=True)
        self.today = date.today()
        weekday = self.today.isoweekday()
        self.dog1 = Dog.objects.create(
            owner=self.owner_a, name='Ace', daycare_days=[weekday], schedule_type='weekly',
        )
        self.dog2 = Dog.objects.create(
            owner=self.owner_b, name='Buddy', daycare_days=[weekday], schedule_type='weekly',
        )
        self.a1 = DailyDogAssignment.objects.create(
            dog=self.dog1, staff_member=self.staff, date=self.today, status='ASSIGNED',
        )
        self.a2 = DailyDogAssignment.objects.create(
            dog=self.dog2, staff_member=self.staff, date=self.today, status='ASSIGNED',
        )

    def _notified_owner_ids(self, mock_push):
        return {call.args[0].id for call in mock_push.call_args_list}

    @patch('api.notifications.send_push_notification')
    def test_explicit_dog_ids_notifies_already_picked_up_dog(self, mock_push):
        from api.notifications import send_traffic_alert
        # dog1 is already PICKED_UP — the default pickup filter would skip it,
        # but an explicit selection must still notify its owner.
        self.a1.status = 'PICKED_UP'
        self.a1.save()
        send_traffic_alert('pickup', self.today, self.staff, dog_ids=[self.dog1.id])
        self.assertIn(self.owner_a.id, self._notified_owner_ids(mock_push))

    @patch('api.notifications.send_push_notification')
    def test_explicit_dog_ids_still_excludes_owner_brings_for_pickup(self, mock_push):
        from api.notifications import send_traffic_alert
        self.dog1.owner_brings_default = True
        self.dog1.save()
        send_traffic_alert('pickup', self.today, self.staff, dog_ids=[self.dog1.id])
        self.assertNotIn(self.owner_a.id, self._notified_owner_ids(mock_push))

    @patch('api.notifications.send_push_notification')
    def test_explicit_dog_ids_dropoff_excludes_owner_collects(self, mock_push):
        from api.notifications import send_traffic_alert
        self.dog1.owner_collects_default = True
        self.dog1.save()
        send_traffic_alert('dropoff', self.today, self.staff, dog_ids=[self.dog1.id])
        self.assertNotIn(self.owner_a.id, self._notified_owner_ids(mock_push))

    @patch('api.notifications.send_push_notification')
    def test_no_dog_ids_uses_status_default_pickup(self, mock_push):
        from api.notifications import send_traffic_alert
        # Default pickup target = dogs still ASSIGNED (not yet picked up).
        self.a2.status = 'PICKED_UP'
        self.a2.save()
        send_traffic_alert('pickup', self.today, self.staff)
        notified = self._notified_owner_ids(mock_push)
        self.assertIn(self.owner_a.id, notified)
        self.assertNotIn(self.owner_b.id, notified)

    @patch('api.notifications.send_push_notification')
    def test_no_dog_ids_uses_status_default_dropoff(self, mock_push):
        from api.notifications import send_traffic_alert
        # Default dropoff target = dogs PICKED_UP (not yet dropped home).
        self.a2.status = 'PICKED_UP'
        self.a2.save()
        send_traffic_alert('dropoff', self.today, self.staff)
        notified = self._notified_owner_ids(mock_push)
        self.assertIn(self.owner_b.id, notified)
        self.assertNotIn(self.owner_a.id, notified)

    @patch('api.notifications.send_push_notification')
    def test_explicit_dog_ids_skips_removed(self, mock_push):
        from api.notifications import send_traffic_alert
        self.a1.status = 'REMOVED'
        self.a1.save()
        send_traffic_alert('pickup', self.today, self.staff, dog_ids=[self.dog1.id])
        self.assertNotIn(self.owner_a.id, self._notified_owner_ids(mock_push))


class IntakeRequestTests(TestCase):
    """The booking form: owners submit contact details + dogs to enrol; staff
    approve (creating the Dog records) or deny."""

    def setUp(self):
        self.owner = User.objects.create_user(
            username='newowner', password='pw', first_name='Nina', email='nina@example.com')
        self.other_owner = User.objects.create_user(username='other', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.client = APIClient()

    def _payload(self, **overrides):
        payload = {
            'phone_number': '07700 900123',
            'address': '1 Kennel Lane, Marlow',
            'postcode': 'sl7 2he',
            'pickup_instructions': 'Side gate, key under the pot',
            'additional_info': 'Both dogs are friendly',
            'dogs': [
                {
                    'name': 'Biscuit',
                    'sex': 'F',
                    'date_of_birth': '2023-05-01',
                    'is_spayed': True,
                    'food_instructions': '1 cup twice a day',
                    'medical_notes': 'None',
                    'registered_vet': 'Marlow Vets',
                    'daycare_days': [1, 3],
                    'schedule_type': 'weekly',
                },
                {
                    'name': 'Rolo',
                    'daycare_days': [],
                    'schedule_type': 'ad_hoc',
                },
            ],
        }
        payload.update(overrides)
        return payload

    def test_owner_can_submit_booking_form(self):
        self.client.login(username='newowner', password='pw')
        resp = self.client.post('/api/intake-requests/', self._payload(), format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'PENDING')
        self.assertEqual(resp.data['postcode'], 'SL7 2HE')  # normalised
        self.assertEqual(len(resp.data['dogs']), 2)
        req = IntakeRequest.objects.get(pk=resp.data['id'])
        self.assertEqual(req.owner, self.owner)
        self.assertEqual(req.dogs.count(), 2)
        # Contact details are mirrored onto the owner's profile.
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.phone_number, '07700 900123')
        self.assertEqual(self.owner.profile.address, '1 Kennel Lane, Marlow')
        self.assertEqual(self.owner.profile.pickup_instructions, 'Side gate, key under the pot')

    def test_booking_form_requires_a_dog(self):
        self.client.login(username='newowner', password='pw')
        resp = self.client.post('/api/intake-requests/', self._payload(dogs=[]), format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(IntakeRequest.objects.count(), 0)

    def test_invalid_daycare_days_rejected(self):
        self.client.login(username='newowner', password='pw')
        payload = self._payload(dogs=[{'name': 'Biscuit', 'daycare_days': [0, 9]}])
        resp = self.client.post('/api/intake-requests/', payload, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_owner_sees_only_own_requests(self):
        self.client.login(username='newowner', password='pw')
        self.client.post('/api/intake-requests/', self._payload(), format='json')
        self.client.logout()

        self.client.login(username='other', password='pw')
        resp = self.client.get('/api/intake-requests/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 0)
        self.client.logout()

        self.client.login(username='staff', password='pw')
        resp = self.client.get('/api/intake-requests/')
        self.assertEqual(len(resp.data), 1)

    def test_approve_creates_dogs(self):
        self.client.login(username='newowner', password='pw')
        resp = self.client.post('/api/intake-requests/', self._payload(), format='json')
        request_id = resp.data['id']
        self.client.logout()

        self.client.login(username='staff', password='pw')
        resp = self.client.post(f'/api/intake-requests/{request_id}/approve/', {}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'APPROVED')

        dogs = Dog.objects.filter(owner=self.owner).order_by('name')
        self.assertEqual(dogs.count(), 2)
        biscuit = dogs.get(name='Biscuit')
        self.assertEqual(biscuit.sex, 'F')
        self.assertTrue(biscuit.is_spayed)
        self.assertEqual(biscuit.food_instructions, '1 cup twice a day')
        self.assertEqual(biscuit.registered_vet, 'Marlow Vets')
        self.assertEqual(biscuit.daycare_days, [1, 3])
        self.assertEqual(biscuit.schedule_type, 'weekly')
        # The home address on the form is copied to each dog for pickups.
        self.assertEqual(biscuit.address, '1 Kennel Lane, Marlow')
        self.assertEqual(biscuit.postcode, 'SL7 2HE')
        rolo = dogs.get(name='Rolo')
        self.assertEqual(rolo.schedule_type, 'ad_hoc')

        req = IntakeRequest.objects.get(pk=request_id)
        self.assertEqual(req.reviewed_by, self.staff)
        self.assertIsNotNone(req.reviewed_at)
        for intake_dog in req.dogs.all():
            self.assertIsNotNone(intake_dog.created_dog)

    def test_non_staff_cannot_approve_or_deny(self):
        self.client.login(username='newowner', password='pw')
        resp = self.client.post('/api/intake-requests/', self._payload(), format='json')
        request_id = resp.data['id']
        resp = self.client.post(f'/api/intake-requests/{request_id}/approve/', {}, format='json')
        self.assertEqual(resp.status_code, 403)
        resp = self.client.post(f'/api/intake-requests/{request_id}/deny/', {}, format='json')
        self.assertEqual(resp.status_code, 403)
        self.assertEqual(Dog.objects.count(), 0)

    def test_deny_records_reason_and_creates_no_dogs(self):
        self.client.login(username='newowner', password='pw')
        resp = self.client.post('/api/intake-requests/', self._payload(), format='json')
        request_id = resp.data['id']
        self.client.logout()

        self.client.login(username='staff', password='pw')
        resp = self.client.post(
            f'/api/intake-requests/{request_id}/deny/', {'reason': 'Fully booked'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'DENIED')
        self.assertEqual(resp.data['denial_reason'], 'Fully booked')
        self.assertEqual(Dog.objects.count(), 0)

    def test_reviewed_request_cannot_be_re_reviewed(self):
        self.client.login(username='newowner', password='pw')
        resp = self.client.post('/api/intake-requests/', self._payload(), format='json')
        request_id = resp.data['id']
        self.client.logout()

        self.client.login(username='staff', password='pw')
        self.client.post(f'/api/intake-requests/{request_id}/approve/', {}, format='json')
        resp = self.client.post(f'/api/intake-requests/{request_id}/approve/', {}, format='json')
        self.assertEqual(resp.status_code, 400)
        # No duplicate dogs from the double approval.
        self.assertEqual(Dog.objects.filter(owner=self.owner).count(), 2)
        resp = self.client.post(f'/api/intake-requests/{request_id}/deny/', {}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_owner_can_withdraw_pending_but_not_reviewed(self):
        self.client.login(username='newowner', password='pw')
        resp = self.client.post('/api/intake-requests/', self._payload(), format='json')
        request_id = resp.data['id']
        resp = self.client.delete(f'/api/intake-requests/{request_id}/')
        self.assertEqual(resp.status_code, 204)
        self.assertEqual(IntakeRequest.objects.count(), 0)

        resp = self.client.post('/api/intake-requests/', self._payload(), format='json')
        request_id = resp.data['id']
        self.client.logout()
        self.client.login(username='staff', password='pw')
        self.client.post(f'/api/intake-requests/{request_id}/deny/', {}, format='json')
        self.client.logout()
        self.client.login(username='newowner', password='pw')
        resp = self.client.delete(f'/api/intake-requests/{request_id}/')
        self.assertEqual(resp.status_code, 403)

    def test_owner_cannot_touch_someone_elses_request(self):
        self.client.login(username='newowner', password='pw')
        resp = self.client.post('/api/intake-requests/', self._payload(), format='json')
        request_id = resp.data['id']
        self.client.logout()

        self.client.login(username='other', password='pw')
        resp = self.client.get(f'/api/intake-requests/{request_id}/')
        self.assertEqual(resp.status_code, 404)
        resp = self.client.delete(f'/api/intake-requests/{request_id}/')
        self.assertEqual(resp.status_code, 404)


class NotificationCorrectnessTests(TestCase):
    """Notification review fixes: single owner push per date-change status
    change (with an app-navigable type), dog_id in dog-status payloads,
    no manager push for staff auto-approved bookings, device-token keepalive
    and deregistration, and no self-notification for staff actions."""

    def setUp(self):
        self.owner = User.objects.create_user(username='nowner', password='pw')
        self.staff = User.objects.create_user(username='nstaff', password='pw', is_staff=True)
        self.manager = User.objects.create_user(username='nmanager', password='pw', is_staff=True)
        self.manager.profile.can_manage_requests = True
        self.manager.profile.save()
        self.dog = Dog.objects.create(owner=self.owner, name='Nala')
        self.client = APIClient()

    # --- date change request status pushes ---

    def test_change_status_sends_single_owner_push_with_navigable_type(self):
        # The change_status endpoint and the model signal used to each push,
        # so the owner got two notifications per approve/deny — and the view's
        # copy used type 'date_change_status', which the app doesn't handle.
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY',
            new_date=date.today() + timedelta(days=30), status='PENDING',
        )
        self.client.login(username='nstaff', password='pw')
        with patch('api.notifications.send_push_notification') as view_push, \
                patch('api.models.send_push_notification') as signal_push:
            resp = self.client.post(
                f'/api/date-change-requests/{req.id}/change_status/',
                {'status': 'APPROVED'}, format='json',
            )
        self.assertEqual(resp.status_code, 200)
        owner_pushes = (
            [c for c in view_push.call_args_list if c.args[0] == self.owner]
            + [c for c in signal_push.call_args_list if c.args[0] == self.owner]
        )
        self.assertEqual(len(owner_pushes), 1)
        args, kwargs = owner_pushes[0]
        self.assertEqual(args[3]['type'], 'date_change_request_update')
        self.assertEqual(kwargs.get('category'), 'bookings')

    def test_direct_status_save_still_notifies_owner_via_signal(self):
        # Paths that bypass change_status (e.g. Django admin) still rely on
        # the model signal.
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL',
            original_date=date.today() + timedelta(days=30), status='PENDING',
        )
        with patch('api.models.send_push_notification') as signal_push:
            req.status = 'APPROVED'
            req.save()
        owner_pushes = [c for c in signal_push.call_args_list if c.args[0] == self.owner]
        self.assertEqual(len(owner_pushes), 1)
        self.assertEqual(owner_pushes[0].args[3]['type'], 'date_change_request_update')

    def test_staff_auto_approved_creation_pushes_navigable_type_once(self):
        self.client.login(username='nstaff', password='pw')
        with patch('api.notifications.send_push_notification') as view_push, \
                patch('api.models.send_push_notification') as signal_push:
            resp = self.client.post('/api/date-change-requests/', {
                'dog': self.dog.id,
                'request_type': 'ADD_DAY',
                'new_date': (date.today() + timedelta(days=30)).isoformat(),
            }, format='json')
        self.assertEqual(resp.status_code, 201)
        owner_pushes = (
            [c for c in view_push.call_args_list if c.args[0] == self.owner]
            + [c for c in signal_push.call_args_list if c.args[0] == self.owner]
        )
        self.assertEqual(len(owner_pushes), 1)
        args, kwargs = owner_pushes[0]
        self.assertEqual(args[3]['type'], 'date_change_request_update')
        self.assertEqual(kwargs.get('category'), 'bookings')

    # --- dog status payload ---

    def test_dog_status_update_payload_includes_dog_id(self):
        # The app deep-links with data['dog_id']; the payload only carried the
        # assignment id under 'id', so the tap never navigated.
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=date.today(), status='ASSIGNED',
        )
        with patch('api.models.send_push_notification') as signal_push:
            assignment.status = 'PICKED_UP'
            assignment.save()
        owner_pushes = [c for c in signal_push.call_args_list if c.args[0] == self.owner]
        self.assertEqual(len(owner_pushes), 1)
        data = owner_pushes[0].args[3]
        self.assertEqual(data['type'], 'dog_status_update')
        self.assertEqual(data['dog_id'], str(self.dog.id))

    # --- boarding request staff notification ---

    def test_staff_created_boarding_does_not_push_new_request_to_managers(self):
        self.client.login(username='nstaff', password='pw')
        with patch('api.models.send_push_notification') as signal_push:
            resp = self.client.post('/api/boarding-requests/', {
                'dogs': [self.dog.id],
                'owner': self.owner.id,
                'start_date': (date.today() + timedelta(days=10)).isoformat(),
                'end_date': (date.today() + timedelta(days=12)).isoformat(),
            }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'APPROVED')
        manager_pushes = [c for c in signal_push.call_args_list if c.args[0] == self.manager]
        self.assertEqual(manager_pushes, [])

    def test_owner_created_boarding_still_pushes_new_request_to_managers(self):
        self.client.login(username='nowner', password='pw')
        with patch('api.models.send_push_notification') as signal_push:
            resp = self.client.post('/api/boarding-requests/', {
                'dogs': [self.dog.id],
                'start_date': (date.today() + timedelta(days=10)).isoformat(),
                'end_date': (date.today() + timedelta(days=12)).isoformat(),
            }, format='json')
        self.assertEqual(resp.status_code, 201)
        manager_pushes = [c for c in signal_push.call_args_list if c.args[0] == self.manager]
        self.assertEqual(len(manager_pushes), 1)
        self.assertEqual(manager_pushes[0].args[3]['type'], 'boarding_request')

    # --- device tokens ---

    def test_reposting_same_token_refreshes_updated_at(self):
        # prune_device_tokens keeps tokens alive by updated_at; a no-op
        # re-registration on app launch must refresh it or live devices get
        # pruned after 90 days and silently stop receiving notifications.
        from api.models import DeviceToken
        self.client.force_authenticate(self.owner)
        self.client.post('/api/device-tokens/', {'token': 'keepalive-tok', 'device_type': 'ANDROID'}, format='json')
        stale = timezone.now() - timedelta(days=120)
        DeviceToken.objects.filter(token='keepalive-tok').update(updated_at=stale)

        resp = self.client.post('/api/device-tokens/', {'token': 'keepalive-tok', 'device_type': 'ANDROID'}, format='json')
        self.assertEqual(resp.status_code, 200)
        token = DeviceToken.objects.get(token='keepalive-tok')
        self.assertGreater(token.updated_at, timezone.now() - timedelta(minutes=5))

        # And the prune command now leaves it alone.
        call_command('prune_device_tokens')
        self.assertTrue(DeviceToken.objects.filter(token='keepalive-tok').exists())

    def test_deregister_deletes_own_token_only(self):
        from api.models import DeviceToken
        DeviceToken.objects.create(user=self.owner, token='mine')
        DeviceToken.objects.create(user=self.staff, token='theirs')
        self.client.force_authenticate(self.owner)

        resp = self.client.post('/api/device-tokens/deregister/', {'token': 'mine'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['deleted'])
        self.assertFalse(DeviceToken.objects.filter(token='mine').exists())

        # Someone else's token (e.g. already reassigned) is left alone.
        resp = self.client.post('/api/device-tokens/deregister/', {'token': 'theirs'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data['deleted'])
        self.assertTrue(DeviceToken.objects.filter(token='theirs').exists())

    def test_deregister_requires_token(self):
        self.client.force_authenticate(self.owner)
        resp = self.client.post('/api/device-tokens/deregister/', {}, format='json')
        self.assertEqual(resp.status_code, 400)

    # --- no self-notification for staff actions ---

    def test_defect_reporter_not_notified_of_own_report(self):
        from api.models import Vehicle
        vehicle = Vehicle.objects.create(name='Blue Van', registration='AB12 CDE')
        reporter = User.objects.create_user(username='nreporter', password='pw', is_staff=True)
        reporter.profile.can_manage_vehicles = True
        reporter.profile.save()
        other = User.objects.create_user(username='nfleet', password='pw', is_staff=True)
        other.profile.can_manage_vehicles = True
        other.profile.save()

        self.client.login(username='nreporter', password='pw')
        with patch('api.notifications.send_push_notification') as mock_push:
            resp = self.client.post('/api/vehicle-defects/', {
                'vehicle': vehicle.id, 'title': 'Flat tyre',
            }, format='json')
        self.assertEqual(resp.status_code, 201)
        notified = {c.args[0] for c in mock_push.call_args_list}
        self.assertIn(other, notified)
        self.assertNotIn(reporter, notified)

    def test_care_instructions_editor_not_notified_of_own_edit(self):
        editor = User.objects.create_user(username='neditor', password='pw', is_staff=True)
        editor.profile.can_assign_dogs = True
        editor.profile.save()
        colleague = User.objects.create_user(username='ncolleague', password='pw', is_staff=True)
        colleague.profile.can_assign_dogs = True
        colleague.profile.save()

        self.client.login(username='neditor', password='pw')
        with patch('api.notifications.send_push_notification') as mock_push:
            resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
                'food_instructions': 'Two scoops, morning only',
            }, format='json')
        self.assertEqual(resp.status_code, 200)
        notified = {c.args[0] for c in mock_push.call_args_list}
        self.assertIn(colleague, notified)
        self.assertNotIn(editor, notified)

    # --- support query resolve deep link ---

    def test_resolve_query_uses_app_handled_type(self):
        query = SupportQuery.objects.create(owner=self.owner, subject='Lead broken')
        self.client.login(username='nstaff', password='pw')
        with patch('api.notifications.send_push_notification') as mock_push:
            resp = self.client.post(f'/api/support-queries/{query.id}/resolve/', {}, format='json')
        self.assertEqual(resp.status_code, 200)
        owner_pushes = [c for c in mock_push.call_args_list if c.args[0] == self.owner]
        self.assertEqual(len(owner_pushes), 1)
        self.assertEqual(owner_pushes[0].args[3]['type'], 'support_query_reply')
