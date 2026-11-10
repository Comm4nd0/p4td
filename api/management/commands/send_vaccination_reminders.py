"""Send push reminders for vaccinations that are expiring or expired.

Designed to run daily from cron. Each milestone (30 days out, 7 days out,
expired) notifies the dog's owners exactly once — bookkeeping flags on the
record make reruns no-ops. Staff with can_manage_requests get a digest of
newly-expired vaccinations so compliance issues are visible.

Dogs that have no detailed VaccinationRecord but do have the simple
``Dog.last_vaccination_date`` get one reminder a week before that date turns
a year old (see ``_send_annual_reminders``). Dogs with records are left to the
record-based milestones above so nobody is told twice.

Separately, a dog with no current vaccination *certificate* on file
(``Dog.certificate_state``: nothing filed, or the newest over a year old) has
its owners chased on an escalating cadence — the day it is first noticed,
then 3 and 7 days on, then weekly, capped — see
``_send_certificate_reminders``. Staff can send the same push by hand from the
dashboard's Dog health row (``dogs/<id>/remind_certificate/``).
"""
from datetime import timedelta

from django.contrib.auth.models import User
from django.utils import timezone

from django.core.management.base import CommandError

from api.management.push_command import PushCommand
from api.models import Dog, VaccinationRecord
from api.notifications import notify_certificate_needed, send_push_notification
from api.cron_heartbeat import ping_heartbeat


class Command(PushCommand):
    help = 'Send vaccination expiry reminders to dog owners (run daily).'
    requires_firebase = True

    def _notify_owners(self, record, title, body):
        data = {
            'type': 'vaccination',
            'dog_id': str(record.dog_id),
            'record_id': str(record.id),
        }
        recipients = [record.dog.owner] if record.dog.owner else []
        recipients += list(record.dog.additional_owners.all())
        for user in recipients:
            try:
                send_push_notification(user, title, body, data, category='dog_updates')
            except Exception as exc:
                self.stderr.write(f'Failed to notify {user}: {exc}')

    #: How far ahead of the anniversary the simple-date reminder goes out.
    ANNUAL_REMINDER_DAYS_BEFORE = 7

    def _send_annual_reminders(self, today):
        """One push a week before ``last_vaccination_date`` is a year old.

        The window is [due - 7 days, due): a date entered late still gets its
        reminder if the anniversary hasn't passed, and one that is already
        overdue gets nothing here — the staff dashboard flags those. The
        reminder is keyed on the date it was sent for, so entering next
        year's date re-arms it with no flag to reset.
        """
        valid = Dog.VACCINATION_VALID_DAYS
        before = self.ANNUAL_REMINDER_DAYS_BEFORE
        window = (
            Dog.objects.filter(
                # due - before <= today  <=>  last <= today - (valid - before)
                last_vaccination_date__lte=today - timedelta(days=valid - before),
                # today < due  <=>  last > today - valid
                last_vaccination_date__gt=today - timedelta(days=valid),
                vaccinations__isnull=True,
            )
            .select_related('owner')
            .prefetch_related('additional_owners')
            .order_by('name')
        )
        sent = 0
        for dog in window:
            try:
                sent += self._send_annual_reminder(dog, today)
            except Exception as exc:
                # One dog's bad data must not cost every other dog its reminder.
                self.errors += 1
                self.stderr.write(f'Annual reminder failed for dog {dog.pk}: {exc!r}')
        return sent

    def _send_annual_reminder(self, dog, today):
        if dog.annual_vaccination_reminder_sent_for == dog.last_vaccination_date:
            return 0
        previous = dog.annual_vaccination_reminder_sent_for
        # Mark before sending: at-most-once, as for the record milestones.
        Dog.objects.filter(pk=dog.pk).update(
            annual_vaccination_reminder_sent_for=dog.last_vaccination_date)
        due = dog.vaccination_due_date
        days_left = (due - today).days
        when = 'today' if days_left == 0 else f"in {days_left} day{'s' if days_left != 1 else ''}"
        title = 'Vaccinations due soon'
        body = (
            f"{dog.name}'s annual vaccinations are due {when} ({due.strftime('%d %b %Y')}) — "
            f"a year since the last date we have on record. Please book a booster and "
            f"add the new certificate to {dog.name}'s profile."
        )
        data = {'type': 'vaccination', 'dog_id': str(dog.id)}
        recipients = [dog.owner] if dog.owner else []
        recipients += list(dog.additional_owners.all())
        with self.dispatch() as outcome:
            for user in recipients:
                try:
                    send_push_notification(user, title, body, data, category='dog_updates')
                except Exception as exc:
                    self.stderr.write(f'Failed to notify {user}: {exc}')
        if outcome.demonstrably_failed:
            # FCM took nothing: put the reminder back for the next run.
            Dog.objects.filter(pk=dog.pk).update(
                annual_vaccination_reminder_sent_for=previous)
            return 0
        return 1

    #: Days between certificate reminders: the first goes the day the lapse
    #: is noticed, the next 3 days later, then 4, then weekly.
    CERTIFICATE_REMINDER_GAPS = (3, 4)
    CERTIFICATE_REMINDER_INTERVAL_DAYS = 7
    #: Cadence stops here (day 42) — after six weeks the owner has heard, and
    #: the dashboard's Dog health row is where staff take it from.
    CERTIFICATE_REMINDER_MAX = 8

    @classmethod
    def certificate_reminder_gap(cls, n):
        """Days to wait after reminder *n* (1-based count already sent)."""
        gaps = cls.CERTIFICATE_REMINDER_GAPS
        if n - 1 < len(gaps):
            return gaps[n - 1]
        return cls.CERTIFICATE_REMINDER_INTERVAL_DAYS

    def _send_certificate_reminders(self, today):
        """Escalating pushes while a dog has no current certificate on file.

        The count is keyed on ``certificate_needed_since`` (the anchor): a new
        lapse — a certificate that just turned a year old — moves the anchor
        and starts the count again; a certificate arriving clears both, so
        nothing has to be reset by the upload path. Pacing runs from the last
        push, not the anchor, so a dog that has been on the books for months
        gets the same 0/3/7/weekly cadence from the day this first notices it
        rather than all its milestones at once. A dog nobody on the app owns
        is skipped (staff phone those; the dashboard lists them).
        """
        sent = 0
        dogs = Dog.objects.select_related('owner').prefetch_related(
            'vaccination_certificates', 'additional_owners').order_by('name')
        for dog in dogs:
            try:
                sent += self._send_certificate_reminder(dog, today)
            except Exception as exc:
                # One dog's bad data must not cost every other dog its reminder.
                self.errors += 1
                self.stderr.write(f'Certificate reminder failed for dog {dog.pk}: {exc!r}')
        return sent

    def _send_certificate_reminder(self, dog, today):
        status, since = dog.certificate_state(today)
        if status == Dog.CERTIFICATE_OK:
            if dog.certificate_reminder_anchor is not None:
                Dog.objects.filter(pk=dog.pk).update(
                    certificate_reminder_anchor=None, certificate_reminders_sent=0)
            return 0
        if not dog.owner_id and not dog.additional_owners.all():
            return 0
        count = dog.certificate_reminders_sent
        if dog.certificate_reminder_anchor != since:
            count = 0
            Dog.objects.filter(pk=dog.pk).update(
                certificate_reminder_anchor=since, certificate_reminders_sent=0)
        if count >= self.CERTIFICATE_REMINDER_MAX:
            return 0
        last = dog.certificate_reminder_last_sent
        if count and last and (today - last).days < self.certificate_reminder_gap(count):
            return 0
        # Mark before sending: at-most-once, as for the record milestones.
        Dog.objects.filter(pk=dog.pk).update(
            certificate_reminders_sent=count + 1, certificate_reminder_last_sent=today)
        with self.dispatch() as outcome:
            notify_certificate_needed(dog, status)
        if outcome.demonstrably_failed:
            # FCM took nothing: this one doesn't count towards the cadence.
            Dog.objects.filter(pk=dog.pk).update(
                certificate_reminders_sent=count, certificate_reminder_last_sent=last)
            return 0
        return 1

    def _send_record_reminder(self, record, flags, title, body):
        """One record milestone: mark, send, and un-mark if FCM took nothing.

        ``flags`` are the bookkeeping fields this milestone sets. Marked
        before dispatching so a crash mid-send can't re-notify on the next
        run — prefer at-most-once for reminders (B34).
        """
        previous = {flag: getattr(record, flag) for flag in flags}
        for flag in flags:
            setattr(record, flag, True)
        record.save(update_fields=flags)
        with self.dispatch() as outcome:
            self._notify_owners(record, title, body)
        if outcome.demonstrably_failed:
            for flag, value in previous.items():
                setattr(record, flag, value)
            record.save(update_fields=flags)
            return 0
        return 1

    def _each_record(self, records, flags, text):
        """Run a milestone over ``records``; returns (sent, records sent for)."""
        sent, done = 0, []
        for record in records:
            try:
                title, body = text(record)
                if self._send_record_reminder(record, flags, title, body):
                    sent += 1
                    done.append(record)
            except Exception as exc:
                # One record's bad data must not cost the rest their reminder.
                self.errors += 1
                self.stderr.write(f'Vaccination reminder failed for record {record.pk}: {exc!r}')
        return sent, done

    def handle(self, *args, **options):
        today = timezone.localdate()
        self.errors = 0
        sent = 0

        sent += self._send_annual_reminders(today)
        certificates_sent = self._send_certificate_reminders(today)

        base = VaccinationRecord.objects.select_related('dog', 'dog__owner').prefetch_related(
            'dog__additional_owners'
        )

        expired_sent, newly_expired = self._each_record(
            list(base.filter(expiry_date__lt=today, expired_notice_sent=False)),
            ['expired_notice_sent', 'reminder_7_sent', 'reminder_30_sent'],
            lambda record: (
                'Vaccination expired',
                f"{record.dog.name}'s {record.name} vaccination expired on "
                f"{record.expiry_date.strftime('%d %b %Y')}. Please update it and let us know.",
            ),
        )
        sent += expired_sent

        def week_text(record):
            days_left = (record.expiry_date - today).days
            when = 'today' if days_left == 0 else f"in {days_left} day{'s' if days_left != 1 else ''}"
            return (
                'Vaccination expiring soon',
                f"{record.dog.name}'s {record.name} vaccination expires {when} "
                f"({record.expiry_date.strftime('%d %b %Y')}).",
            )

        week_sent, _ = self._each_record(
            list(base.filter(
                expiry_date__gte=today,
                expiry_date__lte=today + timedelta(days=7),
                reminder_7_sent=False,
            )),
            ['reminder_7_sent', 'reminder_30_sent'],
            week_text,
        )
        sent += week_sent

        month_sent, _ = self._each_record(
            list(base.filter(
                expiry_date__gt=today + timedelta(days=7),
                expiry_date__lte=today + timedelta(days=VaccinationRecord.EXPIRING_SOON_DAYS),
                reminder_30_sent=False,
            )),
            ['reminder_30_sent'],
            lambda record: (
                'Vaccination due for renewal',
                f"{record.dog.name}'s {record.name} vaccination expires on "
                f"{record.expiry_date.strftime('%d %b %Y')}. Time to book a booster!",
            ),
        )
        sent += month_sent

        if newly_expired:
            staff = User.objects.filter(is_staff=True, profile__can_manage_requests=True)
            names = ', '.join(f'{r.dog.name} ({r.name})' for r in newly_expired[:10])
            extra = '' if len(newly_expired) <= 10 else f' and {len(newly_expired) - 10} more'
            with self.dispatch():
                for user in staff:
                    try:
                        send_push_notification(
                            user,
                            'Vaccinations expired',
                            f'Expired vaccinations need chasing: {names}{extra}.',
                            {'type': 'vaccination_staff'},
                        )
                    except Exception as exc:
                        self.stderr.write(f'Failed to notify staff {user}: {exc}')

        self.stdout.write(
            f'Sent {sent} vaccination reminder(s) and {certificates_sent} certificate reminder(s).')
        if self.errors:
            # Everything that could be sent was; say so loudly and leave the
            # heartbeat unpinged so the monitor notices.
            raise CommandError(f'{self.errors} reminder(s) raised an error (see above).')
        self.fail_if_pushes_failed()
        # Heartbeat on success so a monitor alerts if this cron stops running (I7).
        ping_heartbeat('vaccination-reminders')
