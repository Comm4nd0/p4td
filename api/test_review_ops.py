"""Tests for the operations fixes from the security review: reminder crons that
must not burn their one-shot flags, the SNS webhook's freshness and duplicate
checks, upload size limits, and the scripts that install the crontab.
"""
import io
import json
import os
import subprocess
import tempfile
from datetime import date, datetime, timedelta, timezone as dt_timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from django.contrib.auth.models import User
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone

from .models import DeviceToken, Dog, VaccinationRecord, Vehicle

REPO_ROOT = Path(__file__).resolve().parent.parent


def _fcm(success=True):
    """A stand-in for ``messaging.send_each`` whose every message succeeds or fails."""
    def send_each(messages):
        return SimpleNamespace(responses=[
            SimpleNamespace(success=success, exception=None if success else RuntimeError('refused'))
            for _ in messages
        ])
    return send_each


class ReminderCronTestCase(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user('owner@example.com', 'owner@example.com', 'pw')
        self.dog = Dog.objects.create(owner=self.owner, name='Rex')
        DeviceToken.objects.create(user=self.owner, token='tok-owner')
        today = timezone.localdate()
        self.record = VaccinationRecord.objects.create(
            dog=self.dog, name='Lepto',
            date_administered=today - timedelta(days=400),
            expiry_date=today - timedelta(days=2),
        )
        # Keep the certificate cadence out of the way of the record tests.
        patcher = patch(
            'api.management.commands.send_vaccination_reminders.Command._send_certificate_reminders',
            return_value=0)
        patcher.start()
        self.addCleanup(patcher.stop)


class FirebaseGuardTests(ReminderCronTestCase):
    """No Firebase: stop before anything is marked sent or reported healthy."""

    @patch('api.management.commands.send_vaccination_reminders.ping_heartbeat')
    @patch('api.management.push_command.push_available', return_value=False)
    @patch('api.management.push_command.firebase_enforced', return_value=True)
    def test_refuses_to_run_and_marks_nothing(self, _enforced, _available, heartbeat):
        with self.assertRaises(CommandError):
            call_command('send_vaccination_reminders', stdout=io.StringIO())
        self.record.refresh_from_db()
        self.assertFalse(self.record.expired_notice_sent)
        heartbeat.assert_not_called()

    @patch('api.management.push_command.push_available', return_value=False)
    @patch('api.management.push_command.firebase_enforced', return_value=True)
    def test_every_reminder_cron_is_guarded(self, _enforced, _available):
        for name in ('send_vaccination_reminders', 'send_fleet_reminders',
                     'send_compliance_reminders', 'send_end_of_day_alerts',
                     'send_tomorrow_changes'):
            with self.subTest(command=name):
                with self.assertRaises(CommandError):
                    call_command(name, stdout=io.StringIO())

    @patch('api.management.push_command.push_available', return_value=False)
    @patch('api.management.push_command.firebase_enforced', return_value=True)
    def test_dry_run_needs_no_firebase(self, _enforced, _available):
        call_command('send_tomorrow_changes', '--dry-run', '--date', '2026-01-04',
                     stdout=io.StringIO())

    @patch('api.management.push_command.push_available', return_value=False)
    @patch('api.management.push_command.firebase_enforced', return_value=True)
    def test_commands_that_only_sometimes_push_are_not_guarded(self, _enforced, _available):
        from django.core.management import load_command_class
        for name in ('generate_monthly_invoices', 'sync_xero_invoices', 'send_invoice_reminders'):
            self.assertFalse(load_command_class('api', name).requires_firebase, name)

    def test_enforced_outside_the_test_runner(self):
        from api.management import push_command
        with patch.object(push_command.sys, 'argv', ['manage.py', 'send_fleet_reminders']):
            self.assertTrue(push_command.firebase_enforced())
            with patch.dict(os.environ, {'P4TD_CRON_ALLOW_NO_PUSH': '1'}):
                self.assertFalse(push_command.firebase_enforced())
        with patch.object(push_command.sys, 'argv', ['manage.py', 'test']):
            self.assertFalse(push_command.firebase_enforced())


@patch('api.notifications.initialize_firebase', return_value=True)
class DispatchOutcomeTests(ReminderCronTestCase):
    """A reminder FCM refused is put back; one it took is sent exactly once."""

    @patch('api.management.commands.send_vaccination_reminders.ping_heartbeat')
    def test_failed_dispatch_unmarks_and_exits_nonzero(self, heartbeat, _firebase):
        with patch('api.notifications.messaging.send_each', side_effect=RuntimeError('fcm down')):
            with self.assertRaises(CommandError):
                call_command('send_vaccination_reminders', stdout=io.StringIO())
        self.record.refresh_from_db()
        self.assertFalse(self.record.expired_notice_sent)
        self.assertFalse(self.record.reminder_7_sent)
        heartbeat.assert_not_called()

        # FCM back: the same reminder now goes, once.
        with patch('api.notifications.messaging.send_each', side_effect=_fcm()) as send:
            out = io.StringIO()
            call_command('send_vaccination_reminders', stdout=out)
            self.assertIn('Sent 1 ', out.getvalue())
            self.assertEqual(send.call_count, 1)
            out = io.StringIO()
            call_command('send_vaccination_reminders', stdout=out)
            self.assertIn('Sent 0 ', out.getvalue())
            self.assertEqual(send.call_count, 1)
        self.record.refresh_from_db()
        self.assertTrue(self.record.expired_notice_sent)
        heartbeat.assert_called_with('vaccination-reminders')

    def test_every_device_refusing_counts_as_failed(self, _firebase):
        with patch('api.notifications.messaging.send_each', side_effect=_fcm(success=False)):
            with self.assertRaises(CommandError):
                call_command('send_vaccination_reminders', stdout=io.StringIO())
        self.record.refresh_from_db()
        self.assertFalse(self.record.expired_notice_sent)

    def test_nobody_with_a_device_is_not_a_failure(self, _firebase):
        DeviceToken.objects.all().delete()
        with patch('api.notifications.messaging.send_each') as send:
            call_command('send_vaccination_reminders', stdout=io.StringIO())
        send.assert_not_called()
        self.record.refresh_from_db()
        self.assertTrue(self.record.expired_notice_sent)

    def test_fleet_reminder_is_put_back_when_fcm_refuses(self, _firebase):
        manager = User.objects.create_user('fleet@example.com', 'fleet@example.com', 'pw', is_staff=True)
        manager.profile.can_manage_vehicles = True
        manager.profile.save()
        DeviceToken.objects.create(user=manager, token='tok-fleet')
        vehicle = Vehicle.objects.create(
            name='Van 1', registration='AB12 CDE',
            mot_due_date=timezone.localdate() - timedelta(days=1))
        with patch('api.notifications._is_staff_working_today', return_value=True):
            with patch('api.notifications.messaging.send_each', side_effect=RuntimeError('down')):
                with self.assertRaises(CommandError):
                    call_command('send_fleet_reminders', stdout=io.StringIO())
            vehicle.refresh_from_db()
            self.assertFalse(vehicle.mot_overdue_notice_sent)
            with patch('api.notifications.messaging.send_each', side_effect=_fcm()):
                call_command('send_fleet_reminders', stdout=io.StringIO())
        vehicle.refresh_from_db()
        self.assertTrue(vehicle.mot_overdue_notice_sent)

    def test_web_tier_pushes_are_still_queued_not_inline(self, _firebase):
        from api import notifications
        with patch('api.notifications.messaging.send_each', side_effect=_fcm()) as send:
            with self.captureOnCommitCallbacks(execute=False) as callbacks:
                notifications.send_push_notification(self.owner, 't', 'b')
            self.assertEqual(len(callbacks), 1)
            send.assert_not_called()


class OneBadDogTests(TestCase):
    """An exception on one dog must not cost the others their reminder."""

    def test_other_dogs_are_still_reminded_and_the_run_fails_loudly(self):
        owner = User.objects.create_user('o@example.com', 'o@example.com', 'pw')
        Dog.objects.create(owner=owner, name='Aaa-bad')
        Dog.objects.create(owner=owner, name='Zzz-good')
        real = Dog.certificate_state

        def flaky(dog, today=None):
            if dog.name == 'Aaa-bad':
                raise ValueError('bad data')
            return real(dog, today)

        err = io.StringIO()
        with patch.object(Dog, 'certificate_state', flaky), \
                patch('api.management.commands.send_vaccination_reminders.notify_certificate_needed') as notify, \
                patch('api.management.commands.send_vaccination_reminders.ping_heartbeat') as heartbeat:
            with self.assertRaises(CommandError):
                call_command('send_vaccination_reminders', stdout=io.StringIO(), stderr=err)
        self.assertEqual([c.args[0].name for c in notify.call_args_list], ['Zzz-good'])
        self.assertIn('Aaa-bad', Dog.objects.get(name='Aaa-bad').name)
        self.assertIn('Certificate reminder failed', err.getvalue())
        heartbeat.assert_not_called()


class TomorrowChangesOnceTests(TestCase):
    """The scheduled run summarises a day once, however often it is started."""

    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)
        self.staff = User.objects.create_user('s@example.com', 's@example.com', 'pw', is_staff=True)
        change = {'kind': 'TRANSPORT', 'dog_id': 0}
        for target, value in (
            ('day_changes', [change]),
            ('schedule_change_recipients', [self.staff]),
            ('staff_summary_text', ('Tomorrow: 1 change', 'Team: Rex')),
        ):
            patcher = patch(f'api.management.commands.send_tomorrow_changes.{target}',
                            return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    @patch('api.management.commands.send_tomorrow_changes.send_push_notification')
    def test_second_scheduled_run_sends_nothing(self, push):
        call_command('send_tomorrow_changes', stdout=io.StringIO())
        self.assertEqual(push.call_count, 1)
        out = io.StringIO()
        call_command('send_tomorrow_changes', stdout=out)
        self.assertEqual(push.call_count, 1)
        self.assertIn('already sent', out.getvalue())
        call_command('send_tomorrow_changes', '--force', stdout=io.StringIO())
        self.assertEqual(push.call_count, 2)

    @patch('api.management.commands.send_tomorrow_changes.send_push_notification')
    def test_explicit_date_and_dry_run_are_not_guarded(self, push):
        day = (timezone.localdate() + timedelta(days=1)).isoformat()
        call_command('send_tomorrow_changes', '--dry-run', stdout=io.StringIO())
        call_command('send_tomorrow_changes', '--date', day, stdout=io.StringIO())
        call_command('send_tomorrow_changes', '--date', day, stdout=io.StringIO())
        self.assertEqual(push.call_count, 2)
        # Neither claimed the day, so the scheduled run still goes.
        call_command('send_tomorrow_changes', stdout=io.StringIO())
        self.assertEqual(push.call_count, 3)

    @patch('api.notifications.initialize_firebase', return_value=True)
    @patch('api.notifications._is_staff_working_today', return_value=True)
    def test_a_run_nobody_received_can_be_repeated(self, _working, _firebase):
        DeviceToken.objects.create(user=self.staff, token='tok-staff')
        with patch('api.notifications.messaging.send_each', side_effect=RuntimeError('down')):
            with self.assertRaises(CommandError):
                call_command('send_tomorrow_changes', stdout=io.StringIO())
        with patch('api.notifications.messaging.send_each', side_effect=_fcm()) as send:
            call_command('send_tomorrow_changes', stdout=io.StringIO())
            self.assertEqual(send.call_count, 1)


class SeedDemoDataPasswordTests(TestCase):
    def test_no_default_password(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop('DEMO_PASSWORD', None)
            with self.assertRaises(CommandError):
                call_command('seed_demo_data', '--no-media', stdout=io.StringIO())
        self.assertFalse(User.objects.filter(username='demo-owner@paws4thoughtdogs.com').exists())

    def test_password_from_the_environment_and_never_echoed(self):
        out = io.StringIO()
        with patch.dict(os.environ, {'DEMO_PASSWORD': 'Env-Supplied-9!x'}):
            call_command('seed_demo_data', '--no-media', stdout=out)
        user = User.objects.get(username='demo-owner@paws4thoughtdogs.com')
        self.assertTrue(user.check_password('Env-Supplied-9!x'))
        self.assertNotIn('Env-Supplied-9!x', out.getvalue())

    def test_source_carries_no_password_literal(self):
        source = (REPO_ROOT / 'api/management/commands/seed_demo_data.py').read_text()
        self.assertNotRegex(source, r"add_argument\(\s*'--password'[^)]*default\s*=\s*['\"]")


class SnsFreshnessTests(SimpleTestCase):
    def _message(self, stamp):
        return {
            'Type': 'Notification', 'TopicArn': 'arn:ours', 'Message': '{}', 'MessageId': 'm-1',
            'Timestamp': stamp, 'Signature': 'AAAA',
            'SigningCertURL': 'https://sns.eu-west-2.amazonaws.com/cert.pem',
        }

    def _stamp(self, delta):
        return (datetime.now(dt_timezone.utc) + delta).strftime('%Y-%m-%dT%H:%M:%S.000Z')

    def test_old_message_is_refused_before_any_fetch(self):
        from .sns import SnsVerificationError, verify_message
        with patch('api.sns.urllib.request.urlopen') as urlopen:
            with self.assertRaisesRegex(SnsVerificationError, 'too old'):
                verify_message(self._message(self._stamp(-timedelta(hours=2))), ['arn:ours'])
            with self.assertRaisesRegex(SnsVerificationError, 'future'):
                verify_message(self._message(self._stamp(timedelta(hours=1))), ['arn:ours'])
            with self.assertRaisesRegex(SnsVerificationError, 'Unreadable'):
                verify_message(self._message('yesterday-ish'), ['arn:ours'])
        urlopen.assert_not_called()

    @override_settings(SNS_MAX_MESSAGE_AGE_SECONDS=3 * 3600)
    def test_window_is_configurable(self):
        from .sns import SnsVerificationError, verify_message
        with patch('api.sns._fetch_certificate', side_effect=SnsVerificationError('reached fetch')):
            with self.assertRaisesRegex(SnsVerificationError, 'reached fetch'):
                verify_message(self._message(self._stamp(-timedelta(hours=2))), ['arn:ours'])

    def test_certificate_fetch_failure_is_a_rejection_not_a_crash(self):
        import urllib.error
        from . import sns
        sns._CERT_CACHE.clear()
        with patch('api.sns.urllib.request.urlopen', side_effect=urllib.error.URLError('dns')):
            with self.assertRaisesRegex(sns.SnsVerificationError, 'Could not fetch'):
                sns.verify_message(self._message(self._stamp(timedelta(0))), ['arn:ours'])

    def test_unparseable_certificate_is_a_rejection_and_is_not_cached(self):
        from . import sns
        sns._CERT_CACHE.clear()
        response = io.BytesIO(b'this is not a certificate')
        response.__enter__ = lambda *a: response
        response.__exit__ = lambda *a: False
        with patch('api.sns.urllib.request.urlopen', return_value=response):
            with self.assertRaisesRegex(sns.SnsVerificationError, 'could not be read'):
                sns.verify_message(self._message(self._stamp(timedelta(0))), ['arn:ours'])
        self.assertEqual(sns._CERT_CACHE, {})


class SnsWebhookReplayTests(TestCase):
    URL = '/api/roadworks/street-manager-webhook/'
    TOPIC = 'arn:aws:sns:eu-west-2:287813576808:prod-permit-topic'

    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)

    def _body(self, message_id, **object_data):
        data = {
            'permit_reference_number': 'BC-REPLAY-1',
            'street_name': 'High Street',
            'work_area_wkt': 'POINT(480107 184695)',
            'proposed_start_date': '2026-08-01T00:00:00Z',
            'proposed_end_date': '2026-08-02T00:00:00Z',
            'traffic_management_type': 'road closure',
            'permit_status': 'granted',
            'highway_authority': 'Buckinghamshire Council',
            'highway_authority_swa_code': '440',
        }
        data.update(object_data)
        return json.dumps({
            'Type': 'Notification', 'TopicArn': self.TOPIC, 'MessageId': message_id,
            'Message': json.dumps({'object_data': data}),
        })

    def _post(self, body):
        return self.client.post(self.URL, data=body, content_type='application/json')

    @override_settings(STREET_MANAGER_TOPIC_ARNS=TOPIC)
    @patch('api.sns.verify_message')
    def test_same_message_id_is_applied_once(self, _verify):
        from .models import RoadworkIssue
        self.assertEqual(self._post(self._body('m-1')).json(), {'result': 'created'})
        # The works are cancelled by a later message...
        self.assertEqual(
            self._post(self._body('m-2', permit_status='cancelled')).json(), {'result': 'updated'})
        # ...and replaying the first one must not bring them back.
        response = self._post(self._body('m-1'))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'ignored': 'duplicate'})
        self.assertTrue(RoadworkIssue.objects.get(external_ref='BC-REPLAY-1').is_cancelled)

    @override_settings(STREET_MANAGER_TOPIC_ARNS=TOPIC,
                       STREET_MANAGER_HIGHWAY_AUTHORITIES='Buckinghamshire Council, 3015')
    @patch('api.sns.verify_message')
    def test_only_listed_authorities_are_stored(self, _verify):
        from .models import RoadworkIssue
        other = self._body('m-3', permit_reference_number='ELSEWHERE-1',
                           highway_authority='Cornwall Council', highway_authority_swa_code='1140')
        self.assertEqual(self._post(other).json(), {'result': 'ignored:authority'})
        self.assertEqual(self._post(self._body('m-4')).json(), {'result': 'created'})
        by_code = self._body('m-5', permit_reference_number='BY-CODE-1',
                             highway_authority='Somewhere', highway_authority_swa_code=3015)
        self.assertEqual(self._post(by_code).json(), {'result': 'created'})
        self.assertFalse(RoadworkIssue.objects.filter(external_ref='ELSEWHERE-1').exists())

    @override_settings(STREET_MANAGER_TOPIC_ARNS=TOPIC, STREET_MANAGER_HIGHWAY_AUTHORITIES='')
    @patch('api.sns.verify_message')
    def test_no_allowlist_keeps_everything(self, _verify):
        self.assertEqual(self._post(self._body('m-6')).json(), {'result': 'created'})


class UploadLimitTests(SimpleTestCase):
    def _png(self, size):
        from PIL import Image
        buffer = io.BytesIO()
        Image.new('L', size, 255).save(buffer, format='PNG')
        return SimpleUploadedFile('photo.png', buffer.getvalue(), content_type='image/png')

    def test_pillow_limit_is_set_process_wide(self):
        from PIL import Image
        from .apps import MAX_UPLOAD_IMAGE_PIXELS
        self.assertEqual(Image.MAX_IMAGE_PIXELS, MAX_UPLOAD_IMAGE_PIXELS)
        self.assertEqual(MAX_UPLOAD_IMAGE_PIXELS, 40_000_000)

    def test_small_file_with_a_huge_canvas_is_refused(self):
        from .views import ImageProcessingError, process_image
        bomb = self._png((7000, 6000))  # 42 MP of white: a few KB on the wire
        self.assertLess(bomb.size, 1024 * 1024)
        with self.assertRaises(ImageProcessingError):
            process_image(bomb)

    def test_ordinary_photo_still_goes_through(self):
        from .views import process_image
        self.assertTrue(process_image(self._png((1200, 900))).name.endswith('.jpg'))

    def test_oversized_file_is_refused_before_decoding(self):
        from .views import ImageProcessingError, process_image
        upload = self._png((10, 10))
        upload.size = 26 * 1024 * 1024
        with patch('api.views.Image.open') as opened:
            with self.assertRaises(ImageProcessingError):
                process_image(upload)
        opened.assert_not_called()

    def test_validator_refuses_a_huge_canvas(self):
        from django.core.exceptions import ValidationError
        from .validators import validate_media_upload
        with self.assertRaises(ValidationError):
            validate_media_upload(self._png((7000, 6000)), 'PHOTO')
        validate_media_upload(self._png((1200, 900)), 'PHOTO')

    def test_video_is_copied_in_pieces(self):
        from . import views

        class Chunky(io.BytesIO):
            name = 'clip.mp4'
            reads = []

            def read(self, size=-1):
                self.reads.append(size)
                return super().read(size)

        video = Chunky(b'x' * (3 * 1024 * 1024 + 5))
        with patch('api.views.subprocess.run', return_value=SimpleNamespace(returncode=1, stderr='')):
            views.generate_video_thumbnail(video)
        self.assertNotIn(-1, Chunky.reads)
        self.assertNotIn(None, Chunky.reads)
        self.assertGreaterEqual(len(Chunky.reads), 4)
        self.assertEqual(video.tell(), 0)  # rewound for Django to save


class AdminTodaysDogsTests(TestCase):
    def test_a_brace_in_a_dog_name_is_just_text(self):
        from django.contrib import admin
        from .models import DailyDogAssignment
        staff = User.objects.create_user('driver@example.com', 'driver@example.com', 'pw', is_staff=True)
        for name in ('Rex {0}', 'Bo}{b <b>'):
            dog = Dog.objects.create(name=name)
            DailyDogAssignment.objects.create(
                dog=dog, staff_member=staff, date=timezone.localdate(), status='ASSIGNED')
        html = str(admin.site._registry[User].todays_dogs(staff))
        self.assertIn('Rex {0}', html)
        self.assertIn('Bo}{b &lt;b&gt;', html)
        self.assertEqual(html.count('<span'), 2)


class CronInstallerTests(SimpleTestCase):
    """scripts/install-cron.sh --print: what the crontab would become."""

    script = REPO_ROOT / 'scripts' / 'install-cron.sh'

    def _render(self, existing):
        result = subprocess.run(
            ['bash', str(self.script), '--print'], input=existing,
            capture_output=True, text=True, check=True)
        return result.stdout

    def _legacy(self, command, schedule='0 8 * * *'):
        return (f'{schedule} cd {REPO_ROOT} && docker compose -f docker-compose.prod.yml exec -T web '
                f'python manage.py {command} >> /var/log/p4td-x.log 2>&1')

    def test_replaces_the_old_entries_and_leaves_other_apps_alone(self):
        others = [
            'MAILTO=ops@example.com',
            '# another app',
            '15 4 * * * cd /root/otherapp && docker compose exec -T web python manage.py send_fleet_reminders',
            f'0 5 * * * cd {REPO_ROOT}-staging && docker compose exec -T web python manage.py send_fleet_reminders',
        ]
        existing = '\n'.join(others + [
            self._legacy('send_vaccination_reminders'),
            self._legacy('prune_feed_media --include-orphans', '0 3 * * 0'),
            self._legacy('send_tomorrow_changes', '0 17,18 * * *'),
        ]) + '\n'
        out = self._render(existing)
        for line in others:
            self.assertIn(line, out.splitlines())
        self.assertNotIn('docker-compose.prod.yml exec', out)
        for command in ('send_vaccination_reminders', 'send_fleet_reminders', 'send_compliance_reminders',
                        'send_invoice_reminders', 'send_end_of_day_alerts', 'send_tomorrow_changes',
                        'generate_monthly_invoices', 'sync_xero_invoices', 'prune_feed_media',
                        'prune_device_tokens', 'backup-db.sh'):
            managed = [l for l in out.splitlines() if 'scripts/run-cron.sh' in l and command in l]
            self.assertEqual(len(managed), 1, command)

    def test_is_idempotent(self):
        once = self._render('MAILTO=ops@example.com\n' + self._legacy('send_fleet_reminders') + '\n')
        self.assertEqual(self._render(once), once)
        self.assertEqual(self._render(''), self._render(self._render('')))

    def test_daily_jobs_are_pinned_to_a_london_hour(self):
        out = self._render('')
        line = next(l for l in out.splitlines() if 'send_tomorrow_changes' in l)
        self.assertTrue(line.startswith('0 * * * * '), line)
        self.assertIn('--london-hour 18 ', line)
        self.assertNotIn('%', out)  # cron treats an unescaped % as a newline

    def test_a_hand_written_backup_entry_is_kept_and_not_doubled(self):
        own = f'30 2 * * * cd {REPO_ROOT} && ./scripts/backup-db.sh && rclone copy backups box:p4td'
        out = self._render(own + '\n')
        self.assertIn(own, out.splitlines())
        self.assertEqual(sum('backup-db.sh' in l for l in out.splitlines()), 1)


class CronRunnerTests(SimpleTestCase):
    script = REPO_ROOT / 'scripts' / 'run-cron.sh'

    def _run(self, *args):
        with tempfile.TemporaryDirectory() as logs:
            result = subprocess.run(
                ['bash', str(self.script), *args], capture_output=True, text=True,
                env={**os.environ, 'P4TD_CRON_LOG_DIR': logs})
            written = {p.name: p.read_text() for p in Path(logs).iterdir()}
        return result.returncode, written

    def _london_hour(self, offset=0):
        from zoneinfo import ZoneInfo
        now = datetime.now(ZoneInfo('Europe/London')) + timedelta(hours=offset)
        return f'{now.hour:02d}'

    def test_runs_only_in_the_named_london_hour(self):
        code, written = self._run('--london-hour', self._london_hour(5), 'job', 'host', 'echo', 'ran')
        self.assertEqual((code, written), (0, {}))
        code, written = self._run('--london-hour', self._london_hour(), 'job', 'host', 'echo', 'ran')
        self.assertEqual(code, 0)
        self.assertEqual(written.get('p4td-job.log'), 'ran\n')

    def test_exit_status_is_the_jobs_own(self):
        code, written = self._run('job', 'host', 'false')
        self.assertEqual(code, 1)
        self.assertIn('FAILED with exit status 1', written['p4td-job.log'])


class DeployScriptTests(SimpleTestCase):
    """Cheap guards on the things deploy.sh must keep doing."""

    def setUp(self):
        self.source = (REPO_ROOT / 'deploy.sh').read_text()

    def test_migrates_before_swapping_the_serving_container(self):
        migrate = self.source.index('run --rm -T web python manage.py migrate --noinput')
        dump = self.source.index('pg_dump')
        swap = self.source.index('compose up -d\n')
        self.assertLess(dump, migrate)
        self.assertLess(migrate, swap)

    def test_rollback_commit_survives_the_reexec(self):
        self.assertIn('P4TD_PREV_COMMIT="$PREV_COMMIT" exec ./deploy.sh --skip-pull', self.source)
        self.assertIn('git pull --ff-only origin main', self.source)

    def test_private_media_never_enters_the_image(self):
        ignored = (REPO_ROOT / '.dockerignore').read_text().splitlines()
        self.assertIn('private-media/', ignored)
        self.assertIn('media/', ignored)
        self.assertIn('.env', ignored)

    def test_no_server_address_in_the_laptop_script(self):
        import re
        script = (REPO_ROOT / 'scripts' / 'deploy-to-hetzner.sh').read_text()
        self.assertIsNone(re.search(r'\b\d{1,3}(\.\d{1,3}){3}\b', script))
        result = subprocess.run(
            ['bash', str(REPO_ROOT / 'scripts' / 'deploy-to-hetzner.sh')],
            capture_output=True, text=True, env={k: v for k, v in os.environ.items() if k != 'HETZNER_HOST'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('HETZNER_HOST', result.stderr)
