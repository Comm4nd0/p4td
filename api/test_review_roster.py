"""Regression tests for the roster / requests half of the API review
(api/views.py: date-change requests, dog profile changes, boarding status,
daily assignments). Each test pins one behaviour the review changed."""
import io
from datetime import timedelta
from unittest import skipUnless
from unittest.mock import patch

from django.contrib.auth.models import User
from django.db import connection
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.utils import timezone
from PIL import Image
from rest_framework.test import APIClient

from .models import (
    BoardingRequest, BoardingRequestHistory, ClosureDay, DailyDogAssignment,
    DateChangeRequest, DateChangeRequestHistory, Dog, DogProfileChangeRequest,
    DogWeekdayPickup, GroupMedia,
)


def make_staff(username, **flags):
    """A staff user holding exactly the given ``UserProfile`` flags."""
    user = User.objects.create_user(username=username, password='pw', is_staff=True, first_name=username.title())
    for flag, value in flags.items():
        setattr(user.profile, flag, value)
    user.profile.save()
    return user


def next_weekday(isoweekday, weeks_ahead=1):
    """The date of ``isoweekday`` (1=Mon) at least ``weeks_ahead`` weeks out."""
    today = timezone.localdate()
    day = today + timedelta(days=7 * weeks_ahead)
    return day + timedelta(days=(isoweekday - day.isoweekday()) % 7)


class Base(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.owner = User.objects.create_user(username='owner@example.com', password='pw', first_name='Olive')
        self.plain = make_staff('plain')
        self.assigner = make_staff('assigner', can_assign_dogs=True)
        self.requests_manager = make_staff('reqs', can_manage_requests=True)
        self.payments = make_staff(
            'pay', can_manage_payments=True, can_manage_requests=True, can_assign_dogs=True)
        self.today = timezone.localdate()
        self.monday = next_weekday(1)
        self.dog = Dog.objects.create(owner=self.owner, name='Fido', daycare_days=[1, 3])

    def as_(self, user):
        self.client.force_authenticate(user=user)


# --- 1. Date-change requests: decided requests are closed to owners ----------

class DecidedDateChangeRequestTests(Base):
    def _approved_add_day(self):
        return DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY', new_date=self.today + timedelta(days=10),
            status='APPROVED', approved_by=self.requests_manager, approved_at=timezone.now())

    def test_owner_cannot_move_an_approved_request_to_another_day(self):
        req = self._approved_add_day()
        elsewhere = self.today + timedelta(days=20)
        self.as_(self.owner)
        resp = self.client.patch(
            f'/api/date-change-requests/{req.id}/', {'new_date': elsewhere.isoformat()}, format='json')
        self.assertEqual(resp.status_code, 403)
        req.refresh_from_db()
        self.assertNotEqual(req.new_date, elsewhere)

    def test_owner_cannot_delete_an_approved_cancellation(self):
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=self.monday, status='APPROVED')
        self.as_(self.owner)
        resp = self.client.delete(f'/api/date-change-requests/{req.id}/')
        self.assertEqual(resp.status_code, 403)
        self.assertTrue(DateChangeRequest.objects.filter(id=req.id).exists())

    def test_owner_can_still_withdraw_a_pending_request(self):
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=self.monday)
        self.as_(self.owner)
        self.assertEqual(self.client.delete(f'/api/date-change-requests/{req.id}/').status_code, 204)

    def test_staff_cannot_change_the_dates_of_a_decided_request(self):
        req = self._approved_add_day()
        self.as_(self.requests_manager)
        resp = self.client.patch(
            f'/api/date-change-requests/{req.id}/',
            {'new_date': (self.today + timedelta(days=20)).isoformat()}, format='json')
        self.assertEqual(resp.status_code, 403)
        # ...but a field that isn't the dog, the type or a date still saves.
        resp = self.client.patch(
            f'/api/date-change-requests/{req.id}/', {'is_charged': True}, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_owner_edit_recomputes_the_late_change_fee(self):
        far = self.today + timedelta(days=70)
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=far, is_charged=False)
        soon = self.today + timedelta(days=2)
        self.as_(self.owner)
        resp = self.client.patch(
            f'/api/date-change-requests/{req.id}/', {'original_date': soon.isoformat()}, format='json')
        self.assertEqual(resp.status_code, 200)
        req.refresh_from_db()
        self.assertTrue(req.is_charged)


# --- 2. daily-assignments: the generic routes follow the actions' rules ------

class GenericAssignmentRouteTests(Base):
    def setUp(self):
        super().setUp()
        self.row = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=self.monday)

    def test_plain_staff_cannot_create_patch_or_delete(self):
        self.as_(self.plain)
        other = Dog.objects.create(owner=self.owner, name='Rex')
        resp = self.client.post('/api/daily-assignments/', {
            'dog': other.id, 'staff_member': self.plain.id, 'date': self.monday.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 403)
        resp = self.client.patch(
            f'/api/daily-assignments/{self.row.id}/', {'staff_member': self.plain.id}, format='json')
        self.assertEqual(resp.status_code, 403)
        self.assertEqual(self.client.delete(f'/api/daily-assignments/{self.row.id}/').status_code, 403)
        self.row.refresh_from_db()
        self.assertEqual(self.row.staff_member_id, self.assigner.id)

    def test_assigner_can_create_and_it_is_logged(self):
        from .models import DogChangeLog
        other = Dog.objects.create(owner=self.owner, name='Rex')
        self.as_(self.assigner)
        resp = self.client.post('/api/daily-assignments/', {
            'dog': other.id, 'staff_member': self.plain.id, 'date': self.monday.isoformat(),
        }, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertTrue(DogChangeLog.objects.filter(dog=other, category='SCHEDULE').exists())

    def test_a_row_cannot_be_moved_to_another_date_or_dog(self):
        self.as_(self.assigner)
        resp = self.client.patch(
            f'/api/daily-assignments/{self.row.id}/',
            {'date': (self.monday + timedelta(days=7)).isoformat()}, format='json')
        self.assertEqual(resp.status_code, 400)
        other = Dog.objects.create(owner=self.owner, name='Rex')
        resp = self.client.patch(
            f'/api/daily-assignments/{self.row.id}/', {'dog': other.id}, format='json')
        self.assertEqual(resp.status_code, 400)
        self.row.refresh_from_db()
        self.assertEqual((self.row.date, self.row.dog_id), (self.monday, self.dog.id))

    def test_past_row_cannot_be_moved_off_the_invoice_by_changing_its_date(self):
        past = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=self.today - timedelta(days=7),
            status='DROPPED_OFF')
        self.as_(self.assigner)
        resp = self.client.patch(
            f'/api/daily-assignments/{past.id}/',
            {'date': (self.today + timedelta(days=30)).isoformat()}, format='json')
        self.assertEqual(resp.status_code, 400)
        past.refresh_from_db()
        self.assertEqual(past.date, self.today - timedelta(days=7))

    def test_creating_a_past_day_needs_the_payments_permission(self):
        past = self.today - timedelta(days=7)
        other = Dog.objects.create(owner=self.owner, name='Rex')
        body = {'dog': other.id, 'staff_member': self.assigner.id, 'date': past.isoformat()}
        self.as_(self.assigner)
        self.assertEqual(self.client.post('/api/daily-assignments/', body, format='json').status_code, 403)
        self.assertFalse(DailyDogAssignment.objects.filter(dog=other).exists())
        self.as_(self.payments)
        self.assertEqual(self.client.post('/api/daily-assignments/', body, format='json').status_code, 201)

    def test_update_status_removed_needs_can_assign_dogs(self):
        self.as_(self.plain)
        resp = self.client.post(
            f'/api/daily-assignments/{self.row.id}/update_status/', {'status': 'REMOVED'}, format='json')
        self.assertEqual(resp.status_code, 403)
        self.row.refresh_from_db()
        self.assertEqual(self.row.status, 'ASSIGNED')

    def test_any_staff_can_still_record_pickup_progress(self):
        self.as_(self.plain)
        resp = self.client.post(
            f'/api/daily-assignments/{self.row.id}/update_status/', {'status': 'PICKED_UP'}, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_update_status_removed_offers_the_spot_to_the_waitlist(self):
        self.as_(self.assigner)
        with patch('api.scheduling.process_waitlist_for_date') as waitlist:
            resp = self.client.post(
                f'/api/daily-assignments/{self.row.id}/update_status/', {'status': 'REMOVED'}, format='json')
        self.assertEqual(resp.status_code, 200)
        waitlist.assert_called_once_with(self.monday)


# --- 3 / 5 / 7 / 11. Date-change change_status -------------------------------

class DateChangeStatusTests(Base):
    def _status(self, req, status):
        return self.client.post(
            f'/api/date-change-requests/{req.id}/change_status/', {'status': status}, format='json')

    def test_needs_can_manage_requests(self):
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=self.monday)
        self.as_(self.plain)
        self.assertEqual(self._status(req, 'APPROVED').status_code, 403)
        req.refresh_from_db()
        self.assertEqual(req.status, 'PENDING')
        self.as_(self.requests_manager)
        self.assertEqual(self._status(req, 'APPROVED').status_code, 200)

    def test_superuser_passes_without_the_flag(self):
        boss = User.objects.create_superuser(username='boss', password='pw')
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=self.monday)
        self.as_(boss)
        self.assertEqual(self._status(req, 'DENIED').status_code, 200)

    def test_stale_cancel_keeps_past_attendance_without_payments_permission(self):
        past = self.today - timedelta(days=5)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=past, status='DROPPED_OFF')
        req = DateChangeRequest.objects.create(dog=self.dog, request_type='CANCEL', original_date=past)
        self.as_(self.requests_manager)
        self.assertEqual(self._status(req, 'APPROVED').status_code, 200)
        self.assertTrue(DailyDogAssignment.objects.filter(dog=self.dog, date=past).exists())

    def test_stale_cancel_frees_the_past_day_for_a_payments_manager(self):
        past = self.today - timedelta(days=5)
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=past, status='DROPPED_OFF')
        req = DateChangeRequest.objects.create(dog=self.dog, request_type='CANCEL', original_date=past)
        self.as_(self.payments)
        self.assertEqual(self._status(req, 'APPROVED').status_code, 200)
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog, date=past).exists())

    def test_set_pending_takes_the_added_day_back_off_the_board(self):
        extra = next_weekday(2)  # a Tuesday: not one of Fido's days
        req = DateChangeRequest.objects.create(dog=self.dog, request_type='ADD_DAY', new_date=extra)
        self.as_(self.requests_manager)
        self.assertEqual(self._status(req, 'APPROVED').status_code, 200)
        # Staff give the extra day a driver: a board row now exists.
        self.as_(self.assigner)
        resp = self.client.post('/api/daily-assignments/assign_to_me/', {
            'dog_ids': [self.dog.id], 'date': extra.isoformat()}, format='json')
        self.assertEqual(resp.status_code, 201)
        row = DailyDogAssignment.objects.get(dog=self.dog, date=extra)
        self.assertEqual(row.booking, DailyDogAssignment.BOOKING_EXTRA)

        self.as_(self.requests_manager)
        self.assertEqual(self._status(req, 'PENDING').status_code, 200)
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog, date=extra).exists())
        # And it can be approved again afterwards.
        self.assertEqual(self._status(req, 'APPROVED').status_code, 200)

    def test_denying_an_approved_day_leaves_a_dog_already_collected(self):
        extra = self.today
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY', new_date=extra, status='APPROVED')
        DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=extra, status='PICKED_UP',
            booking=DailyDogAssignment.BOOKING_EXTRA)
        self.as_(self.requests_manager)
        self.assertEqual(self._status(req, 'DENIED').status_code, 200)
        self.assertTrue(DailyDogAssignment.objects.filter(dog=self.dog, date=extra).exists())

    def test_repeating_a_decision_writes_no_second_history_row(self):
        req = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=self.monday)
        self.as_(self.requests_manager)
        self._status(req, 'APPROVED')
        resp = self._status(req, 'APPROVED')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(DateChangeRequestHistory.objects.filter(request=req).count(), 1)


# --- 4 / 12. auto_assign and suggestions -------------------------------------

class AutoAssignTests(Base):
    def _history(self, dog, when, staff):
        return DailyDogAssignment.objects.create(
            dog=dog, staff_member=staff, date=when, status='DROPPED_OFF')

    def _auto(self, when, unassigned=None):
        """POST auto_assign. ``unassigned`` stands in for the "who still
        needs a driver" query, which uses a JSON ``contains`` lookup SQLite
        can't run; the tests that pass it are about what happens next."""
        body = {'date': when.isoformat()}
        if unassigned is None:
            return self.client.post('/api/daily-assignments/auto_assign/', body, format='json')
        with patch('api.views.DailyDogAssignmentViewSet._unassigned_dog_ids',
                   return_value=[d.id for d in unassigned]):
            return self.client.post('/api/daily-assignments/auto_assign/', body, format='json')

    def test_refuses_a_closed_day(self):
        self._history(self.dog, self.monday - timedelta(days=7), self.assigner)
        ClosureDay.objects.create(date=self.monday, closure_type='CLOSED')
        self.as_(self.assigner)
        resp = self._auto(self.monday)
        self.assertEqual(resp.status_code, 400)
        self.assertFalse(DailyDogAssignment.objects.filter(date=self.monday).exists())

    def test_past_day_gets_no_new_attendance_without_payments_permission(self):
        past = self.monday - timedelta(days=14)
        while past >= self.today:
            past -= timedelta(days=7)
        self._history(self.dog, past - timedelta(days=7), self.assigner)
        self.as_(self.assigner)
        resp = self._auto(past, unassigned=[self.dog])
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data['assigned'], [])
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog, date=past).exists())
        # A payments manager may add the past day.
        self.as_(self.payments)
        resp = self._auto(past, unassigned=[self.dog])
        self.assertEqual(len(resp.data['assigned']), 1)

    @skipUnless(connection.features.supports_json_field_contains,
                'unassigned_dogs filters daycare_days with a JSON contains lookup')
    def test_assigns_the_dogs_the_unassigned_list_shows_and_no_others(self):
        self._history(self.dog, self.monday - timedelta(days=7), self.assigner)
        owner_driven = Dog.objects.create(
            owner=self.owner, name='Selfie', daycare_days=[1],
            owner_brings_default=True, owner_collects_default=True)
        # No house account in this test database, so the owner-driven dog is
        # materialised UNASSIGNED — and must stay off every driver's list.
        self._history(owner_driven, self.monday - timedelta(days=7), self.assigner)
        self.as_(self.assigner)
        listed = self.client.get(f'/api/daily-assignments/unassigned_dogs/?date={self.monday.isoformat()}')
        self.assertEqual([d['id'] for d in listed.data], [self.dog.id])
        resp = self._auto(self.monday)
        self.assertEqual(resp.status_code, 201)
        self.assertEqual([a['dog'] for a in resp.data['assigned']], [self.dog.id])
        self.assertFalse(DailyDogAssignment.objects.filter(
            dog=owner_driven, date=self.monday, staff_member=self.assigner, status='ASSIGNED').exists())

    def test_suggestions_look_back_two_months_only(self):
        old_dog = Dog.objects.create(owner=self.owner, name='Oldie', daycare_days=[1])
        self._history(old_dog, self.monday - timedelta(weeks=20), self.assigner)
        self._history(self.dog, self.monday - timedelta(weeks=1), self.assigner)
        self.as_(self.plain)
        resp = self.client.get(
            f'/api/daily-assignments/suggested_assignments/?date={self.monday.isoformat()}')
        self.assertEqual(resp.status_code, 200)
        self.assertIn(self.dog.id, resp.data)
        self.assertEqual(resp.data[self.dog.id]['staff_member_id'], self.assigner.id)
        self.assertEqual(resp.data[self.dog.id]['source'], 'same_weekday')
        self.assertNotIn(old_dog.id, resp.data)

    def test_a_former_staff_member_is_never_suggested(self):
        gone = make_staff('gone')
        self._history(self.dog, self.monday - timedelta(weeks=1), gone)
        gone.is_staff = False
        gone.save()
        self.as_(self.assigner)
        resp = self._auto(self.monday, unassigned=[self.dog])
        self.assertEqual(resp.data['assigned'], [])
        self.assertEqual(resp.data['skipped_dog_ids'], [self.dog.id])

    def test_assigns_from_recent_history(self):
        self._history(self.dog, self.monday - timedelta(days=7), self.assigner)
        self.as_(self.assigner)
        resp = self._auto(self.monday, unassigned=[self.dog])
        self.assertEqual(resp.status_code, 201)
        row = DailyDogAssignment.objects.get(dog=self.dog, date=self.monday)
        self.assertEqual(row.staff_member_id, self.assigner.id)


# --- 5. Flags the app already hides behind ----------------------------------

def _png(name='p.png'):
    buf = io.BytesIO()
    Image.new('RGB', (8, 8), 'red').save(buf, format='PNG')
    return SimpleUploadedFile(name, buf.getvalue(), content_type='image/png')


class FlagEnforcementTests(Base):
    def _change_request(self):
        return DogProfileChangeRequest.objects.create(
            dog=self.dog, requested_by=self.owner, proposed_changes={'name': 'Fidget'})

    def test_profile_change_approve_and_reject_need_can_manage_requests(self):
        cr = self._change_request()
        self.as_(self.plain)
        self.assertEqual(self.client.post(f'/api/dog-profile-changes/{cr.id}/approve/').status_code, 403)
        self.assertEqual(self.client.post(f'/api/dog-profile-changes/{cr.id}/reject/').status_code, 403)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.name, 'Fido')
        self.as_(self.requests_manager)
        self.assertEqual(self.client.post(f'/api/dog-profile-changes/{cr.id}/approve/').status_code, 200)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.name, 'Fidget')

    def test_posting_to_the_feed_needs_can_add_feed_media(self):
        import tempfile
        with tempfile.TemporaryDirectory() as media, override_settings(MEDIA_ROOT=media):
            self.as_(self.plain)
            resp = self.client.post(
                '/api/feed/', {'media_type': 'PHOTO', 'file': _png(), 'caption': 'x'}, format='multipart')
            self.assertEqual(resp.status_code, 403)
            self.assertEqual(GroupMedia.objects.count(), 0)
            self.as_(make_staff('poster', can_add_feed_media=True))
            resp = self.client.post(
                '/api/feed/', {'media_type': 'PHOTO', 'file': _png(), 'caption': 'x'}, format='multipart')
            self.assertEqual(resp.status_code, 201)

    def test_any_staff_member_can_still_edit_a_post(self):
        post = GroupMedia.objects.create(uploaded_by=self.assigner, media_type='PHOTO', caption='old')
        self.as_(self.plain)
        resp = self.client.patch(f'/api/feed/{post.id}/', {'caption': 'new'}, format='json')
        self.assertEqual(resp.status_code, 200)


# --- 6. Owner-proposed dog changes are validated ----------------------------

class ProposedDogChangeValidationTests(Base):
    def test_malformed_daycare_days_are_refused_when_proposed(self):
        self.as_(self.owner)
        for bad in ('abc', [9], ['x']):
            resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {'daycare_days': bad}, format='json')
            self.assertEqual(resp.status_code, 400, bad)
        resp = self.client.patch(
            f'/api/dogs/{self.dog.id}/', {'date_of_birth': 'not-a-date'}, format='json')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(DogProfileChangeRequest.objects.count(), 0)

    def test_day_numbers_sent_as_strings_are_stored_as_numbers(self):
        self.as_(self.owner)
        resp = self.client.patch(f'/api/dogs/{self.dog.id}/', {'daycare_days': ['5', '2']}, format='json')
        self.assertEqual(resp.status_code, 202)
        cr = DogProfileChangeRequest.objects.get(dog=self.dog)
        self.assertEqual(cr.proposed_changes['daycare_days'], [2, 5])
        self.as_(self.requests_manager)
        self.assertEqual(self.client.post(f'/api/dog-profile-changes/{cr.id}/approve/').status_code, 200)
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.daycare_days, [2, 5])

    def test_a_bad_stored_request_cannot_be_approved_onto_the_dog(self):
        # A row written before validation existed (or by hand).
        cr = DogProfileChangeRequest.objects.create(
            dog=self.dog, requested_by=self.owner,
            proposed_changes={'daycare_days': 'abc', 'name': 'Fidget'})
        self.as_(self.requests_manager)
        resp = self.client.post(f'/api/dog-profile-changes/{cr.id}/approve/')
        self.assertEqual(resp.status_code, 400)
        self.dog.refresh_from_db()
        cr.refresh_from_db()
        self.assertEqual(self.dog.daycare_days, [1, 3])
        self.assertEqual(self.dog.name, 'Fido')
        self.assertEqual(cr.status, 'PENDING')
        # The board still loads for a day that dog is rostered on.
        DogWeekdayPickup.objects.create(
            dog=self.dog, weekday=1, staff_member=self.assigner, created_by=self.assigner)
        self.assertEqual(
            self.client.get(f'/api/daily-assignments/today/?date={self.monday.isoformat()}').status_code, 200)

    def test_approval_is_all_or_nothing(self):
        cr = DogProfileChangeRequest.objects.create(
            dog=self.dog, requested_by=self.owner, proposed_changes={'name': 'Fidget'})
        self.as_(self.requests_manager)
        with patch('api.views._apply_schedule_change', side_effect=RuntimeError('boom')):
            with self.assertRaises(RuntimeError):
                self.client.post(f'/api/dog-profile-changes/{cr.id}/approve/')
        self.dog.refresh_from_db()
        cr.refresh_from_db()
        self.assertEqual(self.dog.name, 'Fido')
        self.assertEqual(cr.status, 'PENDING')


# --- 8 / 14. from_now_on cascades and the weekly roster ----------------------

class RosterCascadeTests(Base):
    def setUp(self):
        super().setUp()
        self.other = make_staff('other')
        self.first = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=self.monday)
        self.regular = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=self.monday + timedelta(days=7))
        self.extra = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=self.monday + timedelta(days=14),
            booking=DailyDogAssignment.BOOKING_EXTRA)
        self.boarding = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=self.assigner, date=self.monday + timedelta(days=21),
            from_boarding=True)

    def test_unassign_from_now_on_keeps_extra_and_boarding_days(self):
        self.as_(self.assigner)
        resp = self.client.post(
            f'/api/daily-assignments/{self.first.id}/unassign/', {'scope': 'from_now_on'}, format='json')
        self.assertEqual(resp.status_code, 204)
        left = set(DailyDogAssignment.objects.filter(dog=self.dog).values_list('id', flat=True))
        self.assertEqual(left, {self.extra.id, self.boarding.id})

    def test_reassign_from_now_on_moves_regular_days_only(self):
        self.as_(self.assigner)
        resp = self.client.post(
            f'/api/daily-assignments/{self.first.id}/reassign/',
            {'staff_member_id': self.other.id, 'scope': 'from_now_on'}, format='json')
        self.assertEqual(resp.status_code, 200)
        for row, expected in ((self.regular, self.other), (self.extra, self.assigner),
                              (self.boarding, self.assigner)):
            row.refresh_from_db()
            self.assertEqual(row.staff_member_id, expected.id)

    def test_claiming_an_extra_day_writes_no_weekly_roster_entry(self):
        tuesday = next_weekday(2)
        self.as_(self.assigner)
        resp = self.client.post('/api/daily-assignments/assign_to_me/', {
            'dog_ids': [self.dog.id], 'date': tuesday.isoformat()}, format='json')
        self.assertEqual(resp.status_code, 201)
        self.assertFalse(DogWeekdayPickup.objects.filter(dog=self.dog, weekday=2).exists())

    def test_claiming_a_regular_day_still_writes_the_roster_entry(self):
        wednesday = next_weekday(3)
        self.as_(self.assigner)
        self.client.post('/api/daily-assignments/assign_dogs/', {
            'dog_ids': [self.dog.id], 'staff_member_id': self.other.id,
            'date': wednesday.isoformat()}, format='json')
        entry = DogWeekdayPickup.objects.get(dog=self.dog, weekday=3)
        self.assertEqual(entry.staff_member_id, self.other.id)


# --- 9. Bad input is a 400, never a 500 --------------------------------------

class BadInputTests(Base):
    def test_query_parameters(self):
        self.as_(self.assigner)
        for url in (
            '/api/daily-assignments/?date=tomorrow',
            '/api/daily-assignments/?staff_member=bob',
            '/api/feed/?dog_id=abc',
            '/api/photos/by_dog/?dog_id=abc',
            '/api/profile/get_owner/?user_id=abc',
        ):
            self.assertEqual(self.client.get(url).status_code, 400, url)

    def test_bodies(self):
        self.as_(self.payments)
        cases = [
            ('/api/daily-assignments/assign_to_me/', {'dog_ids': ['abc']}),
            ('/api/daily-assignments/assign_to_me/', {'dog_ids': 7}),
            ('/api/daily-assignments/assign_to_me/', {'dog_ids': [self.dog.id], 'date': 20260101}),
            ('/api/daily-assignments/assign_dogs/',
             {'dog_ids': [self.dog.id], 'staff_member_id': 'bob'}),
            ('/api/daily-assignments/auto_assign/', {'date': 20260101}),
            ('/api/daily-assignments/acknowledge_changes/', {'date': 20260101}),
            ('/api/daily-assignments/mark_removed/', {'dog_id': 'abc', 'date': self.monday.isoformat()}),
            ('/api/daily-assignments/mark_removed/', {'dog_id': self.dog.id, 'date': 5}),
            ('/api/daily-assignments/owner_handovers/', {'leg': 'DROP_OFF', 'staff_member_id': 'bob'}),
            ('/api/daily-assignments/reorder/', {'assignment_ids': ['x']}),
            ('/api/daily-assignments/bulk_reassign/', {'assignment_ids': [1], 'staff_member_id': 'bob'}),
            ('/api/dogs/bulk_import/', {'names': [5]}),
            ('/api/dogs/bulk_import/', {'names': ['Rex'], 'owner': 'bob'}),
            (f'/api/dogs/{self.dog.id}/assign/', {'owner': 'bob'}),
            ('/api/profile/update_owner/?user_id=abc', {'phone_number': '1'}),
            ('/api/boarding-requests/', {
                'owner': 'bob', 'dogs': [self.dog.id],
                'start_date': self.monday.isoformat(),
                'end_date': (self.monday + timedelta(days=2)).isoformat()}),
            ('/api/boarding-requests/', {
                'owner': 999999, 'dogs': [self.dog.id],
                'start_date': self.monday.isoformat(),
                'end_date': (self.monday + timedelta(days=2)).isoformat()}),
        ]
        for url, body in cases:
            resp = self.client.post(url, body, format='json')
            self.assertEqual(resp.status_code, 400, (url, body, getattr(resp, 'data', None)))
        self.assertEqual(BoardingRequest.objects.count(), 0)

    def test_reassign_with_a_non_numeric_staff_id(self):
        row = DailyDogAssignment.objects.create(dog=self.dog, staff_member=self.assigner, date=self.monday)
        self.as_(self.assigner)
        resp = self.client.post(
            f'/api/daily-assignments/{row.id}/reassign/', {'staff_member_id': 'bob'}, format='json')
        self.assertEqual(resp.status_code, 400)


# --- 10. Rows with no driver ------------------------------------------------

class DriverlessRowTests(Base):
    def setUp(self):
        super().setUp()
        self.row = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=None, date=self.today, status='PICKED_UP')

    def test_photo_tagging_survives_a_row_with_no_driver(self):
        self.as_(self.plain)
        resp = self.client.get('/api/daily-assignments/photo_tagging/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['untagged'][0]['staff_member_name'], '')

    def test_a_driverless_row_can_be_claimed_and_keeps_its_progress(self):
        self.as_(self.plain)
        resp = self.client.post(
            '/api/daily-assignments/assign_to_me/', {'dog_ids': [self.dog.id]}, format='json')
        self.assertEqual(resp.status_code, 201)
        self.row.refresh_from_db()
        self.assertEqual(self.row.staff_member_id, self.plain.id)
        self.assertEqual(self.row.status, 'PICKED_UP')

    def test_a_dog_someone_has_is_still_reported_as_taken(self):
        self.row.staff_member = self.assigner
        self.row.save()
        self.as_(self.plain)
        resp = self.client.post(
            '/api/daily-assignments/assign_to_me/', {'dog_ids': [self.dog.id]}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data['skipped']), 1)
        self.row.refresh_from_db()
        self.assertEqual(self.row.staff_member_id, self.assigner.id)


# --- 11. Boarding decisions --------------------------------------------------

class BoardingDecisionTests(Base):
    def setUp(self):
        super().setUp()
        self.manager = make_staff('boarder', can_manage_boarding=True)
        self.stay = BoardingRequest.objects.create(
            owner=self.owner, start_date=self.monday, end_date=self.monday + timedelta(days=2))
        self.stay.dogs.add(self.dog)

    def _status(self, stay, status):
        return self.client.post(
            f'/api/boarding-requests/{stay.id}/change_status/', {'status': status}, format='json')

    def test_decision_and_history_are_written_once(self):
        self.as_(self.manager)
        self.assertEqual(self._status(self.stay, 'APPROVED').status_code, 200)
        self.assertEqual(self._status(self.stay, 'APPROVED').status_code, 200)
        self.stay.refresh_from_db()
        self.assertEqual(self.stay.status, 'APPROVED')
        self.assertEqual(BoardingRequestHistory.objects.filter(request=self.stay).count(), 1)

    def test_an_overlapping_stay_is_still_refused(self):
        other = BoardingRequest.objects.create(
            owner=self.owner, start_date=self.monday + timedelta(days=1),
            end_date=self.monday + timedelta(days=4))
        other.dogs.add(self.dog)
        self.as_(self.manager)
        self.assertEqual(self._status(self.stay, 'APPROVED').status_code, 200)
        resp = self._status(other, 'APPROVED')
        self.assertEqual(resp.status_code, 400)
        other.refresh_from_db()
        self.assertEqual(other.status, 'PENDING')
        self.assertFalse(BoardingRequestHistory.objects.filter(request=other).exists())


# --- 15. update_owner --------------------------------------------------------

class UpdateOwnerTests(Base):
    def _update(self, target, **body):
        return self.client.post(
            f'/api/profile/update_owner/?user_id={target.id}', body, format='json')

    def test_a_colleagues_details_need_can_manage_staff(self):
        self.as_(self.plain)
        resp = self._update(self.assigner, phone_number='07700 900999')
        self.assertEqual(resp.status_code, 403)
        self.assigner.profile.refresh_from_db()
        self.assertNotEqual(self.assigner.profile.phone_number, '07700 900999')
        self.as_(make_staff('hr', can_manage_staff=True))
        self.assertEqual(self._update(self.assigner, phone_number='07700 900999').status_code, 200)

    def test_any_staff_member_can_still_update_a_client(self):
        from .models import DogChangeLog
        self.as_(self.plain)
        resp = self._update(self.owner, phone_number='07700 900123')
        self.assertEqual(resp.status_code, 200)
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.phone_number, '07700 900123')
        self.assertTrue(DogChangeLog.objects.filter(category='CLIENTS').exists())


# --- Narrowed request lists and pending counts (staff badge) -----------------

class RequestListFilterTests(Base):
    def setUp(self):
        super().setUp()
        self.stranger = User.objects.create_user(username='other@example.com', password='pw')
        self.their_dog = Dog.objects.create(owner=self.stranger, name='Rex')
        self.pending = DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=self.monday)
        self.approved = DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY', new_date=self.monday + timedelta(days=1),
            status='APPROVED')
        self.theirs = DateChangeRequest.objects.create(
            dog=self.their_dog, request_type='CANCEL', original_date=self.monday)

    def _ids(self, url):
        resp = self.client.get(url)
        self.assertEqual(resp.status_code, 200, url)
        return sorted(row['id'] for row in resp.data)

    def test_date_change_list_is_unchanged_without_parameters(self):
        self.as_(self.plain)
        self.assertEqual(
            self._ids('/api/date-change-requests/'),
            sorted([self.pending.id, self.approved.id, self.theirs.id]))

    def test_date_change_status_and_dog_filters(self):
        self.as_(self.plain)
        self.assertEqual(
            self._ids('/api/date-change-requests/?status=PENDING'),
            sorted([self.pending.id, self.theirs.id]))
        self.assertEqual(
            self._ids(f'/api/date-change-requests/?dog={self.dog.id}'),
            sorted([self.pending.id, self.approved.id]))
        self.assertEqual(
            self._ids(f'/api/date-change-requests/?status=approved&dog={self.dog.id}'),
            [self.approved.id])

    def test_date_change_filters_never_widen_what_an_owner_sees(self):
        self.as_(self.owner)
        self.assertEqual(self._ids('/api/date-change-requests/?status=PENDING'), [self.pending.id])
        self.assertEqual(self._ids(f'/api/date-change-requests/?dog={self.their_dog.id}'), [])

    def test_date_change_bad_filter_values_are_refused(self):
        self.as_(self.plain)
        for url in ('/api/date-change-requests/?status=MAYBE', '/api/date-change-requests/?dog=abc'):
            self.assertEqual(self.client.get(url).status_code, 400, url)

    def test_a_filter_does_not_hide_a_detail_route(self):
        self.as_(self.plain)
        resp = self.client.get(f'/api/date-change-requests/{self.approved.id}/?status=PENDING')
        self.assertEqual(resp.status_code, 200)

    def test_date_change_pending_count(self):
        self.as_(self.plain)
        self.assertEqual(self.client.get('/api/date-change-requests/pending_count/').data, {'count': 2})
        self.as_(self.owner)
        self.assertEqual(self.client.get('/api/date-change-requests/pending_count/').data, {'count': 1})

    def _stays(self):
        def stay(owner, dog, offset, **fields):
            start = self.monday + timedelta(days=offset)
            row = BoardingRequest.objects.create(
                owner=owner, start_date=start, end_date=start + timedelta(days=2), **fields)
            row.dogs.add(dog)
            return row
        return {
            'pending': stay(self.owner, self.dog, 0),
            'approved': stay(self.owner, self.dog, 10, status='APPROVED'),
            'change_asked': stay(
                self.owner, self.dog, 20, status='APPROVED',
                requested_start_date=self.monday + timedelta(days=21),
                requested_end_date=self.monday + timedelta(days=23)),
            'denied': stay(self.owner, self.dog, 30, status='DENIED'),
            'theirs': stay(self.stranger, self.their_dog, 0),
        }

    def test_boarding_pending_includes_approved_stays_awaiting_a_change(self):
        stays = self._stays()
        self.as_(self.plain)
        self.assertEqual(
            self._ids('/api/boarding-requests/'), sorted(s.id for s in stays.values()))
        self.assertEqual(
            self._ids('/api/boarding-requests/?status=PENDING'),
            sorted([stays['pending'].id, stays['change_asked'].id, stays['theirs'].id]))
        self.assertEqual(
            self._ids('/api/boarding-requests/?status=APPROVED'),
            sorted([stays['approved'].id, stays['change_asked'].id]))
        self.assertEqual(self.client.get('/api/boarding-requests/pending_count/').data, {'count': 3})
        self.assertEqual(self.client.get('/api/boarding-requests/?status=SOON').status_code, 400)

    def test_boarding_owner_counts_only_their_own(self):
        stays = self._stays()
        self.as_(self.owner)
        self.assertEqual(
            self._ids('/api/boarding-requests/?status=PENDING'),
            sorted([stays['pending'].id, stays['change_asked'].id]))
        self.assertEqual(self.client.get('/api/boarding-requests/pending_count/').data, {'count': 2})
