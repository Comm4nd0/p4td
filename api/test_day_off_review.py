"""Day-off requests: who can decide them, and who hears about them."""
from datetime import date, timedelta
from unittest.mock import patch

from django.contrib.auth.models import User
from django.test import TestCase
from rest_framework.test import APIClient

from .models import DayOffRequest


class DayOffReviewTests(TestCase):
    def setUp(self):
        self.worker = User.objects.create_user('worker', password='pw', is_staff=True, first_name='Sam')
        self.manager = User.objects.create_user('manager', password='pw', is_staff=True)
        self.manager.profile.can_manage_staff = True
        self.manager.profile.save()
        # The business owner: superuser, nobody ever ticked the flag.
        self.boss = User.objects.create_user('boss', password='pw', is_staff=True, is_superuser=True)
        self.other = User.objects.create_user('other', password='pw', is_staff=True)
        self.day = date.today() + timedelta(days=14)
        self.client = APIClient()

    def _pending(self, day=None):
        return DayOffRequest.objects.create(staff_member=self.worker, date=day or self.day)

    def test_superuser_without_the_flag_can_list_and_approve(self):
        req = self._pending()
        self.client.force_authenticate(self.boss)
        resp = self.client.get('/api/day-off-requests/')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual([r['id'] for r in resp.data], [req.id])
        resp = self.client.post(f'/api/day-off-requests/{req.id}/approve/')
        self.assertEqual(resp.status_code, 200)
        req.refresh_from_db()
        self.assertEqual(req.status, 'APPROVED')
        self.assertEqual(req.reviewed_by, self.boss)

    def test_ordinary_staff_still_cannot_review(self):
        req = self._pending()
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.get('/api/day-off-requests/').status_code, 403)
        self.assertEqual(self.client.post(f'/api/day-off-requests/{req.id}/approve/').status_code, 403)
        self.assertEqual(self.client.post(f'/api/day-off-requests/{req.id}/deny/').status_code, 403)

    def test_pending_count(self):
        self._pending()
        DayOffRequest.objects.create(staff_member=self.worker, date=self.day + timedelta(days=1),
                                     status='APPROVED')
        for user, expected in ((self.manager, 1), (self.boss, 1), (self.other, 0), (self.worker, 0)):
            self.client.force_authenticate(user)
            resp = self.client.get('/api/day-off-requests/pending_count/')
            self.assertEqual(resp.status_code, 200)
            self.assertEqual(resp.data, {'count': expected}, user.username)

    @patch('api.notifications.send_push_notification')
    def test_request_pushes_every_manager_once_per_burst(self, mock_push):
        self.client.force_authenticate(self.worker)
        end = self.day + timedelta(days=2)
        for offset in range(3):
            resp = self.client.post('/api/day-off-requests/', {
                'date': (self.day + timedelta(days=offset)).isoformat(),
                'range_end': end.isoformat(), 'reason': 'Wedding',
            }, format='json')
            self.assertEqual(resp.status_code, 201)
        recipients = [c.args[0] for c in mock_push.call_args_list]
        self.assertCountEqual(recipients, [self.manager, self.boss])
        call = mock_push.call_args_list[0]
        self.assertEqual(call.args[1], 'Day off requested')
        self.assertIn('Sam has asked for', call.args[2])
        self.assertIn('–', call.args[2])
        self.assertIn('Wedding', call.args[2])
        self.assertEqual(call.args[3]['type'], 'day_off_request')

    @patch('api.notifications.send_push_notification')
    def test_manager_asking_for_their_own_day_does_not_push_themselves(self, mock_push):
        self.client.force_authenticate(self.manager)
        self.client.post('/api/day-off-requests/', {'date': self.day.isoformat()}, format='json')
        self.assertEqual([c.args[0] for c in mock_push.call_args_list], [self.boss])

    @patch('api.notifications.send_push_notification')
    def test_decision_pushes_the_requester(self, mock_push):
        approved, denied = self._pending(), self._pending(self.day + timedelta(days=1))
        self.client.force_authenticate(self.manager)
        self.client.post(f'/api/day-off-requests/{approved.id}/approve/')
        self.client.post(f'/api/day-off-requests/{denied.id}/deny/')
        self.assertEqual([c.args[0] for c in mock_push.call_args_list], [self.worker, self.worker])
        self.assertEqual(mock_push.call_args_list[0].args[1], 'Day off approved')
        self.assertEqual(mock_push.call_args_list[1].args[1], 'Day off not approved')
        self.assertEqual(mock_push.call_args_list[0].args[3]['type'], 'day_off_decision')
        self.assertTrue(mock_push.call_args_list[0].kwargs['ignore_working_hours'])
