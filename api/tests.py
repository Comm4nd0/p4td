from django.test import TestCase
from django.contrib.auth.models import User
from rest_framework.test import APIClient
from .models import Dog, DateChangeRequest, DateChangeRequestHistory
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

    def test_staff_can_approve_and_revert(self):
        self.client.login(username='staff', password='pw')
        url = f"/api/date-change-requests/{self.req.id}/change_status/"
        # Approve
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

        # Revert to PENDING
        resp = self.client.post(url, {'status': 'PENDING'}, format='json')
        self.assertEqual(resp.status_code, 200)
        self.req.refresh_from_db()
        self.assertEqual(self.req.status, 'PENDING')
        self.assertIsNone(self.req.approved_by)
        self.assertIsNone(self.req.approved_at)
        hist2 = DateChangeRequestHistory.objects.filter(request=self.req).order_by('-changed_at').first()
        self.assertEqual(hist2.from_status, 'APPROVED')
        self.assertEqual(hist2.to_status, 'PENDING')
