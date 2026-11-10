"""Tests for the billing / scheduling / Xero / routing review fixes.

Each class covers one finding from the review. Fifty of these tests fail on
the code as it was; the other thirteen pass both before and after and are
here to pin down what the fixes must NOT change (a dog with no app invoice
history is billed exactly as before, a date charged as a boarding night is
never charged again as daycare, a send in flight is left alone, ...). No
test touches the network: Xero and OpenRouteService are patched
at ``api.xero._api_request`` / ``api.xero.fetch_invoices`` /
``api.routing.fetch_drive_times``, the way ``api/tests.py`` does it.

Dates: June 2026 starts on a Monday, May 2026 on a Friday.
"""
from datetime import date, datetime, timedelta, timezone as dt_timezone
from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth.models import User
from django.db import IntegrityError
from django.test import override_settings
from django.test import TestCase
from django.utils import timezone

from api import billing, routing, scheduling, xero
from api.models import (
    BoardingRequest, ClosureDay, DailyDogAssignment, DateChangeRequest, Dog,
    Invoice, InvoiceLine, PaymentRecord, XeroConnection,
)
from api.tests import BillingTestsBase  # noqa: F401  (fixtures; it has no tests of its own)

WEEKDAYS = [1, 2, 3, 4, 5]


def _connect_xero():
    conn = XeroConnection.load()
    conn.tenant_id = 'tenant-1'
    conn.refresh_token = 'refresh-1'
    conn.access_token = 'access-1'
    conn.access_token_expires_at = timezone.now() + timedelta(minutes=20)
    conn.save()
    return conn


@override_settings(BILLING_CATCH_UP_MONTHS=12)
class ReviewBillingBase(BillingTestsBase):
    def setUp(self):
        from website.models import ServicePricing

        super().setUp()
        pricing = ServicePricing.load()
        pricing.boarding_price_per_night = 40
        pricing.save()

    def _generate(self, year, month, **kwargs):
        created, _, _ = billing.generate_invoices_for_month(year, month, **kwargs)
        return created

    def _send(self, *invoices):
        for invoice in invoices:
            Invoice.objects.filter(pk=invoice.pk).update(status='SENT')
            invoice.refresh_from_db()

    def _stay(self, start, end, dog=None, status='APPROVED'):
        stay = BoardingRequest.objects.create(
            owner=self.owner, start_date=start, end_date=end, status=status)
        stay.dogs.add(dog or self.dog)
        return stay

    @staticmethod
    def _kind_dates(invoice, kind):
        return [
            d for line in invoice.lines.filter(is_adjustment=False).order_by('id')
            if billing.line_kind(line.description) == kind
            for d in line.attendance_dates
        ]

    @staticmethod
    def _lines_sum(invoice):
        return sum((line.line_total for line in invoice.lines.all()), Decimal('0.00'))


# ─── 1. Boarding nights on dates already invoiced as daycare ─────────────────

class BoardingNightAfterInvoiceTests(ReviewBillingBase):
    """A stay booked after the month's invoice went out: its nights used to be
    dropped wherever the date was already charged as a daycare day."""

    def setUp(self):
        super().setUp()
        self.dog.daycare_days = WEEKDAYS
        self.dog.save()
        # May is invoiced (21 weekdays at £25) and sent before any stay exists.
        self.may = self._generate(2026, 5)[0]
        self.assertEqual(self.may.total, Decimal('525.00'))
        self._send(self.may)

    def _late_stay(self):
        # Mon 11 May → Mon 18 May: nights of the 11th..17th, five of them weekdays.
        return self._stay(date(2026, 5, 11), date(2026, 5, 18))

    def test_every_night_is_charged_and_the_day_comes_back_as_a_credit(self):
        self._late_stay()
        june = self._generate(2026, 6)[0]

        nights = self._kind_dates(june, billing.LINE_BOARDING)
        self.assertEqual(nights, [f'2026-05-{d}' for d in range(11, 18)])
        credits = self._kind_dates(june, billing.LINE_CREDIT)
        self.assertEqual(credits, [f'2026-05-{d}' for d in range(11, 16)])
        credit_lines = [l for l in june.lines.all() if billing.line_kind(l.description) == billing.LINE_CREDIT]
        self.assertEqual({l.line_total for l in credit_lines}, {Decimal('-25.00')})
        self.assertEqual(
            credit_lines[0].description,
            'Credit — Biscuit — Mon 11/05/2026 (daycare day charged on your May 2026 invoice; '
            'replaced by the boarding night)')
        # 7 nights at £40, less the 5 days already paid at £25, plus June's 22 days.
        self.assertEqual(june.total, Decimal('705.00'))
        self.assertEqual(june.total, self._lines_sum(june))
        # Across both invoices the stay costs the nights and nothing else:
        # the five boarded weekdays net to £40 each, not £25 + £40.
        may_and_stay = self.may.total + Decimal('280.00') - Decimal('125.00')
        self.assertEqual(may_and_stay, Decimal('16') * 25 + Decimal('7') * 40)

    def test_credit_sits_straight_after_its_night(self):
        self._late_stay()
        june = self._generate(2026, 6)[0]
        lines = list(june.lines.order_by('id'))
        self.assertTrue(lines[0].description.startswith('Boarding — Biscuit — night of Mon 11/05/2026'))
        self.assertTrue(lines[1].description.startswith('Credit — Biscuit — Mon 11/05/2026'))

    def test_regenerating_the_draft_changes_nothing(self):
        self._late_stay()
        june = self._generate(2026, 6)[0]
        before = [(l.description, l.line_total, l.attendance_dates) for l in june.lines.order_by('id')]
        for _ in range(2):
            billing.regenerate_draft(june)
        june.refresh_from_db()
        after = [(l.description, l.line_total, l.attendance_dates) for l in june.lines.order_by('id')]
        self.assertEqual(after, before)
        self.assertEqual(june.total, Decimal('705.00'))

    def test_credit_and_night_are_given_once_ever(self):
        self._late_stay()
        june = self._generate(2026, 6)[0]
        self._send(june)
        july = self._generate(2026, 7)[0]
        self.assertEqual(self._kind_dates(july, billing.LINE_CREDIT), [])
        self.assertEqual(self._kind_dates(july, billing.LINE_BOARDING), [])
        self.assertTrue(all(d.startswith('2026-07') for d in self._dates(july)))
        all_credits = InvoiceLine.objects.filter(description__startswith='Credit').count()
        self.assertEqual(all_credits, 5)

    def test_voiding_the_invoice_frees_night_and_credit_for_the_next_one(self):
        self._late_stay()
        june = self._generate(2026, 6)[0]
        self._send(june)
        Invoice.objects.filter(pk=june.pk).update(status='VOID')

        again = self._generate(2026, 6)[0]
        self.assertEqual(len(self._kind_dates(again, billing.LINE_BOARDING)), 7)
        self.assertEqual(len(self._kind_dates(again, billing.LINE_CREDIT)), 5)
        self.assertEqual(again.total, Decimal('705.00'))

    def test_no_credit_when_the_daycare_invoice_was_voided(self):
        """Nothing was charged for the day, so there is nothing to give back."""
        Invoice.objects.filter(pk=self.may.pk).update(status='VOID')
        self._late_stay()
        june = self._generate(2026, 6)[0]
        self.assertEqual(self._kind_dates(june, billing.LINE_CREDIT), [])
        self.assertGreaterEqual(june.total, Decimal('550.00'))

    def test_stay_spanning_the_month_end(self):
        # Thu 28 May → Wed 3 June: nights 28, 29, 30, 31 May and 1, 2 June.
        self._stay(date(2026, 5, 28), date(2026, 6, 3))
        june = self._generate(2026, 6)[0]

        self.assertEqual(
            self._kind_dates(june, billing.LINE_BOARDING),
            ['2026-05-28', '2026-05-29', '2026-05-30', '2026-05-31', '2026-06-01', '2026-06-02'])
        # Only the two May weekdays had been charged as daycare.
        self.assertEqual(self._kind_dates(june, billing.LINE_CREDIT), ['2026-05-28', '2026-05-29'])
        daycare = self._kind_dates(june, billing.LINE_DAYCARE)
        # June's boarded days (1st–3rd) are not booked as daycare at all.
        self.assertEqual(len(daycare), 19)
        self.assertFalse({'2026-06-01', '2026-06-02', '2026-06-03'} & set(daycare))
        self.assertEqual(june.total, Decimal('6') * 40 - Decimal('2') * 25 + Decimal('19') * 25)
        may_night = june.lines.get(description__startswith='Boarding', attendance_dates=['2026-05-28'])
        self.assertIn('extra night in May', may_night.description)
        june_night = june.lines.get(description__startswith='Boarding', attendance_dates=['2026-06-01'])
        self.assertNotIn('extra', june_night.description)

    def test_stay_cancelled_while_the_invoice_is_a_draft(self):
        stay = self._late_stay()
        june = self._generate(2026, 6)[0]
        stay.status = 'CANCELLED'
        stay.save()
        billing.regenerate_draft(june)
        june.refresh_from_db()
        self.assertEqual(self._kind_dates(june, billing.LINE_BOARDING), [])
        self.assertEqual(self._kind_dates(june, billing.LINE_CREDIT), [])
        self.assertEqual(june.total, Decimal('550.00'))

    def test_stay_cancelled_after_the_invoice_went_out_charges_nothing_more(self):
        """The night stays charged (a refund is a staff adjustment, as for any
        cancellation after invoicing) — but the date is never charged again as
        daycare and never credited twice."""
        stay = self._late_stay()
        june = self._generate(2026, 6)[0]
        self._send(june)
        stay.status = 'CANCELLED'
        stay.save()
        for day in range(11, 16):  # the dog came to daycare after all
            self._attend(self.dog, day, month=5)

        july = self._generate(2026, 7)[0]
        self.assertTrue(all(d.startswith('2026-07') for d in self._dates(july)))
        self.assertEqual(InvoiceLine.objects.filter(description__startswith='Credit').count(), 5)

    def test_night_waits_while_the_day_sits_on_an_unsent_draft(self):
        """The daycare charge is still on a draft, which a regenerate will
        take the day off. Charging the night elsewhere meanwhile would put the
        date on two invoices at once."""
        Invoice.objects.filter(pk=self.may.pk).update(status='DRAFT')
        self.may.refresh_from_db()
        self._late_stay()

        june = self._generate(2026, 6)[0]
        # The weekend nights were never on May's draft, so they go ahead.
        self.assertEqual(self._kind_dates(june, billing.LINE_BOARDING), ['2026-05-16', '2026-05-17'])
        self.assertEqual(self._kind_dates(june, billing.LINE_CREDIT), [])

        billing.regenerate_draft(self.may)
        self.may.refresh_from_db()
        self.assertEqual(
            self._kind_dates(self.may, billing.LINE_BOARDING), [f'2026-05-{d}' for d in range(11, 16)])
        boarded = {f'2026-05-{d}' for d in range(11, 19)}
        self.assertFalse(boarded & set(self._kind_dates(self.may, billing.LINE_DAYCARE)))
        self.assertEqual(InvoiceLine.objects.filter(description__startswith='Credit').count(), 0)
        # Every date of the stay is on exactly one non-VOID line.
        seen = [d for inv in (self.may, june) for d in self._dates(inv) if d in boarded]
        self.assertEqual(len(seen), len(set(seen)))

    def test_credit_is_never_more_than_the_night_it_replaces(self):
        """A night cheaper than the day (or a boarding price nobody has set
        yet) must not turn into a refund or a negative invoice."""
        from website.models import ServicePricing
        pricing = ServicePricing.load()
        pricing.boarding_price_per_night = 10
        pricing.save()
        self._late_stay()
        june = self._generate(2026, 6)[0]
        credit_lines = june.lines.filter(description__startswith='Credit')
        self.assertEqual({l.line_total for l in credit_lines}, {Decimal('-10.00')})
        self.assertEqual(june.total, Decimal('7') * 10 - Decimal('5') * 10 + Decimal('550.00'))

    def test_unset_boarding_price_gives_no_credit(self):
        from website.models import ServicePricing
        pricing = ServicePricing.load()
        pricing.boarding_price_per_night = 0
        pricing.save()
        self._late_stay()
        june = self._generate(2026, 6)[0]
        self.assertEqual(self._kind_dates(june, billing.LINE_CREDIT), [])
        self.assertEqual(june.total, Decimal('550.00'))

    def test_a_daycare_day_is_still_never_charged_on_a_boarding_date(self):
        """The reverse case is unchanged: a date charged as a night is done."""
        Invoice.objects.filter(pk=self.may.pk).update(status='VOID')
        stay = self._stay(date(2026, 6, 8), date(2026, 6, 10))
        june = self._generate(2026, 6)[0]
        self._send(june)
        stay.status = 'CANCELLED'
        stay.save()
        self._attend(self.dog, 8)
        self._attend(self.dog, 9)
        july = self._generate(2026, 7)[0]
        self.assertTrue(all(d.startswith('2026-07') for d in self._dates(july)))

    def test_line_kind_reads_the_description(self):
        self.assertEqual(billing.line_kind('Boarding — Rex — night of Mon 01/06/2026'), billing.LINE_BOARDING)
        self.assertEqual(billing.line_kind('Boarding — Rex (3 nights @ £40)'), billing.LINE_BOARDING)
        self.assertEqual(billing.line_kind('Credit — Rex — Mon 01/06/2026 (…)'), billing.LINE_CREDIT)
        self.assertEqual(billing.line_kind('Daycare — Rex — Mon 01/06/2026 (1 day a week rate)'), billing.LINE_DAYCARE)
        self.assertEqual(billing.line_kind('Daycare — Rex (4 days @ £25)'), billing.LINE_DAYCARE)


# ─── 3. Catch-up further back than last month ────────────────────────────────

class CatchUpTests(ReviewBillingBase):
    def setUp(self):
        super().setUp()
        self.dog.daycare_days = [1, 3]  # Mon + Wed
        self.dog.save()

    def test_day_added_to_an_older_app_invoiced_month_is_billed(self):
        """April and May were invoiced by the app. A missed April day is
        keyed in afterwards — June's invoice used to look at May only."""
        april, may = self._generate(2026, 4)[0], self._generate(2026, 5)[0]
        self._send(april, may)
        self._attend(self.dog, 10, month=4)  # Fri 10 April

        june = self._generate(2026, 6)[0]
        extra = june.lines.get(attendance_dates=['2026-04-10'])
        self.assertEqual(extra.description, 'Daycare — Biscuit — Fri 10/04/2026 (extra day in April, 2-4 days a week rate)')
        self.assertEqual(june.lines.count(), 10)  # it, and June's 9 booked days
        self.assertEqual(june.lines.order_by('id').first(), extra)  # date order

        # …and only once.
        self._send(june)
        july = self._generate(2026, 7)[0]
        self.assertFalse(july.lines.filter(attendance_dates=['2026-04-10']).exists())

    def test_older_boarding_nights_are_caught_up_too(self):
        april, may = self._generate(2026, 4)[0], self._generate(2026, 5)[0]
        self._send(april, may)
        self._stay(date(2026, 4, 18), date(2026, 4, 20))  # Sat → Mon, recorded late

        june = self._generate(2026, 6)[0]
        self.assertEqual(self._kind_dates(june, billing.LINE_BOARDING), ['2026-04-18', '2026-04-19'])
        night = june.lines.get(attendance_dates=['2026-04-18'])
        self.assertIn('extra night in April', night.description)

    def test_dog_with_no_app_history_is_billed_exactly_as_before(self):
        """Invoiced by hand until now: last month's days off the schedule come
        through, its regular days are taken as paid, and nothing older is
        touched — a year of pre-app attendance must not land on one invoice."""
        for month in (1, 2, 3, 4, 5):
            first_monday = next(d for d in range(1, 8) if date(2026, month, d).isoweekday() == 1)
            self._attend(self.dog, first_monday, month=month)        # on the schedule
            self._attend(self.dog, first_monday + 4, month=month)    # a Friday, off it
        june = self._generate(2026, 6)[0]
        extras = [d for d in self._dates(june) if not d.startswith('2026-06')]
        self.assertEqual(extras, ['2026-05-08'])

    def test_a_caught_up_day_does_not_make_its_month_app_invoiced(self):
        """June's invoice carries one May extra. That must not read as "the
        app invoiced May", or July would bill May's hand-invoiced regular
        days."""
        self._attend(self.dog, 4, month=5)   # Mon, regular: hand-invoiced
        self._attend(self.dog, 8, month=5)   # Fri, extra
        self._attend(self.dog, 6, month=4)   # Mon in April
        self._attend(self.dog, 10, month=4)  # Fri in April
        june = self._generate(2026, 6)[0]
        self.assertIn('2026-05-08', self._dates(june))
        self._send(june)

        july = self._generate(2026, 7)[0]
        self.assertTrue(all(d.startswith('2026-07') for d in self._dates(july)), self._dates(july))

    def test_months_before_the_first_app_invoice_are_never_reached(self):
        may = self._generate(2026, 5)[0]
        self._send(may)
        self._attend(self.dog, 10, month=4)  # April was never app-invoiced
        june = self._generate(2026, 6)[0]
        self.assertFalse(june.lines.filter(attendance_dates=['2026-04-10']).exists())

    def test_catch_up_stops_twelve_months_back(self):
        old = self._generate(2025, 5)[0]
        self._send(old)
        self._attend(self.dog, 15, month=5, year=2025)  # an unbilled Thursday, 13 months before June 2026
        june = self._generate(2026, 6)[0]
        self.assertFalse(june.lines.filter(attendance_dates=['2025-05-15']).exists())
        # Twelve months before May 2026 is still inside the window.
        Invoice.objects.filter(pk=june.pk).update(status='VOID')
        may = self._generate(2026, 5)[0]
        self.assertTrue(may.lines.filter(attendance_dates=['2025-05-15']).exists())

    def test_generation_survives_a_concurrent_invoice_for_one_customer(self):
        """The cron and a manager pressing Generate at once: the unique
        constraint stops the duplicate, and the run carries on for everyone
        else instead of dying on the IntegrityError."""
        self.other_dog.daycare_days = [1]
        self.other_dog.save()
        real_create = Invoice.objects.create

        def racing_create(**kwargs):
            if kwargs.get('customer') == self.owner:
                raise IntegrityError('duplicate key value violates unique constraint')
            return real_create(**kwargs)

        with patch.object(Invoice.objects, 'create', side_effect=racing_create):
            created, skipped, _ = billing.generate_invoices_for_month(2026, 6)
        self.assertEqual([inv.customer for inv in created], [self.other_owner])
        self.assertEqual(skipped, 1)


# ─── 8. Approved extra day that never got a board row ────────────────────────

class ApprovedExtraDayWithoutRowTests(ReviewBillingBase):
    def setUp(self):
        super().setUp()
        self.dog.daycare_days = [1, 3]
        self.dog.owner_brings_default = True
        self.dog.owner_collects_default = True
        self.dog.save()
        may = self._generate(2026, 5)[0]
        self._send(may)

    def _add(self, day, month=5):
        return DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY', new_date=date(2026, month, day), status='APPROVED')

    def test_it_is_billed_on_the_next_invoice(self):
        self._add(8)  # Fri 8 May, approved after May's invoice; nobody made a row
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog).exists())
        june = self._generate(2026, 6)[0]
        self.assertTrue(june.lines.filter(attendance_dates=['2026-05-08']).exists())
        self.assertEqual(billing.attendance_for_month(2026, 5)[self.owner][self.dog], [(date(2026, 5, 8), True)])

    def test_a_removed_row_or_a_later_cancellation_wins(self):
        self._add(8)
        self._attend(self.dog, 8, status='REMOVED', month=5)
        self._add(15)
        DateChangeRequest.objects.create(
            dog=self.dog, request_type='CANCEL', original_date=date(2026, 5, 15), status='APPROVED')
        self.assertEqual(billing.attendance_for_month(2026, 5), {})

    def test_closed_days_and_boarding_days_do_not_count(self):
        self._add(8)
        ClosureDay.objects.create(date=date(2026, 5, 8), closure_type='CLOSED')
        self._add(15)
        self._stay(date(2026, 5, 14), date(2026, 5, 16))
        self.assertEqual(billing.attendance_for_month(2026, 5), {})

    def test_a_row_is_counted_once(self):
        self._add(8)
        self._attend(self.dog, 8, month=5)
        days = billing.attendance_for_month(2026, 5)[self.owner][self.dog]
        self.assertEqual([d for d, _ in days], [date(2026, 5, 8)])

    def test_future_dates_are_left_to_the_booking_projection(self):
        future = timezone.localdate() + timedelta(days=40)
        DateChangeRequest.objects.create(
            dog=self.dog, request_type='ADD_DAY', new_date=future, status='APPROVED')
        self.assertEqual(billing.attendance_for_month(future.year, future.month), {})


# ─── 4, 5, 12. The Xero sync ─────────────────────────────────────────────────

@patch('api.billing.send_staff_notification')
@patch('api.billing.send_push_notification')
class XeroSyncReviewTests(ReviewBillingBase):
    def setUp(self):
        super().setUp()
        _connect_xero()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='SENT',
            total=Decimal('100.00'), xero_invoice_id='xero-inv-1')
        InvoiceLine.objects.create(
            invoice=self.invoice, dog=self.dog, description='Daycare — Biscuit — Mon 01/06/2026 (x)',
            quantity=1, unit_price=Decimal('100.00'), line_total=Decimal('100.00'),
            attendance_dates=['2026-06-01'])

    def _remote(self, **fields):
        return [{'InvoiceID': 'xero-inv-1', 'AmountPaid': 0, 'AmountCredited': 0, 'Payments': [], **fields}]

    def _age(self, minutes=30):
        Invoice.objects.filter(pk=self.invoice.pk).update(
            updated_at=timezone.now() - timedelta(minutes=minutes))

    def _sync(self, **fields):
        with patch('api.xero.fetch_invoices', return_value=self._remote(**fields)), \
                patch('api.xero.get_online_invoice_url', return_value=''):
            counts = billing.sync_invoices_from_xero()
        self.invoice.refresh_from_db()
        return counts

    # 4 ─ voided / amended in Xero after approval
    def test_sent_invoice_voided_in_xero_is_voided_here(self, mock_push, mock_staff):
        counts = self._sync(Status='VOIDED')
        self.assertEqual(self.invoice.status, 'VOID')
        self.assertEqual(counts['voided'], 1)
        # Its day is free to be invoiced again.
        self.assertNotIn(self.dog.id, billing._billed_dates_by_dog())
        mock_push.assert_not_called()

    def test_part_paid_invoice_voided_in_xero_is_left_for_a_person(self, mock_push, mock_staff):
        PaymentRecord.objects.create(
            invoice=self.invoice, amount=Decimal('40.00'), method='CASH', payment_date=date(2026, 6, 20))
        Invoice.objects.filter(pk=self.invoice.pk).update(status='PART_PAID', amount_paid=Decimal('40.00'))
        counts = self._sync(Status='VOIDED')
        self.assertEqual(self.invoice.status, 'PART_PAID')
        self.assertEqual(counts['needs_review'], 1)
        self.assertEqual(counts['voided'], 0)
        self.assertIn('voided in Xero', self.invoice.xero_sync_error)
        self.assertIn('40.00', self.invoice.xero_sync_error)

    def test_total_amended_in_xero_after_approval_is_adopted(self, mock_push, mock_staff):
        counts = self._sync(Status='AUTHORISED', Total=85.0)
        self.assertEqual(self.invoice.total, Decimal('85.00'))
        self.assertEqual(counts['amended'], 1)
        amended = self.invoice.lines.get(description='Amended in Xero')
        self.assertTrue(amended.is_adjustment)
        self.assertEqual(amended.line_total, Decimal('-15.00'))
        self.assertEqual(self._lines_sum(self.invoice), Decimal('85.00'))
        self.assertEqual(self.invoice.status, 'SENT')
        # Running again books nothing further.
        self._sync(Status='AUTHORISED', Total=85.0)
        self.assertEqual(self.invoice.lines.filter(description='Amended in Xero').count(), 1)

    def test_paying_the_amended_total_settles_the_invoice(self, mock_push, mock_staff):
        self._sync(
            Status='PAID', Total=85.0, AmountPaid=85.0,
            Payments=[{'PaymentID': 'pay-1', 'Amount': 85.0, 'Date': '2026-06-20T00:00:00'}])
        self.assertEqual(self.invoice.status, 'PAID')
        self.assertEqual(self.invoice.total, Decimal('85.00'))

    def test_response_without_total_or_status_changes_nothing(self, mock_push, mock_staff):
        self._sync()
        self.assertEqual(self.invoice.status, 'SENT')
        self.assertEqual(self.invoice.total, Decimal('100.00'))
        self.assertEqual(self.invoice.lines.count(), 1)

    # 5 ─ stranded in SENDING
    def test_stale_sending_approved_in_xero_becomes_sent(self, mock_push, mock_staff):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='SENDING')
        self._age()
        counts = self._sync(Status='AUTHORISED', Total=100.0, InvoiceNumber='INV-0009')
        self.assertEqual(self.invoice.status, 'SENT')
        self.assertEqual(self.invoice.xero_invoice_number, 'INV-0009')
        self.assertIsNotNone(self.invoice.due_date)
        self.assertEqual(counts['recovered'], 1)
        # Whether Xero emailed it is unknown — say so rather than email twice.
        self.assertIn('Push to Xero', self.invoice.xero_sync_error)
        self.assertEqual(mock_push.call_args.args[0], self.owner)

    def test_stale_sending_still_a_draft_in_xero_goes_back_to_draft(self, mock_push, mock_staff):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='SENDING')
        self._age()
        counts = self._sync(Status='DRAFT')
        self.assertEqual(self.invoice.status, 'DRAFT')
        self.assertEqual(counts['recovered'], 1)
        mock_push.assert_not_called()

    def test_stale_sending_unknown_to_xero_goes_back_to_draft(self, mock_push, mock_staff):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='SENDING')
        self._age()
        with patch('api.xero.fetch_invoices', return_value=[]):
            counts = billing.sync_invoices_from_xero()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'DRAFT')
        self.assertEqual(counts['recovered'], 1)

    def test_stale_sending_never_raised_in_xero_goes_back_to_draft(self, mock_push, mock_staff):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='SENDING', xero_invoice_id='')
        self._age()
        with patch('api.xero.fetch_invoices') as fetch:
            counts = billing.sync_invoices_from_xero()
        fetch.assert_not_called()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'DRAFT')
        self.assertEqual(counts['recovered'], 1)

    def test_a_send_in_flight_is_left_alone(self, mock_push, mock_staff):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='SENDING', updated_at=timezone.now())
        with patch('api.xero.fetch_invoices', return_value=self._remote(Status='AUTHORISED')) as fetch:
            billing.sync_invoices_from_xero()
        fetch.assert_not_called()  # not even asked about
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'SENDING')

        Invoice.objects.filter(pk=self.invoice.pk).update(xero_invoice_id='', updated_at=timezone.now())
        billing.sync_invoices_from_xero()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'SENDING')

    # 12 ─ state applied to a fresh row, not the copy read before the HTTP call
    def test_invoice_voided_during_the_xero_call_stays_void(self, mock_push, mock_staff):
        def fetch(ids):
            # A payment manager voids it while the sync is waiting on Xero.
            Invoice.objects.filter(pk=self.invoice.pk).update(status='VOID')
            return self._remote(Status='AUTHORISED', Total=100.0)

        with patch('api.xero.fetch_invoices', side_effect=fetch):
            billing.sync_invoices_from_xero()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'VOID')

    def test_draft_sent_during_the_xero_call_is_not_announced_twice(self, mock_push, mock_staff):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='DRAFT')

        def fetch(ids):
            # send_invoice claims it while the sync is waiting on Xero.
            Invoice.objects.filter(pk=self.invoice.pk).update(status='SENDING', updated_at=timezone.now())
            return self._remote(Status='AUTHORISED', Total=100.0)

        with patch('api.xero.fetch_invoices', side_effect=fetch):
            counts = billing.sync_invoices_from_xero()
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, 'SENDING')
        self.assertEqual(counts['approved'], 0)
        mock_push.assert_not_called()


# ─── 6, 11, 14. The Xero module ──────────────────────────────────────────────

class XeroIdempotencyTests(ReviewBillingBase):
    def setUp(self):
        super().setUp()
        _connect_xero()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='DRAFT', total=Decimal('25.00'))
        InvoiceLine.objects.create(
            invoice=self.invoice, dog=self.dog, description='Daycare — Biscuit — Mon 01/06/2026 (x)',
            quantity=1, unit_price=Decimal('25.00'), line_total=Decimal('25.00'),
            attendance_dates=['2026-06-01'])

    def _create(self, invoice, status='DRAFT'):
        with patch('api.xero._api_request',
                   return_value={'Invoices': [{'InvoiceID': 'x', 'InvoiceNumber': 'INV-1'}]}) as api:
            xero.create_invoice(invoice, 'contact-1', status=status, due_date=date(2026, 6, 15))
        return api.call_args

    def test_create_invoice_sends_a_stable_idempotency_key(self):
        first, second = self._create(self.invoice), self._create(self.invoice)
        key = first.kwargs['idempotency_key']
        self.assertTrue(key.startswith(f'p4td-invoice-{self.invoice.pk}-DRAFT-'))
        self.assertLessEqual(len(key), 128)
        # A retry of the same request carries the same key…
        self.assertEqual(second.kwargs['idempotency_key'], key)
        # …a different invoice, status or content does not.
        other = Invoice.objects.create(
            customer=self.other_owner, period_year=2026, period_month=6, status='DRAFT', total=0)
        self.assertNotEqual(self._create(other).kwargs['idempotency_key'], key)
        self.assertNotEqual(self._create(self.invoice, status='AUTHORISED').kwargs['idempotency_key'], key)
        InvoiceLine.objects.filter(invoice=self.invoice).update(unit_price=Decimal('30.00'))
        self.assertNotEqual(self._create(self.invoice).kwargs['idempotency_key'], key)

    def test_reference_the_customer_sees_is_unchanged(self):
        call = self._create(self.invoice)
        self.assertEqual(call.kwargs['payload']['Invoices'][0]['Reference'], 'Daycare June 2026')

    def test_key_goes_out_as_the_idempotency_key_header(self):
        sent = {}

        class _Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b'{}'

        def fake_urlopen(request, timeout=None):
            sent.update({k.lower(): v for k, v in request.header_items()})
            return _Response()

        with patch('api.xero.urllib.request.urlopen', side_effect=fake_urlopen):
            xero._api_request('POST', 'Invoices', 'token', 'tenant', payload={}, idempotency_key='k-1')
            self.assertEqual(sent['idempotency-key'], 'k-1')
            sent.clear()
            xero._api_request('GET', 'Invoices', 'token', 'tenant')
            self.assertNotIn('idempotency-key', sent)

    def test_manual_payment_mirror_is_keyed_on_the_local_payment(self):
        Invoice.objects.filter(pk=self.invoice.pk).update(status='SENT', xero_invoice_id='xero-1')
        self.invoice.refresh_from_db()
        with self.settings(XERO_PAYMENT_ACCOUNT_CODE='090'), \
                patch('api.xero._api_request', return_value={'Payments': [{'PaymentID': 'p-1'}]}) as api, \
                patch('api.billing.send_push_notification'), patch('api.billing.send_staff_notification'):
            payment = billing.record_manual_payment(self.invoice, Decimal('25.00'), 'CASH')
        self.assertEqual(api.call_args.kwargs['idempotency_key'], f'p4td-payment-{payment.id}')

    def test_invoice_date_is_the_london_date_not_utc(self):
        """00:30 on 2 July in London is still 1 July in UTC."""
        just_after_midnight = datetime(2026, 7, 1, 23, 30, tzinfo=dt_timezone.utc)
        with patch('django.utils.timezone.now', return_value=just_after_midnight):
            call = self._create(self.invoice)
            self.assertEqual(call.kwargs['payload']['Invoices'][0]['Date'], '2026-07-02')
            with patch('api.xero._api_request',
                       return_value={'Invoices': [{'InvoiceID': 'x', 'InvoiceNumber': 'INV-1'}]}) as api:
                self.owner.profile.xero_contact_id = 'pinned'
                self.owner.profile.save()
                billing.push_draft_to_xero(self.invoice)
            sent = next(c for c in api.call_args_list if c.args[1] == 'Invoices').kwargs['payload']['Invoices'][0]
            self.assertEqual(sent['DueDate'], '2026-07-16')


class XeroContactResolutionTests(ReviewBillingBase):
    def setUp(self):
        super().setUp()
        _connect_xero()
        self.owner.last_name = 'Owner'
        self.owner.save()
        self.invoice = Invoice.objects.create(
            customer=self.owner, period_year=2026, period_month=6, status='DRAFT', total=Decimal('25.00'))

    def _api(self, by_email=(), by_name=(), created='contact-new'):
        calls = []

        def respond(method, path, *args, **kwargs):
            calls.append((method, path, kwargs))
            if path == 'Contacts' and method == 'GET':
                where = kwargs['params']['where']
                return {'Contacts': list(by_email if where.startswith('EmailAddress') else by_name)}
            if path == 'Contacts' and method == 'POST':
                return {'Contacts': [{'ContactID': created}]}
            if path == 'Invoices' and method == 'POST':
                return {'Invoices': [{'InvoiceID': 'inv-1', 'InvoiceNumber': 'INV-1'}]}
            return {}
        return patch('api.xero._api_request', side_effect=respond), calls

    def test_email_match_is_pinned(self):
        api, _ = self._api(by_email=[{'ContactID': 'c-email', 'ContactStatus': 'ACTIVE'}])
        with api:
            self.assertEqual(xero.resolve_contact(self.owner), ('c-email', 'email'))
            self.assertTrue(billing.push_draft_to_xero(self.invoice))
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.xero_contact_id, 'c-email')

    def test_name_only_match_is_used_but_never_pinned(self):
        api, calls = self._api(by_name=[{'ContactID': 'c-name', 'Name': 'Olive Owner'}])
        with api:
            self.assertEqual(xero.resolve_contact(self.owner), ('c-name', 'name'))
            self.assertTrue(billing.push_draft_to_xero(self.invoice))
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.xero_contact_id, '')
        posted = next(k for m, p, k in calls if (m, p) == ('POST', 'Invoices'))
        self.assertEqual(posted['payload']['Invoices'][0]['Contact'], {'ContactID': 'c-name'})
        self.assertFalse(any((m, p) == ('POST', 'Contacts') for m, p, _ in calls))

    def test_same_name_with_a_different_email_is_refused(self):
        api, calls = self._api(by_name=[
            {'ContactID': 'c-other', 'Name': 'Olive Owner', 'EmailAddress': 'someone.else@example.com'}])
        with api:
            with self.assertRaises(xero.XeroContactMismatch):
                xero.resolve_contact(self.owner)
            self.assertFalse(billing.push_draft_to_xero(self.invoice))
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.xero_invoice_id, '')
        self.assertIn('reconciliation screen', self.invoice.xero_sync_error)
        self.assertFalse(any(p == 'Invoices' for _, p, _ in calls))
        self.owner.profile.refresh_from_db()
        self.assertEqual(self.owner.profile.xero_contact_id, '')

    def test_same_name_same_email_in_another_case_is_fine(self):
        api, _ = self._api(by_name=[
            {'ContactID': 'c-name', 'Name': 'Olive Owner', 'EmailAddress': 'OLIVE@example.com'}])
        with api:
            self.assertEqual(xero.resolve_contact(self.owner), ('c-name', 'name'))

    def test_archived_contacts_are_never_matched(self):
        api, calls = self._api(
            by_email=[{'ContactID': 'c-dead', 'ContactStatus': 'ARCHIVED'}],
            by_name=[{'ContactID': 'c-dead-2', 'ContactStatus': 'ARCHIVED'}])
        with api:
            self.assertEqual(xero.resolve_contact(self.owner), ('contact-new', 'created'))
            self.assertEqual(xero.find_or_create_contact_by_name('Olive Owner'), 'contact-new')
        api, _ = self._api(by_email=[
            {'ContactID': 'c-dead', 'ContactStatus': 'ARCHIVED'},
            {'ContactID': 'c-live', 'ContactStatus': 'ACTIVE'}])
        with api:
            self.assertEqual(xero.find_or_create_contact(self.owner), 'c-live')


# ─── 9, 10. Boarding ↔ daycare attendance ────────────────────────────────────

class BoardingResyncTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(username='rsowner', password='pw')
        self.driver = User.objects.create_user(username='rsdriver', password='pw', is_staff=True)
        self.house = User.objects.create_user(username='P4TD', password='pw', is_staff=True)
        self.dog = Dog.objects.create(owner=self.owner, name='Nala', daycare_days=[3])
        # A Monday at least a week ahead, so "today or later" rules apply.
        today = timezone.localdate()
        self.monday = today + timedelta(days=(7 - today.weekday()) % 7 + 7)
        self.tue, self.wed, self.thu, self.fri = (self.monday + timedelta(days=n) for n in (1, 2, 3, 4))

    def _stay(self, start=None, end=None):
        stay = BoardingRequest.objects.create(
            owner=self.owner, start_date=start or self.monday, end_date=end or self.fri, status='APPROVED')
        stay.dogs.add(self.dog)
        return stay

    def _row(self, day):
        return DailyDogAssignment.objects.get(dog=self.dog, date=day)

    # 9
    def test_resync_does_not_reset_a_dog_already_collected_or_returned(self):
        stay = self._stay()
        scheduling.sync_boarding_daycare_assignments(stay)
        DailyDogAssignment.objects.filter(dog=self.dog, date=self.tue).update(status='PICKED_UP')
        DailyDogAssignment.objects.filter(dog=self.dog, date=self.wed).update(
            status='DROPPED_OFF', staff_member=self.driver)

        with patch('api.models.send_push_notification') as push:
            scheduling.sync_boarding_daycare_assignments(stay)  # what a date edit runs
        self.assertEqual(self._row(self.tue).status, 'PICKED_UP')
        self.assertEqual(self._row(self.wed).status, 'DROPPED_OFF')
        self.assertEqual(self._row(self.wed).staff_member, self.driver)
        push.assert_not_called()

    def test_resync_leaves_a_boarding_day_given_to_a_real_driver(self):
        stay = self._stay()
        scheduling.sync_boarding_daycare_assignments(stay)
        DailyDogAssignment.objects.filter(dog=self.dog, date=self.thu).update(staff_member=self.driver)
        scheduling.sync_boarding_daycare_assignments(stay)
        row = self._row(self.thu)
        self.assertEqual(row.staff_member, self.driver)
        self.assertTrue(row.from_boarding)

    def test_moving_a_waiting_day_to_the_house_account_sends_no_push(self):
        waiting = DailyDogAssignment.objects.create(
            dog=self.dog, staff_member=None, date=self.wed, status='UNASSIGNED')
        with patch('api.models.send_push_notification') as push:
            scheduling.sync_boarding_daycare_assignments(self._stay())
        waiting.refresh_from_db()
        self.assertEqual((waiting.staff_member, waiting.status), (self.house, 'ASSIGNED'))
        push.assert_not_called()

    # 10
    def test_regular_day_already_on_the_board_is_still_taken_over_and_released(self):
        regular = DailyDogAssignment.objects.create(dog=self.dog, staff_member=self.driver, date=self.wed)
        self.assertEqual(regular.booking, DailyDogAssignment.BOOKING_REGULAR)
        stay = self._stay()
        scheduling.sync_boarding_daycare_assignments(stay)
        regular.refresh_from_db()
        self.assertEqual(regular.staff_member, self.house)
        self.assertTrue(regular.from_boarding)
        # Cancelling removes it; the weekday roster re-creates it with its driver.
        scheduling.clear_boarding_daycare_assignments(stay)
        self.assertFalse(DailyDogAssignment.objects.filter(pk=regular.pk).exists())

    def test_extra_day_already_on_the_board_survives_a_cancelled_stay(self):
        extra = DailyDogAssignment.objects.create(dog=self.dog, staff_member=self.driver, date=self.thu)
        self.assertEqual(extra.booking, DailyDogAssignment.BOOKING_EXTRA)
        stay = self._stay()
        scheduling.sync_boarding_daycare_assignments(stay)
        extra.refresh_from_db()
        # With the carer for the stay, but the stay does not own the booking.
        self.assertEqual(extra.staff_member, self.house)
        self.assertFalse(extra.from_boarding)
        # A second sync (a date edit) leaves it exactly so.
        scheduling.sync_boarding_daycare_assignments(stay)
        extra.refresh_from_db()
        self.assertFalse(extra.from_boarding)

        stay.status = 'CANCELLED'
        stay.save()
        with patch('api.models.send_push_notification') as push:
            scheduling.clear_boarding_daycare_assignments(stay)
        extra.refresh_from_db()  # still there
        # Back in the unassigned list for a driver, not hidden under P4TD.
        self.assertEqual((extra.staff_member, extra.status), (None, 'UNASSIGNED'))
        push.assert_not_called()
        # Everything the stay itself booked is gone.
        self.assertEqual(
            list(DailyDogAssignment.objects.filter(dog=self.dog).values_list('date', flat=True)), [self.thu])
        # No boarding night covers the day any more, so it is a billable day.
        attended = billing._attendance_between(self.monday, self.fri)
        self.assertEqual([d for d, _ in attended[self.dog.id][1]], [self.thu])

    def test_extra_day_is_not_billed_as_daycare_while_the_stay_stands(self):
        DailyDogAssignment.objects.create(dog=self.dog, staff_member=self.driver, date=self.thu)
        scheduling.sync_boarding_daycare_assignments(self._stay())
        self.assertEqual(billing._attendance_between(self.monday, self.fri), {})

    def test_shortening_a_stay_hands_back_only_the_days_it_dropped(self):
        tue_extra = DailyDogAssignment.objects.create(dog=self.dog, staff_member=self.driver, date=self.tue)
        thu_extra = DailyDogAssignment.objects.create(dog=self.dog, staff_member=self.driver, date=self.thu)
        stay = self._stay()
        scheduling.sync_boarding_daycare_assignments(stay)
        # Now Mon–Wed: Thursday and Friday drop off the end.
        stay.end_date = self.wed
        stay.save()
        scheduling.clear_boarding_daycare_assignments(stay, dates=[self.thu, self.fri])
        scheduling.sync_boarding_daycare_assignments(stay)
        tue_extra.refresh_from_db()
        thu_extra.refresh_from_db()
        self.assertEqual(tue_extra.staff_member, self.house)       # still boarding
        self.assertEqual((thu_extra.staff_member, thu_extra.status), (None, 'UNASSIGNED'))
        self.assertFalse(DailyDogAssignment.objects.filter(dog=self.dog, date=self.fri).exists())

    def test_owner_driven_extra_day_stays_with_the_house_account(self):
        self.dog.owner_brings_default = True
        self.dog.owner_collects_default = True
        self.dog.save()
        extra = DailyDogAssignment.objects.create(dog=self.dog, staff_member=self.house, date=self.thu)
        stay = self._stay()
        scheduling.sync_boarding_daycare_assignments(stay)
        scheduling.clear_boarding_daycare_assignments(stay)
        extra.refresh_from_db()
        self.assertEqual((extra.staff_member, extra.status), (self.house, 'ASSIGNED'))


# ─── 13. Route planning ──────────────────────────────────────────────────────

def _straight_line(points):
    return [[0.0 if a == b else routing._haversine_seconds(a, b) for b in points] for a in points]


class RoutingReviewTests(TestCase):
    BASE = (51.5, -0.8)
    A, B, C = (51.52, -0.7), (51.48, -0.6), (51.55, -0.75)

    def setUp(self):
        from django.core.cache import cache
        cache.clear()
        self.fetch_patcher = patch('api.routing.fetch_drive_times', side_effect=_straight_line)
        self.fetch = self.fetch_patcher.start()
        self.addCleanup(self.fetch_patcher.stop)

    def test_matrix_cache_ignores_the_order_points_arrive_in(self):
        first = routing.drive_times([self.BASE, self.A, self.B, self.C])
        again = routing.drive_times([self.BASE, self.C, self.A, self.B])  # the board was reordered
        self.assertEqual(self.fetch.call_count, 1)
        # Each answer is indexed the way its caller asked.
        self.assertEqual(first, _straight_line([self.BASE, self.A, self.B, self.C]))
        self.assertEqual(again, _straight_line([self.BASE, self.C, self.A, self.B]))
        self.assertEqual(first[1][2], again[2][3])  # A → B either way

    def test_a_different_set_of_points_is_a_different_matrix(self):
        routing.drive_times([self.BASE, self.A, self.B])
        routing.drive_times([self.BASE, self.A, self.C])
        self.assertEqual(self.fetch.call_count, 2)

    def test_repeated_points_share_a_stop(self):
        matrix = routing.drive_times([self.BASE, self.A, self.A])
        self.assertEqual(matrix[1][2], 0.0)
        self.assertEqual(len(self.fetch.call_args.args[0]), 2)

    def _day(self, dogs=24):
        points = [self.BASE] + [(51.4 + 0.01 * i, -0.9 + 0.013 * (i * 7 % 11)) for i in range(dogs)]
        matrix = _straight_line(points)
        # Everything starts on one van; the other two drivers have none.
        plan_dogs = [routing.PlanDog(assignment_id=100 + i, dog_id=i, current_staff_id=1, stop=i + 1)
                     for i in range(dogs)]
        drivers = [routing.PlanDriver(staff_id=s) for s in (1, 2, 3)]
        return plan_dogs, drivers, matrix

    def test_out_of_time_returns_a_complete_plan(self):
        plan_dogs, drivers, matrix = self._day()
        plan = routing.plan_routes(plan_dogs, drivers, matrix, budget_seconds=0)
        self.assertTrue(plan.timed_out)
        placed = sorted(a for route in plan.routes for a in route.assignment_ids)
        self.assertEqual(placed, [d.assignment_id for d in plan_dogs])
        self.assertEqual(plan.unplaced, [])
        self.assertEqual([r.staff_id for r in plan.routes], [1, 2, 3])
        self.assertTrue(all(r.seconds >= 0 for r in plan.routes))

    def test_the_search_stops_at_its_deadline(self):
        plan_dogs, drivers, matrix = self._day()
        clock = {'now': 1000.0, 'calls': 0}

        def monotonic():
            # Time leaps forward once the search has had a few looks.
            clock['calls'] += 1
            if clock['calls'] > 5:
                clock['now'] += 100.0
            return clock['now']

        with patch('api.routing.time.monotonic', side_effect=monotonic):
            plan = routing.plan_routes(plan_dogs, drivers, matrix, budget_seconds=15)
        self.assertTrue(plan.timed_out)
        self.assertEqual(sum(len(r.assignment_ids) for r in plan.routes), len(plan_dogs))

    def test_an_ordinary_day_finishes_well_inside_the_budget(self):
        plan_dogs, drivers, matrix = self._day(dogs=9)
        plan = routing.plan_routes(plan_dogs, drivers, matrix)
        self.assertFalse(plan.timed_out)
        # And the answer is the same with no deadline at all.
        unlimited = routing.plan_routes(plan_dogs, drivers, matrix, budget_seconds=None)
        self.assertEqual([r.assignment_ids for r in plan.routes], [r.assignment_ids for r in unlimited.routes])

    def test_slow_matrix_fetch_gives_up_with_a_message(self):
        self.fetch_patcher.stop()  # the real fetch_drive_times, over a fake tile request
        points = [(51.0 + 0.001 * i, -0.8) for i in range(routing._MATRIX_TILE + 5)]  # two tiles a side
        clock = {'now': 0.0}

        def slow_tile(pts, sources, destinations):
            clock['now'] += 30.0
            return [[1.0] * len(destinations) for _ in sources]

        try:
            with patch('api.routing._fetch_matrix_tile', side_effect=slow_tile) as tile, \
                    patch('api.routing.time.monotonic', side_effect=lambda: clock['now']):
                with self.assertRaises(routing.RoutingError):
                    routing.fetch_drive_times(points)
            self.assertLess(tile.call_count, 4)
        finally:
            self.fetch_patcher.start()
