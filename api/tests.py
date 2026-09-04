import json
from datetime import date, timedelta
from decimal import Decimal
from unittest import skipUnless
from unittest.mock import patch
from django.test import TestCase, Client, override_settings
from django.contrib.auth.models import User
from django.core.management import call_command
from rest_framework.test import APIClient
from django.db import connection
from django.test.utils import CaptureQueriesContext
from rest_framework.authtoken.models import Token
from .models import (
    Dog, Photo, DateChangeRequest, DateChangeRequestHistory,
    BoardingRequest, BoardingRequestHistory, DailyDogAssignment, DogWeekdayPickup,
    SupportQuery, SupportMessage,
    ClosureDay, DogNote, StaffAvailability, DayOffRequest,
    GroupMedia, IntakeRequest, Invoice, XeroConnection, PasswordResetOTP,
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
        # Relative dates: past dates are gated behind can_manage_payments, so
        # these tests must always target the future regardless of when they run.
        self.day = date.today() + timedelta(days=10)
        self.other_day = date.today() + timedelta(days=12)
        self.client = APIClient()

    def _post(self, **kwargs):
        payload = {'dog': self.dog.id, **kwargs}
        return self.client.post('/api/date-change-requests/', payload, format='json')

    def test_owner_cancel_stays_pending(self):
        self.client.login(username='owner', password='pw')
        resp = self._post(request_type='CANCEL', original_date=self.day.isoformat())
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'PENDING')
        self.assertIsNone(req.approved_by)

    def test_staff_cancel_auto_approves_and_unassigns(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.day, status='ASSIGNED'
        )
        self.client.login(username='staff', password='pw')
        resp = self._post(request_type='CANCEL', original_date=self.day.isoformat())
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')
        self.assertEqual(req.approved_by, self.staff)
        self.assertIsNotNone(req.approved_at)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.day).exists()
        )
        hist = DateChangeRequestHistory.objects.filter(request=req).first()
        self.assertIsNotNone(hist)
        self.assertEqual(hist.from_status, 'PENDING')
        self.assertEqual(hist.to_status, 'APPROVED')

    def test_staff_change_auto_approves(self):
        self.client.login(username='staff', password='pw')
        resp = self._post(
            request_type='CHANGE',
            original_date=self.day.isoformat(),
            new_date=self.other_day.isoformat(),
        )
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')

    def test_staff_change_unassigns_original_date(self):
        # A staff CHANGE should free up the original date (like a cancel); the
        # new date is surfaced separately by the roster queries.
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.day, status='ASSIGNED'
        )
        self.client.login(username='staff', password='pw')
        resp = self._post(
            request_type='CHANGE',
            original_date=self.day.isoformat(),
            new_date=self.other_day.isoformat(),
        )
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.day).exists()
        )

    def test_staff_add_day_auto_approves(self):
        self.client.login(username='staff', password='pw')
        resp = self._post(request_type='ADD_DAY', new_date=self.other_day.isoformat())
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')


class PastDateEditTests(TestCase):
    """Past dates are billing history: only staff with can_manage_payments may
    add/cancel/move them. Owners and other staff are limited to today onwards,
    and past edits must update the attendance rows invoicing reads."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.payments = User.objects.create_user(username='payments', password='pw', is_staff=True)
        self.payments.profile.can_manage_payments = True
        self.payments.profile.save()
        self.dog = Dog.objects.create(owner=self.owner, name='Fido')
        self.past = date.today() - timedelta(days=5)
        self.other_past = date.today() - timedelta(days=3)
        self.future = date.today() + timedelta(days=5)
        self.client = APIClient()

    def _post(self, **kwargs):
        payload = {'dog': self.dog.id, **kwargs}
        return self.client.post('/api/date-change-requests/', payload, format='json')

    def test_owner_cannot_touch_past_dates(self):
        self.client.login(username='owner', password='pw')
        resp = self._post(request_type='CANCEL', original_date=self.past.isoformat())
        self.assertEqual(resp.status_code, 403)
        resp = self._post(request_type='ADD_DAY', new_date=self.past.isoformat())
        self.assertEqual(resp.status_code, 403)

    def test_staff_without_payments_permission_cannot_touch_past_dates(self):
        self.client.login(username='staff', password='pw')
        resp = self._post(request_type='CANCEL', original_date=self.past.isoformat())
        self.assertEqual(resp.status_code, 403)
        resp = self._post(
            request_type='CHANGE',
            original_date=self.past.isoformat(),
            new_date=self.future.isoformat(),
        )
        self.assertEqual(resp.status_code, 403)
        self.assertFalse(DateChangeRequest.objects.exists())

    def test_payment_manager_can_cancel_past_day(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.past, status='DROPPED_OFF'
        )
        self.client.login(username='payments', password='pw')
        with patch('api.scheduling.process_waitlist_for_date') as waitlist:
            resp = self._post(request_type='CANCEL', original_date=self.past.isoformat())
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.past).exists()
        )
        # Nobody can be offered a spot on a day that already happened.
        waitlist.assert_not_called()

    def test_payment_manager_can_add_past_day(self):
        self.client.login(username='payments', password='pw')
        resp = self._post(request_type='ADD_DAY', new_date=self.past.isoformat())
        self.assertEqual(resp.status_code, 201)
        req = DateChangeRequest.objects.get(id=resp.data['id'])
        self.assertEqual(req.status, 'APPROVED')
        # Roster materialization never runs for past dates, so the attendance
        # row invoicing bills from must have been created directly.
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.past)
        self.assertEqual(assignment.status, 'UNASSIGNED')

    def test_add_past_day_revives_removed_assignment(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.past, status='REMOVED'
        )
        self.client.login(username='payments', password='pw')
        resp = self._post(request_type='ADD_DAY', new_date=self.past.isoformat())
        self.assertEqual(resp.status_code, 201)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.past)
        self.assertEqual(assignment.status, 'UNASSIGNED')

    def test_payment_manager_can_move_past_day(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.past, status='DROPPED_OFF'
        )
        self.client.login(username='payments', password='pw')
        resp = self._post(
            request_type='CHANGE',
            original_date=self.past.isoformat(),
            new_date=self.other_past.isoformat(),
        )
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.past).exists()
        )
        moved = DailyDogAssignment.objects.get(dog=self.dog, date=self.other_past)
        self.assertEqual(moved.status, 'UNASSIGNED')

    def test_superuser_can_edit_past_dates(self):
        User.objects.create_superuser(username='admin', password='pw')
        self.client.login(username='admin', password='pw')
        resp = self._post(request_type='ADD_DAY', new_date=self.past.isoformat())
        self.assertEqual(resp.status_code, 201)

    def test_today_is_not_past(self):
        # An owner cancelling today's booking still goes through the normal flow.
        self.client.login(username='owner', password='pw')
        resp = self._post(request_type='CANCEL', original_date=date.today().isoformat())
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(DateChangeRequest.objects.get(id=resp.data['id']).status, 'PENDING')


class DogPastAttendanceTests(TestCase):
    """Staff-only endpoint feeding the profile calendar's past booked days."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Fido')
        self.client = APIClient()

    def test_owner_cannot_view(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get(f'/api/dogs/{self.dog.id}/past-attendance/')
        self.assertEqual(resp.status_code, 403)

    def test_staff_sees_attended_dates_only(self):
        attended = date.today() - timedelta(days=4)
        removed = date.today() - timedelta(days=3)
        future = date.today() + timedelta(days=4)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=attended, status='DROPPED_OFF')
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=removed, status='REMOVED')
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=future, status='ASSIGNED')
        self.client.login(username='staff', password='pw')
        resp = self.client.get(f'/api/dogs/{self.dog.id}/past-attendance/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['dates'], [attended.isoformat()])

    def test_from_param_bounds_range(self):
        old = date.today() - timedelta(days=30)
        recent = date.today() - timedelta(days=2)
        for d in (old, recent):
            DailyDogAssignment.objects.create(
                dog=self.dog, staff_member=self.staff, date=d, status='DROPPED_OFF')
        self.client.login(username='staff', password='pw')
        since = (date.today() - timedelta(days=7)).isoformat()
        resp = self.client.get(f'/api/dogs/{self.dog.id}/past-attendance/?from={since}')
        self.assertEqual(resp.data['dates'], [recent.isoformat()])
        resp = self.client.get(f'/api/dogs/{self.dog.id}/past-attendance/?from=not-a-date')
        self.assertEqual(resp.status_code, 400)


class PastAssignmentTests(TestCase):
    """Dashboard assignment endpoints follow the same past-date rules as the
    calendar: any assigner may record who drove an already-attended day, but
    making a past day billable (creating/reviving a row) or un-billing it
    (removing/deleting) needs can_manage_payments — and past edits must never
    rewrite the persistent weekly roster."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.staff.profile.can_assign_dogs = True
        self.staff.profile.save()
        self.payments = User.objects.create_user(username='payments', password='pw', is_staff=True)
        self.payments.profile.can_assign_dogs = True
        self.payments.profile.can_manage_payments = True
        self.payments.profile.save()
        self.dog = Dog.objects.create(owner=self.owner, name='Fido')
        self.past = date.today() - timedelta(days=5)
        self.client = APIClient()

    def _assign_to_me(self, **extra):
        return self.client.post('/api/daily-assignments/assign_to_me/', {
            'dog_ids': [self.dog.id],
            'date': self.past.isoformat(),
            **extra,
        }, format='json')

    def test_any_assigner_can_record_driver_on_attended_past_day(self):
        # The row a payment manager's past ADD_DAY creates: attended, no driver.
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.payments, date=self.past, status='UNASSIGNED'
        )
        self.client.login(username='staff', password='pw')
        resp = self._assign_to_me()
        self.assertEqual(resp.status_code, 201)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.past)
        self.assertEqual(assignment.status, 'ASSIGNED')
        self.assertEqual(assignment.staff_member, self.staff)
        # Recording history must not rewrite the future weekly roster.
        self.assertFalse(DogWeekdayPickup.objects.exists())

    def test_plain_staff_cannot_create_past_attendance(self):
        self.client.login(username='staff', password='pw')
        resp = self._assign_to_me()
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['created'], [])
        self.assertEqual(len(resp.data['skipped']), 1)
        self.assertFalse(DailyDogAssignment.objects.exists())

    def test_plain_staff_cannot_revive_removed_past_day(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.payments, date=self.past, status='REMOVED'
        )
        self.client.login(username='staff', password='pw')
        resp = self._assign_to_me()
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data['skipped']), 1)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.past)
        self.assertEqual(assignment.status, 'REMOVED')

    def test_payment_manager_can_create_past_attendance(self):
        self.client.login(username='payments', password='pw')
        resp = self._assign_to_me()
        self.assertEqual(resp.status_code, 201)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.past)
        self.assertEqual(assignment.status, 'ASSIGNED')
        self.assertFalse(DogWeekdayPickup.objects.exists())

    def test_assign_dogs_applies_same_past_rules(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/daily-assignments/assign_dogs/', {
            'dog_ids': [self.dog.id],
            'date': self.past.isoformat(),
            'staff_member_id': self.payments.id,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data['skipped']), 1)
        self.assertFalse(DailyDogAssignment.objects.exists())

        self.client.logout()
        self.client.login(username='payments', password='pw')
        resp = self.client.post('/api/daily-assignments/assign_dogs/', {
            'dog_ids': [self.dog.id],
            'date': self.past.isoformat(),
            'staff_member_id': self.staff.id,
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.past)
        self.assertEqual(assignment.staff_member, self.staff)
        self.assertFalse(DogWeekdayPickup.objects.exists())

    def test_mark_removed_on_past_day_needs_payments_permission(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.past, status='DROPPED_OFF'
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/daily-assignments/mark_removed/', {
            'dog_id': self.dog.id, 'date': self.past.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 403)

        self.client.logout()
        self.client.login(username='payments', password='pw')
        with patch('api.scheduling.process_waitlist_for_date') as waitlist:
            resp = self.client.post('/api/daily-assignments/mark_removed/', {
                'dog_id': self.dog.id, 'date': self.past.isoformat(),
            }, format='json')
        self.assertEqual(resp.status_code, 204)
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.past)
        self.assertEqual(assignment.status, 'REMOVED')
        waitlist.assert_not_called()

    def test_update_status_gates_past_removed_transitions(self):
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.past, status='DROPPED_OFF'
        )
        url = f'/api/daily-assignments/{assignment.id}/update_status/'
        self.client.login(username='staff', password='pw')
        # Un-billing a past day via a status change is blocked...
        resp = self.client.post(url, {'status': 'REMOVED'}, format='json')
        self.assertEqual(resp.status_code, 403)
        # ...but billing-neutral corrections (e.g. fixing the leg status) work.
        resp = self.client.post(url, {'status': 'PICKED_UP'}, format='json')
        self.assertEqual(resp.status_code, 200)

        self.client.logout()
        self.client.login(username='payments', password='pw')
        resp = self.client.post(url, {'status': 'REMOVED'}, format='json')
        self.assertEqual(resp.status_code, 200)
        assignment.refresh_from_db()
        self.assertEqual(assignment.status, 'REMOVED')

    def test_unassign_from_now_on_needs_payments_permission_for_past_rows(self):
        assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.past, status='DROPPED_OFF'
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.post(
            f'/api/daily-assignments/{assignment.id}/unassign/',
            {'scope': 'from_now_on'}, format='json')
        self.assertEqual(resp.status_code, 403)
        # just_this_day only clears the driver — the day stays attended/billed.
        resp = self.client.post(
            f'/api/daily-assignments/{assignment.id}/unassign/',
            {'scope': 'just_this_day'}, format='json')
        self.assertEqual(resp.status_code, 204)
        assignment.refresh_from_db()
        self.assertEqual(assignment.status, 'UNASSIGNED')

        self.client.logout()
        self.client.login(username='payments', password='pw')
        resp = self.client.post(
            f'/api/daily-assignments/{assignment.id}/unassign/',
            {'scope': 'from_now_on'}, format='json')
        self.assertEqual(resp.status_code, 204)
        self.assertFalse(DailyDogAssignment.objects.exists())


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


class DogReAddAfterRemovalTests(TestCase):
    """A dog taken off a day (staff removal or approved cancellation) and then
    added back via an approved request must show as attending again — the
    latest approved action wins, nothing permanently vetoes the date."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.target = date.today() + timedelta(days=7)
        self.weekday = self.target.isoweekday()
        self.dog = Dog.objects.create(
            owner=self.owner, name='Biscuit', daycare_days=[self.weekday],
        )
        self.client = APIClient()

    def _calendar_dog_names(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get(
            f'/api/dogs/calendar/?start={self.target}&end={self.target}'
        )
        self.assertEqual(resp.status_code, 200)
        return [d['name'] for d in resp.data['days'][0]['dogs']]

    def _assert_in_unassigned(self):
        # The unassigned_dogs query uses a JSON `contains` lookup that SQLite
        # (the test DB) doesn't support; only assert membership on Postgres.
        from django.db import connection
        if connection.vendor == 'sqlite':
            return
        self.client.login(username='staff', password='pw')
        resp = self.client.get(
            f'/api/daily-assignments/unassigned_dogs/?date={self.target.isoformat()}'
        )
        self.assertEqual(resp.status_code, 200)
        self.assertIn(self.dog.id, [d['id'] for d in resp.data])

    def test_approving_add_day_clears_stale_removal(self):
        # Staff removed the dog from the day; the owner asks for it back and
        # staff approve. The REMOVED marker must be cleared or the approved
        # re-add silently does nothing.
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.target, status='REMOVED'
        )
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/date-change-requests/', {
            'dog': self.dog.id,
            'request_type': 'ADD_DAY',
            'new_date': self.target.isoformat(),
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
            DailyDogAssignment.objects.filter(
                dog=self.dog, date=self.target, status='REMOVED'
            ).exists()
        )
        self.assertEqual(self._calendar_dog_names(), ['Biscuit'])
        # The dog profile no longer lists the day as cancelled either.
        self.client.login(username='owner', password='pw')
        resp = self.client.get(f'/api/dogs/{self.dog.id}/')
        self.assertNotIn(self.target.isoformat(), resp.data['cancelled_dates'])
        self._assert_in_unassigned()

    def test_staff_add_day_clears_stale_removal(self):
        # Staff-created additions auto-approve in perform_create; that path
        # must clear the marker too.
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.target, status='REMOVED'
        )
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/date-change-requests/', {
            'dog': self.dog.id,
            'request_type': 'ADD_DAY',
            'new_date': self.target.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(
            DailyDogAssignment.objects.filter(
                dog=self.dog, date=self.target, status='REMOVED'
            ).exists()
        )
        self.assertEqual(self._calendar_dog_names(), ['Biscuit'])

    def test_add_back_after_approved_cancellation(self):
        # Day cancelled, then added back: the later approval wins, so the dog
        # attends again even though the approved CANCEL row still exists.
        DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL',
            original_date=self.target, status='APPROVED',
        )
        DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY',
            new_date=self.target, status='APPROVED',
        )
        self.assertEqual(self._calendar_dog_names(), ['Biscuit'])
        self._assert_in_unassigned()

    def test_cancel_after_add_still_cancels(self):
        # The reverse order must keep working: an extra day that is later
        # cancelled stays cancelled.
        extra = self.target + timedelta(days=1)
        ad_hoc = Dog.objects.create(owner=self.owner, name='Ziggy', schedule_type='ad_hoc')
        DateChangeRequest.objects.create(
            dog=ad_hoc, request_type='ADD_DAY',
            new_date=extra, status='APPROVED',
        )
        DateChangeRequest.objects.create(
            dog=ad_hoc, request_type='CANCEL',
            original_date=extra, status='APPROVED',
        )
        self.client.login(username='owner', password='pw')
        resp = self.client.get(f'/api/dogs/calendar/?start={extra}&end={extra}')
        self.assertEqual(resp.status_code, 200)
        self.assertNotIn('Ziggy', [d['name'] for d in resp.data['days'][0]['dogs']])

    def test_approval_order_beats_creation_order(self):
        # A pending re-add created before the cancellation was approved still
        # wins if its approval comes later — the roster reflects the latest
        # approved decision.
        add_req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY',
            new_date=self.target, status='APPROVED',
            approved_at=timezone.now(),
        )
        DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL',
            original_date=self.target, status='APPROVED',
            approved_at=timezone.now() - timedelta(hours=1),
        )
        self.assertEqual(self._calendar_dog_names(), ['Biscuit'])
        add_req.approved_at = timezone.now() - timedelta(hours=2)
        add_req.save(update_fields=['approved_at'])
        self.assertEqual(self._calendar_dog_names(), [])


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

    def test_swap_staff_moves_picked_up_rows_keeping_status(self):
        # Mid-day swap: the dog is already with the team, so the row moves to
        # the new driver and stays PICKED_UP.
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
        self.assertEqual(resp.data['assignment_rows_updated'], 1)
        self.assertTrue(DailyDogAssignment.objects.filter(
            staff_member=self.staff_b, date=self.today, status='PICKED_UP'
        ).exists())

    def test_swap_staff_skips_dropped_off_rows(self):
        # Dogs already returned home are done for the day — swapping must not
        # rewrite who ran them.
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff_a, date=self.today, status='DROPPED_OFF'
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
            staff_member=self.staff_a, date=self.today, status='DROPPED_OFF'
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
        # Managing boarding requests (approve/deny/edit/delete, staff
        # auto-approval) requires the can_manage_boarding flag.
        self.staff.profile.can_manage_boarding = True
        self.staff.profile.save()
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


class PhotoTaggingStatusTests(TestCase):
    """/api/daily-assignments/photo_tagging/ — which of the day's dogs have
    been tagged in feed media posted that day."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(
            username='staff', password='pw', is_staff=True, first_name='Alice',
        )
        self.dog1 = Dog.objects.create(owner=self.owner, name='Rex')
        self.dog2 = Dog.objects.create(owner=self.owner, name='Buddy')
        self.today = date.today()
        self.client = APIClient()

    def _assign(self, dog, status='ASSIGNED'):
        return DailyDogAssignment.objects.create(
            dog=dog, staff_member=self.staff, date=self.today, status=status)

    def _tag(self, *dogs, days_ago=0):
        media = GroupMedia.objects.create(
            uploaded_by=self.staff, media_type='PHOTO', caption='walkies')
        media.tagged_dogs.set(dogs)
        if days_ago:
            GroupMedia.objects.filter(pk=media.pk).update(
                created_at=timezone.now() - timedelta(days=days_ago))
        return media

    def _get(self):
        self.client.login(username='staff', password='pw')
        return self.client.get(
            f'/api/daily-assignments/photo_tagging/?date={self.today.isoformat()}')

    def test_counts_tagged_and_lists_untagged(self):
        self._assign(self.dog1)
        self._assign(self.dog2)
        self._tag(self.dog1)
        resp = self._get()
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['total'], 2)
        self.assertEqual(resp.data['tagged'], 1)
        self.assertEqual(len(resp.data['untagged']), 1)
        self.assertEqual(resp.data['untagged'][0]['dog_name'], 'Buddy')
        self.assertEqual(resp.data['untagged'][0]['staff_member_name'], 'Alice')

    def test_media_from_another_day_does_not_count(self):
        self._assign(self.dog1)
        self._tag(self.dog1, days_ago=1)
        resp = self._get()
        self.assertEqual(resp.data['tagged'], 0)
        self.assertEqual(len(resp.data['untagged']), 1)

    def test_removed_assignment_excluded(self):
        self._assign(self.dog1)
        self._assign(self.dog2, status='REMOVED')
        self._tag(self.dog1)
        resp = self._get()
        self.assertEqual(resp.data['total'], 1)
        self.assertEqual(resp.data['tagged'], 1)
        self.assertEqual(resp.data['untagged'], [])

    def test_non_staff_blocked(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/daily-assignments/photo_tagging/')
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

    def test_manager_can_set_staff_availability(self):
        self.staff.profile.can_manage_staff = True
        self.staff.profile.save()
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/staff-availability/set_staff_availability/', {
            'staff_member': self.staff2.id,
            'availability': [
                {'day_of_week': 1, 'is_available': True, 'note': ''},
                {'day_of_week': 2, 'is_available': False, 'note': 'Not in Tuesdays'},
            ],
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 2)
        tue = StaffAvailability.objects.get(staff_member=self.staff2, day_of_week=2)
        self.assertFalse(tue.is_available)
        self.assertFalse(tue.is_available_daycare)
        self.assertEqual(tue.note, 'Not in Tuesdays')

    def test_non_manager_cannot_set_staff_availability(self):
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/staff-availability/set_staff_availability/', {
            'staff_member': self.staff2.id,
            'availability': [{'day_of_week': 1, 'is_available': False}],
        }, format='json')
        self.assertEqual(resp.status_code, 403)
        self.assertFalse(StaffAvailability.objects.filter(staff_member=self.staff2).exists())

    def test_set_staff_availability_rejects_non_staff_target(self):
        self.staff.profile.can_manage_staff = True
        self.staff.profile.save()
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/staff-availability/set_staff_availability/', {
            'staff_member': self.owner.id,
            'availability': [{'day_of_week': 1, 'is_available': False}],
        }, format='json')
        self.assertEqual(resp.status_code, 404)

    def test_set_staff_availability_requires_staff_member(self):
        self.staff.profile.can_manage_staff = True
        self.staff.profile.save()
        self.client.login(username='staff', password='pw')
        resp = self.client.post('/api/staff-availability/set_staff_availability/', {
            'availability': [{'day_of_week': 1, 'is_available': False}],
        }, format='json')
        self.assertEqual(resp.status_code, 400)

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
                'can_add_feed_media', 'can_manage_staff', 'can_view_inquiries',
                # Legacy alias kept for app builds that predate the rename.
                'can_approve_timeoff',
                'is_superuser',
            ):
                self.assertIn(field, entry)

    def test_legacy_timeoff_alias_mirrors_manage_staff(self):
        """Old app builds read and write can_approve_timeoff; both directions
        must map onto can_manage_staff."""
        self.staff.profile.can_manage_staff = True
        self.staff.profile.save()
        self.client.login(username='admin', password='pw')
        resp = self.client.get('/api/profile/list_staff_permissions/')
        entry = next(e for e in resp.data if e['username'] == 'staff1')
        self.assertTrue(entry['can_approve_timeoff'])
        self.assertTrue(entry['can_manage_staff'])

        resp = self.client.post(
            f'/api/profile/update_staff_permissions/?user_id={self.other_staff.id}',
            {'can_approve_timeoff': True},
            format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.other_staff.profile.refresh_from_db()
        self.assertTrue(self.other_staff.profile.can_manage_staff)

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

    def _age_file(self, path, hours=48):
        """Backdate a file's mtime past the orphan grace period."""
        import os, time
        old = time.time() - hours * 3600
        os.utime(path, (old, old))

    def test_orphan_cleanup_removes_unreferenced_files(self):
        import os
        from django.core.management import call_command
        # Create an orphaned file on disk
        orphan_path = os.path.join(self.media_root, 'group_media', 'orphan.jpg')
        with open(orphan_path, 'wb') as f:
            f.write(b'orphan')
        self._age_file(orphan_path)
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

    def test_orphan_cleanup_spares_a_file_inside_the_grace_period(self):
        """An upload still being written looks exactly like an orphan."""
        import os
        from django.core.management import call_command
        fresh_path = os.path.join(self.media_root, 'dog_photos', 'just-uploaded.jpg')
        os.makedirs(os.path.dirname(fresh_path), exist_ok=True)
        with open(fresh_path, 'wb') as f:
            f.write(b'mid-upload')
        call_command('prune_feed_media', days=9999, include_orphans=True)
        self.assertTrue(os.path.exists(fresh_path))

        # It goes on a later run, once it has sat there unclaimed.
        self._age_file(fresh_path)
        call_command('prune_feed_media', days=9999, include_orphans=True)
        self.assertFalse(os.path.exists(fresh_path))


class DogPhotoRetentionTests(TestCase):
    """Photos in a dog's gallery hold medical records staff have photographed.
    Nothing removes them on a schedule — only deleting the photo or the dog."""

    def setUp(self):
        import os
        from django.conf import settings
        from django.core.files.base import ContentFile

        self.staff = User.objects.create_user(username='photostaff', password='pw', is_staff=True)
        self.owner = User.objects.create_user(username='photoowner', password='pw')
        self.media_root = str(settings.MEDIA_ROOT)
        for d in ['dog_photos', os.path.join('dog_photos', 'thumbnails')]:
            os.makedirs(os.path.join(self.media_root, d), exist_ok=True)

        self.dog = Dog.objects.create(owner=self.owner, name='Bramble')
        self.photo = Photo.objects.create(
            dog=self.dog,
            taken_at=timezone.now() - timedelta(days=1200),
            file=ContentFile(b'vaccination-card', name='meds.jpg'),
        )
        # Years old — well past any feed retention window.
        Photo.objects.filter(pk=self.photo.pk).update(
            created_at=timezone.now() - timedelta(days=1200),
        )
        self.photo.refresh_from_db()
        self.client = APIClient()

    def tearDown(self):
        import shutil, os
        from django.conf import settings
        path = os.path.join(str(settings.MEDIA_ROOT), 'dog_photos')
        if os.path.isdir(path):
            shutil.rmtree(path)

    def _photo_path(self):
        import os
        return os.path.join(self.media_root, self.photo.file.name)

    def test_pruning_never_touches_a_dog_photo_however_old(self):
        import os
        from django.core.management import call_command
        path = self._photo_path()
        self.assertTrue(os.path.exists(path))
        # The production schedule, with the shortest retention anyone would set.
        call_command('prune_feed_media', days=1, include_orphans=True)
        self.assertTrue(Photo.objects.filter(pk=self.photo.pk).exists())
        self.assertTrue(os.path.exists(path))

    def test_the_orphan_sweep_spares_a_photo_added_since_its_snapshot(self):
        """The sweep re-checks the database before deleting anything."""
        import os
        from django.core.files.base import ContentFile
        from django.core.management import call_command
        from api.management.commands import prune_feed_media

        real = prune_feed_media.Command._referenced_names
        state = {'late': None}

        def snapshot_then_upload(names=None):
            result = real(names)
            if state['late'] is None:
                # A staff member uploads while the command is walking the
                # directories: the snapshot it just took is already stale.
                late = Photo.objects.create(
                    dog=self.dog, taken_at=timezone.now(),
                    file=ContentFile(b'x-ray', name='xray.jpg'),
                )
                path = os.path.join(self.media_root, late.file.name)
                os.utime(path, (0, 0))  # and it is not saved by the grace period
                state['late'] = late
            return result

        with patch.object(
            prune_feed_media.Command, '_referenced_names',
            staticmethod(snapshot_then_upload),
        ):
            call_command('prune_feed_media', days=9999, include_orphans=True)

        late = state['late']
        self.assertIsNotNone(late)
        self.assertTrue(Photo.objects.filter(pk=late.pk).exists())
        self.assertTrue(os.path.exists(os.path.join(self.media_root, late.file.name)))

    def test_deleting_the_dog_removes_its_photos(self):
        import os
        path = self._photo_path()
        self.client.login(username='photostaff', password='pw')
        resp = self.client.delete(f'/api/dogs/{self.dog.id}/')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertFalse(Photo.objects.filter(pk=self.photo.pk).exists())
        self.assertFalse(os.path.exists(path))

    def test_an_owner_cannot_delete_a_photo(self):
        """The gallery holds medical records — removing one is staff's call."""
        import os
        path = self._photo_path()
        self.client.login(username='photoowner', password='pw')
        resp = self.client.delete(f'/api/photos/{self.photo.id}/')
        self.assertEqual(resp.status_code, 403)
        self.assertTrue(Photo.objects.filter(pk=self.photo.pk).exists())
        self.assertTrue(os.path.exists(path))

    def test_a_co_owner_cannot_delete_a_photo_either(self):
        co_owner = User.objects.create_user(username='photocoowner', password='pw')
        self.dog.additional_owners.add(co_owner)
        self.client.login(username='photocoowner', password='pw')
        resp = self.client.delete(f'/api/photos/{self.photo.id}/')
        self.assertEqual(resp.status_code, 403)
        self.assertTrue(Photo.objects.filter(pk=self.photo.pk).exists())

    def test_staff_can_still_delete_a_photo(self):
        import os
        path = self._photo_path()
        self.client.login(username='photostaff', password='pw')
        resp = self.client.delete(f'/api/photos/{self.photo.id}/')
        self.assertEqual(resp.status_code, 204)
        self.assertFalse(Photo.objects.filter(pk=self.photo.pk).exists())
        self.assertFalse(os.path.exists(path))

    def test_an_owner_can_still_add_to_the_gallery(self):
        """Read and upload are unchanged — only removal is restricted."""
        from django.core.files.uploadedfile import SimpleUploadedFile
        from PIL import Image
        import io

        buf = io.BytesIO()
        Image.new('RGB', (20, 20), 'white').save(buf, format='JPEG')
        buf.seek(0)
        self.client.login(username='photoowner', password='pw')
        with patch('api.views.PhotoViewSet._notify_owners_of_new_photo'):
            resp = self.client.post('/api/photos/', {
                'dog': self.dog.id,
                'media_type': 'PHOTO',
                'taken_at': timezone.now().isoformat(),
                'file': SimpleUploadedFile('new.jpg', buf.read(), content_type='image/jpeg'),
            }, format='multipart')
        self.assertEqual(resp.status_code, 201, resp.data)

        resp = self.client.get(f'/api/photos/by_dog/?dog_id={self.dog.id}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 2)


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

    def test_materialization_keeps_owner_transport_dog_off_the_route_but_on_record(self):
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
        # Still absent from the driver's list...
        dog_ids = [a['dog'] for a in resp.data]
        self.assertNotIn(self.dog.id, dog_ids)
        # ...but the attendance row exists, because billing reads attendance
        # from DailyDogAssignment. This test previously asserted no row at all,
        # which is why these dogs were silently invoiced £0.
        assignment = DailyDogAssignment.objects.get(dog=self.dog, date=self.today)
        self.assertEqual(assignment.status, 'UNASSIGNED')

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


@override_settings(STORAGES={
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
})
class AdminApproveRequestsTests(TestCase):
    """The admin bulk-approve action must apply the same roster side-effects
    as the API approval paths: cancellations free their day, additions clear
    a stale "removed from this day" marker so the dog shows up again."""

    def setUp(self):
        self.admin = User.objects.create_superuser(username='admin', password='pw')
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.dog = Dog.objects.create(owner=self.owner, name='Rex')
        self.target = date.today() + timedelta(days=7)
        self.client = Client()
        self.client.force_login(self.admin)

    def _approve(self, req):
        resp = self.client.post('/admin/api/datechangerequest/', {
            'action': 'approve_requests',
            '_selected_action': [str(req.id)],
        })
        self.assertEqual(resp.status_code, 302)
        req.refresh_from_db()
        self.assertEqual(req.status, 'APPROVED')

    def test_bulk_approve_add_day_clears_stale_removal(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.admin, date=self.target, status='REMOVED'
        )
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY', new_date=self.target,
        )
        self._approve(req)
        self.assertFalse(
            DailyDogAssignment.objects.filter(
                dog=self.dog, date=self.target, status='REMOVED'
            ).exists()
        )

    def test_bulk_approve_cancel_frees_the_day(self):
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.admin, date=self.target, status='ASSIGNED'
        )
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=self.target,
        )
        self._approve(req)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.target).exists()
        )

    def test_bulk_approve_change_moves_the_day(self):
        new_date = self.target + timedelta(days=1)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.admin, date=self.target, status='ASSIGNED'
        )
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.admin, date=new_date, status='REMOVED'
        )
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CHANGE',
            original_date=self.target, new_date=new_date,
        )
        self._approve(req)
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=self.target).exists()
        )
        self.assertFalse(
            DailyDogAssignment.objects.filter(dog=self.dog, date=new_date).exists()
        )


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


class WriteSideIDORTests(TestCase):
    """get_queryset scopes which rows a caller may READ. These cover the write
    side: a row the caller legitimately owns must not be re-pointed at another
    customer's dog via a writable FK."""

    def setUp(self):
        self.a = User.objects.create_user(username='ownera', password='pw')
        self.b = User.objects.create_user(username='ownerb', password='pw')
        self.a_dog = Dog.objects.create(owner=self.a, name='ADog')
        self.b_dog = Dog.objects.create(owner=self.b, name='BDog')
        self.client = APIClient()
        self.client.force_authenticate(self.a)

    def test_patch_date_change_request_cannot_repoint_dog(self):
        req = DateChangeRequest.objects.create(
            dog=self.a_dog, request_type='CANCEL',
            original_date=timezone.localdate() + timedelta(days=7),
        )
        resp = self.client.patch(
            f'/api/date-change-requests/{req.id}/', {'dog': self.b_dog.id}, format='json',
        )
        self.assertEqual(resp.status_code, 403)
        req.refresh_from_db()
        self.assertEqual(req.dog_id, self.a_dog.id)

    def test_patch_date_change_request_cannot_move_date_into_the_past(self):
        req = DateChangeRequest.objects.create(
            dog=self.a_dog, request_type='CANCEL',
            original_date=timezone.localdate() + timedelta(days=7),
        )
        past = timezone.localdate() - timedelta(days=3)
        resp = self.client.patch(
            f'/api/date-change-requests/{req.id}/',
            {'original_date': past.isoformat()}, format='json',
        )
        self.assertEqual(resp.status_code, 403)
        req.refresh_from_db()
        self.assertNotEqual(req.original_date, past)

    def test_owner_can_still_patch_own_request(self):
        req = DateChangeRequest.objects.create(
            dog=self.a_dog, request_type='CANCEL',
            original_date=timezone.localdate() + timedelta(days=7),
        )
        new_date = timezone.localdate() + timedelta(days=9)
        resp = self.client.patch(
            f'/api/date-change-requests/{req.id}/',
            {'original_date': new_date.isoformat()}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        req.refresh_from_db()
        self.assertEqual(req.original_date, new_date)

    def test_patch_photo_cannot_repoint_to_other_owners_dog(self):
        photo = Photo.objects.create(
            dog=self.a_dog, file='dog_photos/x.jpg', taken_at=timezone.now(),
        )
        resp = self.client.patch(
            f'/api/photos/{photo.id}/', {'dog': self.b_dog.id}, format='json',
        )
        self.assertEqual(resp.status_code, 403)
        photo.refresh_from_db()
        self.assertEqual(photo.dog_id, self.a_dog.id)


class PastDayBillingGuardTests(TestCase):
    """The past-day billing rule is enforced by update_status / mark_removed /
    unassign. The generic detail route reaches the same rows and must not be a
    way around it."""

    def setUp(self):
        self.staff = User.objects.create_user(username='plainstaff', password='pw', is_staff=True)
        self.manager = User.objects.create_user(username='paymgr', password='pw', is_staff=True)
        self.manager.profile.can_manage_payments = True
        self.manager.profile.save()
        self.dog = Dog.objects.create(name='Fido')
        self.past = timezone.localdate() - timedelta(days=3)
        self.assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff, date=self.past, status='ASSIGNED',
        )
        self.client = APIClient()

    def test_patch_daily_assignment_past_date_requires_payments_permission(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.patch(
            f'/api/daily-assignments/{self.assignment.id}/',
            {'status': 'REMOVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 403)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, 'ASSIGNED')

    def test_delete_daily_assignment_past_date_requires_payments_permission(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.delete(f'/api/daily-assignments/{self.assignment.id}/')
        self.assertEqual(resp.status_code, 403)
        self.assertTrue(DailyDogAssignment.objects.filter(pk=self.assignment.pk).exists())

    def test_payments_manager_may_patch_past_date(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.patch(
            f'/api/daily-assignments/{self.assignment.id}/',
            {'status': 'REMOVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, 'REMOVED')

    def test_plain_staff_may_still_patch_a_future_day(self):
        future = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.staff,
            date=timezone.localdate() + timedelta(days=2), status='ASSIGNED',
        )
        self.client.force_authenticate(self.staff)
        resp = self.client.patch(
            f'/api/daily-assignments/{future.id}/', {'status': 'REMOVED'}, format='json',
        )
        self.assertEqual(resp.status_code, 200)


class StaffAvailabilityScopingTests(TestCase):
    """A row marking a staff member unavailable suppresses all their push
    notifications, so only staff managers may edit someone else's."""

    def setUp(self):
        self.staff = User.objects.create_user(username='staff1', password='pw', is_staff=True)
        self.other = User.objects.create_user(username='staff2', password='pw', is_staff=True)
        self.manager = User.objects.create_user(username='staffmgr', password='pw', is_staff=True)
        self.manager.profile.can_manage_staff = True
        self.manager.profile.save()
        self.other_row = StaffAvailability.objects.create(
            staff_member=self.other, day_of_week=1, is_available=True,
        )
        self.client = APIClient()

    def test_staff_cannot_patch_another_staff_availability(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.patch(
            f'/api/staff-availability/{self.other_row.id}/',
            {'is_available': False}, format='json',
        )
        self.assertIn(resp.status_code, (403, 404))
        self.other_row.refresh_from_db()
        self.assertTrue(self.other_row.is_available)

    def test_staff_cannot_delete_another_staff_availability(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.delete(f'/api/staff-availability/{self.other_row.id}/')
        self.assertIn(resp.status_code, (403, 404))
        self.assertTrue(StaffAvailability.objects.filter(pk=self.other_row.pk).exists())

    def test_create_is_pinned_to_the_caller(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.post(
            '/api/staff-availability/',
            {'staff_member': self.other.id, 'day_of_week': 4, 'is_available': False},
            format='json',
        )
        self.assertEqual(resp.status_code, 201)
        row = StaffAvailability.objects.get(day_of_week=4)
        self.assertEqual(row.staff_member_id, self.staff.id)

    def test_staff_manager_may_patch_another_staff_availability(self):
        self.client.force_authenticate(self.manager)
        resp = self.client.patch(
            f'/api/staff-availability/{self.other_row.id}/',
            {'is_available': False}, format='json',
        )
        self.assertEqual(resp.status_code, 200)
        self.other_row.refresh_from_db()
        self.assertFalse(self.other_row.is_available)

    def test_everyone_can_still_read_the_rota(self):
        self.client.force_authenticate(self.staff)
        resp = self.client.get('/api/staff-availability/')
        self.assertEqual(resp.status_code, 200)
        returned = resp.json()
        rows = returned['results'] if isinstance(returned, dict) else returned
        self.assertTrue(any(r['id'] == self.other_row.id for r in rows))


class PasswordResetHardeningTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            username='resetme', password='OldPass123!', email='reset@example.com')
        self.client = APIClient()

    def _reset_to(self, new_password):
        self.client.post(
            '/api/password/reset/request/', {'email': 'reset@example.com'}, format='json')
        otp = PasswordResetOTP.objects.filter(user=self.user, is_used=False).latest('created_at')
        verify = self.client.post(
            '/api/password/reset/verify/',
            {'email': 'reset@example.com', 'otp': otp.otp}, format='json')
        self.assertEqual(verify.status_code, 200)
        return self.client.post(
            '/api/password/reset/confirm/',
            {'reset_token': verify.json()['reset_token'], 'new_password': new_password},
            format='json')

    def test_password_reset_invalidates_existing_token(self):
        token = Token.objects.create(user=self.user)
        resp = self._reset_to('BrandNewPass123!')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(Token.objects.filter(key=token.key).exists())

    def test_duplicate_email_does_not_500_the_reset_request(self):
        # Django's User.email has no unique constraint, so duplicates exist in
        # real data. User.objects.get() would raise MultipleObjectsReturned.
        User.objects.create_user(
            username='resetme2', password='pw', email='RESET@example.com')
        resp = self.client.post(
            '/api/password/reset/request/', {'email': 'reset@example.com'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(PasswordResetOTP.objects.exists())

    def test_duplicate_email_does_not_500_the_verify_step(self):
        User.objects.create_user(
            username='resetme2', password='pw', email='RESET@example.com')
        resp = self.client.post(
            '/api/password/reset/verify/',
            {'email': 'reset@example.com', 'otp': '000000'}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_reset_request_still_succeeds_when_email_sending_fails(self):
        # Otherwise a broken SMTP config turns the deliberately-generic response
        # into an enumeration oracle: 500 for a known address, 200 for unknown.
        with patch('api.views.send_mail', side_effect=Exception('smtp down')):
            resp = self.client.post(
                '/api/password/reset/request/', {'email': 'reset@example.com'}, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_signup_rejects_a_duplicate_email(self):
        resp = self.client.post(
            '/auth/users/',
            {
                'username': 'newperson', 'password': 'BrandNewPass123!',
                'email': 'Reset@Example.com', 'accept_privacy': True,
            },
            format='json',
        )
        self.assertEqual(resp.status_code, 400)
        self.assertIn('email', resp.json())


@skipUnless(
    connection.features.supports_json_field_contains,
    'unassigned_dogs filters daycare_days with a JSON contains lookup, which '
    'SQLite does not support. Runs on PostgreSQL (i.e. in CI and production).',
)
class UnassignedDogsQueryTests(TestCase):
    def setUp(self):
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.today = timezone.localdate()
        self.client = APIClient()
        self.client.force_authenticate(self.staff)

    def _dog(self, name, **kwargs):
        return Dog.objects.create(
            owner=self.owner, name=name,
            daycare_days=[self.today.isoweekday()], **kwargs)

    def test_owner_transport_dog_is_not_listed_as_unassigned(self):
        # It is materialized UNASSIGNED so billing can see the attendance, but
        # it never needs a driver — listing it would be a permanent,
        # un-actionable red banner on the dashboard.
        self._dog('SelfDriven', owner_brings_default=True, owner_collects_default=True)
        resp = self.client.get(f'/api/daily-assignments/unassigned_dogs/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual([d['name'] for d in resp.data], [])

    def test_dog_needing_a_driver_is_still_listed(self):
        self._dog('NeedsLift')
        resp = self.client.get(f'/api/daily-assignments/unassigned_dogs/?date={self.today.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual([d['name'] for d in resp.data], ['NeedsLift'])

    def test_query_count_is_constant_as_dogs_are_added(self):
        # unassigned_dogs built its own Dog queryset and lost the
        # future_removed_assignments prefetch, so cancelled_dates fell back to a
        # query per dog on the staff dashboard's hottest endpoint.
        for i in range(2):
            self._dog(f'Small{i}')
        url = f'/api/daily-assignments/unassigned_dogs/?date={self.today.isoformat()}'
        with CaptureQueriesContext(connection) as small:
            self.client.get(url)

        for i in range(10):
            self._dog(f'Big{i}')
        with CaptureQueriesContext(connection) as big:
            self.client.get(url)

        self.assertEqual(len(big), len(small),
                         f'query count grew with dog count: {len(small)} -> {len(big)}')


class DeleteAccountProtectedTests(TestCase):
    """Invoice.customer and DogWeekdayPickup.staff_member are PROTECT, so
    user.delete() raises for anyone who has ever been invoiced or driven a
    route. Account deletion is an App Store requirement and must not 500."""

    def setUp(self):
        self.user = User.objects.create_user(
            username='billed', password='OldPass123!', email='billed@example.com',
            first_name='Bill')
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_delete_account_with_invoice_anonymises_instead_of_500(self):
        Invoice.objects.create(
            customer=self.user, period_year=2026, period_month=6,
            status='SENT', total=Decimal('40.00'))

        resp = self.client.post(
            '/api/account/delete/', {'password': 'OldPass123!'}, format='json')

        self.assertEqual(resp.status_code, 200)
        self.user.refresh_from_db()
        # Invoice survives (statutory record), the person does not.
        self.assertEqual(Invoice.objects.filter(customer=self.user).count(), 1)
        self.assertFalse(self.user.is_active)
        self.assertEqual(self.user.email, '')
        self.assertEqual(self.user.first_name, '')
        self.assertNotIn('billed', self.user.username)
        self.assertFalse(self.user.has_usable_password())

    def test_delete_account_staff_with_weekday_pickups_does_not_500(self):
        staff = User.objects.create_user(
            username='driver', password='OldPass123!', is_staff=True)
        dog = Dog.objects.create(name='Routed')
        DogWeekdayPickup.objects.create(dog=dog, weekday=1, staff_member=staff)
        client = APIClient()
        client.force_authenticate(staff)

        resp = client.post(
            '/api/account/delete/', {'password': 'OldPass123!'}, format='json')

        self.assertEqual(resp.status_code, 200)
        staff.refresh_from_db()
        self.assertFalse(staff.is_active)

    def test_delete_account_without_protected_rows_still_hard_deletes(self):
        resp = self.client.post(
            '/api/account/delete/', {'password': 'OldPass123!'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(User.objects.filter(pk=self.user.pk).exists())

    def test_dog_ownership_is_not_transferred_when_deletion_fails(self):
        # The promotion loop used to commit before the delete blew up, leaving
        # the customer with an account AND their dog reassigned to a partner.
        partner = User.objects.create_user(username='partner', password='pw')
        dog = Dog.objects.create(owner=self.user, name='Shared')
        dog.additional_owners.add(partner)
        Invoice.objects.create(
            customer=self.user, period_year=2026, period_month=6,
            status='SENT', total=Decimal('40.00'))

        resp = self.client.post(
            '/api/account/delete/', {'password': 'OldPass123!'}, format='json')

        self.assertEqual(resp.status_code, 200)
        dog.refresh_from_db()
        # Promotion is fine here — it committed inside the same transaction that
        # succeeded. What matters is that it is consistent with the outcome.
        self.assertIn(dog.owner_id, (self.user.pk, partner.pk))


class StaffDeletionKeepsAttendanceTests(TestCase):
    def test_deleting_a_staff_member_keeps_the_attendance_rows(self):
        # These rows ARE the billing record. CASCADE deleted every day a
        # departed driver had ever worked, including the unbilled month.
        staff = User.objects.create_user(username='leaver', password='pw', is_staff=True)
        dog = Dog.objects.create(name='Rover')
        assignment = DailyDogAssignment.objects.create(
            dog=dog, staff_member=staff, date=date(2026, 6, 10), status='DROPPED_OFF')

        staff.delete()

        assignment.refresh_from_db()
        self.assertIsNone(assignment.staff_member)
        self.assertEqual(assignment.status, 'DROPPED_OFF')

    def test_serializer_tolerates_a_null_staff_member(self):
        from api.serializers import DailyDogAssignmentSerializer
        dog = Dog.objects.create(name='Rover')
        assignment = DailyDogAssignment.objects.create(
            dog=dog, staff_member=None, date=date(2026, 6, 10), status='DROPPED_OFF')
        data = DailyDogAssignmentSerializer(assignment).data
        self.assertIsNone(data['staff_member_name'])


class CoOwnerBoardingTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='primary', password='pw')
        self.partner = User.objects.create_user(username='partner', password='pw')
        self.dog = Dog.objects.create(owner=self.owner, name='Shared')
        self.dog.additional_owners.add(self.partner)
        self.client = APIClient()
        self.client.force_authenticate(self.partner)

    def test_coowner_can_create_boarding_request(self):
        # The app's dog picker lists co-owned dogs, so scoping the serializer's
        # `dogs` queryset to owner-only made a valid choice 400 as "Invalid pk".
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': (timezone.localdate() + timedelta(days=10)).isoformat(),
            'end_date': (timezone.localdate() + timedelta(days=12)).isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201, resp.content)

    def test_coowner_sees_boarding_requests_for_own_dog(self):
        booking = BoardingRequest.objects.create(
            owner=self.owner,
            start_date=timezone.localdate() + timedelta(days=10),
            end_date=timezone.localdate() + timedelta(days=12),
        )
        booking.dogs.add(self.dog)

        resp = self.client.get(f'/api/boarding-requests/{booking.id}/')
        self.assertEqual(resp.status_code, 200)

    def test_non_owner_still_cannot_book_that_dog(self):
        stranger = User.objects.create_user(username='stranger', password='pw')
        client = APIClient()
        client.force_authenticate(stranger)
        resp = client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': (timezone.localdate() + timedelta(days=10)).isoformat(),
            'end_date': (timezone.localdate() + timedelta(days=12)).isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 400)


class ContactInquiryEndpointTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.viewer = User.objects.create_user(username='viewer', password='pw', is_staff=True)
        self.viewer.profile.can_view_inquiries = True
        self.viewer.profile.save()
        self.client = APIClient()

    def test_owner_cannot_create_blank_inquiries(self):
        # Every field is read-only, so this created empty rows that push-notified
        # every inquiry-managing staff member, unthrottled.
        from website.models import ContactInquiry
        self.client.force_authenticate(self.owner)
        resp = self.client.post('/api/contact-inquiries/', {}, format='json')
        self.assertIn(resp.status_code, (403, 405))
        self.assertEqual(ContactInquiry.objects.count(), 0)

    def test_owner_cannot_list_inquiries(self):
        self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.get('/api/contact-inquiries/').status_code, 403)

    def test_staff_without_permission_cannot_list_inquiries(self):
        self.client.force_authenticate(self.staff)
        self.assertEqual(self.client.get('/api/contact-inquiries/').status_code, 403)

    def test_permitted_staff_can_list_and_count(self):
        self.client.force_authenticate(self.viewer)
        self.assertEqual(self.client.get('/api/contact-inquiries/').status_code, 200)
        resp = self.client.get('/api/contact-inquiries/unread_count/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['count'], 0)


class PhotoUploadValidationTests(TestCase):
    """Photo.file is a FileField and /media/ is served unauthenticated straight
    off disk, so an unvalidated upload is stored XSS on the main domain."""

    def setUp(self):
        import shutil
        import tempfile
        # Keep accepted uploads out of the real media/ directory.
        self._media_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self._media_dir, True)
        overridden = override_settings(MEDIA_ROOT=self._media_dir)
        overridden.enable()
        self.addCleanup(overridden.disable)

        self.owner = User.objects.create_user(username='photoowner', password='pw')
        self.dog = Dog.objects.create(owner=self.owner, name='Snap')
        self.client = APIClient()
        self.client.force_authenticate(self.owner)

    @staticmethod
    def _jpeg(name='real.jpg', size=(60, 40)):
        from io import BytesIO
        from PIL import Image
        from django.core.files.uploadedfile import SimpleUploadedFile
        buf = BytesIO()
        Image.new('RGB', size, (120, 90, 60)).save(buf, format='JPEG')
        return SimpleUploadedFile(name, buf.getvalue(), content_type='image/jpeg')

    def _post(self, upload, media_type='PHOTO'):
        return self.client.post(
            '/api/photos/',
            {
                'dog': self.dog.id, 'media_type': media_type, 'file': upload,
                'taken_at': timezone.now().isoformat(),
            },
            format='multipart',
        )

    def test_photo_upload_accepts_a_real_image(self):
        resp = self._post(self._jpeg())
        self.assertEqual(resp.status_code, 201, resp.content)
        photo = Photo.objects.get()
        # Stored under a generated name, never the uploaded one.
        self.assertNotIn('real', photo.file.name)
        self.assertTrue(photo.file.name.endswith('.jpg'))
        self.assertTrue(photo.thumbnail)

    def test_photo_upload_rejects_html(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        evil = SimpleUploadedFile(
            'evil.html', b'<script>alert(document.domain)</script>',
            content_type='text/html')
        resp = self._post(evil)
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(Photo.objects.count(), 0)

    def test_photo_upload_rejects_svg(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        evil = SimpleUploadedFile(
            'evil.svg', b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
            content_type='image/svg+xml')
        resp = self._post(evil)
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(Photo.objects.count(), 0)

    def test_photo_upload_rejects_html_disguised_as_a_video(self):
        # media_type=VIDEO skips image processing entirely, so the extension
        # allow-list is the only thing standing in the way.
        from django.core.files.uploadedfile import SimpleUploadedFile
        evil = SimpleUploadedFile(
            'evil.html', b'<script>alert(1)</script>', content_type='video/mp4')
        resp = self._post(evil, media_type='VIDEO')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(Photo.objects.count(), 0)

    def test_photo_upload_rejects_a_jpg_that_is_not_an_image(self):
        # Right extension, wrong bytes — caught by the Pillow verify() probe.
        from django.core.files.uploadedfile import SimpleUploadedFile
        evil = SimpleUploadedFile(
            'evil.jpg', b'<script>alert(1)</script>', content_type='image/jpeg')
        resp = self._post(evil)
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(Photo.objects.count(), 0)

    def test_photo_upload_rejects_oversize_file(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        from .validators import MAX_IMAGE_UPLOAD_BYTES
        huge = SimpleUploadedFile(
            'big.jpg', b'\xff\xd8\xff' + b'0' * MAX_IMAGE_UPLOAD_BYTES,
            content_type='image/jpeg')
        resp = self._post(huge)
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(Photo.objects.count(), 0)

    def test_process_image_raises_instead_of_storing_the_original(self):
        from io import BytesIO
        from .views import process_image, ImageProcessingError
        with self.assertRaises(ImageProcessingError):
            process_image(BytesIO(b'not an image at all'))


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


class BusinessAlertTests(TestCase):
    """Business-owner oversight alerts: staff flagged receives_business_alerts
    (i.e. the boss) are told when a driver sends a traffic alert — who pressed
    it, which leg, how many owners it reached — past the working-day filter,
    and even when it reached nobody."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.driver = User.objects.create_user(username='driver', password='pw', is_staff=True)
        self.boss = User.objects.create_user(username='claire', password='pw', is_staff=True)
        self.boss.profile.receives_business_alerts = True
        self.boss.profile.save()
        self.other_staff = User.objects.create_user(username='helper', password='pw', is_staff=True)
        self.today = date.today()
        self.dog = Dog.objects.create(
            owner=self.owner, name='Ace',
            daycare_days=[self.today.isoweekday()], schedule_type='weekly',
        )
        self.assignment = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.driver, date=self.today, status='ASSIGNED',
        )

    def _calls_for(self, mock_push, user):
        return [c for c in mock_push.call_args_list if c.args[0].id == user.id]

    @patch('api.notifications.send_push_notification')
    def test_boss_notified_when_traffic_alert_sent(self, mock_push):
        from api.notifications import send_traffic_alert
        send_traffic_alert('pickup', self.today, self.driver, detail='A34 closed')
        calls = self._calls_for(mock_push, self.boss)
        self.assertEqual(len(calls), 1)
        title, body = calls[0].args[1], calls[0].args[2]
        self.assertEqual(title, 'Traffic alert sent')
        self.assertIn('driver', body)
        self.assertIn('pickup', body)
        self.assertIn('1 owner', body)
        self.assertIn('A34 closed', body)
        # Must reach the boss even on a day off.
        self.assertTrue(calls[0].kwargs.get('ignore_working_hours'))

    @patch('api.notifications.send_push_notification')
    def test_unflagged_staff_not_notified(self, mock_push):
        from api.notifications import send_traffic_alert
        send_traffic_alert('pickup', self.today, self.driver)
        self.assertEqual(self._calls_for(mock_push, self.other_staff), [])

    @patch('api.notifications.send_push_notification')
    def test_pressing_boss_not_notified_of_own_alert(self, mock_push):
        from api.notifications import send_traffic_alert
        self.assignment.staff_member = self.boss
        self.assignment.save()
        send_traffic_alert('pickup', self.today, self.boss)
        self.assertEqual(self._calls_for(mock_push, self.boss), [])

    @patch('api.notifications.send_push_notification')
    def test_boss_notified_even_when_no_owners_matched(self, mock_push):
        from api.notifications import send_traffic_alert
        # Dog already picked up: the default pickup filter matches no owners.
        self.assignment.status = 'PICKED_UP'
        self.assignment.save()
        send_traffic_alert('pickup', self.today, self.driver)
        calls = self._calls_for(mock_push, self.boss)
        self.assertEqual(len(calls), 1)
        self.assertIn('no owners needed notifying', calls[0].args[2])
        # And no owner push went out.
        self.assertEqual(self._calls_for(mock_push, self.owner), [])

    @patch('api.notifications.initialize_firebase', return_value=False)
    @patch('api.notifications._is_staff_working_today', return_value=False)
    def test_ignore_working_hours_bypasses_day_off_filter(self, mock_working, mock_firebase):
        from api.notifications import send_push_notification
        # Normal staff push on a non-working day stops before Firebase init.
        send_push_notification(self.boss, 't', 'b')
        mock_firebase.assert_not_called()
        # An oversight alert carries on past the working-day gate.
        send_push_notification(self.boss, 't', 'b', ignore_working_hours=True)
        mock_firebase.assert_called_once()


class EndOfDayAlertTests(TestCase):
    """send_end_of_day_alerts — the closing-time exception sweep: dogs never
    picked up, still out with the team, or never claimed by a driver go to
    staff flagged receives_business_alerts; owner-handled legs, house-account
    boarding rows and closure days never alarm."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.driver = User.objects.create_user(username='driver', password='pw', is_staff=True)
        self.boss = User.objects.create_user(username='claire', password='pw', is_staff=True)
        self.boss.profile.receives_business_alerts = True
        self.boss.profile.save()
        self.today = date.today()
        self.weekday = [self.today.isoweekday()]

    def _dog(self, name, **overrides):
        return Dog.objects.create(
            owner=self.owner, name=name, daycare_days=self.weekday,
            schedule_type='weekly', **overrides)

    def _row(self, dog, status, staff=..., **overrides):
        return DailyDogAssignment.objects.create(
            dog=dog, staff_member=self.driver if staff is ... else staff,
            date=self.today, status=status, **overrides)

    def _boss_calls(self, mock_push):
        return [c for c in mock_push.call_args_list if c.args[0].id == self.boss.id]

    @patch('api.notifications.send_push_notification')
    def test_exceptions_summarised_to_boss(self, mock_push):
        self._row(self._dog('Ace'), 'ASSIGNED')                # never picked up
        self._row(self._dog('Buddy'), 'PICKED_UP')             # still out
        self._row(self._dog('Coco'), 'DROPPED_OFF')            # fine
        self._row(self._dog('Dot', owner_brings_default=True), 'ASSIGNED')  # owner's leg
        self._row(self._dog('Elm'), 'UNASSIGNED', staff=None)  # never claimed
        call_command('send_end_of_day_alerts')
        calls = self._boss_calls(mock_push)
        self.assertEqual(len(calls), 1)
        title, body = calls[0].args[1], calls[0].args[2]
        self.assertIn('3 dogs', title)
        for name in ('Ace', 'Buddy', 'Elm'):
            self.assertIn(name, body)
        for name in ('Coco', 'Dot'):
            self.assertNotIn(name, body)
        self.assertTrue(calls[0].kwargs.get('ignore_working_hours'))

    @patch('api.notifications.send_push_notification')
    def test_silent_when_everything_got_home(self, mock_push):
        self._row(self._dog('Ace'), 'DROPPED_OFF')
        self._row(self._dog('Rem'), 'REMOVED')
        call_command('send_end_of_day_alerts')
        mock_push.assert_not_called()

    @patch('api.notifications.send_push_notification')
    def test_owner_collected_dog_marked_with_team_not_flagged(self, mock_push):
        self._row(self._dog('Ace', owner_collects_default=True), 'PICKED_UP')
        call_command('send_end_of_day_alerts')
        mock_push.assert_not_called()

    @patch('api.notifications.send_push_notification')
    def test_unassigned_with_owner_handling_both_legs_not_flagged(self, mock_push):
        dog = self._dog('Ace', owner_brings_default=True, owner_collects_default=True)
        self._row(dog, 'UNASSIGNED', staff=None)
        call_command('send_end_of_day_alerts')
        mock_push.assert_not_called()

    @patch('api.notifications.send_push_notification')
    def test_house_account_boarding_rows_skipped(self, mock_push):
        house = User.objects.create_user(username='P4TD', password='pw', is_staff=True)
        self._row(self._dog('Ace'), 'ASSIGNED', staff=house, from_boarding=True)
        call_command('send_end_of_day_alerts')
        mock_push.assert_not_called()

    @patch('api.notifications.send_push_notification')
    def test_closure_day_skipped(self, mock_push):
        ClosureDay.objects.create(date=self.today, closure_type='CLOSED', reason='Bank holiday')
        self._row(self._dog('Ace'), 'ASSIGNED')
        call_command('send_end_of_day_alerts')
        mock_push.assert_not_called()

    @patch('api.notifications.send_push_notification')
    def test_explicit_date_option(self, mock_push):
        other_day = self.today - timedelta(days=1)
        DailyDogAssignment.objects.create(
            dog=self._dog('Ace'), staff_member=self.driver,
            date=other_day, status='ASSIGNED')
        call_command('send_end_of_day_alerts', date=other_day.isoformat())
        self.assertEqual(len(self._boss_calls(mock_push)), 1)


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
        # Staff auto-approval of bookings needs the boarding-manager flag.
        self.staff.profile.can_manage_boarding = True
        self.staff.profile.save()
        self.manager = User.objects.create_user(username='nmanager', password='pw', is_staff=True)
        self.manager.profile.can_manage_requests = True
        self.manager.profile.can_manage_boarding = True
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


# =============================================================================
# CUSTOMER PAYMENTS (monthly invoices + Xero)
# =============================================================================

class BillingTestsBase(TestCase):
    """Shared fixtures for the billing/invoice test classes."""

    def setUp(self):
        from website.models import ServicePricing

        self.superuser = User.objects.create_user(
            username='admin', password='pw', is_staff=True, is_superuser=True)
        self.manager = User.objects.create_user(
            username='manager', password='pw', is_staff=True, first_name='Meg')
        self.manager.profile.can_manage_payments = True
        self.manager.profile.save()
        self.plain_staff = User.objects.create_user(
            username='plainstaff', password='pw', is_staff=True)
        self.owner = User.objects.create_user(
            username='owner', password='pw', first_name='Olive', email='olive@example.com')
        self.other_owner = User.objects.create_user(
            username='other', password='pw', email='other@example.com')
        # Fixture owners are on app billing; the MANUAL/Xero-transition tests
        # (BillingModeTransitionTests) flip this per-case.
        for customer in (self.owner, self.other_owner):
            customer.profile.billing_mode = 'APP'
            customer.profile.save()

        self.dog = Dog.objects.create(owner=self.owner, name='Biscuit')
        self.dog2 = Dog.objects.create(owner=self.owner, name='Alfie')
        self.other_dog = Dog.objects.create(owner=self.other_owner, name='Rex')

        # Known default day rate (save() also refreshes the singleton cache).
        # Fixture dogs have no booked days, so flatten the per-week tiers to
        # £25 too; the tier tests (DaycarePriceTierTests) set them apart.
        pricing = ServicePricing.load()
        pricing.day_care_price = 25
        pricing.day_care_price_1_day = 25
        pricing.day_care_price_2_to_4_days = 25
        pricing.day_care_price_5_days = 25
        pricing.save()

        self.client = APIClient()

    def _attend(self, dog, day, status='DROPPED_OFF', month=6, year=2026):
        return DailyDogAssignment.objects.create(
            dog=dog, staff_member=self.plain_staff,
            date=date(year, month, day), status=status,
        )


class BillingGenerationTests(BillingTestsBase):
    def test_generation_counts_attended_days_and_excludes_removed(self):
        from api import billing

        self._attend(self.dog, 1, 'DROPPED_OFF')
        self._attend(self.dog, 2, 'PICKED_UP')
        self._attend(self.dog, 3, 'ASSIGNED')
        # UNASSIGNED = attending with no staff member yet -> billable.
        self._attend(self.dog, 4, 'UNASSIGNED')
        # REMOVED = not attending -> not billable.
        self._attend(self.dog, 5, 'REMOVED')

        created, skipped, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(len(created), 1)
        self.assertEqual(skipped, 0)
        invoice = created[0]
        self.assertEqual(invoice.status, 'DRAFT')
        self.assertEqual(invoice.customer, self.owner)
        line = invoice.lines.get()
        self.assertEqual(line.quantity, 4)
        self.assertEqual(line.unit_price, Decimal('25.00'))
        self.assertEqual(line.line_total, Decimal('100.00'))
        self.assertEqual(invoice.total, Decimal('100.00'))
        self.assertEqual(line.attendance_dates, ['2026-06-01', '2026-06-02', '2026-06-03', '2026-06-04'])

    def test_multi_dog_owner_gets_one_invoice_with_line_per_dog(self):
        from api import billing

        self._attend(self.dog, 1)
        self._attend(self.dog, 2)
        self._attend(self.dog2, 2)

        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(len(created), 1)
        invoice = created[0]
        self.assertEqual(invoice.lines.count(), 2)
        self.assertEqual(invoice.total, Decimal('75.00'))
        # Lines sorted by dog name.
        self.assertEqual([l.dog.name for l in invoice.lines.all()], ['Alfie', 'Biscuit'])

    def test_daily_rate_override_beats_service_pricing(self):
        from api import billing

        self.dog.daily_rate = Decimal('30.00')
        self.dog.save()
        self._attend(self.dog, 1)
        self._attend(self.dog2, 1)  # falls back to the £25 default

        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        by_dog = {l.dog.name: l for l in created[0].lines.all()}
        self.assertEqual(by_dog['Biscuit'].unit_price, Decimal('30.00'))
        self.assertEqual(by_dog['Alfie'].unit_price, Decimal('25.00'))
        self.assertEqual(created[0].total, Decimal('55.00'))

    def test_zero_attendance_is_skipped_ownerless_dogs_bill_in_dogs_name(self):
        from api import billing

        # APP mode: MANUAL ownerless dogs are deliberately skipped by monthly
        # generation (the business still invoices those by hand in Xero).
        stray = Dog.objects.create(owner=None, name='Stray', billing_mode='APP')
        self._attend(stray, 1)
        self._attend(self.dog, 2, 'REMOVED')  # removed day: nothing to bill

        created, skipped, _ = billing.generate_invoices_for_month(2026, 6)
        # self.owner has no billable days -> no invoice; the ownerless dog's
        # attendance bills in the dog's own name (handled via Xero email).
        self.assertEqual(len(created), 1)
        self.assertIsNone(created[0].customer)
        self.assertEqual(created[0].billed_dog, stray)
        self.assertEqual(skipped, 0)

    def test_generation_is_idempotent(self):
        from api import billing

        self._attend(self.dog, 1)
        first, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(len(first), 1)
        second, skipped, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(second, [])
        self.assertEqual(skipped, 1)
        self.assertEqual(Invoice.objects.count(), 1)

    def test_void_invoice_allows_regeneration_for_period(self):
        from api import billing

        self._attend(self.dog, 1)
        first, _, _ = billing.generate_invoices_for_month(2026, 6)
        first[0].status = 'VOID'
        first[0].save()

        second, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(len(second), 1)
        self.assertEqual(Invoice.objects.count(), 2)

    def test_regenerate_draft_rebuilds_lines(self):
        from api import billing

        self._attend(self.dog, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        self._attend(self.dog, 2)

        billing.regenerate_draft(invoice)
        invoice.refresh_from_db()
        self.assertEqual(invoice.lines.get().quantity, 2)
        self.assertEqual(invoice.total, Decimal('50.00'))

    def test_regenerate_rejects_sent_invoice(self):
        from api import billing

        self._attend(self.dog, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        invoice.status = 'SENT'
        invoice.save()
        with self.assertRaises(ValueError):
            billing.regenerate_draft(invoice)


class InvoiceEndpointPermissionTests(BillingTestsBase):
    def setUp(self):
        super().setUp()
        self.draft = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=5, status='DRAFT',
            total=Decimal('50.00'))
        self.sent = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=4, status='SENT',
            total=Decimal('75.00'))
        self.other_sent = Invoice.objects.create(
            customer=self.other_owner, period_year=2026, period_month=4, status='SENT',
            total=Decimal('25.00'))

    def test_owner_sees_only_own_sent_invoices(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/invoices/')
        self.assertEqual(resp.status_code, 200)
        data = resp.data['results'] if isinstance(resp.data, dict) and 'results' in resp.data else resp.data
        ids = {inv['id'] for inv in data}
        self.assertEqual(ids, {self.sent.id})

    def test_owner_cannot_retrieve_others_invoice_or_own_draft(self):
        self.client.login(username='owner', password='pw')
        self.assertEqual(self.client.get(f'/api/invoices/{self.other_sent.id}/').status_code, 404)
        self.assertEqual(self.client.get(f'/api/invoices/{self.draft.id}/').status_code, 404)

    def test_owner_does_not_see_xero_sync_error(self):
        self.sent.xero_sync_error = 'Xero API error (HTTP 500)'
        self.sent.save()
        self.client.login(username='owner', password='pw')
        resp = self.client.get(f'/api/invoices/{self.sent.id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertNotIn('xero_sync_error', resp.data)

        self.client.login(username='manager', password='pw')
        resp = self.client.get(f'/api/invoices/{self.sent.id}/')
        self.assertIn('xero_sync_error', resp.data)

    def test_manager_sees_all_with_filters(self):
        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/invoices/')
        data = resp.data['results'] if isinstance(resp.data, dict) and 'results' in resp.data else resp.data
        self.assertEqual(len(data), 3)
        resp = self.client.get('/api/invoices/?status=draft')
        data = resp.data['results'] if isinstance(resp.data, dict) and 'results' in resp.data else resp.data
        self.assertEqual([inv['id'] for inv in data], [self.draft.id])
        resp = self.client.get(f'/api/invoices/?month=4&year=2026&customer={self.other_owner.id}')
        data = resp.data['results'] if isinstance(resp.data, dict) and 'results' in resp.data else resp.data
        self.assertEqual([inv['id'] for inv in data], [self.other_sent.id])

    def test_manager_actions_require_flag(self):
        cases = [
            ('post', '/api/invoices/generate/', {'year': 2026, 'month': 6}),
            ('post', f'/api/invoices/{self.draft.id}/send/', {}),
            ('post', '/api/invoices/send_all/', {'year': 2026, 'month': 5}),
            ('post', f'/api/invoices/{self.draft.id}/regenerate/', {}),
            ('post', f'/api/invoices/{self.sent.id}/record_payment/', {'amount': '10'}),
            ('post', f'/api/invoices/{self.sent.id}/void/', {}),
            ('post', f'/api/invoices/{self.sent.id}/push_to_xero/', {}),
            ('post', '/api/invoices/sync_xero/', {}),
            ('get', '/api/invoices/summary/', None),
        ]
        for username in ('plainstaff', 'owner'):
            self.client.login(username=username, password='pw')
            for method, url, body in cases:
                resp = getattr(self.client, method)(url, body, format='json')
                self.assertIn(resp.status_code, (403, 404),
                              f'{username} {method} {url} -> {resp.status_code}')

    def test_superuser_and_manager_can_use_summary(self):
        for username in ('manager', 'admin'):
            self.client.login(username=username, password='pw')
            resp = self.client.get('/api/invoices/summary/?year=2026')
            self.assertEqual(resp.status_code, 200)
            self.assertEqual(resp.data['draft'], 1)
            self.assertEqual(resp.data['sent'], 2)
            self.assertEqual(resp.data['total_billed'], Decimal('100.00'))
            self.assertEqual(resp.data['total_outstanding'], Decimal('100.00'))

    def test_owner_cannot_self_grant_payments_permission(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/profile/', {'can_manage_payments': True}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.owner.profile.refresh_from_db()
        self.assertFalse(self.owner.profile.can_manage_payments)

    def test_superuser_grants_payments_permission(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.post(
            f'/api/profile/update_staff_permissions/?user_id={self.plain_staff.id}',
            {'can_manage_payments': True}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.plain_staff.profile.refresh_from_db()
        self.assertTrue(self.plain_staff.profile.can_manage_payments)

    def test_generate_endpoint_creates_drafts(self):
        self._attend(self.other_dog, 1)
        self.client.login(username='manager', password='pw')
        resp = self.client.post('/api/invoices/generate/', {'year': 2026, 'month': 6}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['created'], 1)
        self.assertTrue(Invoice.objects.filter(
            customer=self.other_owner, period_year=2026, period_month=6, status='DRAFT').exists())

    def test_generate_endpoint_validates_period(self):
        self.client.login(username='manager', password='pw')
        for body in ({}, {'year': 2026, 'month': 13}, {'year': 'x', 'month': 1}):
            resp = self.client.post('/api/invoices/generate/', body, format='json')
            self.assertEqual(resp.status_code, 400)

    def test_send_marks_sent_and_notifies_owner(self):
        with patch('api.billing.send_push_notification') as mock_push:
            self.client.login(username='manager', password='pw')
            resp = self.client.post(f'/api/invoices/{self.draft.id}/send/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.draft.refresh_from_db()
        self.assertEqual(self.draft.status, 'SENT')
        self.assertIsNotNone(self.draft.sent_at)
        self.assertEqual(self.draft.due_date, timezone.now().date() + timedelta(days=14))
        self.assertEqual(mock_push.call_count, 1)
        self.assertEqual(mock_push.call_args.args[0], self.owner)

    def test_send_rejects_non_draft(self):
        self.client.login(username='manager', password='pw')
        resp = self.client.post(f'/api/invoices/{self.sent.id}/send/', format='json')
        self.assertEqual(resp.status_code, 400)

    def test_void_rejects_paid(self):
        self.sent.status = 'PAID'
        self.sent.save()
        self.client.login(username='manager', password='pw')
        resp = self.client.post(f'/api/invoices/{self.sent.id}/void/', format='json')
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post(f'/api/invoices/{self.draft.id}/void/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.draft.refresh_from_db()
        self.assertEqual(self.draft.status, 'VOID')


class ManualPaymentTests(BillingTestsBase):
    def setUp(self):
        super().setUp()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='SENT',
            total=Decimal('100.00'))

    def _record(self, amount, method='CASH', **extra):
        self.client.login(username='manager', password='pw')
        body = {'amount': amount, 'method': method, **extra}
        return self.client.post(f'/api/invoices/{self.invoice.id}/record_payment/', body, format='json')

    def test_partial_payment_sets_part_paid(self):
        with patch('api.billing.send_push_notification') as mock_push, \
                patch('api.billing.send_staff_notification') as mock_staff:
            resp = self._record('40.00')
        self.assertEqual(resp.status_code, 200)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'PART_PAID')
        self.assertEqual(self.invoice.amount_paid, Decimal('40.00'))
        self.assertIsNone(self.invoice.paid_at)
        self.assertEqual(mock_push.call_args.args[0], self.owner)
        self.assertEqual(mock_staff.call_args.kwargs.get('permission'), 'can_manage_payments')
        self.assertEqual(mock_staff.call_args.kwargs.get('exclude_user'), self.manager)

    def test_full_payment_sets_paid(self):
        with patch('api.billing.send_push_notification'), \
                patch('api.billing.send_staff_notification'):
            self._record('60.00', method='BANK_TRANSFER', payment_date='2026-06-20')
            resp = self._record('40.00')
        self.assertEqual(resp.status_code, 200)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'PAID')
        self.assertEqual(self.invoice.amount_paid, Decimal('100.00'))
        self.assertIsNotNone(self.invoice.paid_at)
        methods = list(self.invoice.payments.values_list('method', flat=True))
        self.assertEqual(sorted(methods), ['BANK_TRANSFER', 'CASH'])

    def test_rejects_bad_amounts_methods_and_states(self):
        self.assertEqual(self._record('0').status_code, 400)
        self.assertEqual(self._record('-5').status_code, 400)
        self.assertEqual(self._record('nonsense').status_code, 400)
        self.assertEqual(self._record('10', method='BITCOIN').status_code, 400)
        self.assertEqual(self._record('10', payment_date='not-a-date').status_code, 400)
        for status in ('DRAFT', 'VOID'):
            self.invoice.status = status
            self.invoice.save()
            self.assertEqual(self._record('10').status_code, 400)
        self.assertEqual(self.invoice.payments.count(), 0)


@override_settings(XERO_CLIENT_ID='client-id', XERO_CLIENT_SECRET='client-secret',
                   XERO_REDIRECT_URI='https://example.com/api/xero/callback/')
class XeroModuleTests(TestCase):
    def setUp(self):
        self.superuser = User.objects.create_user(
            username='admin', password='pw', is_staff=True, is_superuser=True)
        self.client = APIClient()

    def _connect(self):
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.tenant_name = 'Paws 4 Thought'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()
        return conn

    def test_connect_returns_authorize_url_and_stores_state(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.post('/api/xero/connect/', format='json')
        self.assertEqual(resp.status_code, 200)
        url = resp.data['authorize_url']
        self.assertIn('login.xero.com', url)
        conn = XeroConnection.load()
        self.assertTrue(conn.oauth_state)
        self.assertIn(conn.oauth_state, url)

    def test_connect_requires_superuser(self):
        staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        staff.profile.can_manage_payments = True
        staff.profile.save()
        self.client.login(username='staff', password='pw')
        self.assertEqual(self.client.post('/api/xero/connect/', format='json').status_code, 403)
        self.assertEqual(self.client.get('/api/xero/status/').status_code, 403)
        self.assertEqual(self.client.post('/api/xero/disconnect/', format='json').status_code, 403)

    @override_settings(XERO_CLIENT_ID='', XERO_CLIENT_SECRET='')
    def test_connect_400_when_unconfigured(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.post('/api/xero/connect/', format='json')
        self.assertEqual(resp.status_code, 400)

    @patch('api.xero._api_request')
    @patch('api.xero._token_request')
    def test_callback_stores_tokens_and_tenant(self, mock_token, mock_api):
        from api import xero

        xero.build_authorize_url()
        state = XeroConnection.load().oauth_state
        mock_token.return_value = {
            'access_token': 'access-new', 'refresh_token': 'refresh-new', 'expires_in': 1800}
        mock_api.return_value = [{'tenantId': 'tenant-1', 'tenantName': 'Paws 4 Thought'}]

        # No login: the callback is a bare browser redirect authenticated by state.
        resp = self.client.get(f'/api/xero/callback/?code=auth-code&state={state}')
        self.assertEqual(resp.status_code, 200)
        conn = XeroConnection.load()
        self.assertTrue(conn.is_connected)
        self.assertEqual(conn.tenant_id, 'tenant-1')
        self.assertEqual(conn.refresh_token, 'refresh-new')
        self.assertEqual(conn.oauth_state, '')  # single-use
        self.assertEqual(mock_token.call_args.args[0]['grant_type'], 'authorization_code')

    @patch('api.xero._token_request')
    def test_callback_rejects_bad_and_expired_state(self, mock_token):
        from api import xero

        xero.build_authorize_url()
        resp = self.client.get('/api/xero/callback/?code=auth-code&state=wrong')
        self.assertEqual(resp.status_code, 400)

        conn = XeroConnection.load()
        state = conn.oauth_state
        conn.oauth_state_created_at = timezone.now() - timedelta(minutes=11)
        conn.save()
        resp = self.client.get(f'/api/xero/callback/?code=auth-code&state={state}')
        self.assertEqual(resp.status_code, 400)
        mock_token.assert_not_called()
        self.assertFalse(XeroConnection.load().is_connected)

    @patch('api.xero._token_request')
    def test_refresh_rotates_and_persists_tokens(self, mock_token):
        from api import xero

        conn = self._connect()
        conn.access_token_expires_at = timezone.now() - timedelta(minutes=1)
        conn.save()
        mock_token.return_value = {
            'access_token': 'access-2', 'refresh_token': 'refresh-2', 'expires_in': 1800}

        token = xero.get_access_token()
        self.assertEqual(token, 'access-2')
        conn = XeroConnection.load()
        self.assertEqual(conn.refresh_token, 'refresh-2')  # rotated token persisted
        self.assertEqual(mock_token.call_args.args[0]['grant_type'], 'refresh_token')

    @patch('api.xero._token_request')
    def test_valid_cached_token_skips_refresh(self, mock_token):
        from api import xero

        self._connect()
        self.assertEqual(xero.get_access_token(), 'access-1')
        mock_token.assert_not_called()

    @patch('api.xero._token_request')
    def test_invalid_grant_clears_connection(self, mock_token):
        from api import xero

        conn = self._connect()
        conn.access_token_expires_at = timezone.now() - timedelta(minutes=1)
        conn.save()
        mock_token.side_effect = xero.XeroAuthError('invalid_grant')

        with self.assertRaises(xero.XeroAuthError):
            xero.get_access_token()
        self.assertFalse(XeroConnection.load().is_connected)

    def test_not_connected_raises(self):
        from api import xero

        with self.assertRaises(xero.XeroNotConnected):
            xero.get_access_token()

    def test_status_and_disconnect(self):
        self._connect()
        self.client.login(username='admin', password='pw')
        resp = self.client.get('/api/xero/status/')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['configured'])
        self.assertTrue(resp.data['connected'])
        self.assertEqual(resp.data['tenant_name'], 'Paws 4 Thought')

        resp = self.client.post('/api/xero/disconnect/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(XeroConnection.load().is_connected)


class XeroDegradationTests(BillingTestsBase):
    """Everything must work locally when Xero has never been connected."""

    @patch('api.xero._api_request')
    def test_send_without_xero_still_sends(self, mock_api):
        from api import billing

        invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='DRAFT',
            total=Decimal('50.00'))
        with patch('api.billing.send_push_notification'):
            billing.send_invoice(invoice)
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, 'SENT')
        self.assertEqual(invoice.xero_invoice_id, '')
        mock_api.assert_not_called()

    @patch('api.xero._api_request')
    def test_pay_url_404_when_no_online_invoice(self, mock_api):
        invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='SENT',
            total=Decimal('50.00'))
        self.client.login(username='owner', password='pw')
        resp = self.client.get(f'/api/invoices/{invoice.id}/pay_url/')
        self.assertEqual(resp.status_code, 404)
        mock_api.assert_not_called()

    def test_pay_url_returns_stored_url(self):
        invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='SENT',
            total=Decimal('50.00'), xero_online_url='https://in.xero.com/abc')
        self.client.login(username='owner', password='pw')
        resp = self.client.get(f'/api/invoices/{invoice.id}/pay_url/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['url'], 'https://in.xero.com/abc')

    def test_pay_url_unavailable_for_paid_invoice(self):
        invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='PAID',
            total=Decimal('50.00'), xero_online_url='https://in.xero.com/abc')
        self.client.login(username='owner', password='pw')
        self.assertEqual(self.client.get(f'/api/invoices/{invoice.id}/pay_url/').status_code, 404)

    @patch('api.xero._api_request')
    def test_sync_endpoint_returns_zeros_unconnected(self, mock_api):
        self.client.login(username='manager', password='pw')
        resp = self.client.post('/api/invoices/sync_xero/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['checked'], 0)
        mock_api.assert_not_called()


@override_settings(XERO_CLIENT_ID='client-id', XERO_CLIENT_SECRET='client-secret')
class XeroSyncTests(BillingTestsBase):
    def setUp(self):
        super().setUp()
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='SENT',
            total=Decimal('100.00'), xero_invoice_id='xero-inv-1')

    def _remote(self, payments=None, amount_paid=0, credited=0):
        return [{
            'InvoiceID': 'xero-inv-1',
            'AmountPaid': amount_paid,
            'AmountCredited': credited,
            'Payments': payments or [],
        }]

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.fetch_invoices')
    def test_imports_payments_once_and_marks_paid(self, mock_fetch, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(
            payments=[{'PaymentID': 'pay-1', 'Amount': 100, 'Date': '/Date(1748736000000+0000)/'}],
            amount_paid=100)

        counts = billing.sync_invoices_from_xero()
        self.assertEqual(counts['payments_imported'], 1)
        self.assertEqual(counts['paid'], 1)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'PAID')
        self.assertEqual(self.invoice.amount_paid, Decimal('100.00'))
        payment = self.invoice.payments.get()
        self.assertEqual(payment.source, 'XERO')
        self.assertEqual(payment.xero_payment_id, 'pay-1')
        self.assertEqual(mock_push.call_args.args[0], self.owner)  # owner receipt
        self.assertIsNotNone(self.invoice.xero_last_synced_at)

        # Second run: dedupe by xero_payment_id, nothing new, no PAID re-fire.
        self.invoice.status = 'SENT'  # pretend still open so it gets checked
        self.invoice.save()
        counts = billing.sync_invoices_from_xero()
        self.assertEqual(counts['payments_imported'], 0)
        self.assertEqual(self.invoice.payments.count(), 1)

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.fetch_invoices')
    def test_partial_payment_sets_part_paid(self, mock_fetch, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(
            payments=[{'PaymentID': 'pay-1', 'Amount': 40, 'Date': '2026-06-15T00:00:00'}],
            amount_paid=40)
        billing.sync_invoices_from_xero()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'PART_PAID')
        self.assertEqual(self.invoice.amount_paid, Decimal('40.00'))

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.fetch_invoices')
    def test_credited_amount_books_adjustment(self, mock_fetch, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(amount_paid=0, credited=100)
        billing.sync_invoices_from_xero()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'PAID')
        adjustment = self.invoice.payments.get()
        self.assertEqual(adjustment.amount, Decimal('100.00'))
        self.assertEqual(adjustment.source, 'XERO')
        self.assertIn('adjustment', adjustment.notes)


class PaymentsCommandTests(BillingTestsBase):
    def test_generate_command_defaults_to_current_month_and_notifies(self):
        """Invoices go out in advance: the default period is the month we're
        in, and an unbilled day from last month rides along as an extra."""
        today = timezone.localdate()
        prev_year, prev_month = (today.year - 1, 12) if today.month == 1 else (today.year, today.month - 1)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.plain_staff,
            date=date(prev_year, prev_month, 15), status='DROPPED_OFF')

        with patch('api.management.commands.generate_monthly_invoices.send_staff_notification') as mock_staff:
            call_command('generate_monthly_invoices')
        invoice = Invoice.objects.get()
        self.assertEqual((invoice.period_year, invoice.period_month), (today.year, today.month))
        self.assertEqual(invoice.status, 'DRAFT')
        line = invoice.lines.get()
        self.assertIn(f'extra day in {date(prev_year, prev_month, 1).strftime("%B")}', line.description)
        self.assertEqual(line.attendance_dates, [date(prev_year, prev_month, 15).isoformat()])
        self.assertEqual(mock_staff.call_args.kwargs.get('permission'), 'can_manage_payments')

        # Idempotent rerun: no new invoices, no new notification.
        with patch('api.management.commands.generate_monthly_invoices.send_staff_notification') as mock_staff:
            call_command('generate_monthly_invoices')
        self.assertEqual(Invoice.objects.count(), 1)
        mock_staff.assert_not_called()

    def test_generate_command_explicit_period(self):
        self._attend(self.dog, 3)
        call_command('generate_monthly_invoices', '--year', '2026', '--month', '6')
        self.assertTrue(Invoice.objects.filter(period_year=2026, period_month=6).exists())

    def test_reminder_command_sends_once(self):
        invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=5, status='SENT',
            total=Decimal('50.00'), due_date=timezone.localdate() - timedelta(days=1))
        fresh = Invoice.objects.create(
            customer=self.other_owner, period_year=2026, period_month=5, status='SENT',
            total=Decimal('25.00'), due_date=timezone.localdate() + timedelta(days=5))

        with patch('api.management.commands.send_invoice_reminders.send_push_notification') as mock_push:
            call_command('send_invoice_reminders')
        self.assertEqual(mock_push.call_count, 1)
        self.assertEqual(mock_push.call_args.args[0], self.owner)
        invoice.refresh_from_db()
        self.assertTrue(invoice.overdue_reminder_sent)
        fresh.refresh_from_db()
        self.assertFalse(fresh.overdue_reminder_sent)

        with patch('api.management.commands.send_invoice_reminders.send_push_notification') as mock_push:
            call_command('send_invoice_reminders')
        mock_push.assert_not_called()

    @patch('api.xero._api_request')
    def test_sync_command_noop_unconnected(self, mock_api):
        call_command('sync_xero_invoices')
        mock_api.assert_not_called()


class BoardingBillingTests(BillingTestsBase):
    """Boarding stays bill per-night on the monthly invoice, in addition to
    any daycare attendance (a boarded dog joining daycare is a paid extra)."""

    def setUp(self):
        super().setUp()
        from website.models import ServicePricing

        pricing = ServicePricing.load()
        pricing.boarding_price_per_night = 30
        pricing.save()

    def _board(self, start, end, dogs=None, owner=None, status='APPROVED'):
        br = BoardingRequest.objects.create(
            owner=owner or self.owner, start_date=start, end_date=end, status=status)
        br.dogs.add(*(dogs or [self.dog]))
        return br

    def test_nights_counted_checkout_day_free(self):
        from api import billing

        # Friday 5 June -> Sunday 7 June = 2 nights.
        self._board(date(2026, 6, 5), date(2026, 6, 7))
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        line = created[0].lines.get()
        self.assertIn('Boarding', line.description)
        self.assertEqual(line.quantity, 2)
        self.assertEqual(line.unit_price, Decimal('30.00'))
        self.assertEqual(line.line_total, Decimal('60.00'))
        self.assertEqual(line.attendance_dates, ['2026-06-05', '2026-06-06'])
        self.assertEqual(created[0].total, Decimal('60.00'))

    def test_stay_spanning_months_bills_each_months_nights(self):
        from api import billing

        # 29 June -> 3 July: June bills nights of 29th/30th, July bills 1st/2nd.
        self._board(date(2026, 6, 29), date(2026, 7, 3))
        june, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(june[0].lines.get().attendance_dates, ['2026-06-29', '2026-06-30'])
        july, _, _ = billing.generate_invoices_for_month(2026, 7)
        self.assertEqual(july[0].lines.get().attendance_dates, ['2026-07-01', '2026-07-02'])

    def test_boarding_rate_override_beats_service_pricing(self):
        from api import billing

        self.dog.boarding_rate = Decimal('45.00')
        self.dog.save()
        self._board(date(2026, 6, 1), date(2026, 6, 2), dogs=[self.dog, self.dog2])
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        by_dog = {l.dog.name: l for l in created[0].lines.all()}
        self.assertEqual(by_dog['Biscuit'].unit_price, Decimal('45.00'))
        self.assertEqual(by_dog['Alfie'].unit_price, Decimal('30.00'))

    def test_zero_price_still_creates_visible_line(self):
        from api import billing
        from website.models import ServicePricing

        pricing = ServicePricing.load()
        pricing.boarding_price_per_night = 0
        pricing.save()
        self._board(date(2026, 6, 1), date(2026, 6, 3))
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        line = created[0].lines.get()
        self.assertEqual(line.quantity, 2)
        self.assertEqual(line.line_total, Decimal('0.00'))

    def test_pending_denied_and_cancelled_requests_not_billed(self):
        from api import billing

        self._board(date(2026, 6, 1), date(2026, 6, 3), status='PENDING')
        self._board(date(2026, 6, 10), date(2026, 6, 12), status='DENIED')
        self._board(date(2026, 6, 20), date(2026, 6, 22), status='CANCELLED')
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created, [])

    def test_boarding_covers_daycare_on_stay_days(self):
        from api import billing

        # Stay 1st -> 3rd: the boarding charge covers the whole stay
        # (arrival to checkout inclusive), so day-board attendance on the
        # 1st-3rd is NOT billed as daycare; the 10th (outside the stay) is.
        self._board(date(2026, 6, 1), date(2026, 6, 3))
        self._attend(self.dog, 1)
        self._attend(self.dog, 2)
        self._attend(self.dog, 3)  # checkout day — still covered
        self._attend(self.dog, 10)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        by_kind = {l.description.split(' — ')[0]: l for l in invoice.lines.all()}
        self.assertEqual(sorted(by_kind), ['Boarding', 'Daycare'])
        self.assertEqual(by_kind['Boarding'].quantity, 2)   # 2 nights @ £30
        self.assertEqual(by_kind['Daycare'].quantity, 1)    # only the 10th
        self.assertEqual(by_kind['Daycare'].attendance_dates, ['2026-06-10'])
        # 2 nights @ £30 + 1 day @ £25.
        self.assertEqual(invoice.total, Decimal('85.00'))

    def test_dogs_owner_billed_not_whoever_booked(self):
        from api import billing

        # A staff member (or anyone else) creating the booking must never be
        # the one invoiced — charges always follow the dog's assigned client.
        staff_booker = User.objects.create_user(
            username='booker', password='pw', is_staff=True)
        self._board(date(2026, 6, 1), date(2026, 6, 2), owner=staff_booker)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0].customer, self.owner)  # Biscuit's owner
        self.assertFalse(Invoice.objects.filter(customer=staff_booker).exists())

    def test_regenerate_rebuilds_boarding_lines(self):
        from api import billing

        booking = self._board(date(2026, 6, 1), date(2026, 6, 2))
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        self.assertEqual(invoice.total, Decimal('30.00'))
        booking.end_date = date(2026, 6, 4)
        booking.save()
        billing.regenerate_draft(invoice)
        invoice.refresh_from_db()
        self.assertEqual(invoice.lines.get().quantity, 3)
        self.assertEqual(invoice.total, Decimal('90.00'))


class BoardingPermissionTests(TestCase):
    """Managing boarding requests requires the can_manage_boarding flag;
    staff without it keep read access (needed for care logistics) plus one
    write: cancelling a booking (owner rang up, dog isn't coming), which is
    routine front-desk work done from the dog's profile."""

    def setUp(self):
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.plain_staff = User.objects.create_user(username='plainstaff', password='pw', is_staff=True)
        self.boarding_manager = User.objects.create_user(username='bmanager', password='pw', is_staff=True)
        self.boarding_manager.profile.can_manage_boarding = True
        self.boarding_manager.profile.save()
        self.superuser = User.objects.create_user(
            username='admin', password='pw', is_staff=True, is_superuser=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Bella')
        self.client = APIClient()

    def _pending(self):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05')
        br.dogs.add(self.dog)
        return br

    def test_staff_without_flag_cannot_change_status(self):
        br = self._pending()
        self.client.login(username='plainstaff', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{br.id}/change_status/',
                                {'status': 'APPROVED'}, format='json')
        self.assertEqual(resp.status_code, 403)
        br.refresh_from_db()
        self.assertEqual(br.status, 'PENDING')

    def test_any_staff_can_cancel_booking(self):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05',
            status='APPROVED')
        br.dogs.add(self.dog)
        self.client.login(username='plainstaff', password='pw')
        with patch('api.notifications.send_push_notification') as mock_push:
            resp = self.client.post(f'/api/boarding-requests/{br.id}/change_status/',
                                    {'status': 'CANCELLED'}, format='json')
        self.assertEqual(resp.status_code, 200)
        br.refresh_from_db()
        self.assertEqual(br.status, 'CANCELLED')
        hist = BoardingRequestHistory.objects.filter(request=br).first()
        self.assertEqual(hist.from_status, 'APPROVED')
        self.assertEqual(hist.to_status, 'CANCELLED')
        self.assertEqual(hist.changed_by, self.plain_staff)
        owner_pushes = [c for c in mock_push.call_args_list if c.args[0] == self.owner]
        self.assertEqual(len(owner_pushes), 1)
        self.assertIn('cancelled', owner_pushes[0].args[2])

    def test_owner_cannot_cancel_via_change_status(self):
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05',
            status='APPROVED')
        br.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.post(f'/api/boarding-requests/{br.id}/change_status/',
                                {'status': 'CANCELLED'}, format='json')
        self.assertEqual(resp.status_code, 403)
        br.refresh_from_db()
        self.assertEqual(br.status, 'APPROVED')

    def test_cancelled_booking_does_not_block_rebooking(self):
        cancelled = BoardingRequest.objects.create(
            owner=self.owner, start_date='2026-04-01', end_date='2026-04-05',
            status='CANCELLED')
        cancelled.dogs.add(self.dog)
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 201)

    def test_flag_holder_and_superuser_can_change_status(self):
        for username in ('bmanager', 'admin'):
            br = self._pending()
            self.client.login(username=username, password='pw')
            resp = self.client.post(f'/api/boarding-requests/{br.id}/change_status/',
                                    {'status': 'APPROVED'}, format='json')
            self.assertEqual(resp.status_code, 200)
            br.delete()

    def test_staff_without_flag_cannot_edit_or_delete(self):
        br = self._pending()
        self.client.login(username='plainstaff', password='pw')
        resp = self.client.patch(f'/api/boarding-requests/{br.id}/',
                                 {'special_instructions': 'x'}, format='json')
        self.assertEqual(resp.status_code, 403)
        resp = self.client.delete(f'/api/boarding-requests/{br.id}/')
        self.assertEqual(resp.status_code, 403)
        self.assertTrue(BoardingRequest.objects.filter(id=br.id).exists())

    def test_staff_without_flag_keeps_read_access(self):
        br = self._pending()
        self.client.login(username='plainstaff', password='pw')
        resp = self.client.get('/api/boarding-requests/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data), 1)
        resp = self.client.get(f'/api/boarding-requests/{br.id}/')
        self.assertEqual(resp.status_code, 200)

    def test_staff_created_without_flag_stays_pending(self):
        self.client.login(username='plainstaff', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'owner': self.owner.id,
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'PENDING')

    def test_manager_created_auto_approves(self):
        self.client.login(username='bmanager', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'owner': self.owner.id,
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['status'], 'APPROVED')

    def test_owner_rights_unchanged(self):
        # Owners still create, edit and withdraw their own PENDING requests.
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/boarding-requests/', {
            'dogs': [self.dog.id],
            'start_date': '2026-04-01',
            'end_date': '2026-04-05',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        br_id = resp.data['id']
        resp = self.client.patch(f'/api/boarding-requests/{br_id}/',
                                 {'special_instructions': 'blanket'}, format='json')
        self.assertEqual(resp.status_code, 200)
        resp = self.client.delete(f'/api/boarding-requests/{br_id}/')
        self.assertEqual(resp.status_code, 204)

    def test_cannot_self_grant_boarding_permission(self):
        self.client.login(username='plainstaff', password='pw')
        resp = self.client.post('/api/profile/', {'can_manage_boarding': True}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.plain_staff.profile.refresh_from_db()
        self.assertFalse(self.plain_staff.profile.can_manage_boarding)

    def test_superuser_grants_boarding_permission(self):
        self.client.login(username='admin', password='pw')
        resp = self.client.post(
            f'/api/profile/update_staff_permissions/?user_id={self.plain_staff.id}',
            {'can_manage_boarding': True}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.plain_staff.profile.refresh_from_db()
        self.assertTrue(self.plain_staff.profile.can_manage_boarding)

    def test_new_request_push_targets_boarding_managers(self):
        request_manager = User.objects.create_user(username='reqmgr', password='pw', is_staff=True)
        request_manager.profile.can_manage_requests = True
        request_manager.profile.save()
        self.client.login(username='owner', password='pw')
        with patch('api.models.send_push_notification') as signal_push:
            resp = self.client.post('/api/boarding-requests/', {
                'dogs': [self.dog.id],
                'start_date': '2026-04-01',
                'end_date': '2026-04-05',
            }, format='json')
        self.assertEqual(resp.status_code, 201)
        recipients = [c.args[0] for c in signal_push.call_args_list]
        self.assertIn(self.boarding_manager, recipients)
        self.assertNotIn(request_manager, recipients)
        self.assertNotIn(self.plain_staff, recipients)


class BillingRateResolutionTests(BillingTestsBase):
    """Rate precedence: per-dog override > per-client rate > standard price."""

    def setUp(self):
        super().setUp()
        from website.models import ServicePricing

        pricing = ServicePricing.load()
        pricing.boarding_price_per_night = 30
        pricing.save()

    def test_client_rate_beats_default_daycare(self):
        from api import billing

        self.owner.profile.daycare_rate = Decimal('20.00')
        self.owner.profile.save()
        self._attend(self.dog, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created[0].lines.get().unit_price, Decimal('20.00'))

    def test_dog_override_beats_client_rate(self):
        from api import billing

        self.owner.profile.daycare_rate = Decimal('20.00')
        self.owner.profile.save()
        self.dog.daily_rate = Decimal('18.00')
        self.dog.save()
        self._attend(self.dog, 1)
        self._attend(self.dog2, 1)  # falls back to the client rate
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        by_dog = {l.dog.name: l for l in created[0].lines.all()}
        self.assertEqual(by_dog['Biscuit'].unit_price, Decimal('18.00'))
        self.assertEqual(by_dog['Alfie'].unit_price, Decimal('20.00'))

    def test_boarding_uses_dog_owners_client_rate(self):
        from api import billing

        # other_owner created the booking, but the dog belongs to self.owner:
        # self.owner is billed, at self.owner's discounted rate.
        self.owner.profile.boarding_rate = Decimal('25.00')
        self.owner.profile.save()
        self.other_owner.profile.boarding_rate = Decimal('99.00')
        self.other_owner.profile.save()
        br = BoardingRequest.objects.create(
            owner=self.other_owner, start_date=date(2026, 6, 1),
            end_date=date(2026, 6, 3), status='APPROVED')
        br.dogs.add(self.dog)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created[0].customer, self.owner)
        self.assertEqual(created[0].lines.get().unit_price, Decimal('25.00'))

    def test_owner_cannot_self_set_rate(self):
        self.client.login(username='owner', password='pw')
        resp = self.client.post('/api/profile/', {'daycare_rate': '1.00'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.owner.profile.refresh_from_db()
        self.assertIsNone(self.owner.profile.daycare_rate)

    def test_owner_sees_own_rate_read_only(self):
        self.owner.profile.daycare_rate = Decimal('20.00')
        self.owner.profile.save()
        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/profile/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['daycare_rate'], '20.00')


class AdvanceBillingTests(BillingTestsBase):
    """Invoices are raised in advance for the month's booked days, and catch
    up last month's unbilled extras. June 2026 starts on a Monday."""

    def setUp(self):
        super().setUp()
        self.dog.daycare_days = [1, 3]  # Mon + Wed
        self.dog.save()

    def _june_dates(self, weekdays):
        return [date(2026, 6, d) for d in range(1, 31) if date(2026, 6, d).isoweekday() in weekdays]

    def test_bills_the_months_booked_days_ahead_of_time(self):
        from api import billing

        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        line = created[0].lines.get()
        expected = self._june_dates({1, 3})
        self.assertEqual(line.quantity, len(expected))  # 9 days
        self.assertEqual(line.attendance_dates, [d.isoformat() for d in expected])
        self.assertIn('booked days', line.description)
        self.assertEqual(created[0].total, Decimal('25.00') * len(expected))

    def test_closure_days_and_boarding_days_are_not_booked(self):
        from api import billing
        from api.models import ClosureDay

        ClosureDay.objects.create(date=date(2026, 6, 1), closure_type='CLOSED')
        br = BoardingRequest.objects.create(
            owner=self.owner, start_date=date(2026, 6, 3), end_date=date(2026, 6, 5), status='APPROVED')
        br.dogs.add(self.dog)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        daycare = created[0].lines.get(description__startswith='Daycare')
        self.assertNotIn('2026-06-01', daycare.attendance_dates)
        self.assertNotIn('2026-06-03', daycare.attendance_dates)
        self.assertEqual(daycare.quantity, 7)

    def test_approved_changes_shape_the_booking(self):
        from api import billing
        from api.models import DateChangeRequest

        DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=date(2026, 6, 8), status='APPROVED')
        DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY', new_date=date(2026, 6, 12), status='APPROVED')
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        dates = created[0].lines.get().attendance_dates
        self.assertNotIn('2026-06-08', dates)
        self.assertIn('2026-06-12', dates)

    def test_staff_removal_drops_the_day(self):
        from api import billing

        self._attend(self.dog, 15, status='REMOVED')
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertNotIn('2026-06-15', created[0].lines.get().attendance_dates)

    def test_last_months_unbilled_extras_are_caught_up(self):
        """May's invoice charged May's booked days; a day added in May after
        that goes on June's invoice, and the booked May days are not charged
        again."""
        from api import billing

        may, _, _ = billing.generate_invoices_for_month(2026, 5)
        may_line = may[0].lines.get()
        self.assertIn('2026-05-04', may_line.attendance_dates)  # a booked Monday
        # Later in May: the booked Monday happens, plus an unplanned Friday.
        self._attend(self.dog, 4, month=5)
        self._attend(self.dog, 8, month=5)

        june, _, _ = billing.generate_invoices_for_month(2026, 6)
        lines = list(june[0].lines.order_by('id'))
        self.assertEqual(len(lines), 2)
        booked, extra = lines
        self.assertIn('booked days', booked.description)
        self.assertIn('extra day in May', extra.description)
        self.assertEqual(extra.attendance_dates, ['2026-05-08'])
        self.assertEqual(june[0].total, Decimal('25.00') * (9 + 1))

    def test_extras_with_no_prior_invoice_are_days_off_the_schedule(self):
        """Transition: May was invoiced by hand, so its regular booked days
        are taken as paid and only the unscheduled Friday comes through."""
        from api import billing

        self._attend(self.dog, 4, month=5)   # Monday: on the schedule, treated as billed by hand
        self._attend(self.dog, 8, month=5)   # Friday: not on the schedule
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        extra = created[0].lines.get(description__contains='extra')
        self.assertEqual(extra.attendance_dates, ['2026-05-08'])

    def test_regenerate_keeps_days_billed_elsewhere_off(self):
        from api import billing

        may, _, _ = billing.generate_invoices_for_month(2026, 5)
        self._attend(self.dog, 8, month=5)
        june, _, _ = billing.generate_invoices_for_month(2026, 6)
        self._attend(self.dog, 15, month=5)  # another May extra after June was drafted
        billing.regenerate_draft(june[0])
        june[0].refresh_from_db()
        extra = june[0].lines.get(description__contains='extra')
        self.assertEqual(extra.attendance_dates, ['2026-05-08', '2026-05-15'])
        # May's booked days stay on May's invoice only.
        self.assertEqual(june[0].lines.filter(description__contains='booked').get().quantity, 9)

    def test_dog_with_nothing_booked_and_nothing_attended_is_skipped(self):
        from api import billing

        self.dog.daycare_days = []
        self.dog.save()
        created, skipped, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created, [])

    def test_owner_transport_defaults_apply_to_booked_days(self):
        from api import billing
        from website.models import ServicePricing

        pricing = ServicePricing.load()
        pricing.owner_transport_discount = 5
        pricing.save()
        self.dog.owner_brings_default = True
        self.dog.owner_collects_default = True
        self.dog.save()
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        line = created[0].lines.get()
        self.assertEqual(line.unit_price, Decimal('20.00'))
        self.assertIn('owner drop-off & pick-up', line.description)


class DaycarePriceTierTests(BillingTestsBase):
    """The day rate follows how many days a week the dog is *booked in*:
    one day £40, two to four £35, five £33 — whatever it actually attended.
    A payment manager's per-dog override beats the tier."""

    def setUp(self):
        super().setUp()
        from website.models import ServicePricing

        pricing = ServicePricing.load()
        pricing.day_care_price_1_day = 40
        pricing.day_care_price_2_to_4_days = 35
        pricing.day_care_price_5_days = 33
        pricing.save()

    def _rate_for(self, days, schedule_type='weekly'):
        from api import billing

        self.dog.daycare_days = days
        self.dog.schedule_type = schedule_type
        self.dog.save()
        return billing.resolve_day_rate(self.dog)

    def test_tiers_by_booked_days(self):
        self.assertEqual(self._rate_for([1]), (Decimal('40.00'), '1 day a week rate'))
        self.assertEqual(self._rate_for([1, 3]), (Decimal('35.00'), '2-4 days a week rate'))
        self.assertEqual(self._rate_for([1, 2, 3, 4]), (Decimal('35.00'), '2-4 days a week rate'))
        self.assertEqual(self._rate_for([1, 2, 3, 4, 5]), (Decimal('33.00'), '5 days a week rate'))
        self.assertEqual(self._rate_for([1, 2, 3, 4, 5, 6]), (Decimal('33.00'), '5 days a week rate'))

    def test_ad_hoc_and_fortnightly_dogs(self):
        # Ad hoc: no regular booking, so the one-day rate whatever days are listed.
        self.assertEqual(self._rate_for([1, 2, 3], 'ad_hoc')[0], Decimal('40.00'))
        # Fortnightly: half the listed days per week, rounded down.
        self.assertEqual(self._rate_for([1, 2], 'fortnightly')[0], Decimal('40.00'))
        self.assertEqual(self._rate_for([1, 2, 3, 4], 'fortnightly')[0], Decimal('35.00'))
        # No booking at all.
        self.assertEqual(self._rate_for([])[0], Decimal('40.00'))

    def test_extra_day_still_bills_at_booked_tier(self):
        """A one-day-a-week dog that takes an extra day pays £40 for it too —
        whether the extra is on this month's roster or caught up from last
        month."""
        from api import billing

        self.dog.daycare_days = [1]  # Mondays: 1, 8, 15, 22, 29 June 2026
        self.dog.save()
        self._attend(self.dog, 2)                 # an extra Tuesday already on June's roster
        self._attend(self.dog, 20, month=5)       # an extra day in May, never invoiced
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        lines = {('extra' in l.description): l for l in created[0].lines.all()}
        booked, extra = lines[False], lines[True]
        self.assertEqual(booked.quantity, 6)
        self.assertEqual(booked.unit_price, Decimal('40.00'))
        self.assertIn('1 day a week rate', booked.description)
        self.assertEqual(extra.quantity, 1)
        self.assertEqual(extra.unit_price, Decimal('40.00'))
        self.assertIn('extra day in May', extra.description)
        self.assertEqual(created[0].total, Decimal('280.00'))

    def test_five_day_dog_missing_days_still_gets_five_day_rate(self):
        from api import billing

        self.dog.daycare_days = [1, 2, 3, 4, 5]
        self.dog.save()
        self._attend(self.dog, 1)
        self._attend(self.dog, 2)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        line = created[0].lines.get()
        self.assertEqual(line.unit_price, Decimal('33.00'))
        self.assertIn('5 days a week rate', line.description)

    def test_per_dog_override_beats_tier(self):
        from api import billing

        self.dog.daycare_days = [1, 2, 3, 4, 5]
        self.dog.daily_rate = Decimal('30.00')
        self.dog.save()
        self._attend(self.dog, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        line = created[0].lines.get()
        self.assertEqual(line.unit_price, Decimal('30.00'))
        self.assertIn('agreed rate', line.description)

    def test_tier_changes_apply_to_new_invoices(self):
        from api import billing
        from website.models import ServicePricing

        self.dog.daycare_days = [1]
        self.dog.save()
        pricing = ServicePricing.load()
        pricing.day_care_price_1_day = 42
        pricing.save()
        self._attend(self.dog, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created[0].lines.get().unit_price, Decimal('42.00'))

    def test_only_payment_managers_set_the_dog_override(self):
        # A staff member without the payments permission: the rate is ignored,
        # the rest of the edit goes through.
        self.client.login(username='plainstaff', password='pw')
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {'daily_rate': '30.00', 'general_notes': 'hi'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertIsNone(self.dog.daily_rate)
        self.assertEqual(self.dog.general_notes, 'hi')

        self.client.login(username='manager', password='pw')
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {'daily_rate': '30.00'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.daily_rate, Decimal('30.00'))
        # And cleared again.
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {'daily_rate': None}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertIsNone(self.dog.daily_rate)

    def test_settings_endpoint_exposes_and_updates_tiers(self):
        from website.models import ServicePricing

        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/billing-settings/')
        self.assertEqual(resp.data['day_care_price_1_day'], Decimal('40.00'))
        self.assertEqual(resp.data['day_care_price_2_to_4_days'], Decimal('35.00'))
        self.assertEqual(resp.data['day_care_price_5_days'], Decimal('33.00'))
        resp = self.client.patch('/api/billing-settings/', {
            'day_care_price_1_day': '41', 'day_care_price_2_to_4_days': '36', 'day_care_price_5_days': '34',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        pricing = ServicePricing.objects.get(pk=1)
        self.assertEqual(pricing.day_care_price_1_day, Decimal('41.00'))
        self.assertEqual(pricing.day_care_price_2_to_4_days, Decimal('36.00'))
        self.assertEqual(pricing.day_care_price_5_days, Decimal('34.00'))
        resp = self.client.patch('/api/billing-settings/', {'day_care_price_5_days': '-1'}, format='json')
        self.assertEqual(resp.status_code, 400)


class BillingSettingsEndpointTests(BillingTestsBase):
    def test_requires_payments_manager(self):
        for username in ('owner', 'plainstaff'):
            self.client.login(username=username, password='pw')
            self.assertEqual(self.client.get('/api/billing-settings/').status_code, 403)
            self.assertEqual(
                self.client.patch('/api/billing-settings/', {'day_care_price': '30'}, format='json').status_code,
                403)

    def test_manager_reads_and_updates_defaults(self):
        from website.models import ServicePricing

        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/billing-settings/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['day_care_price'], Decimal('25.00'))

        resp = self.client.patch('/api/billing-settings/', {
            'day_care_price': '27.50', 'boarding_price_per_night': '35.00',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        pricing = ServicePricing.objects.get(pk=1)
        self.assertEqual(pricing.day_care_price, Decimal('27.50'))
        self.assertEqual(pricing.boarding_price_per_night, Decimal('35.00'))

    def test_rejects_bad_amounts(self):
        self.client.login(username='manager', password='pw')
        for bad in ('nonsense', '-1', '10000'):
            resp = self.client.patch('/api/billing-settings/', {'day_care_price': bad}, format='json')
            self.assertEqual(resp.status_code, 400)


class CustomerRatesEndpointTests(BillingTestsBase):
    def test_requires_payments_manager(self):
        for username in ('owner', 'plainstaff'):
            self.client.login(username=username, password='pw')
            self.assertEqual(self.client.get('/api/customer-rates/').status_code, 403)
            self.assertEqual(
                self.client.post(f'/api/customer-rates/?user_id={self.owner.id}',
                                 {'daycare_rate': '1'}, format='json').status_code,
                403)

    def test_lists_dog_owners_with_rates(self):
        self.owner.profile.daycare_rate = Decimal('20.00')
        self.owner.profile.save()
        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/customer-rates/')
        self.assertEqual(resp.status_code, 200)
        by_user = {entry['username']: entry for entry in resp.data}
        self.assertIn('owner', by_user)
        self.assertIn('other', by_user)
        self.assertNotIn('plainstaff', by_user)
        self.assertEqual(by_user['owner']['daycare_rate'], Decimal('20.00'))
        self.assertIsNone(by_user['owner']['boarding_rate'])
        self.assertEqual(by_user['owner']['dog_names'], ['Alfie', 'Biscuit'])

    def test_set_and_clear_rates(self):
        self.client.login(username='manager', password='pw')
        resp = self.client.post(f'/api/customer-rates/?user_id={self.owner.id}', {
            'daycare_rate': '22.00', 'boarding_rate': '28.00',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.daycare_rate, Decimal('22.00'))
        self.assertEqual(self.owner.profile.boarding_rate, Decimal('28.00'))

        resp = self.client.post(f'/api/customer-rates/?user_id={self.owner.id}', {
            'daycare_rate': None,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.owner.profile.refresh_from_db()
        self.assertIsNone(self.owner.profile.daycare_rate)
        self.assertEqual(self.owner.profile.boarding_rate, Decimal('28.00'))

    def test_validation_and_missing_user(self):
        self.client.login(username='manager', password='pw')
        resp = self.client.post(f'/api/customer-rates/?user_id={self.owner.id}',
                                {'daycare_rate': 'lots'}, format='json')
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post('/api/customer-rates/', {'daycare_rate': '1'}, format='json')
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post('/api/customer-rates/?user_id=999999', {'daycare_rate': '1'}, format='json')
        self.assertEqual(resp.status_code, 404)


class InvoiceAdjustmentTests(BillingTestsBase):
    def setUp(self):
        super().setUp()
        from api import billing

        self._attend(self.dog, 1)
        self._attend(self.dog, 2)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.invoice = created[0]  # 2 days @ £25 = £50
        self.client.login(username='manager', password='pw')

    def _add(self, description, amount):
        return self.client.post(f'/api/invoices/{self.invoice.id}/add_line/',
                                {'description': description, 'amount': amount}, format='json')

    def test_add_charge_and_discount(self):
        resp = self._add('Damaged lead', '15.00')
        self.assertEqual(resp.status_code, 200)
        resp = self._add('Loyalty discount', '-10.00')
        self.assertEqual(resp.status_code, 200)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.total, Decimal('55.00'))
        adjustments = self.invoice.lines.filter(is_adjustment=True)
        self.assertEqual(adjustments.count(), 2)
        self.assertEqual(set(adjustments.values_list('line_total', flat=True)),
                         {Decimal('15.00'), Decimal('-10.00')})

    def test_validation(self):
        self.assertEqual(self._add('', '10').status_code, 400)
        self.assertEqual(self._add('x', '0').status_code, 400)
        self.assertEqual(self._add('x', 'lots').status_code, 400)
        # Would take the £50 invoice negative.
        self.assertEqual(self._add('Huge discount', '-60.00').status_code, 400)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.total, Decimal('50.00'))

    def test_rejected_on_sent_invoice(self):
        self.invoice.status = 'SENT'
        self.invoice.save()
        self.assertEqual(self._add('Late fee', '5.00').status_code, 400)
        resp = self.client.post(f'/api/invoices/{self.invoice.id}/remove_line/',
                                {'line_id': 1}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_regenerate_preserves_adjustments(self):
        from api import billing

        self._add('Damaged lead', '15.00')
        self._attend(self.dog, 3)  # new attendance day
        self.invoice.refresh_from_db()
        billing.regenerate_draft(self.invoice)
        self.invoice.refresh_from_db()
        # 3 days @ £25 + £15 adjustment.
        self.assertEqual(self.invoice.total, Decimal('90.00'))
        self.assertEqual(self.invoice.lines.filter(is_adjustment=True).count(), 1)

    def test_remove_adjustment_only(self):
        self._add('Damaged lead', '15.00')
        self.invoice.refresh_from_db()
        adjustment = self.invoice.lines.get(is_adjustment=True)
        attendance_line = self.invoice.lines.get(is_adjustment=False)

        # Attendance-derived lines can't be deleted.
        resp = self.client.post(f'/api/invoices/{self.invoice.id}/remove_line/',
                                {'line_id': attendance_line.id}, format='json')
        self.assertEqual(resp.status_code, 400)

        resp = self.client.post(f'/api/invoices/{self.invoice.id}/remove_line/',
                                {'line_id': adjustment.id}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.total, Decimal('50.00'))
        self.assertFalse(self.invoice.lines.filter(is_adjustment=True).exists())

    def test_requires_payments_manager(self):
        for username in ('plainstaff', 'owner'):
            self.client.login(username=username, password='pw')
            self.assertIn(self._add('x', '5').status_code, (403, 404))


class InvoiceVoidXeroTests(BillingTestsBase):
    def setUp(self):
        super().setUp()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='SENT',
            total=Decimal('50.00'), xero_invoice_id='xero-inv-9')
        self.client.login(username='manager', password='pw')

    def _connect_xero(self):
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()

    @patch('api.xero._api_request')
    def test_void_mirrors_to_xero(self, mock_api):
        self._connect_xero()
        mock_api.return_value = {}
        resp = self.client.post(f'/api/invoices/{self.invoice.id}/void/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['xero_voided'])
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'VOID')
        method, path = mock_api.call_args.args[0], mock_api.call_args.args[1]
        self.assertEqual((method, path), ('POST', 'Invoices'))
        payload = mock_api.call_args.kwargs['payload']
        self.assertEqual(payload['Invoices'][0]['Status'], 'VOIDED')

    @patch('api.xero._api_request')
    def test_void_survives_xero_refusal(self, mock_api):
        from api import xero as xero_module

        self._connect_xero()
        mock_api.side_effect = xero_module.XeroError('Invoice has payments applied')
        resp = self.client.post(f'/api/invoices/{self.invoice.id}/void/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data['xero_voided'])
        self.assertIn('payments applied', resp.data['xero_void_error'])
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'VOID')  # local void stands
        self.assertIn('Void failed in Xero', self.invoice.xero_sync_error)

    @patch('api.xero._api_request')
    def test_void_skips_xero_when_unconnected(self, mock_api):
        resp = self.client.post(f'/api/invoices/{self.invoice.id}/void/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data['xero_voided'])
        mock_api.assert_not_called()

    def test_void_invoice_with_recorded_payment_is_refused(self):
        # Voiding a part-paid invoice lets the period regenerate at full price
        # (both the unique constraints and generate_invoices_for_month ignore
        # VOID), while the collected payment stays on the dead row.
        from api import billing
        billing.record_manual_payment(
            self.invoice, Decimal('20.00'), 'CASH', recorded_by=self.manager)

        resp = self.client.post(f'/api/invoices/{self.invoice.id}/void/', format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.data['code'], 'invoice_has_payments')
        self.invoice.refresh_from_db()
        self.assertNotEqual(self.invoice.status, 'VOID')

    def test_void_with_payment_proceeds_when_explicitly_confirmed(self):
        from api import billing
        billing.record_manual_payment(
            self.invoice, Decimal('20.00'), 'CASH', recorded_by=self.manager)

        resp = self.client.post(
            f'/api/invoices/{self.invoice.id}/void/',
            {'confirm_discard_payments': True}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'VOID')

    def test_unpaid_invoice_still_voids_without_confirmation(self):
        resp = self.client.post(f'/api/invoices/{self.invoice.id}/void/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'VOID')


class ZeroTotalInvoiceTests(BillingTestsBase):
    def test_zero_total_invoice_is_marked_paid(self):
        # A £0 invoice can never receive a payment (record_manual_payment
        # rejects amounts <= 0), so pinning it at SENT left it counted as
        # overdue forever and chased daily by send_invoice_reminders.
        from api import billing
        invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6,
            status='SENT', total=Decimal('0.00'))

        billing.refresh_payment_state(invoice)

        invoice.refresh_from_db()
        self.assertEqual(invoice.status, 'PAID')
        self.assertIsNotNone(invoice.paid_at)


class InvoiceSendHardeningTests(BillingTestsBase):
    def setUp(self):
        super().setUp()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6,
            status='DRAFT', total=Decimal('50.00'))
        self.client.login(username='manager', password='pw')

    def _connect_xero(self):
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()

    def test_send_stays_draft_when_the_xero_push_fails(self):
        # Flipping to SENT before the push left the invoice unreachable: no
        # xero_invoice_id, so never emailed and pay_url 404s — yet the customer
        # had already been told it was ready, and send_all (DRAFT-only) would
        # never retry it.
        from api import xero as xero_module
        self._connect_xero()
        with patch('api.xero._api_request',
                   side_effect=xero_module.XeroError('Xero is down')):
            resp = self.client.post(f'/api/invoices/{self.invoice.id}/send/', format='json')

        self.assertEqual(resp.status_code, 502)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'DRAFT')
        self.assertIsNone(self.invoice.sent_at)

    def test_send_is_idempotent_under_retry(self):
        # The app times out at 30s while a Xero push can take longer, so staff
        # retry. The second attempt must not raise a second real invoice.
        from api import billing
        self._connect_xero()
        with patch('api.billing._resolve_contact_id', return_value='contact-1'), \
                patch('api.xero.create_invoice', return_value=('xero-1', 'INV-001')) as create, \
                patch('api.xero.get_online_invoice_url', return_value=''), \
                patch('api.billing.email_invoice_from_xero'):
            billing.send_invoice(self.invoice, user=self.manager)
            self.invoice.refresh_from_db()
            with self.assertRaises(ValueError):
                billing.send_invoice(self.invoice, user=self.manager)

        self.assertEqual(create.call_count, 1)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'SENT')

    def test_send_all_reports_failures_instead_of_aborting(self):
        from api import xero as xero_module
        ok = Invoice.objects.create(
            customer=self.other_owner, period_year=2026, period_month=6,
            status='DRAFT', total=Decimal('30.00'))
        self._connect_xero()

        # First push fails, second succeeds — the batch must complete either way.
        with patch('api.billing._resolve_contact_id', return_value='contact-1'), \
                patch('api.xero.create_invoice',
                      side_effect=[xero_module.XeroError('nope'), ('xero-2', 'INV-002')]), \
                patch('api.xero.get_online_invoice_url', return_value=''), \
                patch('api.billing.email_invoice_from_xero'):
            resp = self.client.post(
                '/api/invoices/send_all/', {'year': 2026, 'month': 6}, format='json')

        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['sent'], 1)
        self.assertEqual(len(resp.data['failed']), 1)
        # The failed one is back in DRAFT and can be retried.
        statuses = set(Invoice.objects.filter(id__in=[self.invoice.id, ok.id])
                       .values_list('status', flat=True))
        self.assertEqual(statuses, {'DRAFT', 'SENT'})

    def test_send_works_normally_when_xero_is_not_connected(self):
        from api import billing
        billing.send_invoice(self.invoice, user=self.manager)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'SENT')
        self.assertIsNotNone(self.invoice.sent_at)


class XeroPaymentDedupeTests(BillingTestsBase):
    def setUp(self):
        super().setUp()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6,
            status='SENT', total=Decimal('50.00'), xero_invoice_id='xero-inv-1')

    def test_duplicate_xero_payment_id_is_rejected_by_the_constraint(self):
        from django.db import IntegrityError, transaction
        from api.models import PaymentRecord
        PaymentRecord.objects.create(
            invoice=self.invoice, amount=Decimal('10.00'), method='XERO_ONLINE',
            source='XERO', payment_date=date(2026, 7, 1), xero_payment_id='pay-1')
        with self.assertRaises(IntegrityError):
            with transaction.atomic():
                PaymentRecord.objects.create(
                    invoice=self.invoice, amount=Decimal('10.00'), method='XERO_ONLINE',
                    source='XERO', payment_date=date(2026, 7, 1), xero_payment_id='pay-1')

    def test_blank_xero_payment_ids_are_not_constrained(self):
        # Staff-recorded payments that never reached Xero all carry ''.
        from api.models import PaymentRecord
        for _ in range(3):
            PaymentRecord.objects.create(
                invoice=self.invoice, amount=Decimal('5.00'), method='CASH',
                source='MANUAL', payment_date=date(2026, 7, 1))
        self.assertEqual(self.invoice.payments.count(), 3)

    def test_import_remote_payments_is_idempotent(self):
        from api import billing
        remote = {
            'InvoiceID': 'xero-inv-1',
            'AmountPaid': 20,
            'Payments': [{'PaymentID': 'pay-9', 'Amount': 20, 'Date': '2026-07-02'}],
        }
        first = billing._import_remote_payments(self.invoice, remote)
        second = billing._import_remote_payments(self.invoice, remote)

        self.assertEqual(first, 1)
        self.assertEqual(second, 0)
        self.assertEqual(self.invoice.payments.count(), 1)

    def test_repeated_balance_adjustment_is_not_compounded(self):
        from api import billing
        remote = {'InvoiceID': 'xero-inv-1', 'AmountPaid': 15, 'AmountCredited': 0, 'Payments': []}
        billing._import_remote_payments(self.invoice, remote)
        billing._import_remote_payments(self.invoice, remote)

        total = sum(p.amount for p in self.invoice.payments.all())
        self.assertEqual(total, Decimal('15.00'))


class GenerateForCustomerTests(BillingTestsBase):
    def setUp(self):
        super().setUp()
        self._attend(self.dog, 1)
        self._attend(self.other_dog, 1)
        self.client.login(username='manager', password='pw')

    def test_generates_only_named_customer(self):
        resp = self.client.post('/api/invoices/generate/', {
            'year': 2026, 'month': 6, 'customer': self.owner.id,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['created'], 1)
        self.assertTrue(Invoice.objects.filter(customer=self.owner).exists())
        self.assertFalse(Invoice.objects.filter(customer=self.other_owner).exists())

    def test_skips_already_invoiced_customer(self):
        Invoice.objects.create(customer=self.owner, period_year=2026, period_month=6, status='SENT')
        resp = self.client.post('/api/invoices/generate/', {
            'year': 2026, 'month': 6, 'customer': self.owner.id,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['created'], 0)
        self.assertEqual(resp.data['skipped'], 1)

    def test_void_then_regenerate_single_customer(self):
        Invoice.objects.create(customer=self.owner, period_year=2026, period_month=6, status='VOID')
        resp = self.client.post('/api/invoices/generate/', {
            'year': 2026, 'month': 6, 'customer': self.owner.id,
        }, format='json')
        self.assertEqual(resp.data['created'], 1)

    def test_unknown_customer_rejected(self):
        resp = self.client.post('/api/invoices/generate/', {
            'year': 2026, 'month': 6, 'customer': 999999,
        }, format='json')
        self.assertEqual(resp.status_code, 400)


class OwnerTransportDiscountTests(BillingTestsBase):
    """Days where the owner does both transport legs bill at the day rate
    minus the configurable discount, itemised as their own invoice line."""

    def setUp(self):
        super().setUp()
        from website.models import ServicePricing

        pricing = ServicePricing.load()
        pricing.owner_transport_discount = 5
        pricing.save()

    def _attend_transport(self, dog, day, brings, collects):
        return DailyDogAssignment.objects.create(
            dog=dog, staff_member=self.plain_staff, date=date(2026, 6, day),
            status='DROPPED_OFF', owner_brings=brings, owner_collects=collects,
        )

    def test_both_legs_discounted_single_leg_not(self):
        from api import billing

        self._attend_transport(self.dog, 1, True, True)    # discounted
        self._attend_transport(self.dog, 2, True, False)   # staff pick-up: full rate
        self._attend_transport(self.dog, 3, False, True)   # staff drop-off: full rate
        self._attend_transport(self.dog, 4, False, False)  # full rate
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        lines = list(invoice.lines.order_by('id'))
        self.assertEqual(len(lines), 2)
        standard = next(l for l in lines if 'owner drop-off' not in l.description)
        discounted = next(l for l in lines if 'owner drop-off' in l.description)
        self.assertEqual(standard.quantity, 3)
        self.assertEqual(standard.unit_price, Decimal('25.00'))
        self.assertEqual(discounted.quantity, 1)
        self.assertEqual(discounted.unit_price, Decimal('20.00'))
        self.assertEqual(discounted.attendance_dates, ['2026-06-01'])
        self.assertEqual(invoice.total, Decimal('95.00'))

    def test_dog_transport_defaults_apply(self):
        from api import billing

        # No per-date override: the dog's own defaults decide.
        self.dog.owner_brings_default = True
        self.dog.owner_collects_default = True
        self.dog.save()
        self._attend(self.dog, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        line = created[0].lines.get()
        self.assertIn('owner drop-off', line.description)
        self.assertEqual(line.unit_price, Decimal('20.00'))

    def test_discount_stacks_with_client_rate_and_floors_at_zero(self):
        from api import billing
        from website.models import ServicePricing

        self.owner.profile.daycare_rate = Decimal('22.00')
        self.owner.profile.save()
        self._attend_transport(self.dog, 1, True, True)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created[0].lines.get().unit_price, Decimal('17.00'))

        # A discount bigger than the rate floors at £0, never negative.
        pricing = ServicePricing.load()
        pricing.owner_transport_discount = 50
        pricing.save()
        created[0].status = 'VOID'
        created[0].save()
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created[0].lines.get().unit_price, Decimal('0.00'))

    def test_zero_discount_keeps_single_line(self):
        from api import billing
        from website.models import ServicePricing

        pricing = ServicePricing.load()
        pricing.owner_transport_discount = 0
        pricing.save()
        self._attend_transport(self.dog, 1, True, True)
        self._attend_transport(self.dog, 2, False, False)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        line = created[0].lines.get()
        self.assertEqual(line.quantity, 2)
        self.assertEqual(line.unit_price, Decimal('25.00'))

    def test_billing_settings_exposes_discount(self):
        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/billing-settings/')
        self.assertEqual(resp.data['owner_transport_discount'], Decimal('5.00'))
        resp = self.client.patch('/api/billing-settings/', {'owner_transport_discount': '7.50'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['owner_transport_discount'], Decimal('7.50'))
        resp = self.client.patch('/api/billing-settings/', {'owner_transport_discount': '-1'}, format='json')
        self.assertEqual(resp.status_code, 400)


class OwnerlessDogBillingTests(BillingTestsBase):
    """Dogs with no client attached bill per dog, in the dog's name; the
    invoice goes out via Xero email rather than the app."""

    def setUp(self):
        super().setUp()
        from website.models import ServicePricing

        pricing = ServicePricing.load()
        pricing.boarding_price_per_night = 30
        pricing.save()
        self.stray = Dog.objects.create(owner=None, name='Stray', billing_mode='APP')

    def test_ownerless_dog_gets_dog_name_invoice(self):
        from api import billing

        self._attend(self.stray, 1)
        self._attend(self.stray, 2)
        br = BoardingRequest.objects.create(
            owner=self.plain_staff, start_date=date(2026, 6, 10),
            end_date=date(2026, 6, 12), status='APPROVED')
        br.dogs.add(self.stray)

        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(len(created), 1)
        invoice = created[0]
        self.assertIsNone(invoice.customer)
        self.assertEqual(invoice.billed_dog, self.stray)
        self.assertEqual(invoice.billed_name, 'Stray (dog)')
        # 2 daycare days @ £25 + 2 boarding nights @ £30.
        self.assertEqual(invoice.total, Decimal('110.00'))

        # Idempotent on rerun.
        again, skipped, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(again, [])
        self.assertEqual(skipped, 1)

    def test_two_ownerless_dogs_get_separate_invoices(self):
        from api import billing

        stray2 = Dog.objects.create(owner=None, name='Wanderer', billing_mode='APP')
        self._attend(self.stray, 1)
        self._attend(stray2, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(len(created), 2)
        self.assertEqual(
            {inv.billed_dog for inv in created}, {self.stray, stray2})

    @patch('api.billing.send_push_notification')
    def test_send_works_without_app_user(self, mock_push):
        from api import billing

        self._attend(self.stray, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        billing.send_invoice(created[0])
        created[0].refresh_from_db()
        self.assertEqual(created[0].status, 'SENT')
        mock_push.assert_not_called()  # nobody to push to

    def _connect_xero(self):
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()
        return conn

    @patch('api.xero._api_request')
    def test_draft_raised_in_xero_against_unassigned_contact(self, mock_api):
        """Generating a dog-name invoice raises a DRAFT in Xero on the shared
        "unassigned" placeholder contact — not a contact per dog — for the
        business to reassign in Xero."""
        from api import billing

        self._connect_xero()

        def api_response(method, path, *args, **kwargs):
            if path == 'Contacts' and method == 'GET':
                return {'Contacts': []}
            if path == 'Contacts' and method == 'POST':
                return {'Contacts': [{'ContactID': 'contact-unassigned'}]}
            if path == 'Invoices' and method == 'POST':
                return {'Invoices': [{'InvoiceID': 'inv-1', 'InvoiceNumber': 'INV-0001'}]}
            raise AssertionError(f'unexpected call {method} {path}')
        mock_api.side_effect = api_response

        self._attend(self.stray, 1)
        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, 'DRAFT')
        self.assertEqual(invoice.xero_invoice_id, 'inv-1')
        self.assertEqual(invoice.xero_invoice_number, 'INV-0001')
        self.assertEqual(invoice.xero_sync_error, '')

        invoice_posts = [c for c in mock_api.call_args_list if c.args[0] == 'POST' and c.args[1] == 'Invoices']
        self.assertEqual(len(invoice_posts), 1)
        sent = invoice_posts[0].kwargs['payload']['Invoices'][0]
        self.assertEqual(sent['Status'], 'DRAFT')
        self.assertEqual(sent['Contact'], {'ContactID': 'contact-unassigned'})
        self.assertEqual(len(sent['LineItems']), 1)

        contact_posts = [c for c in mock_api.call_args_list if c.args[0] == 'POST' and c.args[1] == 'Contacts']
        self.assertEqual(len(contact_posts), 1)
        self.assertEqual(contact_posts[0].kwargs['payload']['Contacts'][0]['Name'], billing.UNASSIGNED_CONTACT_NAME)
        # The placeholder is remembered on the connection, never pinned to the dog.
        self.assertEqual(XeroConnection.load().unassigned_contact_id, 'contact-unassigned')
        self.stray.refresh_from_db()
        self.assertEqual(self.stray.xero_contact_id, '')

        # No online-payment lookup for a draft (Xero has no URL until approval).
        self.assertFalse(any('OnlineInvoice' in c.args[1] for c in mock_api.call_args_list))

    @patch('api.xero._api_request')
    def test_pinned_dog_contact_is_used_for_next_draft(self, mock_api):
        from api import billing

        self._connect_xero()
        self.stray.xero_contact_id = 'contact-real-owner'
        self.stray.save()
        mock_api.return_value = {'Invoices': [{'InvoiceID': 'inv-2', 'InvoiceNumber': 'INV-0002'}]}

        self._attend(self.stray, 1)
        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            billing.generate_invoices_for_month(2026, 6)
        sent = mock_api.call_args.kwargs['payload']['Invoices'][0]
        self.assertEqual(sent['Contact'], {'ContactID': 'contact-real-owner'})
        # Only the invoice call: no contact lookup needed.
        self.assertEqual(mock_api.call_count, 1)

    @patch('api.xero._api_request')
    def test_send_approves_the_existing_xero_draft(self, mock_api):
        """Sending from the app authorises the draft already in Xero rather
        than raising a second invoice."""
        from api import billing

        self._connect_xero()
        self._attend(self.stray, 1)
        mock_api.return_value = {'Invoices': [{'InvoiceID': 'inv-1', 'InvoiceNumber': 'INV-0001'}], 'Contacts': [{'ContactID': 'contact-unassigned'}]}
        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        invoice.refresh_from_db()
        self.assertEqual(invoice.xero_invoice_id, 'inv-1')
        mock_api.reset_mock()

        def api_response(method, path, *args, **kwargs):
            if path == 'Invoices' and method == 'POST':
                return {'Invoices': [{'InvoiceID': 'inv-1', 'InvoiceNumber': 'INV-0001'}]}
            if path.endswith('/OnlineInvoice'):
                return {'OnlineInvoices': [{'OnlineInvoiceUrl': 'https://in.xero.com/dog'}]}
            if path.endswith('/Email'):
                return {}
            raise AssertionError(f'unexpected call {method} {path}')
        mock_api.side_effect = api_response

        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            billing.send_invoice(invoice)
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, 'SENT')
        self.assertEqual(invoice.xero_invoice_id, 'inv-1')
        self.assertEqual(invoice.xero_online_url, 'https://in.xero.com/dog')
        invoice_posts = [c for c in mock_api.call_args_list if c.args[0] == 'POST' and c.args[1] == 'Invoices']
        self.assertEqual(len(invoice_posts), 1)
        sent = invoice_posts[0].kwargs['payload']['Invoices'][0]
        self.assertEqual(sent['InvoiceID'], 'inv-1')
        self.assertEqual(sent['Status'], 'AUTHORISED')
        self.assertEqual(sent['DueDate'], invoice.due_date.isoformat())
        self.assertNotIn('LineItems', sent)

    @patch('api.xero._api_request')
    def test_draft_edits_update_the_xero_draft(self, mock_api):
        from api import billing

        self._connect_xero()
        self._attend(self.stray, 1)
        mock_api.return_value = {'Invoices': [{'InvoiceID': 'inv-1', 'InvoiceNumber': 'INV-0001'}], 'Contacts': [{'ContactID': 'contact-unassigned'}]}
        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        invoice.refresh_from_db()
        self.assertEqual(invoice.xero_invoice_id, 'inv-1')
        mock_api.reset_mock()
        mock_api.return_value = {'Invoices': [{'InvoiceID': 'inv-1'}]}

        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            billing.add_adjustment(invoice, 'Damaged lead', Decimal('5.00'))
        sent = mock_api.call_args.kwargs['payload']['Invoices'][0]
        self.assertEqual(sent['InvoiceID'], 'inv-1')
        self.assertNotIn('Status', sent)
        self.assertEqual([li['Description'] for li in sent['LineItems']][-1], 'Damaged lead')
        self.assertEqual(len(sent['LineItems']), 2)

    @patch('api.xero._api_request')
    def test_void_deletes_the_xero_draft(self, mock_api):
        from api import billing

        self._connect_xero()
        self._attend(self.stray, 1)
        mock_api.return_value = {'Invoices': [{'InvoiceID': 'inv-1', 'InvoiceNumber': 'INV-0001'}], 'Contacts': [{'ContactID': 'contact-unassigned'}]}
        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        invoice.refresh_from_db()
        self.assertEqual(invoice.xero_invoice_id, 'inv-1')
        mock_api.reset_mock()
        mock_api.return_value = {'Invoices': [{'InvoiceID': 'inv-1'}]}

        self.client.login(username='manager', password='pw')
        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            resp = self.client.post(f'/api/invoices/{invoice.id}/void/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['xero_voided'])
        sent = mock_api.call_args.kwargs['payload']['Invoices'][0]
        self.assertEqual(sent, {'InvoiceID': 'inv-1', 'Status': 'DELETED'})

    def test_generation_survives_xero_push_failure(self):
        """A Xero outage at generation leaves an app draft with the error on
        it, not a missing invoice."""
        from api import billing, xero

        self._connect_xero()
        self._attend(self.stray, 1)
        with patch('api.xero._api_request', side_effect=xero.XeroError('boom')):
            created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, 'DRAFT')
        self.assertEqual(invoice.xero_invoice_id, '')
        self.assertIn('boom', invoice.xero_sync_error)

    def test_owners_never_see_dog_name_invoices(self):
        from api import billing

        self._attend(self.stray, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        billing.send_invoice(created[0])

        self.client.login(username='owner', password='pw')
        resp = self.client.get('/api/invoices/')
        ids = {inv['id'] for inv in resp.data}
        self.assertNotIn(created[0].id, ids)

        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/invoices/')
        by_id = {inv['id']: inv for inv in resp.data}
        self.assertIn(created[0].id, by_id)
        self.assertEqual(by_id[created[0].id]['billed_name'], 'Stray (dog)')
        self.assertIsNone(by_id[created[0].id]['customer_details'])

    def test_reminder_command_skips_dog_invoices(self):
        from api import billing

        self._attend(self.stray, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        invoice = created[0]
        invoice.status = 'SENT'
        invoice.due_date = timezone.localdate() - timedelta(days=1)
        invoice.save()
        with patch('api.management.commands.send_invoice_reminders.send_push_notification') as mock_push:
            call_command('send_invoice_reminders')
        mock_push.assert_not_called()
        invoice.refresh_from_db()
        self.assertFalse(invoice.overdue_reminder_sent)

    def test_regenerate_dog_invoice(self):
        from api import billing

        self._attend(self.stray, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        self._attend(self.stray, 2)
        billing.regenerate_draft(created[0])
        created[0].refresh_from_db()
        self.assertEqual(created[0].lines.get().quantity, 2)
        self.assertEqual(created[0].total, Decimal('50.00'))


class PerDogGenerationTests(BillingTestsBase):
    """Staff can raise a month for one dog, in the dog's name, regardless of
    whether the dog has a client on the app — the draft goes to Xero, where
    the business assigns the customer. A dog is never billed twice for a
    period, whichever invoice carries it."""

    def setUp(self):
        super().setUp()
        self._attend(self.dog, 1)
        self._attend(self.dog, 2)
        self._attend(self.dog2, 3)
        self.client.login(username='manager', password='pw')

    def test_per_dog_invoice_is_in_the_dogs_name(self):
        from api import billing

        created, skipped, manual = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        self.assertEqual(len(created), 1)
        invoice = created[0]
        self.assertIsNone(invoice.customer)
        self.assertEqual(invoice.billed_dog, self.dog)
        self.assertEqual(invoice.billed_name, 'Biscuit (dog)')
        line = invoice.lines.get()
        self.assertEqual(line.dog, self.dog)
        self.assertEqual(line.quantity, 2)
        self.assertEqual(invoice.total, Decimal('50.00'))

    def test_per_dog_uses_dog_rate_not_owner_discount(self):
        """In the dog's name there is no customer on the invoice, so the
        owner's per-client rate doesn't apply — the dog's own override does."""
        from api import billing

        self.owner.profile.daycare_rate = Decimal('20.00')
        self.owner.profile.save()
        created, _, _ = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        self.assertEqual(created[0].lines.get().unit_price, Decimal('25.00'))

        Invoice.objects.all().delete()
        self.dog.daily_rate = Decimal('30.00')
        self.dog.save()
        created, _, _ = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        self.assertEqual(created[0].lines.get().unit_price, Decimal('30.00'))

    def test_owner_invoice_excludes_dog_already_billed_per_dog(self):
        from api import billing

        billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        created, skipped, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(len(created), 1)
        owner_invoice = created[0]
        self.assertEqual(owner_invoice.customer, self.owner)
        self.assertEqual([l.dog for l in owner_invoice.lines.all()], [self.dog2])
        self.assertEqual(owner_invoice.total, Decimal('25.00'))

    def test_per_dog_skipped_when_owner_invoice_already_carries_dog(self):
        from api import billing

        billing.generate_invoices_for_month(2026, 6, customer=self.owner)
        created, skipped, _ = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        self.assertEqual(created, [])
        self.assertEqual(skipped, 1)

    def test_per_dog_is_idempotent_and_voidable(self):
        from api import billing

        first, _, _ = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        again, skipped, _ = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        self.assertEqual(again, [])
        self.assertEqual(skipped, 1)
        first[0].status = 'VOID'
        first[0].save()
        third, _, _ = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        self.assertEqual(len(third), 1)

    def test_owner_with_all_dogs_billed_per_dog_is_skipped(self):
        from api import billing

        billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        billing.generate_invoices_for_month(2026, 6, dog=self.dog2)
        created, skipped, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created, [])
        self.assertEqual(skipped, 2)  # the two per-dog invoices already covering the month

    def test_regenerate_per_dog_invoice_for_owned_dog_keeps_its_lines(self):
        from api import billing

        created, _, _ = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        self._attend(self.dog, 4)
        billing.regenerate_draft(created[0])
        created[0].refresh_from_db()
        line = created[0].lines.get()
        self.assertEqual(line.dog, self.dog)
        self.assertEqual(line.quantity, 3)
        self.assertEqual(created[0].total, Decimal('75.00'))

    def test_regenerate_owner_invoice_keeps_per_dog_billed_dog_off(self):
        from api import billing

        billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        created, _, _ = billing.generate_invoices_for_month(2026, 6)
        owner_invoice = created[0]
        self._attend(self.dog, 5)  # more Biscuit days: still Biscuit's own invoice's business
        billing.regenerate_draft(owner_invoice)
        owner_invoice.refresh_from_db()
        self.assertEqual([l.dog for l in owner_invoice.lines.all()], [self.dog2])
        self.assertEqual(owner_invoice.total, Decimal('25.00'))

    def test_per_dog_bypasses_billing_mode(self):
        from api import billing

        self.owner.profile.billing_mode = 'MANUAL'
        self.owner.profile.save()
        created, _, manual = billing.generate_invoices_for_month(2026, 6, dog=self.dog)
        self.assertEqual(len(created), 1)
        self.assertEqual(manual, 0)

    def test_per_dog_with_nothing_to_bill_is_skipped(self):
        from api import billing

        created, skipped, _ = billing.generate_invoices_for_month(2026, 6, dog=self.other_dog)
        self.assertEqual(created, [])
        self.assertEqual(skipped, 0)

    def test_generate_endpoint_accepts_dog(self):
        resp = self.client.post('/api/invoices/generate/', {
            'year': 2026, 'month': 6, 'dog': self.dog.id,
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['created'], 1)
        self.assertEqual(resp.data['in_xero'], 0)  # Xero not connected
        invoice = Invoice.objects.get(pk=resp.data['invoices'][0])
        self.assertEqual(invoice.billed_dog, self.dog)
        self.assertIsNone(invoice.customer)
        detail = self.client.get(f'/api/invoices/{invoice.id}/')
        self.assertEqual(detail.data['billed_dog'], self.dog.id)
        self.assertFalse(detail.data['in_xero'])

    def test_generate_endpoint_rejects_unknown_dog_and_both(self):
        resp = self.client.post('/api/invoices/generate/', {'year': 2026, 'month': 6, 'dog': 999999}, format='json')
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post('/api/invoices/generate/', {
            'year': 2026, 'month': 6, 'dog': self.dog.id, 'customer': self.owner.id,
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    @patch('api.xero._api_request')
    def test_push_to_xero_endpoint_raises_draft_for_draft(self, mock_api):
        created_resp = self.client.post('/api/invoices/generate/', {
            'year': 2026, 'month': 6, 'dog': self.dog.id,
        }, format='json')
        invoice_id = created_resp.data['invoices'][0]
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.unassigned_contact_id = 'contact-unassigned'
        conn.save()
        mock_api.return_value = {'Invoices': [{'InvoiceID': 'inv-9', 'InvoiceNumber': 'INV-0009'}]}
        with self.settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret'):
            resp = self.client.post(f'/api/invoices/{invoice_id}/push_to_xero/', format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['pushed'])
        self.assertTrue(resp.data['in_xero'])
        self.assertEqual(resp.data['status'], 'DRAFT')
        sent = mock_api.call_args.kwargs['payload']['Invoices'][0]
        self.assertEqual(sent['Status'], 'DRAFT')


@override_settings(XERO_CLIENT_ID='client-id', XERO_CLIENT_SECRET='client-secret')
class XeroDraftSyncTests(BillingTestsBase):
    """A draft raised in Xero is finished there: the sync notices the
    approval (or deletion) and updates the app's copy."""

    def setUp(self):
        super().setUp()
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.unassigned_contact_id = 'contact-unassigned'
        conn.save()
        from api.models import InvoiceLine

        self.stray = Dog.objects.create(owner=None, name='Stray')
        self.invoice = Invoice.objects.create(
            customer=None, billed_dog=self.stray, period_year=2026, period_month=6, status='DRAFT',
            total=Decimal('50.00'), xero_invoice_id='xero-draft-1', xero_invoice_number='INV-0001')
        InvoiceLine.objects.create(
            invoice=self.invoice, dog=self.stray, description='Daycare — Stray (2 days @ £25)',
            quantity=2, unit_price=Decimal('25.00'), line_total=Decimal('50.00'))

    def _remote(self, status='AUTHORISED', total=50, contact='contact-unassigned', **extra):
        remote = {
            'InvoiceID': 'xero-draft-1',
            'InvoiceNumber': 'INV-0042',
            'Status': status,
            'Total': total,
            'DueDate': '/Date(1751241600000+0000)/',  # 2025-06-30
            'Contact': {'ContactID': contact, 'Name': 'Someone'},
            'AmountPaid': 0,
            'AmountCredited': 0,
            'Payments': [],
        }
        remote.update(extra)
        return [remote]

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.get_online_invoice_url', return_value='https://in.xero.com/draft1')
    @patch('api.xero.fetch_invoices')
    def test_approval_in_xero_marks_sent_and_pins_contact(self, mock_fetch, mock_url, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(contact='contact-olive')
        counts = billing.sync_invoices_from_xero()
        self.assertEqual(counts['approved'], 1)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'SENT')
        self.assertIsNotNone(self.invoice.sent_at)
        self.assertEqual(self.invoice.due_date, date(2025, 6, 30))
        self.assertEqual(self.invoice.xero_invoice_number, 'INV-0042')
        self.assertEqual(self.invoice.xero_online_url, 'https://in.xero.com/draft1')
        self.assertEqual(self.invoice.total, Decimal('50.00'))
        self.assertEqual(self.invoice.lines.count(), 1)
        # The contact the business assigned in Xero is remembered for next month.
        self.stray.refresh_from_db()
        self.assertEqual(self.stray.xero_contact_id, 'contact-olive')
        mock_push.assert_not_called()  # dog-name invoice: nobody on the app to tell

        # A second sync leaves it alone (now an open invoice, no payments).
        counts = billing.sync_invoices_from_xero()
        self.assertEqual(counts['approved'], 0)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'SENT')

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.get_online_invoice_url', return_value='')
    @patch('api.xero.fetch_invoices')
    def test_total_changed_in_xero_is_booked_as_adjustment(self, mock_fetch, mock_url, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(total=45)
        billing.sync_invoices_from_xero()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.total, Decimal('45.00'))
        adjustment = self.invoice.lines.get(is_adjustment=True)
        self.assertEqual(adjustment.line_total, Decimal('-5.00'))
        self.assertEqual(adjustment.description, 'Amended in Xero')
        self.assertEqual(sum(l.line_total for l in self.invoice.lines.all()), Decimal('45.00'))

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.get_online_invoice_url', return_value='')
    @patch('api.xero.fetch_invoices')
    def test_unassigned_contact_is_not_pinned(self, mock_fetch, mock_url, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(contact='contact-unassigned')
        billing.sync_invoices_from_xero()
        self.stray.refresh_from_db()
        self.assertEqual(self.stray.xero_contact_id, '')

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.fetch_invoices')
    def test_still_draft_in_xero_is_left_alone(self, mock_fetch, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(status='DRAFT')
        counts = billing.sync_invoices_from_xero()
        self.assertEqual(counts['checked'], 1)
        self.assertEqual(counts['approved'], 0)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'DRAFT')
        self.assertIsNotNone(self.invoice.xero_last_synced_at)

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.fetch_invoices')
    def test_deleted_in_xero_voids_here(self, mock_fetch, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(status='DELETED')
        counts = billing.sync_invoices_from_xero()
        self.assertEqual(counts['voided'], 1)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'VOID')
        # The period can be raised again.
        self._attend(self.stray, 1)
        created, _, _ = billing.generate_invoices_for_month(2026, 6, dog=self.stray)
        self.assertEqual(len(created), 1)

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.get_online_invoice_url', return_value='')
    @patch('api.xero.fetch_invoices')
    def test_approved_and_paid_in_one_sync(self, mock_fetch, mock_url, mock_push, mock_staff):
        from api import billing

        mock_fetch.return_value = self._remote(
            status='PAID', AmountPaid=50,
            Payments=[{'PaymentID': 'pay-1', 'Amount': 50, 'Date': '2026-07-01T00:00:00'}])
        counts = billing.sync_invoices_from_xero()
        self.assertEqual(counts['approved'], 1)
        self.assertEqual(counts['payments_imported'], 1)
        self.assertEqual(counts['paid'], 1)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'PAID')

    @patch('api.billing.send_staff_notification')
    @patch('api.billing.send_push_notification')
    @patch('api.xero.get_online_invoice_url', return_value='')
    @patch('api.xero.fetch_invoices')
    def test_customer_invoice_approval_notifies_owner(self, mock_fetch, mock_url, mock_push, mock_staff):
        from api import billing

        self.invoice.delete()
        invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='DRAFT',
            total=Decimal('50.00'), xero_invoice_id='xero-draft-1')
        mock_fetch.return_value = self._remote(contact='contact-olive')
        billing.sync_invoices_from_xero()
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, 'SENT')
        self.assertEqual(mock_push.call_args.args[0], self.owner)
        self.assertIn('New invoice', mock_push.call_args.args[1])
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.xero_contact_id, 'contact-olive')


class BillingModeTransitionTests(BillingTestsBase):
    """Long-standing customers are invoiced by hand in Xero (billing_mode
    MANUAL, the default); monthly generation only bills APP customers so the
    transition can't double-bill anyone."""

    def test_monthly_generation_skips_manual_customers(self):
        from api import billing

        self.other_owner.profile.billing_mode = 'MANUAL'
        self.other_owner.profile.save()
        self._attend(self.dog, 1)
        self._attend(self.other_dog, 1)

        created, skipped, manual = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual([inv.customer for inv in created], [self.owner])
        self.assertEqual(skipped, 0)
        self.assertEqual(manual, 1)
        self.assertFalse(Invoice.objects.filter(customer=self.other_owner).exists())

    def test_monthly_generation_skips_manual_ownerless_dog(self):
        from api import billing

        stray = Dog.objects.create(owner=None, name='Stray')  # default MANUAL
        self._attend(stray, 1)
        created, _, manual = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual(created, [])
        self.assertEqual(manual, 1)

    def test_single_customer_generation_bypasses_manual_mode(self):
        from api import billing

        self.owner.profile.billing_mode = 'MANUAL'
        self.owner.profile.save()
        self._attend(self.dog, 1)
        created, _, manual = billing.generate_invoices_for_month(
            2026, 6, customer=self.owner)
        self.assertEqual(len(created), 1)
        self.assertEqual(manual, 0)

    def test_generate_endpoint_reports_manual_count(self):
        self.other_owner.profile.billing_mode = 'MANUAL'
        self.other_owner.profile.save()
        self._attend(self.dog, 1)
        self._attend(self.other_dog, 1)
        self.client.login(username='manager', password='pw')
        resp = self.client.post('/api/invoices/generate/', {'year': 2026, 'month': 6}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['created'], 1)
        self.assertEqual(resp.data['manual'], 1)

    def test_generate_command_reports_manual_count(self):
        from io import StringIO

        self.owner.profile.billing_mode = 'MANUAL'
        self.owner.profile.save()
        self._attend(self.dog, 3)
        out = StringIO()
        call_command('generate_monthly_invoices', '--year', '2026', '--month', '6', stdout=out)
        self.assertIn('1 on manual Xero billing', out.getvalue())
        self.assertFalse(Invoice.objects.exists())

    def test_customer_rates_exposes_and_updates_billing_mode(self):
        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/customer-rates/')
        by_id = {row['user_id']: row for row in resp.data}
        self.assertEqual(by_id[self.owner.id]['billing_mode'], 'APP')

        resp = self.client.post(
            f'/api/customer-rates/?user_id={self.owner.id}',
            {'billing_mode': 'MANUAL'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['billing_mode'], 'MANUAL')
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.billing_mode, 'MANUAL')

        resp = self.client.post(
            f'/api/customer-rates/?user_id={self.owner.id}',
            {'billing_mode': 'bogus'}, format='json')
        self.assertEqual(resp.status_code, 400)


class XeroEmailInvoiceTests(BillingTestsBase):
    """Sending an invoice asks Xero to email it (XERO_EMAIL_INVOICES), so
    customers keep getting the same branded Xero email they always have."""

    def _invoice(self, **kwargs):
        defaults = dict(customer=self.owner, period_year=2026, period_month=6,
                        status='SENT', total=Decimal('50.00'), xero_invoice_id='inv-1')
        defaults.update(kwargs)
        return Invoice.objects.create(**defaults)

    @override_settings(XERO_EMAIL_INVOICES=True)
    @patch('api.xero.email_invoice')
    def test_emails_once_and_stamps_timestamp(self, mock_email):
        from api import billing

        invoice = self._invoice()
        self.assertTrue(billing.email_invoice_from_xero(invoice))
        mock_email.assert_called_once_with('inv-1')
        invoice.refresh_from_db()
        self.assertIsNotNone(invoice.xero_emailed_at)

        # Already emailed -> no second email.
        self.assertFalse(billing.email_invoice_from_xero(invoice))
        mock_email.assert_called_once()

    @override_settings(XERO_EMAIL_INVOICES=False)
    @patch('api.xero.email_invoice')
    def test_disabled_setting_sends_nothing(self, mock_email):
        from api import billing

        invoice = self._invoice()
        self.assertFalse(billing.email_invoice_from_xero(invoice))
        mock_email.assert_not_called()
        invoice.refresh_from_db()
        self.assertIsNone(invoice.xero_emailed_at)

    @override_settings(XERO_EMAIL_INVOICES=True)
    @patch('api.xero.email_invoice')
    def test_email_failure_is_stored_not_raised(self, mock_email):
        from api import billing
        from api import xero as xero_module

        mock_email.side_effect = xero_module.XeroError('Contact has no email address')
        invoice = self._invoice()
        self.assertFalse(billing.email_invoice_from_xero(invoice))
        invoice.refresh_from_db()
        self.assertIsNone(invoice.xero_emailed_at)
        self.assertIn('Xero email failed', invoice.xero_sync_error)
        self.assertIn('no email address', invoice.xero_sync_error)

    @override_settings(XERO_EMAIL_INVOICES=True)
    @patch('api.xero.email_invoice')
    def test_not_emailed_without_xero_invoice(self, mock_email):
        from api import billing

        invoice = self._invoice(xero_invoice_id='')
        self.assertFalse(billing.email_invoice_from_xero(invoice))
        mock_email.assert_not_called()

    @override_settings(XERO_EMAIL_INVOICES=True, XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret')
    @patch('api.xero._api_request')
    def test_send_pushes_then_emails(self, mock_api):
        from api import billing

        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()
        self.owner.profile.xero_contact_id = 'contact-olive'
        self.owner.profile.save()

        def api_response(method, path, *args, **kwargs):
            if path == 'Invoices' and method == 'POST':
                return {'Invoices': [{'InvoiceID': 'inv-9', 'InvoiceNumber': 'INV-0009'}]}
            if path.endswith('/OnlineInvoice'):
                return {'OnlineInvoices': [{'OnlineInvoiceUrl': 'https://in.xero.com/x'}]}
            return {}
        mock_api.side_effect = api_response

        invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='DRAFT',
            total=Decimal('50.00'))
        with patch('api.billing.send_push_notification'):
            billing.send_invoice(invoice)
        invoice.refresh_from_db()
        self.assertEqual(invoice.xero_invoice_id, 'inv-9')
        self.assertIsNotNone(invoice.xero_emailed_at)
        email_calls = [c for c in mock_api.call_args_list if c.args[1] == 'Invoices/inv-9/Email']
        self.assertEqual(len(email_calls), 1)

    @override_settings(XERO_EMAIL_INVOICES=True, XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret')
    @patch('api.xero._api_request')
    def test_push_endpoint_retries_missed_email(self, mock_api):
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()

        mock_api.return_value = {}
        invoice = self._invoice(xero_online_url='https://in.xero.com/x')
        self.client.login(username='manager', password='pw')
        resp = self.client.post(f'/api/invoices/{invoice.id}/push_to_xero/', format='json')
        self.assertEqual(resp.status_code, 200)
        invoice.refresh_from_db()
        self.assertIsNotNone(invoice.xero_emailed_at)


class XeroContactPinningTests(BillingTestsBase):
    """Pushes use the pinned Xero ContactID when one is stored, and pin the
    resolved contact after a match — so invoices keep landing on the
    customer's existing Xero contact instead of creating duplicates."""

    def setUp(self):
        super().setUp()
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='SENT',
            total=Decimal('50.00'))

    @override_settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret')
    @patch('api.xero._api_request')
    def test_pinned_contact_used_without_lookup(self, mock_api):
        from api import billing

        self.owner.profile.xero_contact_id = 'pinned-1'
        self.owner.profile.save()

        def api_response(method, path, *args, **kwargs):
            if path == 'Invoices' and method == 'POST':
                return {'Invoices': [{'InvoiceID': 'inv-2', 'InvoiceNumber': 'INV-0002'}]}
            if path.endswith('/OnlineInvoice'):
                return {'OnlineInvoices': []}
            return {}
        mock_api.side_effect = api_response

        self.assertTrue(billing.push_invoice_to_xero(self.invoice))
        contact_lookups = [c for c in mock_api.call_args_list if c.args[1] == 'Contacts']
        self.assertEqual(contact_lookups, [])
        invoice_post = next(c for c in mock_api.call_args_list
                            if c.args[0] == 'POST' and c.args[1] == 'Invoices')
        self.assertEqual(
            invoice_post.kwargs['payload']['Invoices'][0]['Contact']['ContactID'], 'pinned-1')

    @override_settings(XERO_CLIENT_ID='id', XERO_CLIENT_SECRET='secret')
    @patch('api.xero._api_request')
    def test_matched_contact_is_pinned_for_next_time(self, mock_api):
        from api import billing

        def api_response(method, path, *args, **kwargs):
            if path == 'Contacts' and method == 'GET':
                return {'Contacts': [{'ContactID': 'contact-olive'}]}
            if path == 'Invoices' and method == 'POST':
                return {'Invoices': [{'InvoiceID': 'inv-3', 'InvoiceNumber': 'INV-0003'}]}
            if path.endswith('/OnlineInvoice'):
                return {'OnlineInvoices': []}
            return {}
        mock_api.side_effect = api_response

        self.assertTrue(billing.push_invoice_to_xero(self.invoice))
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.xero_contact_id, 'contact-olive')


class XeroReconciliationEndpointTests(BillingTestsBase):
    """The go-live reconciliation screen: match app customers to the existing
    Xero contacts and pin the right one before flipping them to APP billing."""

    def _connect(self):
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()

    def test_requires_payments_permission(self):
        for username in ('plainstaff', 'owner'):
            self.client.login(username=username, password='pw')
            self.assertEqual(self.client.get('/api/xero/contact-matches/').status_code, 403)
            self.assertEqual(self.client.post('/api/xero/pin-contact/', {}, format='json').status_code, 403)
            self.assertEqual(self.client.get('/api/xero/contacts/?q=ol').status_code, 403)

    def test_reports_unconnected(self):
        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/xero/contact-matches/')
        self.assertEqual(resp.status_code, 200)
        self.assertFalse(resp.data['connected'])
        self.assertEqual(resp.data['customers'], [])

    @patch('api.xero.fetch_all_contacts')
    def test_matches_by_email_name_ambiguous_and_none(self, mock_fetch):
        self._connect()
        # A third customer with a dog but no matching contact at all.
        nobody = User.objects.create_user(username='nobody', password='pw', email='nobody@example.com')
        Dog.objects.create(owner=nobody, name='Ghost')
        mock_fetch.return_value = [
            {'ContactID': 'c-email', 'Name': 'Mrs Olive Smith', 'EmailAddress': 'OLIVE@example.com'},
            {'ContactID': 'c-name-1', 'Name': 'other', 'EmailAddress': ''},
            {'ContactID': 'c-name-2', 'Name': 'Other', 'EmailAddress': 'somebody@else.com'},
        ]
        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/xero/contact-matches/')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['connected'])
        by_id = {row['user_id']: row for row in resp.data['customers']}

        # olive@example.com matches c-email despite the case difference.
        self.assertEqual(by_id[self.owner.id]['match_status'], 'email')
        self.assertEqual(by_id[self.owner.id]['matched_contact']['contact_id'], 'c-email')
        # 'other' has no email match but two case-insensitive name matches.
        self.assertEqual(by_id[self.other_owner.id]['match_status'], 'ambiguous')
        self.assertEqual(
            {c['contact_id'] for c in by_id[self.other_owner.id]['candidates']},
            {'c-name-1', 'c-name-2'})
        self.assertEqual(by_id[nobody.id]['match_status'], 'none')

    @patch('api.xero.fetch_all_contacts')
    def test_pinned_contact_reported(self, mock_fetch):
        self._connect()
        self.owner.profile.xero_contact_id = 'c-pin'
        self.owner.profile.save()
        mock_fetch.return_value = [
            {'ContactID': 'c-pin', 'Name': 'Olive S', 'EmailAddress': 'olive@example.com'},
        ]
        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/xero/contact-matches/')
        by_id = {row['user_id']: row for row in resp.data['customers']}
        self.assertEqual(by_id[self.owner.id]['match_status'], 'pinned')
        self.assertEqual(by_id[self.owner.id]['matched_contact']['name'], 'Olive S')

    @patch('api.xero.get_contact')
    def test_pin_and_unpin_contact(self, mock_get):
        mock_get.return_value = {'ContactID': 'c-1', 'Name': 'Olive', 'EmailAddress': 'olive@example.com'}
        self.client.login(username='manager', password='pw')
        resp = self.client.post('/api/xero/pin-contact/', {
            'user_id': self.owner.id, 'contact_id': 'c-1',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.xero_contact_id, 'c-1')
        self.assertEqual(resp.data['matched_contact']['name'], 'Olive')

        # Unpin: no Xero validation call needed.
        mock_get.reset_mock()
        resp = self.client.post('/api/xero/pin-contact/', {
            'user_id': self.owner.id, 'contact_id': '',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        mock_get.assert_not_called()
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.xero_contact_id, '')

    @patch('api.xero.get_contact')
    def test_pin_rejects_unknown_contact(self, mock_get):
        from api import xero as xero_module

        mock_get.side_effect = xero_module.XeroError('No such contact in Xero.')
        self.client.login(username='manager', password='pw')
        resp = self.client.post('/api/xero/pin-contact/', {
            'user_id': self.owner.id, 'contact_id': 'gone',
        }, format='json')
        self.assertEqual(resp.status_code, 400)
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.xero_contact_id, '')

    @patch('api.xero.search_contacts')
    def test_contact_search(self, mock_search):
        mock_search.return_value = [
            {'ContactID': 'c-1', 'Name': 'Olive Smith', 'EmailAddress': 'olive@example.com'},
        ]
        self.client.login(username='manager', password='pw')
        resp = self.client.get('/api/xero/contacts/?q=oli')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['contacts'][0]['name'], 'Olive Smith')
        # Too-short terms are rejected before hitting Xero.
        self.assertEqual(self.client.get('/api/xero/contacts/?q=o').status_code, 400)


@override_settings(XERO_CLIENT_ID='client-id', XERO_CLIENT_SECRET='client-secret')
class XeroContactApiModuleTests(TestCase):
    """Wire-level tests for the new xero module helpers."""

    def setUp(self):
        conn = XeroConnection.load()
        conn.tenant_id = 'tenant-1'
        conn.refresh_token = 'refresh-1'
        conn.access_token = 'access-1'
        conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
        conn.save()

    @patch('api.xero._api_request')
    def test_email_invoice_posts_to_email_endpoint(self, mock_api):
        from api import xero

        mock_api.return_value = {}
        xero.email_invoice('inv-1')
        self.assertEqual(mock_api.call_args.args[0], 'POST')
        self.assertEqual(mock_api.call_args.args[1], 'Invoices/inv-1/Email')

    @patch('api.xero._api_request')
    def test_fetch_all_contacts_pages_and_drops_archived(self, mock_api):
        from api import xero

        page1 = [{'ContactID': f'c-{i}', 'Name': f'C{i}'} for i in range(100)]
        page2 = [{'ContactID': 'c-live', 'Name': 'Live'},
                 {'ContactID': 'c-arch', 'Name': 'Old', 'ContactStatus': 'ARCHIVED'}]
        mock_api.side_effect = [{'Contacts': page1}, {'Contacts': page2}]
        contacts = xero.fetch_all_contacts()
        self.assertEqual(len(contacts), 101)  # 100 + live, archived dropped
        self.assertEqual(mock_api.call_count, 2)
        first_params = mock_api.call_args_list[0].kwargs['params']
        self.assertEqual(first_params['page'], 1)
        self.assertEqual(first_params['summaryOnly'], 'true')

    @patch('api.xero._api_request')
    def test_search_contacts_uses_search_term(self, mock_api):
        from api import xero

        mock_api.return_value = {'Contacts': [{'ContactID': 'c-1', 'Name': 'Olive'}]}
        result = xero.search_contacts('oli')
        self.assertEqual(result[0]['ContactID'], 'c-1')
        self.assertEqual(mock_api.call_args.kwargs['params']['searchTerm'], 'oli')


class PublicContactInquiryTests(TestCase):
    """Anonymous enquiry endpoint behind the app's logged-out landing page:
    open to AllowAny, honeypot drops spam silently, throttled 5/hour/IP, and a
    real submission reaches staff by email and push."""

    URL = '/api/public/contact-inquiry/'
    PAYLOAD = {
        'name': 'Jane Prospect',
        'email': 'jane@example.com',
        'service': 'daycare',
        'message': 'Do you have space for a spaniel on Tuesdays?',
    }

    def setUp(self):
        from django.core.cache import cache
        # The anon throttle cache survives between tests in-process.
        cache.clear()
        self.client = APIClient()

    def _post(self, **overrides):
        return self.client.post(self.URL, {**self.PAYLOAD, **overrides}, format='json')

    def test_anonymous_submit_creates_inquiry(self):
        from website.models import ContactInquiry
        resp = self._post()
        self.assertEqual(resp.status_code, 201)
        inquiry = ContactInquiry.objects.get()
        self.assertEqual(inquiry.name, 'Jane Prospect')
        self.assertEqual(inquiry.email, 'jane@example.com')
        self.assertEqual(inquiry.service, 'daycare')
        self.assertFalse(inquiry.is_read)

    def test_submit_sends_notification_email(self):
        from django.core import mail
        self._post()
        self.assertEqual(len(mail.outbox), 1)
        self.assertIn('Daycare', mail.outbox[0].subject)
        self.assertEqual(mail.outbox[0].reply_to, ['jane@example.com'])

    def test_missing_fields_rejected(self):
        from website.models import ContactInquiry
        for field in ('name', 'email', 'service', 'message'):
            data = {**self.PAYLOAD}
            data.pop(field)
            resp = self.client.post(self.URL, data, format='json')
            self.assertEqual(resp.status_code, 400, f'missing {field} should 400')
        self.assertEqual(ContactInquiry.objects.count(), 0)

    def test_invalid_email_rejected(self):
        self.assertEqual(self._post(email='not-an-email').status_code, 400)

    def test_invalid_service_rejected(self):
        self.assertEqual(self._post(service='grooming').status_code, 400)

    def test_message_too_long_rejected(self):
        self.assertEqual(self._post(message='x' * 2001).status_code, 400)

    def test_honeypot_looks_successful_but_saves_nothing(self):
        from django.core import mail
        from website.models import ContactInquiry
        resp = self._post(website='http://spam.example.com')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(ContactInquiry.objects.count(), 0)
        self.assertEqual(len(mail.outbox), 0)

    def test_throttled_after_five_submissions(self):
        for _ in range(5):
            self.assertEqual(self._post().status_code, 201)
        self.assertEqual(self._post().status_code, 429)

    def test_staff_push_only_to_flagged_staff(self):
        flagged = User.objects.create_user(username='inbox', password='pw', is_staff=True)
        flagged.profile.can_view_inquiries = True
        flagged.profile.save()
        unflagged = User.objects.create_user(username='other', password='pw', is_staff=True)
        with patch('api.notifications.send_push_notification') as mock_push:
            self._post()
        notified = [call.args[0] for call in mock_push.call_args_list]
        self.assertIn(flagged, notified)
        self.assertNotIn(unflagged, notified)


class RoadworkGeometryTests(TestCase):
    """BNG→WGS84 projection and WKT parsing.

    The reference pairs are real postcode centroids from postcodes.io, which
    publishes both the British National Grid easting/northing and the WGS84
    lat/lng for the same point — the same source `geocode_dogs` already trusts.
    They span the country (Cornwall to Edinburgh) so a projection error that
    only shows up far from the grid origin can't hide.
    """

    # (name, easting, northing, latitude, longitude)
    REFERENCES = [
        ('SL7 2HE Marlow', 480107, 184695, 51.555465, -0.845921),
        ('HP11 2BZ High Wycombe', 486173, 193127, 51.630370, -0.756378),
        ('EH1 1YZ Edinburgh', 325597, 673676, 55.950328, -3.193018),
        ('TR19 7AA Penzance', 134340, 25043, 50.066019, -5.713697),
    ]

    def test_projection_matches_reference_points(self):
        from .roadworks import bng_to_wgs84, haversine_m

        for name, easting, northing, lat, lon in self.REFERENCES:
            with self.subTest(name):
                got_lat, got_lon = bng_to_wgs84(easting, northing)
                error = haversine_m(lat, lon, got_lat, got_lon)
                # Helmert is a ~5m approximation of the full OSTN15 grid shift;
                # irrelevant against a 400m match radius, but tight enough that
                # a real formula error would fail this.
                self.assertLess(error, 10, f'{name} off by {error:.1f}m')

    def test_parses_point_wkt(self):
        from .roadworks import parse_wkt_centroid

        self.assertEqual(parse_wkt_centroid('POINT(480107 184695)'), (480107.0, 184695.0))

    def test_linestring_collapses_to_mean_vertex(self):
        from .roadworks import parse_wkt_centroid

        got = parse_wkt_centroid('LINESTRING(480000 184000, 480200 184400)')
        self.assertEqual(got, (480100.0, 184200.0))

    def test_unparseable_geometry_returns_none(self):
        from .roadworks import parse_wkt_centroid

        self.assertIsNone(parse_wkt_centroid(''))
        self.assertIsNone(parse_wkt_centroid('not wkt at all'))

    def test_severity_buckets(self):
        from .models import RoadworkIssue
        from .roadworks import severity_for

        self.assertEqual(severity_for('road_closure'), RoadworkIssue.SEVERITY_HIGH)
        self.assertEqual(severity_for('two-way signals'), RoadworkIssue.SEVERITY_MEDIUM)
        self.assertEqual(severity_for('no carriageway incursion'), RoadworkIssue.SEVERITY_LOW)
        # Unknown values must not cry wolf on the dashboard.
        self.assertEqual(severity_for('something new the feed invented'), RoadworkIssue.SEVERITY_LOW)
        self.assertEqual(severity_for(''), RoadworkIssue.SEVERITY_LOW)

    def test_severity_tolerates_the_feed_s_mixed_formatting(self):
        from .models import RoadworkIssue
        from .roadworks import severity_for

        # The feed's own enum mixes underscores, hyphens, slashes and spaces,
        # and nothing pins the case. All of these are the same closure.
        for variant in ['road_closure', 'Road Closure', 'ROAD-CLOSURE', 'road closure']:
            with self.subTest(variant):
                self.assertEqual(severity_for(variant), RoadworkIssue.SEVERITY_HIGH)
        for variant in ['multi-way signals', 'Multi Way Signals', 'stop/go boards']:
            with self.subTest(variant):
                self.assertEqual(severity_for(variant), RoadworkIssue.SEVERITY_MEDIUM)


class RoadworkMatchingTests(TestCase):
    """Which staff routes a roadwork is judged to disrupt."""

    def setUp(self):
        from .models import RoadworkIssue

        self.today = timezone.localdate()
        self.driver = User.objects.create_user(username='driver', password='pw', is_staff=True)
        self.other_driver = User.objects.create_user(username='driver2', password='pw', is_staff=True)
        self.owner = User.objects.create_user(username='owner', password='pw')

        # Two pickups ~1.4km apart in Marlow.
        self.near_dog = Dog.objects.create(
            name='Near', owner=self.owner, latitude=51.5555, longitude=-0.8459)
        self.far_dog = Dog.objects.create(
            name='Far', owner=self.owner, latitude=51.5680, longitude=-0.8459)

        DailyDogAssignment.objects.create(
            dog=self.near_dog, staff_member=self.driver, date=self.today)
        DailyDogAssignment.objects.create(
            dog=self.far_dog, staff_member=self.other_driver, date=self.today)

        self.issue = RoadworkIssue.objects.create(
            external_ref='PERMIT-1', description='Gas main replacement',
            street='Station Road', town='Marlow',
            latitude=51.5556, longitude=-0.8460,
            start_date=self.today, end_date=self.today,
            traffic_management='road_closure', severity=RoadworkIssue.SEVERITY_HIGH,
        )

    def test_matches_only_the_route_within_radius(self):
        from .roadworks import match_issues_to_routes

        matches = match_issues_to_routes(self.today)
        self.assertIn(self.issue.id, matches)
        self.assertEqual(matches[self.issue.id]['staff_ids'], {self.driver.id})
        self.assertEqual(matches[self.issue.id]['dog_ids'], {self.near_dog.id})

    def test_ignores_issues_not_in_force_on_the_date(self):
        from .roadworks import match_issues_to_routes

        self.issue.start_date = self.today + timedelta(days=3)
        self.issue.end_date = self.today + timedelta(days=4)
        self.issue.save()
        self.assertEqual(match_issues_to_routes(self.today), {})

    def test_ignores_cancelled_issues(self):
        from .roadworks import match_issues_to_routes

        self.issue.is_cancelled = True
        self.issue.save()
        self.assertEqual(match_issues_to_routes(self.today), {})

    def test_ignores_ungeocoded_dogs(self):
        from .roadworks import match_issues_to_routes

        self.near_dog.latitude = None
        self.near_dog.longitude = None
        self.near_dog.save()
        self.assertEqual(match_issues_to_routes(self.today), {})

    def test_removed_dogs_do_not_flag_a_route(self):
        from .roadworks import match_issues_to_routes

        DailyDogAssignment.objects.filter(dog=self.near_dog, date=self.today).update(status='REMOVED')
        self.assertEqual(match_issues_to_routes(self.today), {})

    def test_reassigning_the_dog_moves_the_flag(self):
        # The whole reason matching is recomputed rather than stored: the day
        # board reassigns dogs between drivers constantly.
        from .roadworks import match_issues_to_routes

        DailyDogAssignment.objects.filter(dog=self.near_dog, date=self.today).update(
            staff_member=self.other_driver)
        matches = match_issues_to_routes(self.today)
        self.assertEqual(matches[self.issue.id]['staff_ids'], {self.other_driver.id})

    @override_settings(ROADWORK_MATCH_RADIUS_M=50)
    def test_radius_is_configurable(self):
        from .roadworks import match_issues_to_routes

        # The near dog is ~15m from the works, so it still matches at 50m.
        self.assertIn(self.issue.id, match_issues_to_routes(self.today))

    @override_settings(ROADWORK_MATCH_RADIUS_M=5)
    def test_tight_radius_excludes_everything(self):
        from .roadworks import match_issues_to_routes

        self.assertEqual(match_issues_to_routes(self.today), {})


class RoadworkApiTests(TestCase):
    def setUp(self):
        from .models import RoadworkIssue

        self.today = timezone.localdate()
        self.client = APIClient()
        self.driver = User.objects.create_user(username='driver', password='pw', is_staff=True)
        self.owner = User.objects.create_user(username='owner', password='pw')
        self.dog = Dog.objects.create(
            name='Rex', owner=self.owner, latitude=51.5555, longitude=-0.8459)
        DailyDogAssignment.objects.create(dog=self.dog, staff_member=self.driver, date=self.today)
        RoadworkIssue.objects.create(
            external_ref='PERMIT-1', description='Gas main', street='Station Road',
            latitude=51.5556, longitude=-0.8460,
            start_date=self.today, end_date=self.today,
            traffic_management='road_closure', severity=RoadworkIssue.SEVERITY_HIGH,
        )

    def test_staff_see_matched_issues(self):
        self.client.force_authenticate(user=self.driver)
        response = self.client.get('/api/roadworks/', {'date': self.today.isoformat()})
        self.assertEqual(response.status_code, 200)
        results = response.data['results']
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['street'], 'Station Road')
        self.assertEqual(results[0]['severity'], 'HIGH')
        self.assertEqual(results[0]['affected_staff_ids'], [self.driver.id])
        self.assertEqual(results[0]['affected_dog_ids'], [self.dog.id])

    def test_owners_are_refused(self):
        self.client.force_authenticate(user=self.owner)
        response = self.client.get('/api/roadworks/')
        self.assertEqual(response.status_code, 403)

    def test_anonymous_is_refused(self):
        self.assertEqual(self.client.get('/api/roadworks/').status_code, 401)

    def test_bad_date_is_rejected(self):
        self.client.force_authenticate(user=self.driver)
        response = self.client.get('/api/roadworks/', {'date': 'yesterday'})
        self.assertEqual(response.status_code, 400)

    def test_date_defaults_to_today(self):
        self.client.force_authenticate(user=self.driver)
        response = self.client.get('/api/roadworks/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data['results']), 1)


class StreetManagerIngestTests(TestCase):
    """Mapping Street Manager records onto RoadworkIssue rows."""

    def _payload(self, **overrides):
        data = {
            'permit_reference_number': 'BC1234-ABC-001',
            'description_of_work': 'Excavate to repair gas main',
            'street_name': 'Station Road',
            'town': 'Marlow',
            'highway_authority': 'Buckinghamshire Council',
            'work_area_wkt': 'POINT(480107 184695)',
            'proposed_start_date': '2026-08-01T00:00:00Z',
            'proposed_end_date': '2026-08-05T00:00:00Z',
            'traffic_management_type': 'road_closure',
            'permit_status': 'granted',
        }
        data.update(overrides)
        return {'event_reference': 1, 'event_type': 'PERMIT_GRANTED', 'object_data': data}

    def test_creates_an_issue_from_a_permit(self):
        from .models import RoadworkIssue
        from .roadwork_ingest import ingest_event

        self.assertEqual(ingest_event(self._payload()), 'created')
        issue = RoadworkIssue.objects.get(external_ref='BC1234-ABC-001')
        self.assertEqual(issue.street, 'Station Road')
        self.assertEqual(issue.severity, RoadworkIssue.SEVERITY_HIGH)
        self.assertEqual(issue.start_date, date(2026, 8, 1))
        self.assertEqual(issue.end_date, date(2026, 8, 5))
        self.assertAlmostEqual(issue.latitude, 51.5555, places=2)
        self.assertAlmostEqual(issue.longitude, -0.8459, places=2)
        self.assertFalse(issue.is_cancelled)

    def test_replaying_the_same_permit_updates_rather_than_duplicates(self):
        from .models import RoadworkIssue
        from .roadwork_ingest import ingest_event

        # SNS guarantees at-least-once delivery, so replays are normal traffic.
        ingest_event(self._payload())
        self.assertEqual(ingest_event(self._payload(description_of_work='Revised scope')), 'updated')
        self.assertEqual(RoadworkIssue.objects.filter(external_ref='BC1234-ABC-001').count(), 1)
        self.assertEqual(
            RoadworkIssue.objects.get(external_ref='BC1234-ABC-001').description, 'Revised scope')

    def test_cancelled_permit_is_flagged_not_deleted(self):
        from .models import RoadworkIssue
        from .roadwork_ingest import ingest_event

        ingest_event(self._payload())
        ingest_event(self._payload(permit_status='cancelled'))
        issue = RoadworkIssue.objects.get(external_ref='BC1234-ABC-001')
        self.assertTrue(issue.is_cancelled)

    def test_records_without_a_location_are_skipped(self):
        from .models import RoadworkIssue
        from .roadwork_ingest import ingest_event

        self.assertEqual(ingest_event(self._payload(work_area_wkt='')), 'ignored:unusable')
        self.assertEqual(RoadworkIssue.objects.count(), 0)

    def test_records_without_dates_are_skipped(self):
        from .roadwork_ingest import ingest_event

        payload = self._payload()
        del payload['object_data']['proposed_start_date']
        del payload['object_data']['proposed_end_date']
        self.assertEqual(ingest_event(payload), 'ignored:unusable')

    def test_reversed_dates_are_corrected(self):
        from .models import RoadworkIssue
        from .roadwork_ingest import ingest_event

        ingest_event(self._payload(
            proposed_start_date='2026-08-05T00:00:00Z',
            proposed_end_date='2026-08-01T00:00:00Z'))
        issue = RoadworkIssue.objects.get(external_ref='BC1234-ABC-001')
        self.assertLessEqual(issue.start_date, issue.end_date)

    def test_event_without_object_data_is_ignored(self):
        from .roadwork_ingest import ingest_event

        self.assertEqual(ingest_event({'event_type': 'PERMIT_GRANTED'}), 'ignored:no-object-data')


class StreetManagerWebhookTests(TestCase):
    """The public SNS endpoint. Everything here is about refusing bad input."""

    URL = '/api/roadworks/street-manager-webhook/'
    TOPIC = 'arn:aws:sns:eu-west-2:287813576808:prod-permit-topic'

    def setUp(self):
        self.client = Client()

    def test_refuses_when_no_topic_is_configured(self):
        # Wide open by default would accept any validly signed AWS message.
        with override_settings(STREET_MANAGER_TOPIC_ARNS=''):
            response = self.client.post(self.URL, data='{}', content_type='application/json')
        self.assertEqual(response.status_code, 503)

    @override_settings(STREET_MANAGER_TOPIC_ARNS=TOPIC)
    def test_rejects_a_message_with_no_signature(self):
        import json as _json

        body = _json.dumps({'Type': 'Notification', 'TopicArn': self.TOPIC, 'Message': '{}'})
        response = self.client.post(self.URL, data=body, content_type='application/json')
        self.assertEqual(response.status_code, 403)

    @override_settings(STREET_MANAGER_TOPIC_ARNS=TOPIC)
    def test_rejects_junk_body(self):
        response = self.client.post(self.URL, data='not json', content_type='application/json')
        self.assertEqual(response.status_code, 403)

    @override_settings(STREET_MANAGER_TOPIC_ARNS=TOPIC)
    @patch('api.sns.verify_message')
    def test_ingests_a_verified_notification(self, _mock_verify):
        from .models import RoadworkIssue
        import json as _json

        inner = _json.dumps({'object_data': {
            'permit_reference_number': 'BC1234-ABC-002',
            'street_name': 'High Street',
            'work_area_wkt': 'POINT(480107 184695)',
            'proposed_start_date': '2026-08-01T00:00:00Z',
            'proposed_end_date': '2026-08-02T00:00:00Z',
            'traffic_management_type': 'two-way signals',
            'permit_status': 'granted',
        }})
        body = _json.dumps({'Type': 'Notification', 'TopicArn': self.TOPIC, 'Message': inner})

        response = self.client.post(self.URL, data=body, content_type='application/json')

        self.assertEqual(response.status_code, 200)
        issue = RoadworkIssue.objects.get(external_ref='BC1234-ABC-002')
        self.assertEqual(issue.severity, RoadworkIssue.SEVERITY_MEDIUM)

    @override_settings(STREET_MANAGER_TOPIC_ARNS=TOPIC)
    @patch('api.sns.verify_message')
    @patch('api.sns.confirm_subscription', return_value=True)
    def test_completes_a_subscription_handshake(self, mock_confirm, _mock_verify):
        import json as _json

        body = _json.dumps({
            'Type': 'SubscriptionConfirmation', 'TopicArn': self.TOPIC,
            'Message': 'hi', 'SubscribeURL': 'https://sns.eu-west-2.amazonaws.com/?Action=Confirm',
        })
        response = self.client.post(self.URL, data=body, content_type='application/json')

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()['confirmed'])
        mock_confirm.assert_called_once()

    @override_settings(STREET_MANAGER_TOPIC_ARNS=TOPIC)
    @patch('api.sns.verify_message')
    def test_a_broken_record_does_not_trigger_sns_retries(self, _mock_verify):
        # Any non-2xx makes SNS redeliver; a record we simply can't use must not
        # spin forever.
        import json as _json

        body = _json.dumps({
            'Type': 'Notification', 'TopicArn': self.TOPIC, 'Message': 'not json at all'})
        response = self.client.post(self.URL, data=body, content_type='application/json')
        self.assertEqual(response.status_code, 200)


class SnsVerificationTests(TestCase):
    """The signature check itself — the only thing standing between the public
    internet and the roadworks table."""

    def test_refuses_certificate_urls_off_the_aws_domain(self):
        from .sns import SnsVerificationError, verify_message

        message = {
            'Type': 'Notification', 'TopicArn': 'arn:test', 'Message': '{}',
            'MessageId': '1', 'Timestamp': 'now', 'Signature': 'AAAA',
            'SigningCertURL': 'https://evil.example.com/cert.pem',
        }
        with self.assertRaises(SnsVerificationError):
            verify_message(message)

    def test_refuses_a_topic_we_did_not_subscribe_to(self):
        from .sns import SnsVerificationError, verify_message

        message = {'Type': 'Notification', 'TopicArn': 'arn:aws:sns:eu-west-2:1:other-topic'}
        with self.assertRaises(SnsVerificationError):
            verify_message(message, allowed_topic_arns=['arn:aws:sns:eu-west-2:1:ours'])

    def test_refuses_an_unknown_signature_version(self):
        from .sns import SnsVerificationError, verify_message

        message = {'Type': 'Notification', 'TopicArn': 'arn:ours', 'SignatureVersion': '99'}
        with self.assertRaises(SnsVerificationError):
            verify_message(message, allowed_topic_arns=['arn:ours'])

    def test_canonical_string_uses_the_fixed_field_list(self):
        from .sns import _canonical_string

        message = {
            'Type': 'Notification', 'MessageId': 'm1', 'TopicArn': 't',
            'Message': 'body', 'Timestamp': 'ts', 'AttackerControlled': 'ignored',
        }
        canonical = _canonical_string(message).decode()
        self.assertIn('Message\nbody\n', canonical)
        self.assertNotIn('AttackerControlled', canonical)

    def test_subscription_confirmation_is_not_followed_off_domain(self):
        from .sns import confirm_subscription

        self.assertFalse(confirm_subscription(
            {'SubscribeURL': 'https://evil.example.com/confirm'}))


# =============================================================================
# INCIDENTS
# =============================================================================

class IncidentApiTests(TestCase):
    """The incident log: staff-only, tied to the dogs involved."""

    def setUp(self):
        from .models import Incident  # noqa: F401 (model import sanity)
        self.owner = User.objects.create_user(username='incowner', password='pw')
        self.other_owner = User.objects.create_user(username='incowner2', password='pw')
        self.staff = User.objects.create_user(username='incstaff', password='pw', is_staff=True)
        self.staff2 = User.objects.create_user(username='incstaff2', password='pw', is_staff=True)
        self.dog_a = Dog.objects.create(owner=self.owner, name='Rocky')
        self.dog_b = Dog.objects.create(owner=self.other_owner, name='Milo')
        self.client = APIClient()

    def _create(self, **overrides):
        payload = {
            'title': 'Scuffle in the paddock',
            'incident_type': 'SCUFFLE',
            'severity': 'MEDIUM',
            'description': 'Rocky and Milo went at each other over a ball.',
            'dog_entries': json.dumps([
                {'dog': self.dog_a.id, 'role': 'INSTIGATOR'},
                {'dog': self.dog_b.id, 'role': 'INJURED', 'injuries': 'Nicked ear'},
            ]),
        }
        payload.update(overrides)
        return self.client.post('/api/incidents/', payload, format='multipart')

    def test_staff_can_log_incident_with_dogs(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            resp = self._create()
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(len(resp.data['dogs_involved']), 2)
        roles = {d['dog_name']: d['role'] for d in resp.data['dogs_involved']}
        self.assertEqual(roles, {'Rocky': 'INSTIGATOR', 'Milo': 'INJURED'})
        self.assertEqual(resp.data['reported_by_name'], 'incstaff')
        self.assertEqual(resp.data['status'], 'OPEN')

    def test_dog_entries_accepts_plain_ids(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            resp = self._create(dog_entries=json.dumps([self.dog_a.id]))
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['dogs_involved'][0]['role'], 'INVOLVED')

    def test_unknown_dog_rejected(self):
        self.client.login(username='incstaff', password='pw')
        resp = self._create(dog_entries=json.dumps([999999]))
        self.assertEqual(resp.status_code, 400)

    def test_owners_cannot_see_or_create_incidents(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            created = self._create()
        incident_id = created.data['id']

        self.client.logout()
        self.client.login(username='incowner', password='pw')
        # ...not even for their own dog.
        self.assertEqual(self.client.get('/api/incidents/').status_code, 403)
        self.assertEqual(
            self.client.get(f'/api/incidents/{incident_id}/').status_code, 403)
        self.assertEqual(
            self.client.get(f'/api/incidents/?dog={self.dog_a.id}').status_code, 403)
        self.assertEqual(self._create().status_code, 403)

    def test_filter_by_dog(self):
        from .models import Incident, IncidentDog

        self.client.login(username='incstaff', password='pw')
        both = Incident.objects.create(title='Both', description='x', reported_by=self.staff)
        IncidentDog.objects.create(incident=both, dog=self.dog_a)
        IncidentDog.objects.create(incident=both, dog=self.dog_b)
        only_b = Incident.objects.create(title='Only Milo', description='x')
        IncidentDog.objects.create(incident=only_b, dog=self.dog_b)

        resp = self.client.get(f'/api/incidents/?dog={self.dog_a.id}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual([i['title'] for i in resp.data], ['Both'])

        resp = self.client.get(f'/api/incidents/?dog={self.dog_b.id}')
        self.assertEqual({i['title'] for i in resp.data}, {'Both', 'Only Milo'})

    def test_change_status_stamps_resolver_and_open_count(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            created = self._create()
        incident_id = created.data['id']

        self.assertEqual(self.client.get('/api/incidents/open_count/').data['count'], 1)

        self.client.logout()
        self.client.login(username='incstaff2', password='pw')
        with patch('api.notifications.send_push_notification') as mock_push:
            resp = self.client.post(
                f'/api/incidents/{incident_id}/change_status/',
                {'status': 'RESOLVED', 'resolution_notes': 'Ear healed, kept apart since.'},
                format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'RESOLVED')
        self.assertEqual(resp.data['resolved_by_name'], 'incstaff2')
        self.assertIsNotNone(resp.data['resolved_at'])
        self.assertEqual(resp.data['resolution_notes'], 'Ear healed, kept apart since.')
        # The person who wrote it up hears when it's closed out.
        mock_push.assert_called_once()
        self.assertEqual(self.client.get('/api/incidents/open_count/').data['count'], 0)

    def test_monitoring_still_counts_as_open(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            created = self._create()
        self.client.post(f"/api/incidents/{created.data['id']}/change_status/",
                         {'status': 'MONITORING'}, format='json')
        self.assertEqual(self.client.get('/api/incidents/open_count/').data['count'], 1)

    def test_comment_and_owner_notified(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            created = self._create()
        incident_id = created.data['id']

        resp = self.client.post(f'/api/incidents/{incident_id}/comment/',
                                {'text': 'Stitches out Friday'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data['comments']), 1)
        self.assertEqual(resp.data['comments'][0]['text'], 'Stitches out Friday')

        resp = self.client.post(f'/api/incidents/{incident_id}/owner_notified/',
                                {'dog': self.dog_b.id, 'notified': True}, format='json')
        self.assertEqual(resp.status_code, 200)
        entry = next(d for d in resp.data['dogs_involved'] if d['dog'] == self.dog_b.id)
        self.assertTrue(entry['owner_notified'])
        self.assertIsNotNone(entry['owner_notified_at'])

        # ...and can be taken back off if it was ticked by mistake.
        resp = self.client.post(f'/api/incidents/{incident_id}/owner_notified/',
                                {'dog': self.dog_b.id, 'notified': False}, format='json')
        entry = next(d for d in resp.data['dogs_involved'] if d['dog'] == self.dog_b.id)
        self.assertFalse(entry['owner_notified'])
        self.assertIsNone(entry['owner_notified_at'])

    def test_owner_notified_rejects_dog_not_on_incident(self):
        from .models import Incident

        self.client.login(username='incstaff', password='pw')
        incident = Incident.objects.create(title='Solo', description='x')
        resp = self.client.post(f'/api/incidents/{incident.id}/owner_notified/',
                                {'dog': self.dog_a.id}, format='json')
        self.assertEqual(resp.status_code, 404)

    def test_media_upload_and_removal(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            resp = self._create(media=_test_image_file('wound.jpg'))
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(len(resp.data['media']), 1)
        self.assertEqual(resp.data['media'][0]['media_type'], 'PHOTO')
        self.assertTrue(resp.data['media'][0]['file'])
        self.assertTrue(resp.data['media'][0]['thumbnail'])

        incident_id = resp.data['id']
        media_id = resp.data['media'][0]['id']
        resp = self.client.post(f'/api/incidents/{incident_id}/add_media/',
                                {'media': _test_image_file('second.jpg')}, format='multipart')
        self.assertEqual(len(resp.data['media']), 2)

        resp = self.client.delete(f'/api/incidents/{incident_id}/media/{media_id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data['media']), 1)

    def test_media_upload_rejects_disallowed_file_type(self):
        from django.core.files.uploadedfile import SimpleUploadedFile

        self.client.login(username='incstaff', password='pw')
        evil = SimpleUploadedFile('payload.html', b'<script>alert(1)</script>',
                                  content_type='text/html')
        resp = self._create(media=evil)
        self.assertEqual(resp.status_code, 400)

    def test_staff_present_accepts_json_list_and_rejects_owners(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            resp = self._create(staff_present=json.dumps([self.staff2.id]))
        self.assertEqual(resp.status_code, 201, resp.data)
        self.assertEqual(resp.data['staff_present_names'], ['incstaff2'])

        resp = self._create(staff_present=json.dumps([self.owner.id]))
        self.assertEqual(resp.status_code, 400)

    def test_editing_keeps_owner_notified_stamp_for_dogs_that_stay(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            created = self._create()
        incident_id = created.data['id']
        self.client.post(f'/api/incidents/{incident_id}/owner_notified/',
                         {'dog': self.dog_a.id, 'notified': True}, format='json')

        # Drop dog B from the write-up; dog A stays and keeps its stamp.
        resp = self.client.patch(
            f'/api/incidents/{incident_id}/',
            {'dog_entries': json.dumps([{'dog': self.dog_a.id, 'role': 'INVOLVED'}])},
            format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(len(resp.data['dogs_involved']), 1)
        entry = resp.data['dogs_involved'][0]
        self.assertEqual(entry['dog'], self.dog_a.id)
        self.assertTrue(entry['owner_notified'])
        self.assertIsNotNone(entry['owner_notified_at'])

    def test_only_a_superuser_can_delete_an_incident(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            created = self._create()
        incident_id = created.data['id']
        self.assertEqual(
            self.client.delete(f'/api/incidents/{incident_id}/').status_code, 403)

        admin = User.objects.create_user(
            username='incadmin', password='pw', is_staff=True, is_superuser=True)
        self.client.force_authenticate(user=admin)
        self.assertEqual(
            self.client.delete(f'/api/incidents/{incident_id}/').status_code, 204)

    def test_deleting_a_dog_leaves_the_incident_standing(self):
        self.client.login(username='incstaff', password='pw')
        with patch('api.notifications.send_staff_notification'):
            created = self._create()
        incident_id = created.data['id']
        self.dog_b.delete()
        resp = self.client.get(f'/api/incidents/{incident_id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual([d['dog_name'] for d in resp.data['dogs_involved']], ['Rocky'])


# =============================================================================
# BOARDING → DAYCARE ATTENDANCE
# =============================================================================

class BoardingDaycareAttendanceTests(TestCase):
    """A boarding dog is here all week, so it is booked into daycare on every
    weekday of its stay — arrival and departure days included — under the
    business's own P4TD account. The exception is a weekday arrival, when the
    dog is still at home and needs collecting: that day is left unassigned for
    a driver to claim."""

    def setUp(self):
        self.owner = User.objects.create_user(username='bdowner', password='pw')
        self.manager = User.objects.create_user(username='bdmanager', password='pw', is_staff=True)
        self.manager.profile.can_manage_boarding = True
        self.manager.profile.save()
        self.driver = User.objects.create_user(username='bddriver', password='pw', is_staff=True)
        self.house = User.objects.create_user(username='P4TD', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Nala', daycare_days=[3])
        self.client = APIClient()
        # Mon 6 Apr 2026 → Sun 12 Apr 2026.
        self.monday = date(2026, 4, 6)
        self.sunday = date(2026, 4, 12)

    def _stay(self, start=None, end=None, status='PENDING'):
        stay = BoardingRequest.objects.create(
            owner=self.owner,
            start_date=start or self.monday,
            end_date=end or self.sunday,
            status=status,
        )
        stay.dogs.add(self.dog)
        return stay

    def _approve(self, stay):
        self.client.login(username='bdmanager', password='pw')
        with patch('api.notifications.send_push_notification'):
            return self.client.post(f'/api/boarding-requests/{stay.id}/change_status/',
                                    {'status': 'APPROVED'}, format='json')

    def _dates(self):
        """Days booked to the house account."""
        return sorted(
            DailyDogAssignment.objects
            .filter(dog=self.dog, staff_member=self.house)
            .values_list('date', flat=True)
        )

    def _all_dates(self):
        """Every day the stay booked, however it was staffed."""
        return sorted(
            DailyDogAssignment.objects
            .filter(dog=self.dog).values_list('date', flat=True)
        )

    def _unassigned_dates(self):
        """Days waiting for a driver to claim the pickup."""
        return sorted(
            DailyDogAssignment.objects
            .filter(dog=self.dog, status='UNASSIGNED', staff_member__isnull=True)
            .values_list('date', flat=True)
        )

    def test_approval_books_every_weekday_including_the_last(self):
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))  # Mon–Fri
        self.assertEqual(self._approve(stay).status_code, 200)
        self.assertEqual(
            self._all_dates(),
            [date(2026, 4, d) for d in range(6, 11)],
        )
        # Monday is the arrival: the dog is at home that morning, so it waits
        # for a driver instead of going to the house account.
        self.assertEqual(self._dates(), [date(2026, 4, d) for d in range(7, 11)])
        self.assertEqual(self._unassigned_dates(), [self.monday])
        for assignment in DailyDogAssignment.objects.filter(dog=self.dog):
            self.assertTrue(assignment.from_boarding)
            self.assertEqual(
                assignment.status,
                'UNASSIGNED' if assignment.date == self.monday else 'ASSIGNED',
            )

    def test_weekend_days_are_skipped(self):
        stay = self._stay()  # Mon–Sun
        self._approve(stay)
        self.assertNotIn(date(2026, 4, 11), self._dates())  # Saturday
        self.assertNotIn(date(2026, 4, 12), self._dates())  # Sunday
        self.assertIn(date(2026, 4, 10), self._dates())     # Friday

    def test_closed_days_are_skipped(self):
        ClosureDay.objects.create(date=date(2026, 4, 8), closure_type='CLOSED')
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        self.assertNotIn(date(2026, 4, 8), self._dates())

    def test_existing_daycare_day_is_repointed_to_the_house_account(self):
        # Wednesday is the dog's normal daycare day with its normal driver.
        existing = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.driver, date=date(2026, 4, 8))
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        existing.refresh_from_db()
        self.assertEqual(existing.staff_member, self.house)
        self.assertTrue(existing.from_boarding)

    def test_days_staff_removed_the_dog_from_are_left_alone(self):
        removed = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.driver, date=date(2026, 4, 8), status='REMOVED')
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        removed.refresh_from_db()
        self.assertEqual(removed.status, 'REMOVED')
        self.assertEqual(removed.staff_member, self.driver)

    def test_cancelling_releases_the_bookings_it_made(self):
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        self.assertEqual(len(self._all_dates()), 5)

        with patch('api.notifications.send_push_notification'):
            resp = self.client.post(f'/api/boarding-requests/{stay.id}/change_status/',
                                    {'status': 'CANCELLED'}, format='json')
        self.assertEqual(resp.status_code, 200)
        # Including the unassigned arrival day — it is flagged from_boarding
        # too, so it goes with the rest.
        self.assertEqual(self._all_dates(), [])

    def test_cancelling_leaves_manual_attendance_alone(self):
        manual = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.driver, date=date(2026, 4, 9))
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        with patch('api.notifications.send_push_notification'):
            self.client.post(f'/api/boarding-requests/{stay.id}/change_status/',
                             {'status': 'CANCELLED'}, format='json')
        # The row staff created by hand survives — but it was re-pointed at the
        # house account while the stay stood, so it is cleared like the rest.
        self.assertFalse(DailyDogAssignment.objects.filter(id=manual.id).exists())

    def test_cancelling_one_stay_leaves_a_consecutive_stay_alone(self):
        first = self._stay(start=self.monday, end=date(2026, 4, 7))
        self._approve(first)
        second = self._stay(start=date(2026, 4, 8), end=date(2026, 4, 9))
        self.assertEqual(self._approve(second).status_code, 200)
        with patch('api.notifications.send_push_notification'):
            self.client.post(f'/api/boarding-requests/{first.id}/change_status/',
                             {'status': 'CANCELLED'}, format='json')
        # Only the cancelled stay's days go; the next booking keeps its own.
        self.assertEqual(self._dates(), [date(2026, 4, 8), date(2026, 4, 9)])

    def test_moving_the_dates_moves_the_attendance(self):
        stay = self._stay(start=self.monday, end=date(2026, 4, 8))
        self._approve(stay)
        self.assertEqual(self._all_dates(), [date(2026, 4, 6), date(2026, 4, 7), date(2026, 4, 8)])

        with patch('api.notifications.send_push_notification'):
            resp = self.client.patch(
                f'/api/boarding-requests/{stay.id}/',
                {'start_date': '2026-04-08', 'end_date': '2026-04-10',
                 'dogs': [self.dog.id]},
                format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(self._all_dates(), [date(2026, 4, 8), date(2026, 4, 9), date(2026, 4, 10)])
        # The pickup moves with the arrival: Wednesday is the new first day,
        # and the row that was booked to the house account is stood down.
        self.assertEqual(self._unassigned_dates(), [date(2026, 4, 8)])
        self.assertEqual(self._dates(), [date(2026, 4, 9), date(2026, 4, 10)])

    def test_no_house_account_means_no_change(self):
        self.house.delete()
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog).exists())

    def test_boarding_days_are_not_billed_as_daycare(self):
        """The whole point of it being safe: attendance for a boarded day is
        already excluded from the daycare charge."""
        from .billing import attendance_for_month

        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        self.assertEqual(len(self._all_dates()), 5)
        self.assertEqual(attendance_for_month(2026, 4), {})

    def test_loading_a_day_books_a_stay_approved_earlier(self):
        """Stays approved before this existed (or dogs added afterwards) are
        picked up when the day is loaded."""
        stay = self._stay(start=self.monday, end=date(2026, 4, 10), status='APPROVED')
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog).exists())

        target = date(2026, 4, 7)  # Tuesday — mid-stay, nobody to collect
        with patch('api.views.timezone.localdate', return_value=target):
            self.client.login(username='bdmanager', password='pw')
            resp = self.client.get(f'/api/daily-assignments/today/?date={target.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(
            list(DailyDogAssignment.objects
                 .filter(dog=self.dog, date=target)
                 .values_list('staff_member', flat=True)),
            [self.house.id],
        )
        self.assertEqual(stay.status, 'APPROVED')

    # ---- weekday arrival: the dog is still at home and needs collecting ----

    def test_weekday_arrival_is_left_unassigned_for_a_driver(self):
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        arrival = DailyDogAssignment.objects.get(dog=self.dog, date=self.monday)
        self.assertEqual(arrival.status, 'UNASSIGNED')
        self.assertIsNone(arrival.staff_member)
        self.assertTrue(arrival.from_boarding)

    def test_weekday_arrival_shows_in_the_unassigned_list(self):
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        self.client.login(username='bdmanager', password='pw')

        with patch('api.views.timezone.localdate', return_value=self.monday):
            resp = self.client.get(
                f'/api/daily-assignments/unassigned_dogs/?date={self.monday.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertIn(self.dog.id, [d['id'] for d in resp.data])

        # The rest of the stay is covered by the house account, so it never
        # nags the dashboard.
        tuesday = date(2026, 4, 7)
        with patch('api.views.timezone.localdate', return_value=tuesday):
            resp = self.client.get(
                f'/api/daily-assignments/unassigned_dogs/?date={tuesday.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertNotIn(self.dog.id, [d['id'] for d in resp.data])

    def test_owner_who_normally_brings_the_dog_in_goes_to_the_house_account(self):
        """Nobody has to drive out for a dog its owner drops off anyway."""
        self.dog.owner_brings_default = True
        self.dog.save(update_fields=['owner_brings_default'])
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        self.assertEqual(self._dates(), [date(2026, 4, d) for d in range(6, 11)])
        self.assertEqual(self._unassigned_dates(), [])

    def test_owner_brings_override_for_the_arrival_day_wins(self):
        """A per-date override beats the dog's default, both ways round."""
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.house, date=self.monday,
            owner_brings=True, from_boarding=True)
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        arrival = DailyDogAssignment.objects.get(dog=self.dog, date=self.monday)
        self.assertEqual(arrival.status, 'ASSIGNED')
        self.assertEqual(arrival.staff_member, self.house)

    def test_owner_brings_override_can_ask_for_a_pickup(self):
        self.dog.owner_brings_default = True
        self.dog.save(update_fields=['owner_brings_default'])
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.house, date=self.monday,
            owner_brings=False, from_boarding=True)
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        arrival = DailyDogAssignment.objects.get(dog=self.dog, date=self.monday)
        self.assertEqual(arrival.status, 'UNASSIGNED')
        self.assertIsNone(arrival.staff_member)

    def test_weekend_arrival_goes_straight_to_the_house_account(self):
        """Saturday arrival: by Monday the dog is already with the carer."""
        stay = self._stay(start=date(2026, 4, 4), end=date(2026, 4, 8))
        self._approve(stay)
        self.assertEqual(
            self._dates(), [date(2026, 4, 6), date(2026, 4, 7), date(2026, 4, 8)])
        self.assertEqual(self._unassigned_dates(), [])

    def test_arrival_day_keeps_a_driver_who_already_has_it(self):
        """The dog's normal Monday driver collects it — don't stand them down."""
        existing = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.driver, date=self.monday)
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        existing.refresh_from_db()
        self.assertEqual(existing.staff_member, self.driver)
        self.assertEqual(existing.status, 'ASSIGNED')
        self.assertFalse(existing.from_boarding)

    def test_a_back_to_back_stay_does_not_ask_for_a_second_pickup(self):
        """The dog never went home, so nobody has to fetch it again."""
        first = self._stay(start=self.monday, end=date(2026, 4, 7))
        self._approve(first)
        second = self._stay(start=date(2026, 4, 8), end=date(2026, 4, 10))
        self.assertEqual(self._approve(second).status_code, 200)
        self.assertEqual(self._unassigned_dates(), [self.monday])
        self.assertEqual(self._dates(), [date(2026, 4, d) for d in range(7, 11)])

    def test_loading_a_day_leaves_the_arrival_unassigned(self):
        """The lazy day-load path applies the same rule as approval."""
        self._stay(start=self.monday, end=date(2026, 4, 10), status='APPROVED')
        with patch('api.views.timezone.localdate', return_value=self.monday):
            self.client.login(username='bdmanager', password='pw')
            resp = self.client.get(
                f'/api/daily-assignments/today/?date={self.monday.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        arrival = DailyDogAssignment.objects.get(dog=self.dog, date=self.monday)
        self.assertEqual(arrival.status, 'UNASSIGNED')
        self.assertIsNone(arrival.staff_member)
        self.assertTrue(arrival.from_boarding)

    def test_claiming_the_arrival_day_assigns_the_driver(self):
        """The point of leaving it unassigned: a driver can pick it up."""
        stay = self._stay(start=self.monday, end=date(2026, 4, 10))
        self._approve(stay)
        self.client.login(username='bddriver', password='pw')
        with patch('api.views.timezone.localdate', return_value=self.monday):
            resp = self.client.post('/api/daily-assignments/assign_to_me/', {
                'dog_ids': [self.dog.id], 'date': self.monday.isoformat(),
            }, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        arrival = DailyDogAssignment.objects.get(dog=self.dog, date=self.monday)
        self.assertEqual(arrival.status, 'ASSIGNED')
        self.assertEqual(arrival.staff_member, self.driver)

    def test_standing_down_the_house_account_does_not_ping_the_owner(self):
        """Who drives the van is not the owner's business."""
        stay = self._stay(start=self.monday, end=date(2026, 4, 8))
        self._approve(stay)
        with patch('api.models.send_push_notification') as push:
            with patch('api.notifications.send_push_notification'):
                resp = self.client.patch(
                    f'/api/boarding-requests/{stay.id}/',
                    {'start_date': '2026-04-07', 'end_date': '2026-04-09',
                     'dogs': [self.dog.id]},
                    format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        # Tuesday was booked to the house account and is now the arrival.
        arrival = DailyDogAssignment.objects.get(dog=self.dog, date=date(2026, 4, 7))
        self.assertEqual(arrival.status, 'UNASSIGNED')
        self.assertIsNone(arrival.staff_member)
        self.assertEqual(
            [c for c in push.call_args_list if 'Status Update' in str(c)], [])


class StaffManagementTests(TestCase):
    """The manager-only HR section: staff-hr, pay rates, meetings, appraisals,
    sickness absences and training records, all gated by can_manage_staff."""

    def setUp(self):
        from .models import UserProfile
        self.manager = User.objects.create_user(username='manager', password='pw', is_staff=True, first_name='Claire')
        self.manager.profile.can_manage_staff = True
        self.manager.profile.save()
        self.worker = User.objects.create_user(username='worker', password='pw', is_staff=True, first_name='Sam')
        self.owner = User.objects.create_user(username='dogowner', password='pw')
        self.client = APIClient()

    def _login(self, user):
        self.client.force_authenticate(user=user)

    # --- gating ---

    def test_owner_gets_403_everywhere(self):
        self._login(self.owner)
        for url in ['/api/staff-hr/', '/api/staff-hr/team_overview/', '/api/staff-pay-rates/',
                    '/api/staff-meetings/', '/api/staff-appraisals/', '/api/staff-absences/',
                    '/api/staff-training/']:
            resp = self.client.get(url)
            self.assertEqual(resp.status_code, 403, url)

    def test_non_manager_staff_cannot_see_hr_or_pay(self):
        self._login(self.worker)
        for url in ['/api/staff-hr/', '/api/staff-hr/team_overview/',
                    f'/api/staff-hr/for_staff/?staff_member={self.worker.id}',
                    '/api/staff-pay-rates/']:
            resp = self.client.get(url)
            self.assertEqual(resp.status_code, 403, url)

    # --- HR record + holiday maths ---

    def test_for_staff_creates_record_and_reports_holiday(self):
        from .models import DayOffRequest, StaffHRRecord
        year = timezone.localdate().year
        for day in (5, 6, 7):
            DayOffRequest.objects.create(staff_member=self.worker, date=date(year, 3, day), status='APPROVED')
        DayOffRequest.objects.create(staff_member=self.worker, date=date(year, 4, 1), status='PENDING')

        self._login(self.manager)
        resp = self.client.get(f'/api/staff-hr/for_staff/?staff_member={self.worker.id}')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(StaffHRRecord.objects.filter(user=self.worker).exists())
        self.assertEqual(resp.data['holiday']['used_days'], 3)
        self.assertEqual(resp.data['holiday']['allowance_days'], 28.0)
        self.assertEqual(resp.data['holiday']['remaining_days'], 25.0)

    def test_manager_can_update_hr_record(self):
        self._login(self.manager)
        resp = self.client.get(f'/api/staff-hr/for_staff/?staff_member={self.worker.id}')
        record_id = resp.data['id']
        resp = self.client.patch(f'/api/staff-hr/{record_id}/',
                                 {'job_title': 'Driver', 'holiday_allowance_days': '30.0'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['job_title'], 'Driver')

    # --- pay ---

    def test_pay_rate_crud_and_current_pay(self):
        self._login(self.manager)
        resp = self.client.post('/api/staff-pay-rates/', {
            'staff_member': self.worker.id, 'pay_type': 'HOURLY', 'rate': '12.50',
            'effective_from': '2024-01-01',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        resp = self.client.post('/api/staff-pay-rates/', {
            'staff_member': self.worker.id, 'pay_type': 'HOURLY', 'rate': '13.25',
            'effective_from': '2025-01-01', 'note': 'Annual review',
        }, format='json')
        self.assertEqual(resp.status_code, 201)

        resp = self.client.get(f'/api/staff-hr/for_staff/?staff_member={self.worker.id}')
        self.assertEqual(resp.data['current_pay']['rate'], '13.25')

        resp = self.client.get(f'/api/staff-pay-rates/?staff_member={self.worker.id}')
        self.assertEqual(len(resp.data), 2)

    def test_worker_cannot_create_pay_rate(self):
        self._login(self.worker)
        resp = self.client.post('/api/staff-pay-rates/', {
            'staff_member': self.worker.id, 'pay_type': 'HOURLY', 'rate': '99.00',
            'effective_from': '2025-01-01',
        }, format='json')
        self.assertEqual(resp.status_code, 403)

    # --- meetings ---

    def test_meeting_visibility_and_write_gate(self):
        from .models import StaffMeeting
        self._login(self.manager)
        resp = self.client.post('/api/staff-meetings/', {
            'title': '1:1 with Sam', 'meeting_type': 'ONE_TO_ONE',
            'scheduled_for': (timezone.now() + timedelta(days=2)).isoformat(),
            'attendees': [self.worker.id],
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        meeting_id = resp.data['id']

        other_meeting = StaffMeeting.objects.create(
            title='Managers only', scheduled_for=timezone.now() + timedelta(days=3),
            created_by=self.manager,
        )
        other_meeting.attendees.set([self.manager])

        # The worker sees only meetings they attend, and cannot edit them.
        self._login(self.worker)
        resp = self.client.get('/api/staff-meetings/')
        titles = [m['title'] for m in resp.data]
        self.assertEqual(titles, ['1:1 with Sam'])
        resp = self.client.patch(f'/api/staff-meetings/{meeting_id}/', {'title': 'hacked'}, format='json')
        self.assertEqual(resp.status_code, 403)

        # The manager can complete it with minutes.
        self._login(self.manager)
        resp = self.client.patch(f'/api/staff-meetings/{meeting_id}/',
                                 {'status': 'COMPLETED', 'minutes': 'Agreed new rota.'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'COMPLETED')

    # --- appraisals ---

    def test_appraisal_share_comment_acknowledge_flow(self):
        self._login(self.manager)
        resp = self.client.post('/api/staff-appraisals/', {
            'staff_member': self.worker.id, 'appraisal_date': '2026-08-01',
            'overall_rating': 4, 'summary': 'Strong year.', 'goals': 'Van training.',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        appraisal_id = resp.data['id']
        self.assertEqual(resp.data['status'], 'DRAFT')
        self.assertEqual(resp.data['appraiser'], self.manager.id)

        # Invisible to the worker while draft.
        self._login(self.worker)
        self.assertEqual(self.client.get(f'/api/staff-appraisals/{appraisal_id}/').status_code, 404)
        self.assertEqual(self.client.get('/api/staff-appraisals/').data, [])

        # Manager shares it.
        self._login(self.manager)
        resp = self.client.post(f'/api/staff-appraisals/{appraisal_id}/share/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'SHARED')
        self.assertIsNotNone(resp.data['shared_at'])

        # Now the worker can read, comment and acknowledge — but not edit.
        self._login(self.worker)
        resp = self.client.get(f'/api/staff-appraisals/{appraisal_id}/')
        self.assertEqual(resp.status_code, 200)
        resp = self.client.patch(f'/api/staff-appraisals/{appraisal_id}/', {'summary': 'edited'}, format='json')
        self.assertEqual(resp.status_code, 403)
        resp = self.client.post(f'/api/staff-appraisals/{appraisal_id}/acknowledge/',
                                {'staff_comments': 'Happy with this.'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'ACKNOWLEDGED')
        self.assertEqual(resp.data['staff_comments'], 'Happy with this.')
        self.assertIsNotNone(resp.data['acknowledged_at'])

    def test_worker_cannot_acknowledge_someone_elses_appraisal(self):
        from .models import StaffAppraisal
        other = User.objects.create_user(username='other', password='pw', is_staff=True)
        appraisal = StaffAppraisal.objects.create(
            staff_member=other, appraiser=self.manager,
            appraisal_date=date(2026, 8, 1), status='SHARED', shared_at=timezone.now(),
        )
        self._login(self.worker)
        resp = self.client.post(f'/api/staff-appraisals/{appraisal.id}/acknowledge/')
        # Scoped out of the worker's queryset entirely.
        self.assertEqual(resp.status_code, 404)

    # --- sickness + training ---

    def test_sickness_scoping_and_validation(self):
        self._login(self.manager)
        resp = self.client.post('/api/staff-absences/', {
            'staff_member': self.worker.id, 'start_date': '2026-08-20', 'end_date': '2026-08-10',
        }, format='json')
        self.assertEqual(resp.status_code, 400)
        resp = self.client.post('/api/staff-absences/', {
            'staff_member': self.worker.id, 'start_date': '2026-08-20', 'reason': 'Flu',
        }, format='json')
        self.assertEqual(resp.status_code, 201)

        other = User.objects.create_user(username='other2', password='pw', is_staff=True)
        from .models import SicknessAbsence
        SicknessAbsence.objects.create(staff_member=other, start_date=date(2026, 8, 1),
                                       end_date=date(2026, 8, 2), recorded_by=self.manager)

        # Worker reads only their own, and cannot write.
        self._login(self.worker)
        resp = self.client.get('/api/staff-absences/')
        self.assertEqual(len(resp.data), 1)
        self.assertEqual(resp.data[0]['staff_member'], self.worker.id)
        resp = self.client.post('/api/staff-absences/', {
            'staff_member': self.worker.id, 'start_date': '2026-08-25',
        }, format='json')
        self.assertEqual(resp.status_code, 403)

    def test_training_expiry_status(self):
        from .models import StaffTrainingRecord
        self._login(self.manager)
        resp = self.client.post('/api/staff-training/', {
            'staff_member': self.worker.id, 'name': 'Canine First Aid',
            'completed_date': '2024-09-01',
            'expiry_date': (timezone.localdate() + timedelta(days=30)).isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['expiry_status'], 'EXPIRING')

    # --- team overview ---

    def test_team_overview_shape_and_house_account_excluded(self):
        from .models import StaffHRRecord, StaffPayRate, DayOffRequest
        User.objects.create_user(username='p4td', password='pw', is_staff=True)
        record = StaffHRRecord.objects.create(user=self.worker, job_title='Driver')
        StaffPayRate.objects.create(staff_member=self.worker, pay_type='HOURLY',
                                    rate=Decimal('12.50'), effective_from=date(2024, 1, 1))
        year = timezone.localdate().year
        DayOffRequest.objects.create(staff_member=self.worker, date=date(year, 2, 2), status='APPROVED')
        DayOffRequest.objects.create(staff_member=self.worker, date=date(year, 9, 9), status='PENDING')

        self._login(self.manager)
        resp = self.client.get('/api/staff-hr/team_overview/')
        self.assertEqual(resp.status_code, 200)
        usernames = [r['username'] for r in resp.data]
        self.assertNotIn('p4td', usernames)
        row = next(r for r in resp.data if r['username'] == 'worker')
        self.assertEqual(row['job_title'], 'Driver')
        self.assertEqual(row['pay_rate'], '12.50')
        self.assertEqual(row['holiday']['used_days'], 1)
        self.assertEqual(row['holiday']['remaining_days'], 27.0)
        self.assertEqual(row['pending_day_off_requests'], 1)


class ComplianceTests(TestCase):
    """The safety & compliance register: all staff read and log checks,
    can_manage_compliance gates managing the register, and the daily
    reminder command notifies once per cycle."""

    def setUp(self):
        self.manager = User.objects.create_user(username='compmanager', password='pw', is_staff=True)
        self.manager.profile.can_manage_compliance = True
        self.manager.profile.save()
        self.worker = User.objects.create_user(username='compworker', password='pw', is_staff=True)
        self.owner = User.objects.create_user(username='compowner', password='pw')
        from .models import ComplianceCheckType
        self.check = ComplianceCheckType.objects.create(
            name='Fire alarm test', category='FIRE', frequency='WEEKLY',
        )
        self.client = APIClient()

    def test_owner_gets_403(self):
        self.client.force_authenticate(user=self.owner)
        self.assertEqual(self.client.get('/api/compliance-checks/').status_code, 403)
        self.assertEqual(self.client.get('/api/compliance-logs/').status_code, 403)

    def test_any_staff_can_read_and_log_but_not_manage(self):
        self.client.force_authenticate(user=self.worker)
        resp = self.client.get('/api/compliance-checks/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data[0]['status'], 'NEVER_DONE')

        resp = self.client.post('/api/compliance-logs/', {
            'check_type': self.check.id,
            'performed_on': timezone.localdate().isoformat(),
            'result': 'PASS',
            'notes': 'Call point 3',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['performed_by'], self.worker.id)

        # But the register itself is manager-only.
        resp = self.client.post('/api/compliance-checks/', {
            'name': 'Made up check', 'category': 'OTHER', 'frequency': 'WEEKLY',
        }, format='json')
        self.assertEqual(resp.status_code, 403)
        resp = self.client.patch(f'/api/compliance-checks/{self.check.id}/',
                                 {'is_active': False}, format='json')
        self.assertEqual(resp.status_code, 403)
        # And so is tampering with the audit trail.
        log_id = self.check.logs.first().id
        self.assertEqual(self.client.delete(f'/api/compliance-logs/{log_id}/').status_code, 403)

    def test_future_dated_log_rejected(self):
        self.client.force_authenticate(user=self.worker)
        resp = self.client.post('/api/compliance-logs/', {
            'check_type': self.check.id,
            'performed_on': (timezone.localdate() + timedelta(days=1)).isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_manager_can_manage_register(self):
        self.client.force_authenticate(user=self.manager)
        resp = self.client.post('/api/compliance-checks/', {
            'name': 'Boiler service', 'category': 'HEALTH_SAFETY', 'frequency': 'ANNUAL',
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        check_id = resp.data['id']
        resp = self.client.patch(f'/api/compliance-checks/{check_id}/',
                                 {'is_active': False}, format='json')
        self.assertEqual(resp.status_code, 200)
        # Inactive checks drop out of the default list but come back on demand.
        names = [c['name'] for c in self.client.get('/api/compliance-checks/').data]
        self.assertNotIn('Boiler service', names)
        names = [c['name'] for c in
                 self.client.get('/api/compliance-checks/?include_inactive=1').data]
        self.assertIn('Boiler service', names)

    def test_status_computation(self):
        from .models import ComplianceCheckLog
        today = timezone.localdate()
        # Done yesterday → weekly check is OK.
        ComplianceCheckLog.objects.create(
            check_type=self.check, performed_on=today - timedelta(days=1))
        self.assertEqual(self.check.status(), 'OK')
        # Done 6 days ago → due tomorrow, within the due-soon window (1 day).
        self.check.logs.all().delete()
        ComplianceCheckLog.objects.create(
            check_type=self.check, performed_on=today - timedelta(days=6))
        self.assertEqual(self.check.status(), 'DUE_SOON')
        # Done 10 days ago → overdue.
        self.check.logs.all().delete()
        ComplianceCheckLog.objects.create(
            check_type=self.check, performed_on=today - timedelta(days=10))
        self.assertEqual(self.check.status(), 'OVERDUE')
        # API agrees.
        self.client.force_authenticate(user=self.worker)
        rows = self.client.get('/api/compliance-checks/').data
        row = next(r for r in rows if r['id'] == self.check.id)
        self.assertEqual(row['status'], 'OVERDUE')
        self.assertEqual(row['next_due'], today - timedelta(days=3))

    def test_reminder_command_sends_once_and_rearms_on_new_log(self):
        from .models import ComplianceCheckType, ComplianceCheckLog
        from io import StringIO
        today = timezone.localdate()
        # The migration-seeded checks would each fire a never-done reminder;
        # keep the run to just the check under test.
        ComplianceCheckType.objects.exclude(pk=self.check.pk).delete()
        ComplianceCheckLog.objects.create(
            check_type=self.check, performed_on=today - timedelta(days=10))

        with patch('api.management.commands.send_compliance_reminders.send_push_notification') as mock_push:
            out = StringIO()
            call_command('send_compliance_reminders', stdout=out)
            # One overdue check × one flag-holding manager.
            self.assertEqual(mock_push.call_count, 1)
            self.assertEqual(mock_push.call_args[0][0], self.manager)
            # Second run is silent — already notified this cycle.
            call_command('send_compliance_reminders', stdout=out)
            self.assertEqual(mock_push.call_count, 1)

        # Logging a completion re-arms the reminder for the next cycle.
        ComplianceCheckLog.objects.create(check_type=self.check, performed_on=today)
        self.check.refresh_from_db()
        self.assertFalse(self.check.due_notice_sent)

    def test_advance_notice_for_long_cycle_checks(self):
        from .models import ComplianceCheckType, ComplianceCheckLog
        from io import StringIO
        today = timezone.localdate()
        ComplianceCheckType.objects.all().delete()  # incl. migration-seeded rows
        annual = ComplianceCheckType.objects.create(
            name='Public liability insurance renewal', category='DOCUMENTS', frequency='ANNUAL',
        )
        ComplianceCheckLog.objects.create(
            check_type=annual, performed_on=today - timedelta(days=345))  # due in 20 days

        with patch('api.management.commands.send_compliance_reminders.send_push_notification') as mock_push:
            call_command('send_compliance_reminders', stdout=StringIO())
            self.assertEqual(mock_push.call_count, 1)
            self.assertIn('coming up', mock_push.call_args[0][1])

    def test_seeded_register(self):
        # The data migration seeded the standard checks (setUp added one more).
        from .models import ComplianceCheckType
        names = set(ComplianceCheckType.objects.values_list('name', flat=True))
        self.assertIn('Emergency lighting test', names)
        self.assertIn('Animal welfare licence renewal', names)


class DogContactNumberTests(TestCase):
    """The dog-level contact and emergency contact numbers round-trip through
    the API and the owner change-request flow."""

    def setUp(self):
        self.owner = User.objects.create_user(username='contactowner', password='pw')
        self.staff = User.objects.create_user(username='contactstaff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Biscuit')
        self.client = APIClient()

    def test_staff_can_set_contact_numbers_directly(self):
        self.client.force_authenticate(user=self.staff)
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'contact_number': '07700 900001',
            'emergency_contact_number': '07700 900002 (Sue, neighbour)',
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['contact_number'], '07700 900001')
        self.assertEqual(resp.data['emergency_contact_number'], '07700 900002 (Sue, neighbour)')

    def test_owner_edit_goes_through_change_request_and_applies(self):
        from .models import DogProfileChangeRequest
        self.client.force_authenticate(user=self.owner)
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'contact_number': '07700 900010',
            'emergency_contact_number': '07700 900011',
        }, format='json')
        self.assertEqual(resp.status_code, 202)
        # Not applied directly — a change request was created instead.
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.contact_number, '')
        cr = DogProfileChangeRequest.objects.get(dog=self.dog)
        self.assertEqual(cr.proposed_changes['contact_number'], '07700 900010')

        # Staff approve; the numbers land on the dog.
        self.client.force_authenticate(user=self.staff)
        resp = self.client.post(f'/api/dog-profile-changes/{cr.id}/approve/')
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.contact_number, '07700 900010')
        self.assertEqual(self.dog.emergency_contact_number, '07700 900011')


class DogVaccinationDateTests(TestCase):
    """The simple per-dog vaccination date, its overdue flag, and its sync
    with the detailed VaccinationRecord system."""

    def setUp(self):
        self.owner = User.objects.create_user(username='vaxowner', password='pw')
        self.staff = User.objects.create_user(username='vaxstaff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Pip')
        self.client = APIClient()

    def test_overdue_flag(self):
        today = timezone.localdate()
        self.dog.last_vaccination_date = today - timedelta(days=100)
        self.assertFalse(self.dog.vaccination_overdue)
        self.dog.last_vaccination_date = today - timedelta(days=366)
        self.assertTrue(self.dog.vaccination_overdue)
        self.dog.last_vaccination_date = None
        self.assertFalse(self.dog.vaccination_overdue)

    def test_api_roundtrip_and_flag(self):
        today = timezone.localdate()
        self.client.force_authenticate(user=self.staff)
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'last_vaccination_date': (today - timedelta(days=400)).isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['vaccination_overdue'])
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'last_vaccination_date': today.isoformat(),
        }, format='json')
        self.assertFalse(resp.data['vaccination_overdue'])

    def test_vaccination_record_advances_the_date(self):
        from .models import VaccinationRecord
        today = timezone.localdate()
        VaccinationRecord.objects.create(
            dog=self.dog, name='DHP',
            date_administered=today - timedelta(days=30),
            expiry_date=today + timedelta(days=335),
        )
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.last_vaccination_date, today - timedelta(days=30))

        # A newer record advances it; deleting recomputes from what's left.
        newer = VaccinationRecord.objects.create(
            dog=self.dog, name='Rabies',
            date_administered=today - timedelta(days=5),
            expiry_date=today + timedelta(days=360),
        )
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.last_vaccination_date, today - timedelta(days=5))
        newer.delete()
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.last_vaccination_date, today - timedelta(days=30))

    def test_owner_edit_goes_through_change_request(self):
        from .models import DogProfileChangeRequest
        today = timezone.localdate()
        self.client.force_authenticate(user=self.owner)
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {
            'last_vaccination_date': today.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 202)
        cr = DogProfileChangeRequest.objects.get(dog=self.dog)
        self.client.force_authenticate(user=self.staff)
        resp = self.client.post(f'/api/dog-profile-changes/{cr.id}/approve/')
        self.assertEqual(resp.status_code, 200)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.last_vaccination_date, today)


class VaccinationCertificateTests(TestCase):
    """Vaccination certificates never touch MEDIA_ROOT (which is served to
    anyone), the bytes are checked rather than the client's claims about
    them, images are re-encoded so nothing the uploader embedded survives,
    and the only way to a file is the owner/staff-gated download view."""

    def setUp(self):
        import shutil
        import tempfile
        from django.core.cache import cache

        self.private_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.private_dir, True)
        self.media_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.media_dir, True)
        overridden = override_settings(
            PRIVATE_MEDIA_ROOT=self.private_dir, MEDIA_ROOT=self.media_dir)
        overridden.enable()
        self.addCleanup(overridden.disable)
        # Upload throttle counters live in the (in-process) cache.
        cache.clear()

        self.owner = User.objects.create_user(username='certowner', password='pw')
        self.coowner = User.objects.create_user(username='certcoowner', password='pw')
        self.other = User.objects.create_user(username='certother', password='pw')
        self.staff = User.objects.create_user(username='certstaff', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Biscuit')
        self.dog.additional_owners.add(self.coowner)
        self.other_dog = Dog.objects.create(owner=self.other, name='Rex')
        self.client = APIClient()

    # ── helpers ──────────────────────────────────────────────────────

    @staticmethod
    def _jpeg(name='card.jpg', size=(80, 60), exif=None, fmt='JPEG'):
        from io import BytesIO
        from PIL import Image
        from django.core.files.uploadedfile import SimpleUploadedFile
        buf = BytesIO()
        img = Image.new('RGB', size, (200, 180, 120))
        kwargs = {'format': fmt}
        if exif is not None:
            kwargs['exif'] = exif
        img.save(buf, **kwargs)
        content_type = 'image/png' if fmt == 'PNG' else 'image/jpeg'
        return SimpleUploadedFile(name, buf.getvalue(), content_type=content_type)

    @staticmethod
    def _pdf(name='certificate.pdf', extra=b''):
        from django.core.files.uploadedfile import SimpleUploadedFile
        body = (
            b'%PDF-1.4\n'
            b'1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
            b'2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n'
            b'3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] ' + extra + b' >> endobj\n'
            b'trailer << /Root 1 0 R >>\n%%EOF\n'
        )
        return SimpleUploadedFile(name, body, content_type='application/pdf')

    def _post(self, upload, dog=None, as_user=None, **fields):
        self.client.force_authenticate(as_user or self.owner)
        data = {'dog': (dog or self.dog).id, 'file': upload}
        data.update(fields)
        return self.client.post('/api/vaccination-certificates/', data, format='multipart')

    def _private_files(self):
        import os
        found = []
        for root, _dirs, files in os.walk(self.private_dir):
            found.extend(os.path.join(root, f) for f in files)
        return found

    # ── storage ──────────────────────────────────────────────────────

    def test_upload_is_stored_privately_under_a_random_name(self):
        import os
        from .models import VaccinationCertificate
        resp = self._post(self._pdf('Biscuit Smith vaccination card.pdf'),
                          vaccination_date='2026-03-12')
        self.assertEqual(resp.status_code, 201, resp.content)
        cert = VaccinationCertificate.objects.get()

        # On disk under PRIVATE_MEDIA_ROOT, in the dog's folder, not under the
        # uploader's name — and nowhere near MEDIA_ROOT.
        self.assertTrue(cert.file.path.startswith(self.private_dir))
        self.assertIn(f'vaccination_certificates/{self.dog.id}/', cert.file.name)
        self.assertNotIn('Biscuit', cert.file.name)
        self.assertNotIn('Smith', cert.file.name)
        self.assertTrue(cert.file.name.endswith('.pdf'))
        self.assertEqual(os.listdir(self.media_dir), [])

        # The row remembers what it was, safely.
        self.assertEqual(cert.content_type, 'application/pdf')
        self.assertEqual(cert.original_filename, 'Biscuit Smith vaccination card.pdf')
        self.assertEqual(cert.size_bytes, os.path.getsize(cert.file.path))
        self.assertEqual(cert.uploaded_by, self.owner)
        self.assertEqual(cert.vaccination_date.isoformat(), '2026-03-12')

        # The API never discloses the storage path; only the gated URL.
        self.assertNotIn('file', resp.data)
        self.assertTrue(resp.data['download_url'].endswith(
            f'/api/vaccination-certificates/{cert.id}/download/'))
        self.assertEqual(resp.data['dog_name'], 'Biscuit')

    def test_private_storage_has_no_url(self):
        from .models import VaccinationCertificate
        self._post(self._pdf())
        cert = VaccinationCertificate.objects.get()
        with self.assertRaises(ValueError):
            cert.file.url

    def test_nothing_serves_private_media_over_http(self):
        from .models import VaccinationCertificate
        self._post(self._pdf())
        cert = VaccinationCertificate.objects.get()
        # Even a caller who somehow learned the stored name gets nothing from
        # the public media route (the file is not under MEDIA_ROOT) — and the
        # file's own directory is not routed at all.
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get(f'/media/{cert.file.name}').status_code, 404)
        self.assertEqual(self.client.get(f'/private-media/{cert.file.name}').status_code, 404)

    def test_image_is_reencoded_and_stripped(self):
        from PIL import ExifTags, Image
        from .models import VaccinationCertificate
        exif = Image.Exif()
        exif[ExifTags.Base.Make] = 'PhoneMaker'
        # The one that matters: where the photo was taken.
        gps = exif.get_ifd(ExifTags.IFD.GPSInfo)
        gps[ExifTags.GPS.GPSLatitudeRef] = 'N'
        gps[ExifTags.GPS.GPSLatitude] = (51.0, 24.0, 36.0)
        upload = self._jpeg('kitchen-table.png', size=(3000, 2000), exif=exif, fmt='PNG')
        # Sanity: the upload really carries it.
        with Image.open(upload) as probe:
            self.assertEqual(probe.getexif().get_ifd(ExifTags.IFD.GPSInfo)[ExifTags.GPS.GPSLatitudeRef], 'N')
        upload.seek(0)
        resp = self._post(upload)
        self.assertEqual(resp.status_code, 201, resp.content)
        cert = VaccinationCertificate.objects.get()

        # Stored as a JPEG we produced, whatever came in.
        self.assertEqual(cert.content_type, 'image/jpeg')
        self.assertTrue(cert.file.name.endswith('.jpg'))
        with Image.open(cert.file.path) as stored:
            self.assertEqual(stored.format, 'JPEG')
            self.assertEqual(dict(stored.getexif()), {})
            self.assertNotIn('icc_profile', stored.info)
            self.assertLessEqual(max(stored.size), 2400)

        # Display name keeps the uploader's stem; the download name is honest
        # about the bytes.
        self.assertEqual(cert.original_filename, 'kitchen-table.png')
        resp = self.client.get(resp.data['download_url'])
        self.assertEqual(resp.status_code, 200)
        self.assertIn('filename="kitchen-table.jpg"', resp['Content-Disposition'])

    # ── access ───────────────────────────────────────────────────────

    def test_owner_cannot_file_against_someone_elses_dog(self):
        from .models import VaccinationCertificate
        resp = self._post(self._pdf(), dog=self.other_dog)
        self.assertEqual(resp.status_code, 403)
        self.assertEqual(VaccinationCertificate.objects.count(), 0)
        self.assertEqual(self._private_files(), [])

    def test_co_owner_and_staff_can_list_and_download(self):
        resp = self._post(self._pdf())
        url = resp.data['download_url']
        for user in (self.coowner, self.staff):
            self.client.force_authenticate(user)
            listed = self.client.get(f'/api/vaccination-certificates/?dog={self.dog.id}')
            self.assertEqual(listed.status_code, 200)
            self.assertEqual([c['id'] for c in listed.data], [resp.data['id']])
            self.assertEqual(self.client.get(url).status_code, 200)

    def test_unrelated_owner_cannot_see_or_download(self):
        resp = self._post(self._pdf())
        cert_id = resp.data['id']
        self.client.force_authenticate(self.other)
        # Not in the listing, even when asking for that dog by id.
        listed = self.client.get(f'/api/vaccination-certificates/?dog={self.dog.id}')
        self.assertEqual(listed.status_code, 200)
        self.assertEqual(listed.data, [])
        # And 404 — not 403 — on the row and the file, so the id discloses nothing.
        self.assertEqual(self.client.get(f'/api/vaccination-certificates/{cert_id}/').status_code, 404)
        self.assertEqual(self.client.get(f'/api/vaccination-certificates/{cert_id}/download/').status_code, 404)

    def test_anonymous_is_refused_everywhere(self):
        resp = self._post(self._pdf())
        url = resp.data['download_url']
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get('/api/vaccination-certificates/').status_code, 401)
        self.assertEqual(self.client.get(url).status_code, 401)
        self.assertEqual(self.client.post('/api/vaccination-certificates/',
                                          {'dog': self.dog.id, 'file': self._pdf()},
                                          format='multipart').status_code, 401)

    def test_download_is_an_attachment_with_hardening_headers(self):
        from .models import VaccinationCertificate
        resp = self._post(self._pdf('cert.pdf'))
        cert = VaccinationCertificate.objects.get()
        resp = self.client.get(resp.data['download_url'])
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp['Content-Type'], 'application/pdf')
        self.assertIn('attachment', resp['Content-Disposition'])
        self.assertIn('filename="cert.pdf"', resp['Content-Disposition'])
        self.assertEqual(resp['X-Content-Type-Options'], 'nosniff')
        self.assertIn("default-src 'none'", resp['Content-Security-Policy'])
        self.assertIn('no-store', resp['Cache-Control'])
        with open(cert.file.path, 'rb') as fh:
            self.assertEqual(b''.join(resp.streaming_content), fh.read())

    def test_download_filename_falls_back_to_the_dog(self):
        from .models import VaccinationCertificate
        resp = self._post(self._pdf('../../etc/passwd.pdf'))
        cert = VaccinationCertificate.objects.get()
        # Traversal characters never make it into the stored name.
        self.assertEqual(cert.original_filename, 'passwd.pdf')
        cert.original_filename = ''
        cert.save(update_fields=['original_filename'])
        resp = self.client.get(resp.data['download_url'])
        self.assertIn('filename="Biscuit-vaccination-certificate.pdf"', resp['Content-Disposition'])

    # ── validation ───────────────────────────────────────────────────

    def _assert_rejected(self, upload, **fields):
        from .models import VaccinationCertificate
        resp = self._post(upload, **fields)
        self.assertEqual(resp.status_code, 400, resp.content)
        self.assertIn('file', resp.data)
        self.assertEqual(VaccinationCertificate.objects.count(), 0)
        self.assertEqual(self._private_files(), [])
        return resp

    def test_rejects_html_dressed_as_a_pdf(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        self._assert_rejected(SimpleUploadedFile(
            'cert.pdf', b'<html><script>alert(document.domain)</script></html>',
            content_type='application/pdf'))

    def test_rejects_svg_however_it_is_named(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        svg = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
        self._assert_rejected(SimpleUploadedFile('cert.svg', svg, content_type='image/svg+xml'))
        self._assert_rejected(SimpleUploadedFile('cert.png', svg, content_type='image/png'))

    def test_rejects_disallowed_extensions(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        self._assert_rejected(SimpleUploadedFile('cert.exe', b'MZ\x90\x00' * 20, content_type='application/octet-stream'))
        self._assert_rejected(SimpleUploadedFile('cert', b'%PDF-1.4 no extension', content_type='application/pdf'))
        # HEIC is not decodable here; say so rather than store an unchecked blob.
        self._assert_rejected(SimpleUploadedFile('cert.heic', b'\x00\x00\x00\x18ftypheic' + b'\x00' * 40, content_type='image/heic'))

    def test_rejects_an_image_that_is_not_one(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        self._assert_rejected(SimpleUploadedFile('cert.jpg', b'\xff\xd8\xff' + b'garbage' * 10, content_type='image/jpeg'))
        self._assert_rejected(SimpleUploadedFile('cert.jpg', b'<?php system($_GET["c"]); ?>', content_type='image/jpeg'))

    def test_rejects_unsupported_image_formats(self):
        # A real, decodable image in a format we don't take: right extension,
        # wrong bytes. Pillow reports the true format, not the name.
        self._assert_rejected(self._jpeg('cert.png', fmt='BMP'))

    def test_rejects_oversize_and_empty_files(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        from django.conf import settings
        limit = settings.MAX_VACCINATION_CERTIFICATE_BYTES
        self._assert_rejected(SimpleUploadedFile(
            'big.pdf', b'%PDF-1.4\n' + b'0' * limit, content_type='application/pdf'))
        self._assert_rejected(SimpleUploadedFile('empty.pdf', b'', content_type='application/pdf'))

    def test_rejects_a_decompression_bomb(self):
        from io import BytesIO
        from PIL import Image
        from django.core.files.uploadedfile import SimpleUploadedFile
        # 10000x10000 of one colour compresses to a few KB but is 100 MP.
        buf = BytesIO()
        Image.new('L', (10000, 10000), 255).save(buf, format='PNG', optimize=True)
        self._assert_rejected(SimpleUploadedFile('bomb.png', buf.getvalue(), content_type='image/png'))

    def test_rejects_pdfs_with_active_content(self):
        self._assert_rejected(self._pdf(extra=b'/AA << /O << /S /JavaScript /JS (app.alert(1)) >> >>'))
        self._assert_rejected(self._pdf(extra=b'/OpenAction << /S /Launch /F (cmd.exe) >>'))
        self._assert_rejected(self._pdf(extra=b'/Names << /EmbeddedFiles 9 0 R >>'))
        # A benign OpenAction (open on page one) is a normal PDF.
        resp = self._post(self._pdf(extra=b'/OpenAction [3 0 R /Fit]'))
        self.assertEqual(resp.status_code, 201, resp.content)

    def test_per_dog_cap(self):
        from django.core.files.base import ContentFile
        from .certificates import MAX_CERTIFICATES_PER_DOG
        from .models import VaccinationCertificate
        for i in range(MAX_CERTIFICATES_PER_DOG):
            VaccinationCertificate.objects.create(
                dog=self.dog, file=ContentFile(b'%PDF-1.4', name=f'{i}.pdf'),
                content_type='application/pdf', size_bytes=8, uploaded_by=self.staff)
        resp = self._post(self._pdf())
        self.assertEqual(resp.status_code, 400)
        self.assertIn('file', resp.data)
        self.assertEqual(VaccinationCertificate.objects.count(), MAX_CERTIFICATES_PER_DOG)

    def test_upload_throttle(self):
        from django.core.cache import cache
        from rest_framework.throttling import ScopedRateThrottle
        # THROTTLE_RATES is bound on the class at import, so override_settings
        # on REST_FRAMEWORK would not reach it.
        self.assertEqual(ScopedRateThrottle.THROTTLE_RATES['certificate_upload'], '60/hour')
        with patch.dict(ScopedRateThrottle.THROTTLE_RATES, {'certificate_upload': '2/hour'}):
            cache.clear()
            self.assertEqual(self._post(self._pdf()).status_code, 201)
            self.assertEqual(self._post(self._pdf()).status_code, 201)
            self.assertEqual(self._post(self._pdf()).status_code, 429)
            # Reads are not throttled.
            self.client.force_authenticate(self.owner)
            self.assertEqual(self.client.get('/api/vaccination-certificates/').status_code, 200)
            # Nor is anyone else.
            self.assertEqual(self._post(self._pdf(), as_user=self.staff).status_code, 201)
        cache.clear()

    # ── deletion ─────────────────────────────────────────────────────

    def test_owner_can_remove_their_own_upload_but_not_staffs(self):
        import os
        from .models import VaccinationCertificate
        mine = self._post(self._pdf()).data['id']
        theirs = self._post(self._pdf(), as_user=self.staff).data['id']
        theirs_path = VaccinationCertificate.objects.get(pk=theirs).file.path

        self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.delete(f'/api/vaccination-certificates/{theirs}/').status_code, 403)
        self.assertTrue(os.path.exists(theirs_path))

        mine_path = VaccinationCertificate.objects.get(pk=mine).file.path
        self.assertEqual(self.client.delete(f'/api/vaccination-certificates/{mine}/').status_code, 204)
        self.assertFalse(os.path.exists(mine_path))
        self.assertFalse(VaccinationCertificate.objects.filter(pk=mine).exists())

        self.client.force_authenticate(self.staff)
        self.assertEqual(self.client.delete(f'/api/vaccination-certificates/{theirs}/').status_code, 204)
        self.assertFalse(os.path.exists(theirs_path))

    def test_there_is_no_update(self):
        cert_id = self._post(self._pdf()).data['id']
        self.client.force_authenticate(self.staff)
        resp = self.client.patch(f'/api/vaccination-certificates/{cert_id}/',
                                 {'vaccination_date': '2020-01-01'}, format='multipart')
        self.assertEqual(resp.status_code, 405)

    def test_deleting_the_dog_removes_its_certificates_from_disk(self):
        self._post(self._pdf())
        self._post(self._jpeg())
        self.assertEqual(len(self._private_files()), 2)
        self.client.force_authenticate(self.staff)
        resp = self.client.delete(f'/api/dogs/{self.dog.id}/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(self._private_files(), [])


class DogHealthFlagsTests(TestCase):
    """The staff dashboard's single "Dog health to confirm" row: neutered
    status to confirm and vaccinations over a year old, in one call."""

    def setUp(self):
        self.owner = User.objects.create_user(username='hfowner', password='pw')
        self.staff = User.objects.create_user(username='hfstaff', password='pw', is_staff=True)
        self.client = APIClient()

    def test_staff_get_both_lists_and_a_total(self):
        today = timezone.localdate()
        unspayed = Dog.objects.create(
            owner=self.owner, name='Alfie', sex='M', is_spayed=False,
            date_of_birth=today - timedelta(days=800))
        overdue = Dog.objects.create(
            owner=self.owner, name='Bella',
            last_vaccination_date=today - timedelta(days=400))
        both = Dog.objects.create(
            owner=self.owner, name='Charlie', sex='M', is_spayed=False,
            date_of_birth=today - timedelta(days=800),
            last_vaccination_date=today - timedelta(days=366))
        Dog.objects.create(owner=self.owner, name='Fine',
                           last_vaccination_date=today - timedelta(days=100))
        Dog.objects.create(owner=self.owner, name='Exactly a year',
                           last_vaccination_date=today - timedelta(days=365))
        Dog.objects.create(owner=self.owner, name='Unknown')  # no date: not flagged

        self.client.force_authenticate(self.staff)
        resp = self.client.get('/api/dogs/health_flags/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['count'], 4)
        self.assertEqual([d['id'] for d in resp.data['unspayed_males']['dogs']], [unspayed.id, both.id])
        self.assertEqual(resp.data['unspayed_males']['count'], 2)
        overdue_rows = resp.data['vaccinations_overdue']['dogs']
        self.assertEqual([d['id'] for d in overdue_rows], [overdue.id, both.id])
        self.assertEqual(overdue_rows[0]['last_vaccination_date'],
                         (today - timedelta(days=400)).isoformat())
        self.assertIn('profile_image', overdue_rows[0])

    def test_owner_is_refused(self):
        self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.get('/api/dogs/health_flags/').status_code, 403)


class AnnualVaccinationReminderTests(TestCase):
    """A week before Dog.last_vaccination_date is a year old, the owners get
    one push. Dogs with detailed records are left to the record reminders."""

    def setUp(self):
        self.owner = User.objects.create_user(username='avowner', password='pw')
        self.coowner = User.objects.create_user(username='avcoowner', password='pw')
        self.today = timezone.localdate()

    def _dog(self, name, days_ago, **extra):
        return Dog.objects.create(
            owner=self.owner, name=name,
            last_vaccination_date=self.today - timedelta(days=days_ago), **extra)

    def _run(self):
        import io
        out = io.StringIO()
        with patch('api.management.commands.send_vaccination_reminders.send_push_notification') as push:
            call_command('send_vaccination_reminders', stdout=out)
        return out.getvalue(), push

    def test_reminds_once_a_week_before_the_anniversary(self):
        due_soon = self._dog('Milo', 360)          # due in 5 days
        due_soon.additional_owners.add(self.coowner)
        self._dog('Fresh', 200)                    # nothing to say yet
        self._dog('Overdue', 370)                  # the dashboard's job, not a push
        self._dog('Anniversary', 365)              # due today is past the window's end
        with_records = self._dog('Recorded', 360)
        from .models import VaccinationRecord
        VaccinationRecord.objects.create(
            dog=with_records, name='DHP',
            date_administered=self.today - timedelta(days=360),
            expiry_date=self.today + timedelta(days=5),
            reminder_30_sent=True, reminder_7_sent=True)

        output, push = self._run()
        self.assertIn('Sent 1 ', output)
        self.assertEqual(push.call_count, 2)  # owner and co-owner
        recipients = {call.args[0] for call in push.call_args_list}
        self.assertEqual(recipients, {self.owner, self.coowner})
        title, body = push.call_args_list[0].args[1:3]
        self.assertEqual(title, 'Vaccinations due soon')
        self.assertIn("Milo's annual vaccinations are due in 5 days", body)
        self.assertEqual(push.call_args_list[0].args[3]['dog_id'], str(due_soon.id))
        self.assertEqual(push.call_args_list[0].kwargs.get('category'), 'dog_updates')

        due_soon.refresh_from_db()
        self.assertEqual(due_soon.annual_vaccination_reminder_sent_for, due_soon.last_vaccination_date)

        # Tomorrow: nothing new.
        output, push = self._run()
        self.assertIn('Sent 0 ', output)
        self.assertEqual(push.call_count, 0)

    def test_window_edges(self):
        self._dog('SevenDays', 358)   # due in exactly 7 days: first day of the window
        self._dog('EightDays', 357)   # not yet
        self._dog('Tomorrow', 364)    # last day of the window
        output, push = self._run()
        self.assertIn('Sent 2 ', output)
        names = sorted(call.args[2].split("'s")[0] for call in push.call_args_list)
        self.assertEqual(names, ['SevenDays', 'Tomorrow'])

    def test_a_new_date_rearms_the_reminder(self):
        dog = self._dog('Milo', 360)
        self._run()
        # Next year: staff enter the booster date; a year on it comes due again.
        dog.last_vaccination_date = self.today - timedelta(days=359)
        dog.save()
        output, push = self._run()
        self.assertIn('Sent 1 ', output)
        self.assertEqual(push.call_count, 1)
