"""Tests for the account, auth, request and billing-view fixes from the
November 2026 review of api/views.py (second half).

Each test fails against the code as it stood before the fix it names.
"""
from datetime import timedelta
from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth.models import User
from django.core.cache import cache
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from .models import (
    BoardingRequest, DailyDogAssignment, DayOffRequest, DeviceToken, Dog,
    DogChangeLog, DogLinkRequest, IntakeDog, IntakeRequest, Invoice,
    PasswordResetOTP, PaymentRecord, SupportMessage, SupportQuery,
)

STRONG_PW = 'Str0ngNewP@ss99'


def _next_weekday(start, weekday):
    """The first date on or after ``start`` that falls on ``weekday`` (0=Mon)."""
    return start + timedelta(days=(weekday - start.weekday()) % 7)


class ThrottleCase(TestCase):
    """Throttle counters live in the cache and outlast a test, so every case
    here starts and ends with an empty one."""

    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)


# ── 1. Password reset ───────────────────────────────────────────────────────

class PasswordResetGuessingTests(ThrottleCase):
    def setUp(self):
        super().setUp()
        self.user = User.objects.create_user(
            username='victim@example.com', email='victim@example.com', password='OldPass123!')
        self.otp = PasswordResetOTP.objects.create(
            user=self.user, otp='123456', expires_at=timezone.now() + timedelta(minutes=15))
        self.client = APIClient()

    def _guess(self, code, ip='10.0.0.1', client=None):
        return (client or self.client).post(
            '/api/password/reset/verify/', {'email': 'victim@example.com', 'otp': code},
            format='json', REMOTE_ADDR=ip)

    def test_code_is_burnt_after_five_wrong_guesses(self):
        for n in range(PasswordResetOTP.MAX_FAILED_ATTEMPTS):
            self.assertEqual(self._guess(f'00000{n}').status_code, 400)
        self.otp.refresh_from_db()
        self.assertTrue(self.otp.is_used)
        self.assertEqual(self.otp.failed_attempts, PasswordResetOTP.MAX_FAILED_ATTEMPTS)
        # The right code no longer works, and says nothing different.
        resp = self._guess('123456')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.data['detail'], 'Invalid or expired code.')

    def test_wrong_guesses_below_the_limit_leave_the_code_usable(self):
        for n in range(PasswordResetOTP.MAX_FAILED_ATTEMPTS - 1):
            self._guess(f'00000{n}')
        resp = self._guess('123456')
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.data['reset_token'])

    def test_a_signed_in_caller_is_throttled_like_anyone_else(self):
        # The hole: AnonRateThrottle skips any request with a valid token, and
        # anyone can sign up for one.
        attacker = User.objects.create_user(username='attacker', password='pw')
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f'Token {Token.objects.create(user=attacker).key}')
        codes = [client.post('/api/password/reset/verify/',
                             {'email': f'someone{n}@example.com', 'otp': '000000'},
                             format='json', REMOTE_ADDR='10.0.0.9').status_code
                 for n in range(11)]
        self.assertEqual(codes[:10], [400] * 10)
        self.assertEqual(codes[10], 429)

    def test_guesses_at_one_account_are_limited_across_addresses(self):
        codes = [self._guess('999999', ip=f'10.1.0.{n}').status_code for n in range(11)]
        self.assertEqual(codes[10], 429)

    def test_reset_emails_to_one_mailbox_are_limited_across_addresses(self):
        codes = [self.client.post('/api/password/reset/request/', {'email': 'Victim@Example.com'},
                                  format='json', REMOTE_ADDR=f'10.2.0.{n}').status_code
                 for n in range(6)]
        self.assertEqual(codes, [200] * 5 + [429])

    def test_signed_in_caller_cannot_flood_reset_requests(self):
        attacker = User.objects.create_user(username='attacker', password='pw')
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f'Token {Token.objects.create(user=attacker).key}')
        codes = [client.post('/api/password/reset/request/', {'email': f'p{n}@example.com'},
                             format='json', REMOTE_ADDR='10.0.0.9').status_code
                 for n in range(6)]
        self.assertEqual(codes, [200] * 5 + [429])


# ── S2. Token login ─────────────────────────────────────────────────────────

class LoginThrottleTests(ThrottleCase):
    def setUp(self):
        super().setUp()
        self.user = User.objects.create_user(username='rita@example.com', password=STRONG_PW)

    def _attempt(self, client, ip, username='rita@example.com', password='wrong'):
        return client.post('/auth/token/login/', {'username': username, 'password': password},
                           REMOTE_ADDR=ip).status_code

    def test_guessing_one_username_is_limited_across_addresses(self):
        client = APIClient()
        codes = [self._attempt(client, f'10.3.0.{n}') for n in range(11)]
        self.assertEqual(codes[:10], [400] * 10)
        self.assertEqual(codes[10], 429)
        # Case and spacing don't make it a different account.
        self.assertEqual(self._attempt(client, '10.3.9.9', username=' RITA@example.com '), 429)

    def test_sending_a_token_does_not_lift_the_limit(self):
        attacker = User.objects.create_user(username='attacker', password='pw')
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f'Token {Token.objects.create(user=attacker).key}')
        codes = [self._attempt(client, '10.3.1.1') for _ in range(11)]
        self.assertEqual(codes[10], 429)

    def test_one_address_is_limited_whatever_usernames_it_tries(self):
        client = APIClient()
        codes = [self._attempt(client, '10.3.2.2', username=f'u{n}@example.com') for n in range(31)]
        self.assertEqual(codes[30], 429)

    def test_a_normal_sign_in_still_works(self):
        resp = APIClient().post('/auth/token/login/',
                                {'username': 'rita@example.com', 'password': STRONG_PW})
        self.assertEqual(resp.status_code, 200)
        self.assertIn('auth_token', resp.data)

    def test_admin_sign_in_is_refused_after_repeated_failures(self):
        from django.test import Client
        from .throttles import ADMIN_LOGIN_MAX_FAILURES
        from django.conf import settings
        client = Client()
        # The login page renders admin CSS links; the manifest storage has no
        # manifest in a test run.
        plain_static = {**settings.STORAGES, 'staticfiles': {
            'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'}}
        with self.settings(STORAGES=plain_static):
            for _ in range(ADMIN_LOGIN_MAX_FAILURES):
                resp = client.post('/admin/login/', {'username': 'boss', 'password': 'nope'},
                                   REMOTE_ADDR='10.3.3.3')
                self.assertEqual(resp.status_code, 200)  # the form again, with an error
            resp = client.post('/admin/login/', {'username': 'boss', 'password': 'nope'},
                               REMOTE_ADDR='10.3.3.3')
            self.assertEqual(resp.status_code, 429)
            # Another address is unaffected.
            resp = client.post('/admin/login/', {'username': 'boss', 'password': 'nope'},
                               REMOTE_ADDR='10.3.3.4')
            self.assertEqual(resp.status_code, 200)


# ── S3. Contact form and postcode lookup ────────────────────────────────────

class PublicFormThrottleTests(ThrottleCase):
    def test_signed_in_caller_cannot_flood_the_contact_form(self):
        user = User.objects.create_user(username='someone', password='pw')
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f'Token {Token.objects.create(user=user).key}')
        codes = [client.post('/api/public/contact-inquiry/',
                             {'name': 'A', 'email': f'a{n}@example.com', 'service': 'daycare',
                              'message': f'Hello there, message number {n}'},
                             format='json', REMOTE_ADDR='10.4.0.1').status_code
                 for n in range(6)]
        self.assertNotIn(429, codes[:5])
        self.assertEqual(codes[5], 429)


@override_settings(POSTCODE_LOOKUP_API_KEY='k', POSTCODE_LOOKUP_PROVIDER='getaddress')
class PostcodeLookupCostTests(ThrottleCase):
    def setUp(self):
        super().setUp()
        self.client = APIClient()
        self.client.force_authenticate(User.objects.create_user(username='pc', password='pw'))

    @patch('api.views.lookup_addresses')
    def test_a_found_postcode_is_looked_up_once(self, mock_lookup):
        mock_lookup.return_value = [{'formatted': '1 High St', 'lines': ['1 High St'], 'postcode': 'SL6 1AA'}]
        first = self.client.get('/api/postcode/lookup/?postcode=sl6 1aa')
        second = self.client.get('/api/postcode/lookup/?postcode=SL61AA')
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertEqual(second.data['addresses'], first.data['addresses'])
        self.assertEqual(mock_lookup.call_count, 1)

    @patch('api.views.lookup_addresses')
    def test_a_failed_lookup_is_not_cached(self, mock_lookup):
        from .geocoding import PostcodeLookupError
        mock_lookup.side_effect = PostcodeLookupError('down')
        self.assertEqual(self.client.get('/api/postcode/lookup/?postcode=SL6 2BB').status_code, 502)
        mock_lookup.side_effect = None
        mock_lookup.return_value = [{'formatted': 'x', 'lines': ['x'], 'postcode': 'SL6 2BB'}]
        self.assertEqual(self.client.get('/api/postcode/lookup/?postcode=SL6 2BB').status_code, 200)

    @patch('api.views.lookup_addresses', return_value=[])
    def test_lookups_are_limited_per_user(self, mock_lookup):
        from .throttles import PostcodeLookupThrottle
        with patch.object(PostcodeLookupThrottle, 'get_rate', return_value='2/hour'):
            codes = [self.client.get(f'/api/postcode/lookup/?postcode=SL6 {n}ZZ').status_code
                     for n in range(3)]
        self.assertEqual(codes, [200, 200, 429])


# ── 2 & 3. Account deletion ─────────────────────────────────────────────────

class DeleteAccountTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(
            username='owner@example.com', email='owner@example.com', password='OldPass123!',
            first_name='Olive', last_name='Owner')
        self.client = APIClient()
        self.client.force_authenticate(self.owner)
        self.house = User.objects.create_user(username='P4TD', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Biscuit')

    def _delete(self, client=None):
        return (client or self.client).post(
            '/api/account/delete/', {'password': 'OldPass123!'}, format='json')

    def _approved_stay(self, start, end):
        from .scheduling import sync_boarding_daycare_assignments
        stay = BoardingRequest.objects.create(
            owner=self.owner, start_date=start, end_date=end, status='APPROVED')
        stay.dogs.add(self.dog)
        sync_boarding_daycare_assignments(stay)
        return stay

    def test_staff_cannot_delete_their_own_account(self):
        staff = User.objects.create_user(username='driver', password='OldPass123!', is_staff=True)
        thread = SupportQuery.objects.create(owner=self.owner, subject='Hello')
        SupportMessage.objects.create(query=thread, sender=staff, text='A staff reply')
        client = APIClient()
        client.force_authenticate(staff)

        resp = self._delete(client)

        self.assertEqual(resp.status_code, 403)
        self.assertIn('manager', resp.data['detail'])
        self.assertTrue(User.objects.filter(pk=staff.pk, is_active=True).exists())
        self.assertEqual(SupportMessage.objects.filter(sender=staff).count(), 1)

    def test_upcoming_boarding_is_cancelled_and_its_daycare_days_released(self):
        monday = _next_weekday(timezone.localdate() + timedelta(days=7), 0)
        stay = self._approved_stay(monday, monday + timedelta(days=2))
        self.assertTrue(DailyDogAssignment.objects.filter(dog=self.dog, from_boarding=True).exists())

        self.assertEqual(self._delete().status_code, 200)

        # Nothing left booked in under the house account for a stay that is gone.
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog, from_boarding=True).exists())
        self.assertFalse(BoardingRequest.objects.filter(pk=stay.pk, status='APPROVED').exists())
        self.assertTrue(DogChangeLog.objects.filter(
            category='BOOKINGS', summary__contains='deleted their account').exists())
        # No stay had started and nothing is invoiced, so it is a real delete.
        self.assertFalse(User.objects.filter(pk=self.owner.pk).exists())

    def test_a_stay_already_under_way_is_kept_and_the_account_emptied(self):
        today = timezone.localdate()
        stay = self._approved_stay(today - timedelta(days=1), today + timedelta(days=2))

        self.assertEqual(self._delete().status_code, 200)

        stay.refresh_from_db()
        self.assertEqual(stay.status, 'APPROVED')
        self.owner.refresh_from_db()
        self.assertFalse(self.owner.is_active)
        self.assertEqual(self.owner.email, '')

    def test_anonymised_account_is_unreachable_and_its_requests_scrubbed(self):
        Invoice.objects.create(customer=self.owner, period_year=2026, period_month=6,
                               status='SENT', total=Decimal('40.00'))
        DeviceToken.objects.create(user=self.owner, token='fcm-token-1', device_type='IOS')
        Token.objects.create(user=self.owner)
        reviewed = IntakeRequest.objects.create(
            owner=self.owner, phone_number='07700 900123', emergency_contact_number='07700 900456',
            address='1 High Street', postcode='SL6 1AA', pickup_instructions='Key under the mat',
            additional_info='Nervous of vans', status='APPROVED')
        IntakeDog.objects.create(request=reviewed, name='Biscuit', created_dog=self.dog)
        pending = IntakeRequest.objects.create(owner=self.owner, phone_number='07700 900123')
        linked = DogLinkRequest.objects.create(
            owner=self.owner, dog_name='Biscuit', postcode='SL6 1AA', phone_number='07700 900123',
            notes='My partner usually drops him off', status='APPROVED', dog=self.dog)
        waiting = DogLinkRequest.objects.create(owner=self.owner, dog_name='Other')
        shared = Dog.objects.create(name='Shared', owner=User.objects.create_user(username='partner'))
        shared.additional_owners.add(self.owner)

        self.assertEqual(self._delete().status_code, 200)

        self.owner.refresh_from_db()
        self.assertFalse(self.owner.is_active)
        # Nothing reaches the person or signs in as them.
        self.assertFalse(DeviceToken.objects.filter(user=self.owner).exists())
        self.assertFalse(Token.objects.filter(user=self.owner).exists())
        # The dog is ownerless, as a hard delete leaves it — not "deleted-user-N"'s.
        self.dog.refresh_from_db()
        self.assertIsNone(self.dog.owner_id)
        self.assertFalse(shared.additional_owners.filter(pk=self.owner.pk).exists())
        # Reviewed requests keep the decision and lose the contact details.
        reviewed.refresh_from_db()
        self.assertEqual(reviewed.status, 'APPROVED')
        for field in ('phone_number', 'emergency_contact_number', 'address', 'postcode',
                      'pickup_instructions', 'additional_info'):
            self.assertEqual(getattr(reviewed, field), '', field)
        linked.refresh_from_db()
        self.assertEqual((linked.status, linked.dog_id), ('APPROVED', self.dog.id))
        self.assertEqual((linked.phone_number, linked.postcode, linked.notes), ('', '', ''))
        # Undecided ones go altogether.
        self.assertFalse(IntakeRequest.objects.filter(pk=pending.pk).exists())
        self.assertFalse(DogLinkRequest.objects.filter(pk=waiting.pk).exists())
        # The ledger is untouched.
        self.assertEqual(Invoice.objects.filter(customer=self.owner).count(), 1)

    def test_anonymising_strips_staff_status(self):
        from .views import _anonymise_user
        staff = User.objects.create_user(username='leaver', password='pw', is_staff=True, is_superuser=True)
        _anonymise_user(staff)
        staff.refresh_from_db()
        self.assertFalse(staff.is_staff)
        self.assertFalse(staff.is_superuser)


# ── 4. Day-off requests ─────────────────────────────────────────────────────

class DayOffRequestUpdateTests(TestCase):
    def setUp(self):
        self.staff = User.objects.create_user(username='sam', password='pw', is_staff=True, first_name='Sam')
        self.other = User.objects.create_user(username='alex', password='pw', is_staff=True)
        self.manager = User.objects.create_user(username='boss', password='pw', is_staff=True)
        self.manager.profile.can_manage_staff = True
        self.manager.profile.save()
        self.day = timezone.localdate() + timedelta(days=30)
        self.client = APIClient()
        self.client.force_authenticate(self.staff)

    def _request(self, status='PENDING', staff=None, day=None):
        return DayOffRequest.objects.create(
            staff_member=staff or self.staff, date=day or self.day, status=status, reason='Dentist')

    def test_an_approved_day_off_cannot_be_moved(self):
        req = self._request('APPROVED')
        new_day = self.day + timedelta(days=5)
        for method in (self.client.patch, self.client.put):
            resp = method(f'/api/day-off-requests/{req.id}/', {'date': new_day.isoformat()}, format='json')
            self.assertEqual(resp.status_code, 400)
        req.refresh_from_db()
        self.assertEqual(req.date, self.day)

    def test_a_denied_request_cannot_be_edited_either(self):
        req = self._request('DENIED')
        resp = self.client.patch(f'/api/day-off-requests/{req.id}/', {'reason': 'Please'}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_own_pending_request_can_be_changed_and_is_logged(self):
        req = self._request()
        new_day = self.day + timedelta(days=5)
        resp = self.client.patch(f'/api/day-off-requests/{req.id}/', {'date': new_day.isoformat()}, format='json')
        self.assertEqual(resp.status_code, 200)
        req.refresh_from_db()
        self.assertEqual((req.date, req.status), (new_day, 'PENDING'))
        self.assertTrue(DogChangeLog.objects.filter(
            category='STAFF', action='UPDATED', summary__contains='day-off request').exists())

    def test_cannot_move_onto_a_day_already_requested(self):
        req = self._request()
        taken = self.day + timedelta(days=1)
        self._request('APPROVED', day=taken)
        resp = self.client.patch(f'/api/day-off-requests/{req.id}/', {'date': taken.isoformat()}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_someone_elses_request_is_out_of_reach_but_a_manager_can_edit_it(self):
        req = self._request(staff=self.other)
        resp = self.client.patch(f'/api/day-off-requests/{req.id}/', {'reason': 'x'}, format='json')
        self.assertEqual(resp.status_code, 404)
        manager = APIClient()
        manager.force_authenticate(self.manager)
        resp = manager.patch(f'/api/day-off-requests/{req.id}/', {'reason': 'Moved by manager'}, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_a_date_that_is_not_a_string_is_a_400(self):
        resp = self.client.post('/api/day-off-requests/', {'date': 20261224}, format='json')
        self.assertEqual(resp.status_code, 400)


# ── 5. Booking form and link request approval ───────────────────────────────

class RequestApprovalAtomicityTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='client@example.com', password='pw', first_name='Cleo')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True)
        self.client = APIClient()
        self.client.force_authenticate(self.staff)
        self.client.raise_request_exception = False

    def test_a_failed_booking_form_approval_creates_no_dogs(self):
        form = IntakeRequest.objects.create(
            owner=self.owner, phone_number='07700 900123', emergency_contact_number='07700 900456')
        IntakeDog.objects.create(request=form, name='Ant')
        IntakeDog.objects.create(request=form, name='Dec')
        calls = []

        def fail_on_second(self_, intake_dog, dog):
            calls.append(intake_dog.name)
            if len(calls) == 2:
                raise RuntimeError('certificate file missing')
            return False

        with patch('api.views.IntakeRequestViewSet._file_intake_certificate', fail_on_second):
            resp = self.client.post(f'/api/intake-requests/{form.id}/approve/')

        self.assertEqual(resp.status_code, 500)
        form.refresh_from_db()
        self.assertEqual(form.status, 'PENDING')
        # Before: Ant existed already, and the retry made a second Ant.
        self.assertEqual(Dog.objects.count(), 0)

        resp = self.client.post(f'/api/intake-requests/{form.id}/approve/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(sorted(Dog.objects.values_list('name', flat=True)), ['Ant', 'Dec'])
        # And once approved, a repeat is refused rather than repeated.
        resp = self.client.post(f'/api/intake-requests/{form.id}/approve/')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(Dog.objects.count(), 2)

    def test_a_failed_link_approval_leaves_the_dog_alone(self):
        dog = Dog.objects.create(name='Rex')
        link = DogLinkRequest.objects.create(owner=self.owner, dog_name='Rex', phone_number='07700 900123')

        with patch('api.views.DogLinkRequestViewSet._log', side_effect=RuntimeError('boom')):
            resp = self.client.post(f'/api/dog-link-requests/{link.id}/approve/', {'dog': dog.id}, format='json')

        self.assertEqual(resp.status_code, 500)
        dog.refresh_from_db()
        link.refresh_from_db()
        self.assertIsNone(dog.owner_id)
        self.assertEqual(dog.contact_number, '')
        self.assertEqual(link.status, 'PENDING')

        resp = self.client.post(f'/api/dog-link-requests/{link.id}/approve/', {'dog': dog.id}, format='json')
        self.assertEqual(resp.status_code, 200)
        dog.refresh_from_db()
        self.assertEqual(dog.owner_id, self.owner.id)


# ── 6, 10, 12, 13. Invoices and money ───────────────────────────────────────

class InvoiceViewGuardTests(TestCase):
    def setUp(self):
        self.manager = User.objects.create_user(username='money', password='pw', is_staff=True)
        self.manager.profile.can_manage_payments = True
        self.manager.profile.save()
        self.customer = User.objects.create_user(username='cust@example.com', password='pw')
        self.invoice = Invoice.objects.create(
            customer=self.customer, period_year=2026, period_month=10, status='SENT',
            total=Decimal('100.00'))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)

    def _pay(self, amount, **extra):
        return self.client.post(f'/api/invoices/{self.invoice.id}/record_payment/',
                                {'amount': amount, 'method': 'CASH', **extra}, format='json')

    def test_a_payment_cannot_exceed_what_is_outstanding(self):
        self.assertEqual(self._pay('60.00').status_code, 200)
        resp = self._pay('40.01')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.data['code'], 'exceeds_balance')
        self.assertEqual(resp.data['balance'], '40.00')
        self.assertEqual(self._pay('40.00').status_code, 200)
        self.invoice.refresh_from_db()
        self.assertEqual((self.invoice.status, self.invoice.amount_paid), ('PAID', Decimal('100.00')))

    def test_a_paid_invoice_takes_no_more_payments(self):
        self.assertEqual(self._pay('100.00').status_code, 200)
        resp = self._pay('5.00')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(PaymentRecord.objects.filter(invoice=self.invoice).count(), 1)

    def test_an_identical_payment_straight_after_is_taken_for_a_repeat(self):
        self.assertEqual(self._pay('20.00').status_code, 200)
        resp = self._pay('20.00')
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.data['code'], 'duplicate_payment')
        self.assertEqual(PaymentRecord.objects.filter(invoice=self.invoice).count(), 1)
        # A different amount, or saying it is deliberate, goes through.
        self.assertEqual(self._pay('25.00').status_code, 200)
        self.assertEqual(self._pay('20.00', confirm_duplicate=True).status_code, 200)

    def test_an_identical_payment_later_on_is_a_second_payment(self):
        self.assertEqual(self._pay('20.00').status_code, 200)
        PaymentRecord.objects.filter(invoice=self.invoice).update(
            created_at=timezone.now() - timedelta(minutes=5))
        self.assertEqual(self._pay('20.00').status_code, 200)

    def test_no_payment_on_an_invoice_that_is_mid_send(self):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='SENDING')
        self.assertEqual(self._pay('10.00').status_code, 400)
        self.assertFalse(PaymentRecord.objects.filter(invoice=self.invoice).exists())

    def test_amounts_are_rounded_to_pence(self):
        self.assertEqual(self._pay('10.005').status_code, 200)
        self.assertEqual(PaymentRecord.objects.get(invoice=self.invoice).amount, Decimal('10.01'))

    def test_an_invoice_being_sent_cannot_be_voided_until_the_claim_is_stale(self):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='SENDING', updated_at=timezone.now())
        resp = self.client.post(f'/api/invoices/{self.invoice.id}/void/')
        self.assertEqual(resp.status_code, 409)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'SENDING')

        Invoice.objects.filter(pk=self.invoice.pk).update(updated_at=timezone.now() - timedelta(minutes=10))
        resp = self.client.post(f'/api/invoices/{self.invoice.id}/void/')
        self.assertEqual(resp.status_code, 200)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'VOID')

    def test_amounts_that_are_not_numbers_are_400_everywhere(self):
        draft = Invoice.objects.create(customer=self.customer, period_year=2026, period_month=11,
                                       status='DRAFT', total=Decimal('50.00'))
        for bad in ('NaN', 'Infinity', '-Infinity', '1e12', 'abc', None, True):
            with self.subTest(amount=bad):
                self.assertEqual(self._pay(bad).status_code, 400)
                resp = self.client.post(f'/api/invoices/{draft.id}/add_line/',
                                        {'amount': bad, 'description': 'Lead'}, format='json')
                self.assertEqual(resp.status_code, 400)
                if bad is None:
                    continue  # null is "back to the standard price" for a customer rate
                resp = self.client.patch('/api/billing-settings/', {'day_care_price_1_day': bad}, format='json')
                self.assertEqual(resp.status_code, 400)
                resp = self.client.post(f'/api/customer-rates/?user_id={self.customer.id}',
                                        {'daycare_rate': bad}, format='json')
                self.assertEqual(resp.status_code, 400)

    def test_a_discount_line_may_still_be_negative(self):
        draft = Invoice.objects.create(customer=self.customer, period_year=2026, period_month=11,
                                       status='DRAFT', total=Decimal('50.00'))
        resp = self.client.post(f'/api/invoices/{draft.id}/add_line/',
                                {'amount': '-5.00', 'description': 'Loyalty discount'}, format='json')
        self.assertEqual(resp.status_code, 200)

    def test_overdue_is_judged_on_the_uk_date(self):
        # 23:30 UTC on 30 June is 00:30 on 1 July in the UK: an invoice due on
        # the 30th is overdue here, though UTC still calls it the 30th.
        from datetime import date, datetime, timezone as dt_timezone
        Invoice.objects.filter(pk=self.invoice.pk).update(due_date=date(2026, 6, 30))
        with patch('django.utils.timezone.now',
                   return_value=datetime(2026, 6, 30, 23, 30, tzinfo=dt_timezone.utc)):
            resp = self.client.get('/api/invoices/summary/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['overdue_count'], 1)


# ── 8, 9, 14. Contact Staff threads ─────────────────────────────────────────

class SupportThreadTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='client@example.com', password='pw', first_name='Cleo')
        self.staff = User.objects.create_user(username='staff', password='pw', is_staff=True, first_name='Sam')
        self.staff.profile.can_reply_queries = True
        self.staff.profile.save()
        self.thread = SupportQuery.objects.create(owner=self.owner, subject='Collar')
        SupportMessage.objects.create(query=self.thread, sender=self.owner, text='Has anyone seen it?')
        SupportMessage.objects.create(query=self.thread, sender=self.staff, text='Found it!')
        self.as_owner = APIClient()
        self.as_owner.force_authenticate(self.owner)
        self.as_staff = APIClient()
        self.as_staff.force_authenticate(self.staff)

    def test_a_thread_cannot_be_deleted_or_retitled(self):
        url = f'/api/support-queries/{self.thread.id}/'
        for client in (self.as_owner, self.as_staff):
            self.assertEqual(client.delete(url).status_code, 405)
            self.assertEqual(client.patch(url, {'subject': 'x'}, format='json').status_code, 405)
            self.assertEqual(client.put(url, {'subject': 'x'}, format='json').status_code, 405)
        self.thread.refresh_from_db()
        self.assertEqual(self.thread.subject, 'Collar')
        self.assertEqual(self.thread.messages.count(), 2)

    def test_an_owner_message_on_a_resolved_thread_reopens_it(self):
        self.assertEqual(self.as_staff.post(f'/api/support-queries/{self.thread.id}/resolve/').status_code, 200)
        self.assertEqual(self.as_staff.get('/api/support-queries/unresolved_count/').data['count'], 0)

        resp = self.as_owner.post(f'/api/support-queries/{self.thread.id}/add_message/',
                                  {'text': 'Actually it was the wrong collar'}, format='json')

        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.data['status'], 'OPEN')
        self.thread.refresh_from_db()
        self.assertIsNone(self.thread.resolved_at)
        self.assertEqual(self.as_staff.get('/api/support-queries/unresolved_count/').data['count'], 1)

    def test_a_staff_message_on_a_resolved_thread_leaves_it_resolved(self):
        self.as_staff.post(f'/api/support-queries/{self.thread.id}/resolve/')
        self.as_staff.post(f'/api/support-queries/{self.thread.id}/add_message/',
                           {'text': 'PS it is on the hook'}, format='json')
        self.thread.refresh_from_db()
        self.assertEqual(self.thread.status, 'RESOLVED')

    def test_the_list_carries_the_same_numbers_without_loading_messages(self):
        empty = SupportQuery.objects.create(owner=self.owner, subject='No messages yet')
        last = self.thread.messages.order_by('-created_at').first().created_at

        def fetch():
            with CaptureQueriesContext(connection) as queries:
                resp = self.as_staff.get('/api/support-queries/')
            self.assertEqual(resp.status_code, 200)
            return resp, len(queries)

        resp, before = fetch()
        rows = {row['id']: row for row in resp.data}
        self.assertEqual(rows[self.thread.id]['message_count'], 2)
        self.assertEqual(rows[self.thread.id]['last_message_at'], last.isoformat())
        self.assertEqual(rows[empty.id]['message_count'], 0)
        self.assertEqual(rows[empty.id]['last_message_at'], empty.created_at.isoformat())
        self.assertEqual(rows[self.thread.id]['owner_name'], 'Cleo')

        # More threads, more owners, more messages: no more queries.
        for n in range(5):
            other = User.objects.create_user(username=f'c{n}@example.com', first_name=f'C{n}')
            Dog.objects.create(owner=other, name=f'Dog{n}')
            thread = SupportQuery.objects.create(owner=other, subject=f'Thread {n}')
            SupportMessage.objects.create(query=thread, sender=other, text='Hi')
        _, after = fetch()
        self.assertEqual(after, before)
        self.assertLessEqual(after, 3)

    def test_owner_only_lists_their_own_threads(self):
        stranger = User.objects.create_user(username='other@example.com')
        SupportQuery.objects.create(owner=stranger, subject='Private')
        resp = self.as_owner.get('/api/support-queries/')
        self.assertEqual([row['id'] for row in resp.data], [self.thread.id])


# ── 15. Bad input ───────────────────────────────────────────────────────────

class BadInputTests(TestCase):
    def setUp(self):
        self.manager = User.objects.create_user(username='boss', password='pw', is_staff=True, is_superuser=True)
        self.client = APIClient()
        self.client.force_authenticate(self.manager)

    def test_malformed_filters_are_400_not_500(self):
        urls = [
            '/api/closure-days/?from_date=soon',
            '/api/closure-days/?to_date=2026-13-45',
            '/api/dog-addresses/?dog=abc',
            '/api/vaccinations/?dog=abc',
            '/api/vaccination-certificates/?dog=abc',
            '/api/waitlist/?date=tomorrow',
            '/api/dog-notes/?dog_id=abc',
            '/api/dog-change-logs/?dog=abc',
            '/api/dog-change-logs/?actor=abc',
            '/api/staff-availability/?staff_member=abc',
            '/api/vehicle-defects/?vehicle=abc',
            '/api/incidents/?dog=abc',
            '/api/invoices/?year=abc',
            '/api/invoices/?month=abc',
            '/api/invoices/?customer=abc',
            '/api/invoices/summary/?year=abc',
            '/api/staff-pay-rates/?staff_member=abc',
            '/api/staff-meetings/?staff_member=abc',
            '/api/staff-appraisals/?staff_member=abc',
            '/api/staff-absences/?staff_member=abc',
            '/api/staff-training/?staff_member=abc',
            '/api/staff-certifications/?staff_member=abc',
            '/api/compliance-logs/?check_type=abc',
        ]
        for url in urls:
            with self.subTest(url=url):
                self.assertEqual(self.client.get(url).status_code, 400)

    def test_well_formed_filters_still_work(self):
        for url in ('/api/closure-days/?from_date=2026-01-01&to_date=2026-12-31',
                    '/api/dog-change-logs/?actor=system', f'/api/dog-change-logs/?actor={self.manager.id}',
                    '/api/invoices/?year=2026&month=10', '/api/staff-absences/?staff_member=1',
                    '/api/waitlist/?date=2026-12-01'):
            with self.subTest(url=url):
                self.assertEqual(self.client.get(url).status_code, 200)

    def test_availability_entries_that_are_not_objects_are_ignored(self):
        resp = self.client.post('/api/staff-availability/set_my_availability/',
                                {'availability': ['monday', 3, {'day_of_week': 2, 'is_available': False}]},
                                format='json')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual([row['day_of_week'] for row in resp.data], [2])

    def test_waitlist_dog_that_is_not_an_id_is_a_404(self):
        day = (timezone.localdate() + timedelta(days=10)).isoformat()
        resp = self.client.post('/api/waitlist/', {'dog': 'abc', 'date': day}, format='json')
        self.assertEqual(resp.status_code, 404)

    def test_support_thread_for_an_owner_id_that_is_not_a_number(self):
        resp = self.client.post('/api/support-queries/', {'subject': 'Hi', 'owner_id': 'abc'}, format='json')
        self.assertEqual(resp.status_code, 400)
