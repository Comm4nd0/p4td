"""Send push reminders for safety & compliance checks falling due.

Designed to run daily from cron. Two milestones per check, each sent at most
once per cycle to staff with can_manage_compliance:

- 30 days ahead, for long-cycle checks only (>= 90-day frequency) — lead time
  to book engineers or renew policies;
- when the check is due or overdue (including scheduled checks never done).

The flags re-arm when a new completion is logged (see
models.rearm_compliance_reminders), starting the next cycle's reminders.
"""
from django.contrib.auth.models import User
from django.core.management.base import BaseCommand
from django.utils import timezone

from api.models import ComplianceCheckType
from api.notifications import send_push_notification
from api.cron_heartbeat import ping_heartbeat


class Command(BaseCommand):
    help = 'Send due/overdue compliance check reminders to compliance managers (run daily).'

    def _notify(self, check, event, title, body):
        data = {
            'type': 'compliance_reminder',
            'check_id': str(check.id),
            'event': event,
        }
        recipients = User.objects.filter(is_staff=True, profile__can_manage_compliance=True)
        for user in recipients:
            try:
                send_push_notification(user, title, body, data)
            except Exception as exc:
                self.stderr.write(f'Failed to notify {user}: {exc}')

    def handle(self, *args, **options):
        today = timezone.localdate()
        sent = 0

        for check in ComplianceCheckType.objects.filter(is_active=True):
            days = check.frequency_days
            if days is None:
                continue
            last = check.last_log()
            due = check.next_due(last_done=last.performed_on if last else None)

            if due is None:
                # Scheduled but never completed: nag once until the first log.
                if not check.due_notice_sent:
                    check.due_notice_sent = True
                    check.save(update_fields=['due_notice_sent'])
                    self._notify(
                        check, 'never_done',
                        'Compliance check needs a first record',
                        f'"{check.name}" ({check.get_frequency_display().lower()}) has never been logged.',
                    )
                    sent += 1
                continue

            if today > due and not check.due_notice_sent:
                check.due_notice_sent = True
                check.advance_notice_sent = True
                check.save(update_fields=['due_notice_sent', 'advance_notice_sent'])
                self._notify(
                    check, 'overdue',
                    'Compliance check overdue',
                    f'"{check.name}" was due on {due:%d %b %Y}.',
                )
                sent += 1
            elif today == due and not check.due_notice_sent:
                check.due_notice_sent = True
                check.advance_notice_sent = True
                check.save(update_fields=['due_notice_sent', 'advance_notice_sent'])
                self._notify(
                    check, 'due',
                    'Compliance check due today',
                    f'"{check.name}" is due today.',
                )
                sent += 1
            elif (days >= 90 and not check.advance_notice_sent
                  and today >= due - timezone.timedelta(days=30)):
                check.advance_notice_sent = True
                check.save(update_fields=['advance_notice_sent'])
                self._notify(
                    check, 'due_soon',
                    'Compliance check coming up',
                    f'"{check.name}" is due on {due:%d %b %Y}.',
                )
                sent += 1

        self.stdout.write(self.style.SUCCESS(f'Sent {sent} compliance reminder(s).'))
        ping_heartbeat('send_compliance_reminders')
