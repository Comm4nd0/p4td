from datetime import date, timedelta
from django.test import TestCase
from django.contrib.auth.models import User
from rest_framework.test import APIClient
from .models import (
    Dog, DateChangeRequest, DateChangeRequestHistory,
    BoardingRequest, DailyDogAssignment,
    SupportQuery, SupportMessage,
    ClosureDay, DogNote, StaffAvailability,
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

    def test_update_dog(self):
        dog = Dog.objects.create(owner=self.owner, name='OldName')
        self.client.login(username='owner', password='pw')
        resp = self.client.patch(f'/api/dogs/{dog.id}/', {'name': 'NewName'}, format='json')
        self.assertEqual(resp.status_code, 200)
        dog.refresh_from_db()
        self.assertEqual(dog.name, 'NewName')


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
        SupportQuery.objects.create(owner=self.owner, subject='Open1')
        SupportQuery.objects.create(owner=self.owner, subject='Open2')
        SupportQuery.objects.create(owner=self.owner, subject='Resolved', status='RESOLVED')
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
        StaffAvailability.objects.create(staff_member=self.staff, day_of_week=1, is_available=True)
        StaffAvailability.objects.create(staff_member=self.staff2, day_of_week=1, is_available=False)
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
