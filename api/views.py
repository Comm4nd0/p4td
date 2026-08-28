from rest_framework import viewsets, mixins, status as drf_status
from rest_framework.response import Response
from rest_framework.decorators import action, api_view, permission_classes as perm_classes, throttle_classes
from rest_framework.permissions import IsAuthenticated, IsAdminUser, AllowAny, BasePermission, SAFE_METHODS
from rest_framework.throttling import AnonRateThrottle
from django.contrib.auth.models import User
from django.core.mail import send_mail, EmailMessage
from django.conf import settings
from django.db.models import Prefetch, Sum
from decimal import Decimal
from .pagination import FeedPagination, OptInPagination
from .models import Dog, Photo, UserProfile, DateChangeRequest, DateChangeRequestHistory, GroupMedia, MediaReaction, Comment, BoardingRequest, BoardingRequestHistory, DeviceToken, DailyDogAssignment, DogWeekdayPickup, PasswordResetOTP, DogProfileChangeRequest, IntakeRequest
from .serializers import DogSerializer, PhotoSerializer, UserProfileSerializer, DateChangeRequestSerializer, GroupMediaSerializer, OwnerDetailSerializer, CommentSerializer, BoardingRequestSerializer, DeviceTokenSerializer, DailyDogAssignmentSerializer, DogWeekdayPickupSerializer, RequestPasswordResetSerializer, VerifyOTPSerializer, ResetPasswordSerializer, ChangePasswordSerializer, ContactInquirySerializer, PublicContactInquirySerializer, DogProfileChangeRequestSerializer, IntakeRequestSerializer
from website.models import ContactInquiry

import logging

logger = logging.getLogger(__name__)

# Dog fields an owner may propose to change via a profile-change request. Used
# both when building the request and when applying it on approval, so the
# approval step can re-enforce the whitelist (defense in depth — B19).
OWNER_EDITABLE_DOG_FIELDS = ['name', 'food_instructions', 'medical_notes', 'registered_vet', 'address', 'postcode', 'contact_number', 'emergency_contact_number', 'daycare_days', 'schedule_type', 'sex', 'date_of_birth', 'last_vaccination_date']


def dog_listing_queryset():
    """Dog queryset with everything DogSerializer renders already loaded.

    Shared so that every endpoint returning dogs gets the same constant query
    count. In particular `future_removed_assignments` must be prefetched:
    without it, DogSerializer.get_cancelled_dates falls through to a per-dog
    query, which is ~30 extra round-trips on the staff dashboard's hottest
    endpoint (unassigned_dogs) — it built its own queryset and missed this.
    """
    removed_assignments = Prefetch(
        'daily_assignments',
        queryset=DailyDogAssignment.objects.filter(
            status='REMOVED', date__gte=timezone.localdate()
        ).only('id', 'dog_id', 'date', 'status'),
        to_attr='future_removed_assignments',
    )
    return Dog.objects.select_related('owner__profile').prefetch_related(
        'vaccinations', 'additional_owners__profile', removed_assignments
    )


def _truthy(value):
    """Interpret a JSON/form flag from a client that may send a bool or a string."""
    return str(value).lower() in ('1', 'true', 'yes')


def _user_owns_dog(user, dog):
    """True when ``user`` may act on ``dog`` — primary owner, co-owner, or staff.

    Mirrors the ``Q(owner=user) | Q(additional_owners=user)`` scoping used by
    every owner-facing ``get_queryset``. ``get_queryset`` only limits which rows
    a caller may *read*; this is the check for what they may write.
    """
    if user.is_staff:
        return True
    if dog is None:
        return False
    if dog.owner_id == user.id:
        return True
    return dog.additional_owners.filter(id=user.id).exists()


def _require_dog_access(user, dog, message):
    """Raise PermissionDenied unless ``user`` may act on ``dog``."""
    if not _user_owns_dog(user, dog):
        from rest_framework.exceptions import PermissionDenied
        raise PermissionDenied(message)


def _compute_date_change_is_charged(request_type, original_date):
    """Late-change fee rule, computed server-side so an owner can't dodge it by
    sending is_charged=false (B2). Mirrors the app: a CANCEL/CHANGE is charged
    when the original date is within one month of today; ADD_DAY is never
    charged."""
    if request_type == 'ADD_DAY' or not original_date:
        return False
    from datetime import date, timedelta
    from django.utils import timezone
    today = timezone.localdate()
    # One month from today, matching the Flutter DateTime(y, m + 1, d) rollover.
    y, m, d = today.year, today.month + 1, today.day
    y += (m - 1) // 12
    m = (m - 1) % 12 + 1
    one_month_later = date(y, m, 1) + timedelta(days=d - 1)
    return original_date < one_month_later


class DeviceTokenViewSet(viewsets.ModelViewSet):
    serializer_class = DeviceTokenSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return DeviceToken.objects.filter(user=self.request.user)

    def create(self, request, *args, **kwargs):
        # Check if token already exists
        token = request.data.get('token')
        if token:
            existing = DeviceToken.objects.filter(token=token).first()
            if existing:
                # If it belongs to a different user, reassign it
                if existing.user != request.user:
                    existing.user = request.user
                # Determine device_type from request if available and not set
                device_type = request.data.get('device_type')
                if device_type and existing.device_type != device_type:
                    existing.device_type = device_type
                # Always save, even when nothing changed: the app re-registers
                # on every launch and prune_device_tokens keeps tokens alive by
                # updated_at, so a no-op re-registration must still refresh the
                # timestamp or live devices get pruned after 90 days.
                existing.save()

                # Return the existing token with 200 OK
                serializer = self.get_serializer(existing)
                return Response(serializer.data)

        # Otherwise create new
        return super().create(request, *args, **kwargs)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)

    @action(detail=False, methods=['post'])
    def deregister(self, request):
        """Remove this device's token on logout so the device stops receiving
        the logged-out user's notifications. Scoped to the caller's own tokens;
        a token that was already reassigned to another account is left alone."""
        token = request.data.get('token')
        if not token:
            return Response({'detail': 'token is required'}, status=400)
        deleted, _ = DeviceToken.objects.filter(token=token, user=request.user).delete()
        return Response({'deleted': bool(deleted)})
from django.utils import timezone
from django.core.files.base import ContentFile
import io
from PIL import Image
import os
import tempfile
import subprocess
import uuid

from rest_framework.exceptions import ValidationError as DRFValidationError


class ImageProcessingError(DRFValidationError):
    """Raised when an upload cannot be decoded or re-encoded as an image.

    These helpers used to swallow the failure and return the *original* file
    unchanged, which stored the raw upload under its attacker-chosen filename in
    a publicly-served media directory. Subclassing DRF's ValidationError makes
    every one of the ~12 call sites return 400 instead, with no per-site
    handling.
    """

    def __init__(self, reason=''):
        logger.warning('Rejected an unprocessable image upload: %s', reason)
        super().__init__({'file': ["That file couldn't be read as an image."]})


def _decode_upload(image_file):
    """Open an upload as a Pillow image, oriented per its EXIF data."""
    from PIL import ImageOps
    try:
        image_file.seek(0)
        img = Image.open(image_file)
        img = ImageOps.exif_transpose(img)
        # JPEG can only encode RGB/L/CMYK, so normalise everything else —
        # palette, transparency, 16-bit greyscale — rather than letting save()
        # fail later and fall back to storing the raw upload.
        if img.mode not in ('RGB', 'L', 'CMYK'):
            img = img.convert('RGB')
        return img
    except Exception as exc:
        raise ImageProcessingError(str(exc)) from exc


def _encode_jpeg(img, size, quality, name):
    im = img.copy()
    if im.width > size[0] or im.height > size[1]:
        im.thumbnail(size, Image.Resampling.LANCZOS)
    out = io.BytesIO()
    try:
        im.save(out, format='JPEG', quality=quality, optimize=True)
    except Exception as exc:
        raise ImageProcessingError(str(exc)) from exc
    out.seek(0)
    return ContentFile(out.read(), name=name)


def process_image(image_file, max_size=(1280, 1280), quality=85):
    """Resize and compress an image, returning a JPEG ContentFile.

    Raises ImageProcessingError if the upload isn't a decodable image.
    """
    img = _decode_upload(image_file)
    # Random filename so stored media URLs aren't guessable from the original
    # name (partial mitigation for I3 — full auth-gating is a separate
    # coordinated change). Applied on every path, so a file can never reach
    # disk under its uploaded name.
    return _encode_jpeg(img, max_size, quality, f'{uuid.uuid4().hex}.jpg')


def process_image_pair(image_file, main_size=(1280, 1280), thumb_size=(400, 400), main_quality=85, thumb_quality=70):
    """Decode an image once and return (main, thumbnail) ContentFiles.

    Avoids decoding the original a second time just to build the thumbnail (B31).
    Raises ImageProcessingError if the upload isn't a decodable image.
    """
    img = _decode_upload(image_file)
    base_name = uuid.uuid4().hex
    return (
        _encode_jpeg(img, main_size, main_quality, f'{base_name}.jpg'),
        _encode_jpeg(img, thumb_size, thumb_quality, f'{base_name}_thumb.jpg'),
    )


def generate_video_thumbnail(file_obj):
    """Generate a thumbnail image from a video file.

    Extracts the first frame using FFmpeg, scales it to max 400px wide while
    keeping the original aspect ratio, and returns a ContentFile ready to be
    saved to an ImageField.  Returns None on any failure so uploads are never
    blocked by thumbnail issues.

    IMPORTANT: resets file_obj's read pointer to 0 before returning so that
    Django can still save the original video file afterwards.
    """
    try:
        if not file_obj:
            return None

        # Determine a proper temp-file suffix from the original filename
        original_name = getattr(file_obj, 'name', '') or ''
        ext = os.path.splitext(original_name)[1].lower() or '.mp4'

        # Write the uploaded video to a temp file so FFmpeg can read it
        if hasattr(file_obj, 'seek'):
            file_obj.seek(0)

        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp_video:
            if hasattr(file_obj, 'read'):
                tmp_video.write(file_obj.read())
            else:
                for chunk in file_obj.chunks():
                    tmp_video.write(chunk)
            tmp_video_path = tmp_video.name

        # Reset the file pointer so Django can save the video file later
        if hasattr(file_obj, 'seek'):
            file_obj.seek(0)

        thumb_path = tempfile.mktemp(suffix='.jpg')
        try:
            # Extract the very first frame (works for any video length)
            # and scale to max 400px wide, keeping aspect ratio.
            # -2 ensures the height is divisible by 2 (required by many codecs).
            result = subprocess.run([
                'ffmpeg',
                '-i', tmp_video_path,
                '-vframes', '1',
                '-vf', 'scale=400:-2',
                '-y',
                thumb_path,
            ], capture_output=True, timeout=30, text=True)

            if os.path.exists(thumb_path) and os.path.getsize(thumb_path) > 0:
                with open(thumb_path, 'rb') as f:
                    return ContentFile(f.read(), name='thumbnail.jpg')
            else:
                print(f"FFmpeg failed to generate thumbnail (rc={result.returncode})")
                if result.stderr:
                    print(f"FFmpeg stderr: {result.stderr[:500]}")
                return None
        finally:
            for p in (tmp_video_path, thumb_path):
                try:
                    if os.path.exists(p):
                        os.unlink(p)
                except OSError:
                    pass
    except FileNotFoundError:
        print("FFmpeg not found – install it to enable video thumbnails: sudo apt-get install ffmpeg")
        return None
    except Exception as e:
        print(f"Error generating video thumbnail: {e}")
        return None


class UserProfileViewSet(mixins.RetrieveModelMixin, mixins.UpdateModelMixin, viewsets.GenericViewSet):
    serializer_class = UserProfileSerializer
    permission_classes = [IsAuthenticated]

    def get_object(self):
        # Always return the profile of the current user
        return self.request.user.profile

    def list(self, request, *args, **kwargs):
        # Override list to return current user's profile (singleton pattern)
        instance = self.get_object()
        serializer = self.get_serializer(instance)
        return Response(serializer.data)

    def create(self, request, *args, **kwargs):
        # Use create endpoint for PATCH/PUT since we're using list route
        return self.partial_update(request, *args, **kwargs)

    def partial_update(self, request, *args, **kwargs):
        instance = self.get_object()
        serializer = self.get_serializer(instance, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)

        # Process profile photo upload if present
        if 'profile_photo' in serializer.validated_data:
            image_file = serializer.validated_data['profile_photo']
            if image_file:
                processed_image = process_image(image_file, max_size=(800, 800))
                serializer.validated_data['profile_photo'] = processed_image

        serializer.save()
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def get_owner(self, request):
        """Staff-only endpoint to get a specific owner's profile: GET /profile/get_owner/?user_id=<id>"""
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can view owner profiles")

        user_id = request.query_params.get('user_id')
        if not user_id:
            return Response({'detail': 'user_id query parameter required'}, status=400)

        try:
            profile = UserProfile.objects.get(user_id=user_id)
        except UserProfile.DoesNotExist:
            return Response({'detail': 'User profile not found'}, status=404)

        serializer = OwnerDetailSerializer(profile)
        return Response(serializer.data)

    @action(detail=False, methods=['post'])
    def update_owner(self, request):
        """Staff-only endpoint to update an owner's profile: POST /profile/update_owner/?user_id=<id>"""
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can update owner profiles")

        user_id = request.query_params.get('user_id')
        if not user_id:
            return Response({'detail': 'user_id query parameter required'}, status=400)

        try:
            profile = UserProfile.objects.get(user_id=user_id)
        except UserProfile.DoesNotExist:
            return Response({'detail': 'User profile not found'}, status=404)

        serializer = OwnerDetailSerializer(profile, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def get_owners(self, request):
        """Staff-only endpoint to get list of all owners: GET /profile/get_owners/"""
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can view owner list")

        profiles = UserProfile.objects.select_related('user').all()
        from .serializers import UserSummarySerializer
        serializer = UserSummarySerializer(profiles, many=True, context={'request': request})
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def list_staff_permissions(self, request):
        """Superuser-only endpoint to list staff members and their permissions: GET /profile/list_staff_permissions/"""
        if not request.user.is_superuser:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only superusers can manage staff permissions")

        from .serializers import StaffPermissionsSerializer
        profiles = UserProfile.objects.filter(user__is_staff=True).select_related('user').order_by('user__first_name', 'user__username')
        serializer = StaffPermissionsSerializer(profiles, many=True)
        return Response(serializer.data)

    @action(detail=False, methods=['post'])
    def update_staff_permissions(self, request):
        """Superuser-only endpoint to update a staff member's permissions: POST /profile/update_staff_permissions/?user_id=<id>"""
        if not request.user.is_superuser:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only superusers can manage staff permissions")

        user_id = request.query_params.get('user_id')
        if not user_id:
            return Response({'detail': 'user_id query parameter required'}, status=400)

        try:
            profile = UserProfile.objects.select_related('user').get(user_id=user_id)
        except UserProfile.DoesNotExist:
            return Response({'detail': 'User profile not found'}, status=404)

        if not profile.user.is_staff:
            return Response({'detail': 'Target user is not a staff member'}, status=400)

        from .serializers import StaffPermissionsSerializer
        serializer = StaffPermissionsSerializer(profile, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)

class DogViewSet(viewsets.ModelViewSet):
    serializer_class = DogSerializer
    permission_classes = [IsAuthenticated]
    pagination_class = OptInPagination

    def get_permissions(self):
        # Only staff can create or delete dogs
        if self.action in ('create', 'destroy'):
            return [IsAdminUser()]
        return super().get_permissions()

    def get_queryset(self):
        # Staff can see all dogs, Clients see dogs they own or co-own.
        # select_related/prefetch the owner profiles the serializer renders so a
        # kennel listing stays at a constant query count (B5).
        # Deterministic order (name, then id as a tie-breaker) so opt-in
        # pagination can't drop or duplicate rows across pages — Dog has no
        # Meta.ordering of its own (B6).
        base = dog_listing_queryset().order_by('name', 'id')
        if self.request.user.is_staff:
            return base.all()
        from django.db.models import Q
        return base.filter(
            Q(owner=self.request.user) | Q(additional_owners=self.request.user)
        ).distinct()

    @action(detail=False, methods=['get'])
    def calendar(self, request):
        """Owner self-serve calendar.

        GET /api/dogs/calendar/?start=YYYY-MM-DD&end=YYYY-MM-DD

        For each day in the range: which of the caller's dogs attend (daycare
        or boarding), closures, capacity/fullness, plus the caller's pending
        requests and waitlist entries. Range defaults to today -> today+60
        and is capped at 92 days.
        """
        from collections import defaultdict
        from datetime import date as date_cls, timedelta
        from django.db.models import Q
        from .models import WaitlistEntry
        from .scheduling import ScheduleIndex, daterange

        today = timezone.localdate()
        try:
            start = (
                date_cls.fromisoformat(request.query_params['start'])
                if 'start' in request.query_params else today
            )
            end = (
                date_cls.fromisoformat(request.query_params['end'])
                if 'end' in request.query_params else start + timedelta(days=60)
            )
        except ValueError:
            return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
        if end < start:
            return Response({'detail': 'end must not be before start.'}, status=400)
        if (end - start).days > 92:
            return Response({'detail': 'Date range too large (max 92 days).'}, status=400)

        my_dogs = list(
            Dog.objects.filter(Q(owner=request.user) | Q(additional_owners=request.user))
            .distinct().values('id', 'name')
        )
        my_dog_ids = {d['id'] for d in my_dogs}
        name_by_id = {d['id']: d['name'] for d in my_dogs}

        index = ScheduleIndex(start, end)

        pending_by_date = defaultdict(list)
        pending_rows = DateChangeRequest.objects.filter(
            dog_id__in=my_dog_ids, status='PENDING',
        ).filter(
            Q(original_date__range=(start, end)) | Q(new_date__range=(start, end))
        ).values('id', 'dog_id', 'request_type', 'original_date', 'new_date')
        for row in pending_rows:
            marker = {'id': row['id'], 'dog_id': row['dog_id'], 'request_type': row['request_type']}
            if row['original_date'] and start <= row['original_date'] <= end:
                pending_by_date[row['original_date']].append(marker)
            if row['new_date'] and start <= row['new_date'] <= end and row['new_date'] != row['original_date']:
                pending_by_date[row['new_date']].append(marker)

        waitlist_by_date = defaultdict(list)
        for entry in WaitlistEntry.objects.filter(dog_id__in=my_dog_ids, date__range=(start, end)):
            waitlist_by_date[entry.date].append(
                {'id': entry.id, 'dog_id': entry.dog_id, 'status': entry.status}
            )

        days = []
        for day in daterange(start, end):
            attending = index.attending_dog_ids(day)
            boarding = index.boarding_dog_ids(day)
            closure = index.closure(day)
            info = index.capacity_info(day)
            days.append({
                'date': day.isoformat(),
                'dogs': [
                    {'id': dog_id, 'name': name_by_id[dog_id], 'boarding': dog_id in boarding}
                    for dog_id in sorted(my_dog_ids & attending)
                ],
                'closure': (
                    {'closure_type': closure.closure_type, 'reason': closure.reason}
                    if closure else None
                ),
                'is_full': info['is_full'],
                'spots_left': info['spots_left'],
                'capacity': info['capacity'],
                'pending_requests': pending_by_date.get(day, []),
                'waitlist': waitlist_by_date.get(day, []),
            })

        return Response({
            'start': start.isoformat(),
            'end': end.isoformat(),
            'dogs': my_dogs,
            'days': days,
        })

    @action(detail=True, methods=['get'], url_path='past-attendance')
    def past_attendance(self, request, pk=None):
        """Staff-only: dates the dog actually attended before today.

        GET /api/dogs/{id}/past-attendance/?from=YYYY-MM-DD

        Attendance is the roster history invoicing bills from: every
        DailyDogAssignment whose status is not REMOVED. The range defaults to
        the last 12 months, matching how far back the schedule calendar lets
        payment managers scroll.
        """
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can view past attendance.")
        from datetime import date as date_cls, timedelta

        dog = self.get_object()
        today = timezone.localdate()
        since = today - timedelta(days=366)
        if 'from' in request.query_params:
            try:
                since = date_cls.fromisoformat(request.query_params['from'])
            except ValueError:
                return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)

        dates = (
            dog.daily_assignments
            .filter(date__gte=since, date__lt=today)
            .exclude(status='REMOVED')
            .order_by('date')
            .values_list('date', flat=True)
        )
        return Response({'dates': [d.isoformat() for d in dates]})

    @action(detail=False, methods=['post'])
    def bulk_import(self, request):
        """Staff-only endpoint to bulk import dog names.
        Accepts: {"names": ["Buddy", "Max", "Luna"], "owner": 1}
        Owner is optional."""
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can bulk import dogs.")
        names = request.data.get('names', [])
        owner_id = request.data.get('owner')

        if not names:
            return Response({'detail': 'names list is required'}, status=400)

        owner = None
        if owner_id:
            from django.contrib.auth.models import User
            try:
                owner = User.objects.get(id=owner_id)
            except User.DoesNotExist:
                return Response({'detail': 'Owner not found'}, status=404)

        created = []
        skipped = []
        for name in names:
            name = name.strip()
            if not name:
                continue
            existing = Dog.objects.filter(name=name)
            if owner:
                existing = existing.filter(owner=owner)
            else:
                existing = existing.filter(owner__isnull=True)
            if existing.exists():
                skipped.append(name)
                continue
            dog = Dog.objects.create(name=name, owner=owner)
            created.append({'id': dog.id, 'name': dog.name})

        return Response({
            'created': created,
            'skipped': skipped,
        }, status=201)

    def perform_create(self, serializer):
        # Staff must assign an owner when creating a dog
        self._handle_image_upload(serializer)
        if 'owner' in self.request.data:
            dog = serializer.save()
        else:
            dog = serializer.save(owner=self.request.user)
        self._maybe_geocode(dog)

    def update(self, request, *args, **kwargs):
        """Override update to route non-staff edits through the approval workflow."""
        instance = self.get_object()

        if not request.user.is_staff:
            return self._create_change_request(request, instance)

        # Staff: apply changes directly via the normal DRF path
        return super().update(request, *args, **kwargs)

    def _create_change_request(self, request, dog):
        """Build a DogProfileChangeRequest from the incoming PATCH data."""
        # Fields an owner may propose to change (shared whitelist, also re-checked
        # at approval time).
        ALLOWED_FIELDS = OWNER_EDITABLE_DOG_FIELDS

        proposed_changes = {}
        for field in ALLOWED_FIELDS:
            if field in request.data:
                new_val = request.data[field]
                # Parse daycare_days from JSON string if needed
                if field == 'daycare_days' and isinstance(new_val, str):
                    import json as _json
                    try:
                        new_val = _json.loads(new_val)
                    except (ValueError, TypeError):
                        pass
                old_val = getattr(dog, field)
                # Normalize for comparison
                if field == 'daycare_days':
                    old_val = list(old_val or [])
                    if isinstance(new_val, list):
                        new_val_cmp = sorted(new_val)
                        old_val_cmp = sorted(old_val)
                    else:
                        new_val_cmp = new_val
                        old_val_cmp = old_val
                    if new_val_cmp != old_val_cmp:
                        proposed_changes[field] = new_val
                else:
                    # Treat empty string / None as equivalent
                    old_norm = (old_val or '').strip() if isinstance(old_val, str) else old_val
                    new_norm = (new_val or '').strip() if isinstance(new_val, str) else new_val
                    if old_norm != new_norm:
                        proposed_changes[field] = new_val

        # Handle image upload / deletion
        proposed_image = None
        delete_image = False
        if 'profile_image' in request.FILES:
            proposed_image = request.FILES['profile_image']
            # Process image the same way we do for direct updates
            proposed_image = process_image(proposed_image, max_size=(800, 800))
        elif 'profile_image' in request.data and request.data['profile_image'] == '':
            delete_image = True

        # Don't create a request if nothing actually changed
        if not proposed_changes and not proposed_image and not delete_image:
            # Return the current dog as-is (nothing to approve)
            serializer = self.get_serializer(dog)
            return Response(serializer.data, status=200)

        change_request = DogProfileChangeRequest.objects.create(
            dog=dog,
            requested_by=request.user,
            proposed_changes=proposed_changes,
            proposed_image=proposed_image,
            delete_image=delete_image,
        )

        # Notify staff about the pending change
        try:
            from .notifications import send_staff_notification
            owner_name = request.user.first_name or request.user.username
            title = "Dog Profile Change Request"
            body = f"{owner_name} wants to update {dog.name}'s profile."
            data = {
                'type': 'dog_profile_change',
                'id': str(change_request.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            send_staff_notification(title, body, data, permission='can_manage_requests')
        except Exception as e:
            print(f"Failed to send push notification: {e}")

        from .serializers import DogProfileChangeRequestSerializer
        result = DogProfileChangeRequestSerializer(change_request, context={'request': request}).data
        return Response(
            {
                'detail': 'Your changes have been submitted for approval.',
                'change_request': result,
            },
            status=202,
        )

    def perform_update(self, serializer):
        self._handle_image_upload(serializer)

        # Transport default fields, is_spayed and billing rates are staff-only.
        # Strip them from validated_data when the caller is not staff.
        if not self.request.user.is_staff:
            for field in ('owner_brings_default', 'owner_collects_default',
                          'owner_brings_default_time', 'owner_collects_default_time',
                          'is_spayed', 'daily_rate', 'boarding_rate'):
                serializer.validated_data.pop(field, None)

        # Attach the requesting user so the care-instructions signal can
        # include who made the change in the staff notification.
        serializer.instance._changed_by = self.request.user

        # Capture prior values so we can clean up the persistent pickup roster
        # when the dog's schedule changes.
        dog = serializer.instance
        old_daycare_days = list(dog.daycare_days or [])
        old_schedule_type = dog.schedule_type

        serializer.save()

        dog.refresh_from_db()
        # Refresh cached pickup coordinates if the address changed.
        self._maybe_geocode(dog)
        new_daycare_days = list(dog.daycare_days or [])
        new_schedule_type = dog.schedule_type

        # If the dog became ad-hoc, wipe its entire roster.
        if old_schedule_type != 'ad_hoc' and new_schedule_type == 'ad_hoc':
            DogWeekdayPickup.objects.filter(dog=dog).delete()
            return

        # Otherwise, drop roster entries for weekdays that are no longer part
        # of the dog's schedule.
        if set(old_daycare_days) != set(new_daycare_days):
            dropped = set(old_daycare_days) - set(new_daycare_days)
            if dropped:
                DogWeekdayPickup.objects.filter(
                    dog=dog,
                    weekday__in=dropped,
                ).delete()

    @action(detail=False, methods=['get'])
    def unspayed_males(self, request):
        """Staff-only: list male dogs over 1 year old that are not yet spayed.

        Dogs with no recorded date_of_birth are excluded because their age
        is unknown. Used by the staff dashboard to prompt asking owners.
        """
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Staff only.")

        cutoff = timezone.now().date() - timezone.timedelta(days=365)
        qs = Dog.objects.filter(
            sex='M',
            is_spayed=False,
            date_of_birth__isnull=False,
            date_of_birth__lte=cutoff,
        ).order_by('name')
        return Response({
            'count': qs.count(),
            'dogs': [
                {
                    'id': d.id,
                    'name': d.name,
                    'profile_image': (
                        request.build_absolute_uri(d.profile_image.url)
                        if d.profile_image else None
                    ),
                }
                for d in qs
            ],
        })

    def destroy(self, request, *args, **kwargs):
        """Staff-only endpoint to delete a dog and clean up associated data."""
        dog = self.get_object()
        dog_name = dog.name
        dog_id = dog.id

        # Delete associated media files from storage
        if dog.profile_image:
            dog.profile_image.delete(save=False)
        for photo in dog.photos.all():
            if photo.file:
                photo.file.delete(save=False)
            if photo.thumbnail:
                photo.thumbnail.delete(save=False)

        dog.delete()
        return Response({'detail': f'{dog_name} has been deleted.', 'id': dog_id}, status=200)

    @action(detail=True, methods=['post'])
    def assign(self, request, pk=None):
        """Staff-only endpoint to assign a dog to a user.
        Accepts: {"owner": <user_id>} and/or {"additional_owners": [<user_id>, ...]}
        Pass owner as null to remove the primary owner.
        Pass additional_owners to replace the full list of additional owners."""
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can assign dogs to users.")

        dog = self.get_object()
        from django.contrib.auth.models import User

        if 'owner' in request.data:
            owner_id = request.data.get('owner')
            if owner_id is None:
                dog.owner = None
            else:
                try:
                    owner = User.objects.get(id=owner_id)
                except User.DoesNotExist:
                    return Response({'detail': 'Owner not found.'}, status=404)
                dog.owner = owner
            dog.save()

        if 'additional_owners' in request.data:
            additional_owner_ids = request.data.get('additional_owners', [])
            additional_owners = User.objects.filter(id__in=additional_owner_ids)
            if len(additional_owners) != len(additional_owner_ids):
                return Response({'detail': 'One or more additional owners not found.'}, status=404)
            dog.additional_owners.set(additional_owners)

        serializer = self.get_serializer(dog)
        return Response(serializer.data)

    def _handle_image_upload(self, serializer):
        if 'profile_image' in serializer.validated_data:
            image_file = serializer.validated_data['profile_image']
            if image_file:
                # Resize profile images to max 800x800
                processed_image = process_image(image_file, max_size=(800, 800))
                serializer.validated_data['profile_image'] = processed_image

    def _maybe_geocode(self, dog):
        """Best-effort refresh of the dog's cached pickup coordinates after a
        save. Blocks only briefly — the postcode lookup is bounded by a short
        provider timeout — and failures are swallowed so a save is never lost.
        Cron (geocode_dogs) is the backstop for any address it couldn't reach (B32)."""
        try:
            from .geocoding import geocode_dog
            geocode_dog(dog)
        except Exception as e:
            print(f"Geocoding failed for dog {getattr(dog, 'id', '?')}: {e}")

class DogProfileChangeRequestViewSet(viewsets.ReadOnlyModelViewSet):
    """View and manage dog profile change requests.

    Owners see requests for their own dogs.  Staff see all requests and can
    approve or reject them via the ``/approve/`` and ``/reject/`` actions.
    """
    serializer_class = DogProfileChangeRequestSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        qs = DogProfileChangeRequest.objects.select_related(
            'dog', 'requested_by', 'reviewed_by',
        )
        if self.request.user.is_staff:
            status = self.request.query_params.get('status')
            if status:
                qs = qs.filter(status=status.upper())
            return qs
        from django.db.models import Q
        return qs.filter(
            Q(dog__owner=self.request.user) | Q(dog__additional_owners=self.request.user)
        ).distinct()

    @action(detail=True, methods=['post'])
    def approve(self, request, pk=None):
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can approve change requests.")

        change_request = self.get_object()
        if change_request.status != 'PENDING':
            return Response(
                {'detail': f'Request is already {change_request.get_status_display().lower()}.'},
                status=400,
            )

        dog = change_request.dog

        # Apply proposed text/JSON field changes. Re-enforce the whitelist here
        # so a malformed/stale proposed_changes can never write a field an owner
        # was never allowed to edit, e.g. owner (B19).
        for field, value in change_request.proposed_changes.items():
            if field in OWNER_EDITABLE_DOG_FIELDS and hasattr(dog, field):
                setattr(dog, field, value)

        # Apply image changes
        if change_request.delete_image:
            if dog.profile_image:
                dog.profile_image.delete(save=False)
            dog.profile_image = None
        elif change_request.proposed_image:
            # Delete old image file first
            if dog.profile_image:
                dog.profile_image.delete(save=False)
            dog.profile_image = change_request.proposed_image

        # Handle schedule/roster side-effects (same logic as perform_update)
        old_daycare_days = list(dog.daycare_days or [])
        old_schedule_type = dog.schedule_type

        # Attribute the change to the owner who requested it so the
        # care-instructions staff notification names them (not "A user").
        dog._changed_by = change_request.requested_by
        dog.save()

        dog.refresh_from_db()
        # Refresh cached pickup coordinates if an approved change altered the
        # address. Best-effort, bounded by the short provider timeout (B32).
        try:
            from .geocoding import geocode_dog
            geocode_dog(dog)
        except Exception as e:
            print(f"Geocoding failed for dog {getattr(dog, 'id', '?')}: {e}")
        new_daycare_days = list(dog.daycare_days or [])
        new_schedule_type = dog.schedule_type

        if old_schedule_type != 'ad_hoc' and new_schedule_type == 'ad_hoc':
            DogWeekdayPickup.objects.filter(dog=dog).delete()
        elif set(old_daycare_days) != set(new_daycare_days):
            dropped = set(old_daycare_days) - set(new_daycare_days)
            if dropped:
                DogWeekdayPickup.objects.filter(dog=dog, weekday__in=dropped).delete()

        # Mark as approved
        change_request.status = 'APPROVED'
        change_request.reviewed_by = request.user
        change_request.reviewed_at = timezone.now()
        change_request.save()

        # Notify the owner
        try:
            from .notifications import send_push_notification
            staff_name = request.user.first_name or request.user.username
            title = "Profile Update Approved"
            body = f"Your changes to {dog.name}'s profile have been approved by {staff_name}."
            data = {
                'type': 'dog_profile_change_approved',
                'id': str(change_request.id),
                'dog_id': str(dog.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            send_push_notification(change_request.requested_by, title, body, data)
        except Exception as e:
            print(f"Failed to send push notification: {e}")

        serializer = self.get_serializer(change_request)
        return Response(serializer.data)

    @action(detail=True, methods=['post'])
    def reject(self, request, pk=None):
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can reject change requests.")

        change_request = self.get_object()
        if change_request.status != 'PENDING':
            return Response(
                {'detail': f'Request is already {change_request.get_status_display().lower()}.'},
                status=400,
            )

        change_request.status = 'REJECTED'
        change_request.reviewed_by = request.user
        change_request.reviewed_at = timezone.now()
        change_request.save()

        # Clean up the proposed image file if any
        if change_request.proposed_image:
            change_request.proposed_image.delete(save=False)

        # Notify the owner
        try:
            from .notifications import send_push_notification
            staff_name = request.user.first_name or request.user.username
            title = "Profile Update Rejected"
            body = f"Your changes to {change_request.dog.name}'s profile were not approved."
            data = {
                'type': 'dog_profile_change_rejected',
                'id': str(change_request.id),
                'dog_id': str(change_request.dog.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            send_push_notification(change_request.requested_by, title, body, data)
        except Exception as e:
            print(f"Failed to send push notification: {e}")

        serializer = self.get_serializer(change_request)
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def pending_count(self, request):
        """Return the number of pending change requests (staff only)."""
        if not request.user.is_staff:
            return Response({'count': 0})
        count = DogProfileChangeRequest.objects.filter(status='PENDING').count()
        return Response({'count': count})


class PhotoViewSet(viewsets.ModelViewSet):
    serializer_class = PhotoSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        base = Photo.objects.select_related('dog').prefetch_related('comments__user')
        if self.request.user.is_staff:
            return base.all()
        from django.db.models import Q
        return base.filter(
            Q(dog__owner=self.request.user) | Q(dog__additional_owners=self.request.user)
        ).distinct()

    def perform_create(self, serializer):
        # Validate that user owns the dog or is staff
        _require_dog_access(
            self.request.user,
            serializer.validated_data['dog'],
            "You can only upload photos for your own dogs",
        )

        # Generate thumbnail and resize for photos
        media_type = serializer.validated_data.get('media_type', 'PHOTO')
        if media_type == 'VIDEO':
            thumb = generate_video_thumbnail(serializer.validated_data.get('file'))
            if thumb:
                serializer.validated_data['thumbnail'] = thumb
        elif media_type == 'PHOTO':
            image_file = serializer.validated_data.get('file')
            if image_file:
                # Decode once, derive both the resized photo and its thumbnail (B31)
                processed_image, thumbnail = process_image_pair(image_file)
                serializer.validated_data['file'] = processed_image
                if thumbnail:
                    serializer.validated_data['thumbnail'] = thumbnail

        instance = serializer.save()
        self._notify_owners_of_new_photo(instance)

    def perform_update(self, serializer):
        # get_queryset only decides which photos a caller may *fetch*. `dog` is
        # writable, so without this an owner could PATCH one of their own photos
        # onto someone else's dog: the image lands in a stranger's gallery and
        # leaves the uploader's queryset, so they can no longer see or delete it.
        _require_dog_access(
            self.request.user,
            serializer.validated_data.get('dog', serializer.instance.dog),
            "You can only move photos between your own dogs",
        )
        serializer.save()

    def perform_destroy(self, instance):
        # Staff only. A dog's gallery is where staff photograph vaccination
        # cards and other medical paperwork, so a photo is a record the
        # business keeps — an owner deleting one destroys it for everybody.
        # Owners can still see their dog's gallery and add to it; taking one
        # back out is a staff decision. (Deleting the dog still clears them
        # all — see DogViewSet.destroy.)
        if not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied(
                "Only staff can delete photos. Ask us to remove it for you.")

        # Remove the files too. DogViewSet.destroy already does this; deleting a
        # single photo did not, so its image and thumbnail stayed on disk
        # forever — and the prune_feed_media orphan sweep is a weekly backstop,
        # not a substitute.
        if instance.file:
            instance.file.delete(save=False)
        if instance.thumbnail:
            instance.thumbnail.delete(save=False)
        instance.delete()

    def _notify_owners_of_new_photo(self, instance):
        """Notify the dog's owner(s) when a new photo/video is added to their
        dog's gallery.

        The uploader is never notified about their own upload, and bulk uploads
        are de-duplicated: only the first item within a short window triggers a
        notification so owners are not spammed when staff add several photos at
        once (the gallery has no batch endpoint — each photo posts separately).
        """
        dog = instance.dog

        # Skip if another photo for this dog was added very recently — assume it
        # is part of the same batch and the owner has already been notified.
        recent_cutoff = timezone.now() - timezone.timedelta(minutes=30)
        if Photo.objects.filter(dog=dog, created_at__gte=recent_cutoff).exclude(id=instance.id).exists():
            return

        uploader_id = self.request.user.id
        recipients = []
        if dog.owner and dog.owner_id != uploader_id:
            recipients.append(dog.owner)
        for additional_owner in dog.additional_owners.all():
            if additional_owner.id != uploader_id:
                recipients.append(additional_owner)
        if not recipients:
            return

        word = 'video' if instance.media_type == 'VIDEO' else 'photo'
        title = f"New {word} of {dog.name}"
        body = f"A new {word} of {dog.name} has been added to their profile."
        data = {
            'type': 'dog_photo',
            'dog_id': str(dog.id),
            'photo_id': str(instance.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
        try:
            from .notifications import send_push_notification
            for recipient in recipients:
                send_push_notification(recipient, title, body, data, category='dog_updates')
        except Exception as e:
            print(f"Failed to send photo notification: {e}")

    @action(detail=True, methods=['post'])
    def comment(self, request, pk=None):
        photo = self.get_object()
        text = request.data.get('text')
        if not text:
            return Response({'detail': 'Text is required'}, status=400)
        
        Comment.objects.create(user=request.user, photo=photo, text=text)
        return Response(self.get_serializer(photo).data)

    @action(detail=False, methods=['get'])
    def by_dog(self, request):
        """Get all photos for a specific dog: /photos/by_dog/?dog_id=<id>"""
        dog_id = request.query_params.get('dog_id')
        if not dog_id:
            return Response({'detail': 'dog_id query parameter required'}, status=400)
        
        try:
            dog = Dog.objects.get(id=dog_id)
        except Dog.DoesNotExist:
            return Response({'detail': 'Dog not found'}, status=404)
        
        # Check permissions
        if dog.owner != request.user and not request.user.is_staff and not dog.additional_owners.filter(id=request.user.id).exists():
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("You can only view photos for your own dogs")
        
        photos = Photo.objects.filter(dog=dog).order_by('-created_at')
        serializer = self.get_serializer(photos, many=True)
        return Response(serializer.data)

class DateChangeRequestViewSet(viewsets.ModelViewSet):
    serializer_class = DateChangeRequestSerializer
    permission_classes = [IsAuthenticated]
    pagination_class = OptInPagination

    def get_queryset(self):
        base = DateChangeRequest.objects.select_related('dog', 'dog__owner', 'approved_by')
        if self.request.user.is_staff:
            return base.all()
        from django.db.models import Q
        return base.filter(
            Q(dog__owner=self.request.user) | Q(dog__additional_owners=self.request.user)
        ).distinct()

    @staticmethod
    def _apply_approved_schedule_change(instance, past_added_by=None):
        """Apply the roster side-effects of approving a CANCEL/CHANGE request.

        Must run inside the approval transaction so the request can never end up
        APPROVED with a stale roster.

        * CANCEL/CHANGE free the original date: the assignment there is removed
          and the waitlist is processed.
        * ADD_DAY/CHANGE put the dog onto the new date. We deliberately do not
          assign a driver here — the dog shows up in the unassigned list for
          staff to pick a driver — but we must clear any stale REMOVED marker
          on the new date. Without that, the dog is treated as "already cancelled
          for this day" and would never surface anywhere (the approved addition
          would silently do nothing on the target day).

        Past dates get special handling (payment managers may correct billing
        history): freeing a past date never processes the waitlist (nobody can
        be offered a spot on a day that already happened), and adding a past
        day must create the attendance row directly — roster materialization
        deliberately never runs for past dates, so without the row the added
        day would be invisible to invoicing. ``past_added_by`` is the staff
        member recorded on such a row; when None (the change_status approval
        path, where a stale request may be approved after its date has passed)
        past additions are skipped rather than fabricating attendance.
        """
        from datetime import date as date_cls
        from .scheduling import process_waitlist_for_date

        today = timezone.localdate()

        if instance.request_type in ('CANCEL', 'CHANGE') and instance.original_date:
            DailyDogAssignment.objects.filter(
                dog=instance.dog, date=instance.original_date,
            ).delete()
            if instance.original_date >= today:
                try:
                    process_waitlist_for_date(instance.original_date)
                except Exception as e:
                    print(f"Failed to process waitlist: {e}")

        if instance.request_type in ('ADD_DAY', 'CHANGE') and instance.new_date:
            # Clear a prior "removed from this day" marker so the addition takes
            # effect; the dog then surfaces in unassigned_dogs for the new date
            # (an approved ADD_DAY/CHANGE counts as an added day there). A dog
            # staff removed from a day can therefore be put back on it by
            # approving a new request for that same day.
            DailyDogAssignment.objects.filter(
                dog=instance.dog, date=instance.new_date, status='REMOVED',
            ).delete()

        if (
            past_added_by is not None
            and instance.request_type in ('ADD_DAY', 'CHANGE')
            and instance.new_date and instance.new_date < today
        ):
            # UNASSIGNED = "attended, no staff member" — bills the day without
            # fabricating who drove the dog on a day that already happened.
            assignment, created = DailyDogAssignment.objects.get_or_create(
                dog=instance.dog, date=instance.new_date,
                defaults={'staff_member': past_added_by, 'status': 'UNASSIGNED'},
            )
            if not created and assignment.status == 'REMOVED':
                assignment.status = 'UNASSIGNED'
                assignment.staff_member = past_added_by
                assignment.save(update_fields=['status', 'staff_member', 'updated_at'])

    def _check_dog_and_dates(self, dog, original_date, new_date):
        """Ownership + past-date guards shared by create and update.

        These must run on *both* paths. `dog` is writable on the serializer and
        get_queryset only scopes reads, so without the update path an owner
        could PATCH their own pending request onto another customer's dog — and
        on approval `_apply_approved_schedule_change` would delete that
        customer's assignment — or move a date into the past to dodge the
        payments-manager gate.
        """
        _require_dog_access(
            self.request.user, dog, "You can only create requests for your own dogs")

        # Past dates are attendance history that feeds invoicing, so only staff
        # who can manage payments may touch them. Owners (and other staff) are
        # limited to today onwards.
        from django.utils import timezone
        today = timezone.localdate()
        if any(d and d < today for d in (original_date, new_date)):
            from rest_framework.exceptions import PermissionDenied
            if not self.request.user.is_staff:
                raise PermissionDenied("Dates in the past can't be changed. Contact the daycare if a past day looks wrong.")
            if not _user_can_manage_payments(self.request.user):
                raise PermissionDenied("Only staff who can manage payments can edit past dates.")

    def perform_update(self, serializer):
        instance = serializer.instance
        data = serializer.validated_data
        self._check_dog_and_dates(
            data.get('dog', instance.dog),
            data.get('original_date', instance.original_date),
            data.get('new_date', instance.new_date),
        )
        serializer.save()

    def perform_create(self, serializer):
        dog = serializer.validated_data['dog']
        original_date = serializer.validated_data.get('original_date')
        new_date = serializer.validated_data.get('new_date')
        self._check_dog_and_dates(dog, original_date, new_date)

        from django.utils import timezone
        today = timezone.localdate()

        # Auto-approve any date change request created by staff — owner-created
        # requests stay PENDING and go through the normal approval workflow.
        if not self.request.user.is_staff:
            # Compute the late-change fee server-side; never trust the client (B2).
            serializer.save(is_charged=_compute_date_change_is_charged(
                serializer.validated_data.get('request_type'),
                serializer.validated_data.get('original_date'),
            ))
            return

        # Staff auto-approval puts the dog straight onto new_date. The capacity
        # check, approval, history row and original-date unassignment all run in
        # one transaction so a mid-way failure can't leave the request approved
        # without history or with a stale assignment (B11/B12). The transaction
        # is not a lock — see the note in change_status; capacity is a soft
        # limit and override_capacity is the supported way past it.
        request_type = serializer.validated_data.get('request_type')
        override = _truthy(self.request.data.get('override_capacity'))

        from django.db import transaction
        with transaction.atomic():
            # Past days already happened, so capacity is meaningless there —
            # only future additions compete for spots.
            if request_type in ('ADD_DAY', 'CHANGE') and new_date and new_date >= today:
                from .scheduling import capacity_check
                fits, info = capacity_check(new_date, dog_id=dog.id)
                if not fits and not override:
                    from rest_framework import serializers as drf_serializers
                    raise drf_serializers.ValidationError({
                        'detail': (
                            f"{new_date} is full ({info['booked']}/{info['capacity']} dogs). "
                            "Send override_capacity=true to add anyway."
                        ),
                        'code': 'capacity_full',
                    })

            instance = serializer.save(
                status='APPROVED',
                approved_by=self.request.user,
                approved_at=timezone.now(),
            )

            # Record history
            DateChangeRequestHistory.objects.create(
                request=instance,
                changed_by=self.request.user,
                from_status='PENDING',
                to_status='APPROVED',
            )

            # A CANCEL frees the original date; a CHANGE frees the original date
            # and moves the dog onto the new one (clearing any stale removal so
            # it lands in the unassigned list for the new date). Staff-created
            # additions of past days also materialize the attendance row here.
            self._apply_approved_schedule_change(instance, past_added_by=self.request.user)

        # Notify dog owners (best-effort, after the transaction commits — a push
        # failure must never roll back the approval).
        try:
            from .notifications import send_push_notification
            if instance.request_type == 'ADD_DAY':
                title = "Additional Day Added"
                body = f"An additional day for {instance.dog.name} on {instance.new_date} has been added by staff."
            elif instance.request_type == 'CANCEL':
                title = "Day Cancelled"
                body = f"{instance.dog.name}'s day on {instance.original_date} has been cancelled by staff."
            else:  # CHANGE
                title = "Day Changed"
                body = (
                    f"{instance.dog.name}'s day has been changed from "
                    f"{instance.original_date} to {instance.new_date} by staff."
                )
            # 'date_change_request_update' is the type the app deep-links to
            # the requests screen; category 'bookings' honours the owner's
            # notification preferences.
            data = {
                'type': 'date_change_request_update',
                'id': str(instance.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            if instance.dog.owner:
                send_push_notification(instance.dog.owner, title, body, data, category='bookings')
            for additional_owner in instance.dog.additional_owners.all():
                send_push_notification(additional_owner, title, body, data, category='bookings')
        except Exception as e:
            print(f"Failed to send push notification: {e}")

    @action(detail=True, methods=['post'])
    def change_status(self, request, pk=None):
        # Only staff may change status via this endpoint
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can change request status")

        instance = self.get_object()
        new_status = request.data.get('status')
        if new_status not in dict(DateChangeRequest.STATUS_CHOICES).keys():
            return Response({'detail': 'Invalid status'}, status=400)

        old_status = instance.status
        if old_status == new_status:
            return Response({'detail': 'Status unchanged'}, status=200)

        override = _truthy(request.data.get('override_capacity'))
        from django.db import transaction
        from django.utils import timezone
        from .models import DateChangeRequestHistory

        # Status change, original-date unassignment and the history row run in
        # one transaction, so a mid-way failure can't leave the request APPROVED
        # without history or with a stale assignment (B11/B12).
        #
        # NOTE: atomic() alone is NOT mutual exclusion. capacity_check is plain
        # SELECTs under READ COMMITTED and there is no constraint on
        # dogs-per-date, so two managers approving in the same second can both
        # read 19 < 20 and both pass. Capacity is a soft limit here by design
        # (override_capacity exists precisely to exceed it), so this is accepted
        # rather than fixed with an advisory lock — but do not read the
        # transaction as a guard against it.
        with transaction.atomic():
            # No capacity check for dates that have already passed — approving a
            # stale request can't overbook a day that already happened.
            from datetime import date as date_cls
            if new_status == 'APPROVED' and instance.request_type in ('ADD_DAY', 'CHANGE') and instance.new_date and instance.new_date >= timezone.localdate():
                from .scheduling import capacity_check
                fits, info = capacity_check(instance.new_date, dog_id=instance.dog_id)
                if not fits and not override:
                    return Response({
                        'detail': (
                            f"{instance.new_date} is full ({info['booked']}/{info['capacity']} dogs). "
                            "Send override_capacity=true to approve anyway."
                        ),
                        'code': 'capacity_full',
                    }, status=400)

            if new_status == 'APPROVED':
                instance.approved_by = request.user
                instance.approved_at = timezone.now()
            instance.status = new_status
            # This endpoint sends its own, more detailed owner push below —
            # stop the status-change signal from sending a second one.
            instance._owner_push_handled = True
            instance.save()

            # Approving a CANCEL frees the original date; approving a CHANGE frees
            # the original date and moves the dog onto the new one (clearing any
            # stale removal so it lands in the unassigned list for the new date).
            if new_status == 'APPROVED':
                self._apply_approved_schedule_change(instance)

            # History is recorded in the same transaction so an approval always
            # has its audit row (previously it could be skipped if notification
            # setup raised) (B12).
            DateChangeRequestHistory.objects.create(
                request=instance,
                changed_by=request.user,
                from_status=old_status,
                to_status=new_status,
            )

        # Send push notification to all owners — after commit, best-effort.
        try:
            from .notifications import send_push_notification
            title = f"Request {new_status.title()}"
            if instance.request_type == 'ADD_DAY':
                body = f"Your additional day request for {instance.dog.name} on {instance.new_date} has been {new_status.lower()}."
            else:
                body = f"Your {instance.request_type.lower()} request for {instance.dog.name} on {instance.original_date} has been {new_status.lower()}."
            data = {
                'type': 'date_change_request_update',
                'id': str(instance.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            if instance.dog.owner:
                send_push_notification(instance.dog.owner, title, body, data, category='bookings')
            for additional_owner in instance.dog.additional_owners.all():
                send_push_notification(additional_owner, title, body, data, category='bookings')
        except Exception as e:
            print(f"Failed to send push notification: {e}")

        serializer = self.get_serializer(instance)
        return Response(serializer.data)

class GroupMediaViewSet(viewsets.ModelViewSet):
    serializer_class = GroupMediaSerializer
    permission_classes = [IsAuthenticated]
    pagination_class = FeedPagination

    def _feed_queryset(self):
        # Prefetch every relation the serializer touches so rendering a page of
        # feed items stays at a small, constant number of queries instead of
        # N+1 (uploader profile, comments + their authors, reactions, tags).
        # The current user's own reactions are prefetched into a separate
        # attribute so get_user_reaction() needs no extra per-item query.
        # No request-param filtering here, so it is safe to re-fetch a single
        # already-permitted item after a write (B26).
        user_reactions = Prefetch(
            'reactions',
            queryset=MediaReaction.objects.filter(user=self.request.user),
            to_attr='my_reactions',
        )
        return (
            GroupMedia.objects
            .select_related('uploaded_by', 'uploaded_by__profile')
            .prefetch_related('tagged_dogs', 'comments__user', 'reactions', user_reactions)
            # Deterministic tie-breaker so paging can't drop or duplicate rows
            # when several items share a created_at second (B30).
            .order_by('-created_at', '-id')
        )

    def get_queryset(self):
        qs = self._feed_queryset()
        dog_id = self.request.query_params.get('dog_id')
        if dog_id:
            qs = qs.filter(tagged_dogs__id=dog_id).distinct()
        return qs

    def get_permissions(self):
        # Only staff can create, update, or delete
        if self.action in ['create', 'update', 'partial_update', 'destroy']:
            return [IsAdminUser()]
        return [IsAuthenticated()]

    def perform_create(self, serializer):
        try:
            print(f"Creating GroupMedia for user: {self.request.user}")
            # Generate thumbnail and resize for photos
            media_type = serializer.validated_data.get('media_type', 'PHOTO')
            if media_type == 'VIDEO':
                thumb = generate_video_thumbnail(serializer.validated_data.get('file'))
                if thumb:
                    serializer.validated_data['thumbnail'] = thumb
            elif media_type == 'PHOTO':
                image_file = serializer.validated_data.get('file')
                if image_file:
                    # Decode once, derive both the resized photo and its thumbnail (B31)
                    processed_image, thumbnail = process_image_pair(image_file)
                    serializer.validated_data['file'] = processed_image
                    if thumbnail:
                        serializer.validated_data['thumbnail'] = thumbnail

            instance = serializer.save(uploaded_by=self.request.user)

        except Exception as e:
            import traceback
            traceback.print_exc()
            raise e

    @action(detail=True, methods=['get'])
    def reaction_details(self, request, pk=None):
        media = self.get_object()
        reactions = MediaReaction.objects.filter(media=media).select_related('user')
        
        data = []
        for reaction in reactions:
            user_name = reaction.user.first_name if reaction.user.first_name else reaction.user.username
            data.append({
                'user_id': reaction.user.id,
                'user_name': user_name,
                'emoji': reaction.emoji
            })
            
        return Response(data)

    @action(detail=True, methods=['post'])
    def react(self, request, pk=None):
        media = self.get_object()
        emoji = request.data.get('emoji')
        
        if not emoji:
            return Response({'detail': 'Emoji is required'}, status=400)
        
        # Check if this exact reaction already exists for this user
        existing_reaction = MediaReaction.objects.filter(media=media, user=request.user, emoji=emoji).first()
        
        if existing_reaction:
            # If it exists, remove it (toggle off)
            existing_reaction.delete()
        else:
            # If user has any other reaction on this media, remove it (only one reaction per user/post)
            MediaReaction.objects.filter(media=media, user=request.user).delete()
            # Add the new reaction
            MediaReaction.objects.create(media=media, user=request.user, emoji=emoji)

        # Re-fetch so the response reflects the toggle instead of the stale
        # prefetched reactions on the original instance.
        media = self._feed_queryset().get(pk=media.pk)
        return Response(self.get_serializer(media).data)

    @action(detail=True, methods=['post'])
    def comment(self, request, pk=None):
        media = self.get_object()
        text = request.data.get('text')
        if not text:
            return Response({'detail': 'Text is required'}, status=400)

        comment = Comment.objects.create(user=request.user, group_media=media, text=text)

        # Notify post owner and previous commenters
        try:
            from .notifications import notify_post_comment
            notify_post_comment(comment, media)
        except Exception as e:
            print(f"Failed to send comment notification: {e}")

        # Re-fetch so the response includes the new comment instead of the
        # stale prefetched comments on the original instance.
        media = self._feed_queryset().get(pk=media.pk)
        return Response(self.get_serializer(media).data)

    @action(detail=False, methods=['get'])
    def today_stats(self, request):
        from django.utils import timezone
        today = timezone.localdate()
        qs = GroupMedia.objects.filter(created_at__date=today)
        return Response({
            'photos': qs.filter(media_type='PHOTO').count(),
            'videos': qs.filter(media_type='VIDEO').count(),
        })

class CommentViewSet(viewsets.GenericViewSet, mixins.DestroyModelMixin):
    queryset = Comment.objects.all()
    serializer_class = CommentSerializer
    permission_classes = [IsAuthenticated]

    def perform_destroy(self, instance):
        # Only allow deleting own comments or staff
        if instance.user == self.request.user or self.request.user.is_staff:
            instance.delete()
        else:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("You can only delete your own comments.")

def _user_can_manage_boarding(user):
    if user.is_superuser:
        return True
    return user.is_staff and getattr(getattr(user, 'profile', None), 'can_manage_boarding', False)


class BoardingRequestViewSet(viewsets.ModelViewSet):
    serializer_class = BoardingRequestSerializer
    permission_classes = [IsAuthenticated]
    pagination_class = OptInPagination

    def get_queryset(self):
        # All staff keep read access — the day board and Boarding Tonight rely
        # on this data for care logistics. Managing requests (approve/deny/
        # edit/delete) additionally requires profile.can_manage_boarding.
        base = BoardingRequest.objects.select_related('owner', 'approved_by').prefetch_related(
            'dogs', 'history__changed_by'
        )
        if self.request.user.is_staff:
            return base.all()
        # Co-owners see (and can amend) bookings for the dogs they co-own, not
        # only ones they personally created — otherwise a partner gets a 404 on
        # a booking for their own dog.
        from django.db.models import Q
        return base.filter(
            Q(owner=self.request.user) | Q(dogs__additional_owners=self.request.user)
        ).distinct()

    def perform_destroy(self, instance):
        # Boarding managers can delete any booking (e.g. removing duplicates);
        # owners can only withdraw their own requests while they're still
        # PENDING — an approved booking must be denied/changed by a manager,
        # not silently deleted by the owner.
        if self.request.user.is_staff:
            if not _user_can_manage_boarding(self.request.user):
                from rest_framework.exceptions import PermissionDenied
                raise PermissionDenied('You do not have permission to manage boarding requests.')
        elif instance.status != 'PENDING':
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('Only staff can delete a booking that has been approved or denied.')
        # Release the daycare attendance this stay booked before the stay (and
        # its dog list) is gone — afterwards there is nothing left to derive it
        # from, and the rows would sit on the roster forever.
        if instance.status == 'APPROVED':
            from .scheduling import clear_boarding_daycare_assignments
            try:
                clear_boarding_daycare_assignments(instance)
            except Exception as e:
                print(f"Failed to release boarding daycare attendance: {e}")
        instance.delete()

    def perform_update(self, serializer):
        # Owners can amend their own request only while it's still PENDING —
        # once a booking is approved/denied, changes go through a boarding
        # manager (who can edit any booking, e.g. to shift the dates of an
        # approved stay). Other staff are view-only.
        if self.request.user.is_staff:
            if not _user_can_manage_boarding(self.request.user):
                from rest_framework.exceptions import PermissionDenied
                raise PermissionDenied('You do not have permission to manage boarding requests.')
        elif serializer.instance.status != 'PENDING':
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('Only staff can edit a booking that has been approved or denied.')

        old_start = serializer.instance.start_date
        old_end = serializer.instance.end_date
        old_dog_ids = set(serializer.instance.dogs.values_list('id', flat=True))
        instance = serializer.save()

        # Moving the dates (or the dogs) of an approved stay moves its daycare
        # attendance with it: days the stay no longer covers are released,
        # days it still covers keep whatever progress they already have.
        if (
            instance.status == 'APPROVED'
            and (instance.start_date != old_start or instance.end_date != old_end
                 or set(instance.dogs.values_list('id', flat=True)) != old_dog_ids)
        ):
            from .scheduling import (
                boarding_daycare_dates, clear_boarding_daycare_assignments,
                sync_boarding_daycare_assignments,
            )
            try:
                dropped = (
                    set(boarding_daycare_dates(old_start, old_end))
                    - set(boarding_daycare_dates(instance.start_date, instance.end_date))
                )
                # Dogs taken off the booking are cleared over the whole old
                # range; the remaining dogs only lose the days that went away.
                # (A dog dropped from one stay but still covered by another is
                # re-booked by materialize_boarding_for_date on the next load.)
                removed_dogs = old_dog_ids - set(instance.dogs.values_list('id', flat=True))
                if removed_dogs:
                    from .models import DailyDogAssignment
                    DailyDogAssignment.objects.filter(
                        dog_id__in=removed_dogs,
                        date__in=boarding_daycare_dates(old_start, old_end),
                        from_boarding=True,
                    ).delete()
                if dropped:
                    clear_boarding_daycare_assignments(instance, dates=sorted(dropped))
                sync_boarding_daycare_assignments(instance)
            except Exception as e:
                print(f"Failed to move boarding daycare attendance: {e}")

        # Let the owner know when staff move the dates of their booking.
        if (
            self.request.user.is_staff
            and self.request.user != instance.owner
            and (instance.start_date != old_start or instance.end_date != old_end)
        ):
            try:
                from .notifications import send_push_notification
                dogs = ', '.join(d.name for d in instance.dogs.all())
                body = (
                    f"The dates for {dogs}'s boarding have been updated to "
                    f"{instance.start_date.strftime('%d/%m/%Y')} - {instance.end_date.strftime('%d/%m/%Y')}."
                )
                send_push_notification(
                    instance.owner,
                    'Boarding Booking Updated',
                    body,
                    {
                        'type': 'boarding_request_update',
                        'id': str(instance.id),
                        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
                    },
                    category='bookings',
                )
            except Exception as e:
                print(f"Failed to send push notification: {e}")

    def _resolve_assigned_staff(self, staff_id):
        """Resolve a staff user id to a User, or None. Ignores non-staff ids."""
        if staff_id in (None, ''):
            return None
        from django.contrib.auth.models import User
        try:
            return User.objects.get(pk=staff_id, is_staff=True)
        except (User.DoesNotExist, ValueError, TypeError):
            return None

    def _notify_owner_boarding_status(self, instance, new_status):
        # The single owner-facing status notification (the old model signal
        # duplicated this). Type 'boarding_request_update' is what the app
        # deep-links to the boarding requests screen; category 'bookings'
        # honours the owner's notification preferences.
        try:
            from .notifications import send_push_notification
            title = f"Boarding Request {new_status.title()}"
            body = f"Your boarding request for {', '.join([d.name for d in instance.dogs.all()])} has been {new_status.lower()}."
            data = {
                'type': 'boarding_request_update',
                'id': str(instance.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            send_push_notification(instance.owner, title, body, data, category='bookings')
        except Exception as e:
            print(f"Failed to send push notification: {e}")

    def perform_create(self, serializer):
        # Ensure owner is set to current user (unless staff specifying owner)
        if self.request.user.is_staff and 'owner' in self.request.data:
            owner_id = self.request.data['owner']
            from django.contrib.auth.models import User
            owner = User.objects.get(pk=owner_id)
        else:
            owner = self.request.user

        # Auto-approve boarding requests created by boarding managers —
        # owner-created requests (and those from staff without the manage
        # flag, e.g. submitting on an owner's behalf) stay PENDING and go
        # through the normal approval workflow.
        if not _user_can_manage_boarding(self.request.user):
            serializer.save(owner=owner)
            return

        from django.utils import timezone
        instance = serializer.save(
            owner=owner,
            status='APPROVED',
            approved_by=self.request.user,
            approved_at=timezone.now(),
            assigned_staff=self._resolve_assigned_staff(self.request.data.get('assigned_staff_id')),
        )
        BoardingRequestHistory.objects.create(
            request=instance,
            changed_by=self.request.user,
            from_status='PENDING',
            to_status='APPROVED',
        )
        self._sync_boarding_attendance(instance)
        self._notify_owner_boarding_status(instance, 'APPROVED')

    def _sync_boarding_attendance(self, instance):
        """Book (or un-book) the stay's dogs into daycare for its weekdays.

        Best-effort: attendance is a convenience on top of the booking, so a
        failure here must never fail the approval the user actually asked for.
        """
        from .scheduling import clear_boarding_daycare_assignments, sync_boarding_daycare_assignments

        try:
            if instance.status == 'APPROVED':
                sync_boarding_daycare_assignments(instance)
            else:
                clear_boarding_daycare_assignments(instance)
        except Exception as e:
            print(f"Failed to sync boarding daycare attendance: {e}")

    @action(detail=True, methods=['post'])
    def change_status(self, request, pk=None):
        new_status = request.data.get('status')
        if new_status not in dict(BoardingRequest.STATUS_CHOICES).keys():
            return Response({'detail': 'Invalid status'}, status=400)

        # Cancelling a booked stay (the owner rang up, the dog isn't coming)
        # is routine front-desk work any staff member handles from the dog's
        # profile. Every other transition — approve/deny/reopen — stays with
        # boarding managers because it drives billing.
        if new_status == 'CANCELLED':
            if not request.user.is_staff:
                from rest_framework.exceptions import PermissionDenied
                raise PermissionDenied('Only staff can cancel a boarding booking.')
        elif not _user_can_manage_boarding(request.user):
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('You do not have permission to manage boarding requests.')

        instance = self.get_object()

        old_status = instance.status
        if old_status == new_status:
             return Response({'detail': 'Status unchanged'}, status=200)

        from django.utils import timezone
        if new_status == 'APPROVED':
            # Flag double bookings at approval time too: two separate pending
            # requests for the same dog can both pass creation validation, so
            # block approving one when it overlaps an already-approved booking.
            conflicts = []
            for dog in instance.dogs.all():
                clash = dog.boarding_requests.filter(
                    status='APPROVED',
                    start_date__lte=instance.end_date,
                    end_date__gte=instance.start_date,
                ).exclude(pk=instance.pk).first()
                if clash:
                    conflicts.append(
                        f"{dog.name} already has an approved boarding "
                        f"{clash.start_date.strftime('%d/%m/%Y')} to {clash.end_date.strftime('%d/%m/%Y')}"
                    )
            if conflicts:
                return Response(
                    {'detail': '; '.join(conflicts) + ". Deny or amend the existing booking first."},
                    status=400,
                )
            instance.approved_by = request.user
            instance.approved_at = timezone.now()
            # Optionally record who the dog boards with, supplied at approval time.
            assigned_staff = self._resolve_assigned_staff(request.data.get('assigned_staff_id'))
            if assigned_staff is not None:
                instance.assigned_staff = assigned_staff
        instance.status = new_status
        instance.save()

        # Approving books the stay into daycare; anything else (denied,
        # cancelled, re-opened to pending) takes those bookings back out.
        self._sync_boarding_attendance(instance)

        self._notify_owner_boarding_status(instance, new_status)

        # Record history
        BoardingRequestHistory.objects.create(
            request=instance,
            changed_by=request.user,
            from_status=old_status,
            to_status=new_status,
        )

        return Response(self.get_serializer(instance).data)

    @action(detail=True, methods=['post'])
    def assign_staff(self, request, pk=None):
        """Set or change which staff member a boarding dog stays with.

        Used from the dashboard's Boarding Tonight section to (re)assign the
        carer without touching the request's approval status. Pass
        ``assigned_staff_id`` (or null/empty to clear).
        """
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can assign boarding staff")

        instance = self.get_object()
        staff_id = request.data.get('assigned_staff_id')
        if staff_id in (None, ''):
            instance.assigned_staff = None
        else:
            staff = self._resolve_assigned_staff(staff_id)
            if staff is None:
                return Response({'detail': 'Invalid staff member'}, status=400)
            instance.assigned_staff = staff
        instance.save(update_fields=['assigned_staff', 'updated_at'])
        return Response(self.get_serializer(instance).data)


class DailyDogAssignmentViewSet(viewsets.ModelViewSet):
    serializer_class = DailyDogAssignmentSerializer
    permission_classes = [IsAdminUser]

    def get_queryset(self):
        queryset = DailyDogAssignment.objects.select_related(
            'dog', 'dog__owner', 'dog__owner__profile', 'staff_member'
        ).prefetch_related('dog__additional_owners', 'dog__additional_owners__profile')
        date = self.request.query_params.get('date')
        if date:
            queryset = queryset.filter(date=date)
        staff_id = self.request.query_params.get('staff_member')
        if staff_id:
            queryset = queryset.filter(staff_member_id=staff_id)
        return queryset

    def perform_update(self, serializer):
        # update_status, mark_removed and unassign all gate past-day billing
        # edits on can_manage_payments. The generic PATCH route reaches the same
        # rows, so it has to enforce the same rule — otherwise any staff member
        # could quietly un-bill a past day with
        # `PATCH /daily-assignments/<id>/ {"status": "REMOVED"}`.
        instance = serializer.instance
        new_status = serializer.validated_data.get('status', instance.status)
        self._require_payments_permission_for_past_billing_change(
            instance.date, instance.status, new_status)
        serializer.save()

    def perform_destroy(self, instance):
        # Deleting a past row removes the day from the invoice just as surely as
        # marking it REMOVED does, so it needs the same permission.
        self._require_payments_permission_for_past_billing_change(
            instance.date, instance.status, 'REMOVED')
        instance.delete()

    def _require_payments_permission_for_past_billing_change(self, when, old_status, new_status):
        from django.utils import timezone
        if when >= timezone.localdate():
            return
        if 'REMOVED' not in (old_status, new_status) or old_status == new_status:
            return
        if _user_can_manage_payments(self.request.user):
            return
        from rest_framework.exceptions import PermissionDenied
        raise PermissionDenied(
            'Only staff who can manage payments can change whether a past day is billed.')

    def _boarding_context(self, target_date):
        # Compute the sets of dogs boarding on target_date and its neighbours
        # once, so the serializer answers is_boarding / boarding_first_day /
        # boarding_last_day (and the needs_pickup / needs_dropoff legs derived
        # from them) with set lookups instead of queries per row (B7).
        from datetime import timedelta

        def boarding_ids(d):
            return set(
                BoardingRequest.objects.filter(
                    status='APPROVED',
                    start_date__lte=d,
                    end_date__gte=d,
                ).values_list('dogs__id', flat=True)
            )

        ctx = self.get_serializer_context()
        ctx['boarding_dog_ids'] = boarding_ids(target_date)
        ctx['boarding_prev_dog_ids'] = boarding_ids(target_date - timedelta(days=1))
        ctx['boarding_next_dog_ids'] = boarding_ids(target_date + timedelta(days=1))
        return ctx

    def perform_create(self, serializer):
        serializer.save()

    def _parse_date(self, request):
        """Parse a date from query params, defaulting to today.

        The daycare calendar can be viewed/edited arbitrarily far into the
        future, so no upper bound is enforced on the requested date.
        """
        from datetime import date
        date_str = request.query_params.get('date')
        if date_str:
            try:
                target = date.fromisoformat(date_str)
            except ValueError:
                return None, Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
            return target, None
        return timezone.localdate(), None

    @staticmethod
    def _cancelled_dog_ids_for_date(target_date, dog_ids=None):
        """Dog ids that should be REMOVED from the roster for ``target_date``.

        A dog is cancelled for a date if its most recently approved request
        for that date is a CANCEL whose original_date matches, or a CHANGE
        moving *away* from that date — a CHANGE is a cancel of the old date
        plus an add of the new date. A later approved ADD_DAY/CHANGE-to for
        the same date supersedes the cancellation (the dog was added back).
        """
        from .scheduling import effective_change_actions
        _, cancels_by_date = effective_change_actions(
            target_date, target_date, dog_ids=dog_ids,
        )
        return cancels_by_date.get(target_date, set())

    @staticmethod
    def _added_dogs_for_date(target_date):
        """Dogs that should be ADDED to the roster for ``target_date``.

        Covers APPROVED ADD_DAY requests (new_date matches) and APPROVED
        CHANGE requests moving *to* that date — unless a later approved
        CANCEL/CHANGE-away for the same date supersedes the addition.
        """
        from .scheduling import effective_change_actions
        adds_by_date, _ = effective_change_actions(target_date, target_date)
        return Dog.objects.filter(id__in=adds_by_date.get(target_date, set()))

    def _materialize_roster_for_date(self, target_date):
        """Create any missing DailyDogAssignment rows for ``target_date`` from
        the persistent DogWeekdayPickup roster, plus any dog boarding that day.

        Returns the number of newly created rows. Skips:
          * CLOSED closure days
          * ad-hoc dogs (defensive — they should never have roster entries)
          * dogs whose current ``daycare_days`` no longer include this weekday
          * dogs with an APPROVED CANCEL DateChangeRequest for this date
          * dogs that already have a DailyDogAssignment for this date
          * dogs whose owner handles BOTH legs of transport
            (owner_brings_default AND owner_collects_default) — no staff route
            ever touches them. Dogs the owner only brings OR only collects are
            still materialized, because staff run the other leg.
        """
        from .models import ClosureDay
        from datetime import date as date_cls

        # Never fabricate roster history for past dates. Staff can now scroll
        # back on the dashboard to review earlier days, and those should show
        # the assignments that actually existed — not new ones materialized
        # retroactively from the current weekday roster.
        if target_date < timezone.localdate():
            return 0

        if ClosureDay.objects.filter(date=target_date, closure_type='CLOSED').exists():
            return 0

        # Dogs boarding today are in daycare today, booked under the house
        # "P4TD" account (see api.scheduling). Done here as well as at approval
        # time so stays approved before this existed — and dogs added to a stay
        # afterwards — still turn up on the day's roster.
        from .scheduling import materialize_boarding_for_date
        boarding_created = materialize_boarding_for_date(target_date)

        weekday = target_date.isoweekday()

        roster_entries = list(
            DogWeekdayPickup.objects
            .filter(weekday=weekday)
            .select_related('dog', 'staff_member')
        )
        if not roster_entries:
            return boarding_created

        existing_dog_ids = set(
            DailyDogAssignment.objects
            .filter(date=target_date, dog_id__in=[e.dog_id for e in roster_entries])
            .values_list('dog_id', flat=True)
        )
        cancelled_dog_ids = set(
            self._cancelled_dog_ids_for_date(
                target_date,
                dog_ids=[e.dog_id for e in roster_entries],
            )
        )

        to_create = []
        for entry in roster_entries:
            dog = entry.dog
            if dog.schedule_type == 'ad_hoc':
                continue
            if weekday not in (dog.daycare_days or []):
                continue
            if dog.id in existing_dog_ids or dog.id in cancelled_dog_ids:
                continue
            # When the owner handles BOTH legs no staff route touches this dog —
            # but the dog still *attends*, and attendance is what billing reads
            # (billing.attendance_for_month counts DailyDogAssignment rows).
            # Skipping the row entirely meant these dogs were invoiced £0 every
            # month and had to be added to the roster by hand every week.
            # Materialise them as UNASSIGNED instead: every roster/van view
            # already excludes REMOVED and UNASSIGNED, so they stay off the
            # driver's list while billing and capacity can still see them.
            owner_does_both = dog.owner_brings_default and dog.owner_collects_default
            to_create.append(DailyDogAssignment(
                dog=dog,
                staff_member=entry.staff_member,
                date=target_date,
                status='UNASSIGNED' if owner_does_both else 'ASSIGNED',
                sort_order=entry.sort_order,
            ))

        if not to_create:
            return boarding_created

        DailyDogAssignment.objects.bulk_create(to_create, ignore_conflicts=True)
        return boarding_created + len(to_create)

    @action(detail=False, methods=['get'])
    def today(self, request):
        """Get all assignments for a date. Accepts optional ?date=YYYY-MM-DD, defaults to today."""
        target_date, error = self._parse_date(request)
        if error:
            return error
        self._materialize_roster_for_date(target_date)
        assignments = self.get_queryset().filter(date=target_date).exclude(status__in=['REMOVED', 'UNASSIGNED'])
        serializer = self.get_serializer(assignments, many=True, context=self._boarding_context(target_date))
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def my_assignments(self, request):
        """Get current staff member's assignments for a date. Accepts optional ?date=YYYY-MM-DD."""
        target_date, error = self._parse_date(request)
        if error:
            return error
        self._materialize_roster_for_date(target_date)
        assignments = self.get_queryset().filter(
            staff_member=request.user, date=target_date
        ).exclude(status__in=['REMOVED', 'UNASSIGNED'])
        serializer = self.get_serializer(assignments, many=True, context=self._boarding_context(target_date))
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def compatibility_conflicts(self, request):
        """List pairs of incompatible dogs assigned to the same staff member
        on a given date.

        A conflict is detected when both dogs share the same ``staff_member``
        for the date and at least one negative COMPATIBILITY DogNote links
        them. Accepts optional ?date=YYYY-MM-DD (defaults to today).
        """
        from django.db.models import Q
        from .models import DogNote

        target_date, error = self._parse_date(request)
        if error:
            return error
        self._materialize_roster_for_date(target_date)

        assignments = (
            self.get_queryset()
            .filter(date=target_date)
            .exclude(status__in=['REMOVED', 'UNASSIGNED'])
        )

        dogs_by_staff = {}
        for a in assignments:
            dogs_by_staff.setdefault(a.staff_member_id, []).append(a)

        negative_notes = (
            DogNote.objects.filter(note_type='COMPATIBILITY', is_positive=False)
            .filter(~Q(related_dog=None))
            .select_related('dog', 'related_dog')
        )
        incompat = {}
        for note in negative_notes:
            key = tuple(sorted((note.dog_id, note.related_dog_id)))
            incompat.setdefault(key, []).append(note)

        conflicts = []
        for staff_id, staff_assignments in dogs_by_staff.items():
            assigned_dog_ids = {a.dog_id for a in staff_assignments}
            assignment_by_dog = {a.dog_id: a for a in staff_assignments}
            for (dog_a_id, dog_b_id), notes in incompat.items():
                if dog_a_id in assigned_dog_ids and dog_b_id in assigned_dog_ids:
                    a_assignment = assignment_by_dog[dog_a_id]
                    b_assignment = assignment_by_dog[dog_b_id]
                    conflicts.append({
                        'staff_member_id': staff_id,
                        'staff_member_name': (
                            a_assignment.staff_member.first_name
                            or a_assignment.staff_member.username
                        ),
                        'dog_a_id': dog_a_id,
                        'dog_a_name': a_assignment.dog.name,
                        'dog_b_id': dog_b_id,
                        'dog_b_name': b_assignment.dog.name,
                        'reasons': [n.text for n in notes],
                    })

        conflicts.sort(key=lambda c: (c['staff_member_name'].lower(), c['dog_a_name'].lower()))
        return Response({'date': target_date.isoformat(), 'conflicts': conflicts})

    @action(detail=False, methods=['get'])
    def photo_tagging(self, request):
        """How many of the day's dogs have been tagged in feed media posted
        that day, and which dogs still need tagging.

        A dog counts as tagged when any GroupMedia created on the given local
        date tags it — regardless of who posted. Accepts optional
        ?date=YYYY-MM-DD (defaults to today).
        """
        target_date, error = self._parse_date(request)
        if error:
            return error
        self._materialize_roster_for_date(target_date)

        assignments = (
            self.get_queryset()
            .filter(date=target_date)
            .exclude(status__in=['REMOVED', 'UNASSIGNED'])
        )
        by_dog = {a.dog_id: a for a in assignments}

        # __date evaluates in the current (Europe/London) timezone, so "posted
        # today" matches what staff see on the feed.
        tagged_ids = set(
            GroupMedia.objects.filter(
                created_at__date=target_date,
                tagged_dogs__in=by_dog.keys(),
            ).values_list('tagged_dogs', flat=True)
        )

        untagged = []
        for dog_id, a in by_dog.items():
            if dog_id in tagged_ids:
                continue
            image = a.dog.profile_image
            untagged.append({
                'dog_id': dog_id,
                'dog_name': a.dog.name,
                'dog_profile_image': request.build_absolute_uri(image.url) if image else None,
                'staff_member_id': a.staff_member_id,
                'staff_member_name': a.staff_member.first_name or a.staff_member.username,
            })
        untagged.sort(key=lambda d: (d['staff_member_name'].lower(), d['dog_name'].lower()))
        return Response({
            'date': target_date.isoformat(),
            'total': len(by_dog),
            'tagged': len(by_dog) - len(untagged),
            'untagged': untagged,
        })

    @action(detail=True, methods=['post'])
    def update_status(self, request, pk=None):
        """Update the status of an assignment."""
        assignment = self.get_object()
        new_status = request.data.get('status')
        valid_statuses = dict(DailyDogAssignment.STATUS_CHOICES).keys()
        if new_status not in valid_statuses:
            return Response({'detail': 'Invalid status'}, status=400)
        # On past rows, moving into or out of REMOVED changes whether the day
        # is billed — that's a billing-history edit reserved for payment
        # managers (same rule as the dog calendar and mark_removed).
        from datetime import date as date_cls
        if (
            assignment.date < timezone.localdate()
            and 'REMOVED' in (new_status, assignment.status)
            and new_status != assignment.status
            and not _user_can_manage_payments(request.user)
        ):
            return Response({'detail': 'Only staff who can manage payments can change whether a past day is billed.'}, status=403)
        assignment.status = new_status
        assignment.save()
        return Response(self.get_serializer(assignment).data)

    @action(detail=True, methods=['patch'], url_path='transport')
    def set_transport(self, request, pk=None):
        """Staff sets owner_brings / owner_collects / times for this assignment.

        Requires can_assign_dogs or can_manage_requests.
        Accepts any subset of: owner_brings, owner_collects,
        owner_brings_time, owner_collects_time. Times accept HH:MM or HH:MM:SS.
        Explicit null clears a field; absent keys leave the field unchanged.
        """
        try:
            profile = request.user.profile
        except AttributeError:
            return Response({'detail': 'Staff permission required.'}, status=403)
        if not (profile.can_assign_dogs or profile.can_manage_requests):
            return Response({'detail': 'Staff permission required.'}, status=403)

        from .models import ClosureDay
        assignment = self.get_object()

        if ClosureDay.objects.filter(date=assignment.date, closure_type='CLOSED').exists():
            return Response({'detail': 'Cannot set transport on a closure day.'}, status=400)

        bool_fields = ('owner_brings', 'owner_collects')
        time_fields = ('owner_brings_time', 'owner_collects_time')

        for field in bool_fields:
            if field in request.data:
                value = request.data[field]
                if value is None or isinstance(value, bool):
                    setattr(assignment, field, value)
                else:
                    return Response({field: 'Must be true, false, or null.'}, status=400)

        for field in time_fields:
            if field in request.data:
                value = request.data[field]
                if value is None or value == '':
                    setattr(assignment, field, None)
                    continue
                from datetime import datetime
                parsed = None
                for fmt in ('%H:%M:%S', '%H:%M'):
                    try:
                        parsed = datetime.strptime(value, fmt).time()
                        break
                    except (TypeError, ValueError):
                        continue
                if parsed is None:
                    return Response({field: 'Must be HH:MM or HH:MM:SS.'}, status=400)
                setattr(assignment, field, parsed)

        assignment.save()
        return Response(self.get_serializer(assignment).data)

    @action(detail=False, methods=['get'])
    def unassigned_dogs(self, request):
        """Get dogs scheduled for a date that have no assignment yet.
        Accepts optional ?date=YYYY-MM-DD, defaults to today."""
        target_date, error = self._parse_date(request)
        if error:
            return error

        # Return empty list if the business is fully closed on this date
        from .models import ClosureDay
        if ClosureDay.objects.filter(date=target_date, closure_type='CLOSED').exists():
            return Response([])

        # Lazily materialize the persistent weekday roster so rostered dogs
        # do not show up as "unassigned".
        self._materialize_roster_for_date(target_date)

        day_number = target_date.isoweekday()  # Monday=1, Sunday=7

        # Dogs with this weekday in their daycare_days
        daycare_dogs = Dog.objects.filter(daycare_days__contains=[day_number])

        # Dogs with approved boarding that spans the target date
        boarding_dogs = Dog.objects.filter(
            boarding_requests__status='APPROVED',
            boarding_requests__start_date__lte=target_date,
            boarding_requests__end_date__gte=target_date,
        )

        # Dogs explicitly added for the target date: approved ADD_DAY requests
        # (covers ad-hoc dogs) and approved CHANGE requests moving to this date.
        add_day_dogs = self._added_dogs_for_date(target_date)

        # Dogs removed for the target date: approved CANCEL requests and
        # approved CHANGE requests moving away from this date.
        cancelled_dog_ids = self._cancelled_dog_ids_for_date(target_date)

        # Combine daycare + boarding + additional days, exclude cancelled
        scheduled_dogs = (daycare_dogs | boarding_dogs | add_day_dogs).exclude(
            id__in=cancelled_dog_ids
        ).distinct()

        # This list means "attending but still needs a driver". A dog whose
        # owner handles both legs by default never does — it is materialized
        # UNASSIGNED purely so billing can see the attendance (see
        # _materialize_roster_for_date), and surfacing it here would leave a
        # permanent, un-actionable warning on the dashboard.
        scheduled_dogs = scheduled_dogs.exclude(
            owner_brings_default=True, owner_collects_default=True)

        # Exclude dogs that already have an assignment for this date,
        # including REMOVED (staff explicitly cancelled the dog for this
        # day) — but NOT UNASSIGNED, which means "attending, no staff member
        # yet" and is exactly what this list is for.
        assigned_or_removed_dog_ids = DailyDogAssignment.objects.filter(
            date=target_date
        ).exclude(status='UNASSIGNED').values_list('dog_id', flat=True)

        # Reuse the shared prefetch set — building a bespoke queryset here is
        # what made cancelled_dates fall back to a query per dog.
        unassigned = dog_listing_queryset().filter(
            id__in=scheduled_dogs.exclude(id__in=assigned_or_removed_dog_ids)
            .values_list('id', flat=True)
        )
        serializer = DogSerializer(unassigned, many=True, context={'request': request})
        return Response(serializer.data)

    @action(detail=False, methods=['post'])
    def assign_to_me(self, request):
        """Assign one or more dogs to the current staff member.
        Accepts optional 'date' in body (YYYY-MM-DD), defaults to today.

        Also writes a persistent DogWeekdayPickup entry for recurring dogs so
        the assignment repeats forever until explicitly changed. If a roster
        entry for (dog, weekday) already exists pointing at a different staff
        member, only the single-day assignment is created and the roster is
        left alone (use ``reassign`` with scope=from_now_on to change it).
        """
        from datetime import date
        date_str = request.data.get('date')
        if date_str:
            try:
                target_date = date.fromisoformat(date_str)
            except ValueError:
                return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
        else:
            target_date = timezone.localdate()

        dog_ids = request.data.get('dog_ids', [])
        if not dog_ids:
            return Response({'detail': 'dog_ids is required'}, status=400)

        # Nobody attends on a CLOSED closure day — refuse rather than create
        # assignments roster materialisation would never produce (B14).
        from .models import ClosureDay
        if ClosureDay.objects.filter(date=target_date, closure_type='CLOSED').exists():
            return Response({'detail': 'The daycare is closed on that date.'}, status=400)

        weekday = target_date.isoweekday()
        is_past = target_date < timezone.localdate()
        created = []
        skipped = []
        for dog_id in dog_ids:
            try:
                dog = Dog.objects.get(id=dog_id)
            except Dog.DoesNotExist:
                continue

            # A past day is billing history: recording who drove the dog on an
            # existing attended (UNASSIGNED) day is fine for any assigner, but
            # creating a new row — or reviving a REMOVED one — makes the day
            # billable, which is reserved for payment managers (same rule as
            # past edits on the dog calendar).
            if is_past:
                existing_row = DailyDogAssignment.objects.filter(dog=dog, date=target_date).first()
                changes_billing = existing_row is None or existing_row.status == 'REMOVED'
                if changes_billing and not _user_can_manage_payments(request.user):
                    skipped.append({'dog': dog.name, 'reason': 'Past day — only staff who manage payments can add attendance'})
                    continue

            # Silently upsert the persistent roster for recurring dogs, but
            # do not clobber an existing roster entry pointing elsewhere.
            # Never for past days: recording history must not rewrite who
            # picks the dog up every week from now on.
            if dog.schedule_type != 'ad_hoc' and not is_past:
                existing = DogWeekdayPickup.objects.filter(dog=dog, weekday=weekday).first()
                if existing is None:
                    DogWeekdayPickup.objects.create(
                        dog=dog,
                        weekday=weekday,
                        staff_member=request.user,
                        created_by=request.user,
                    )

            assignment, was_created = DailyDogAssignment.objects.get_or_create(
                dog=dog,
                date=target_date,
                defaults={'staff_member': request.user},
            )
            if was_created:
                created.append(assignment)
            elif assignment.status in ('REMOVED', 'UNASSIGNED'):
                assignment.status = 'ASSIGNED'
                assignment.staff_member = request.user
                assignment.save(update_fields=['status', 'staff_member', 'updated_at'])
                created.append(assignment)
            else:
                skipped.append({'dog': dog.name, 'reason': f'Already assigned to {assignment.staff_member.first_name or assignment.staff_member.username}'})

        serializer = self.get_serializer(created, many=True)
        data = serializer.data
        if skipped:
            return Response({'created': data, 'skipped': skipped}, status=200)
        return Response(data, status=201)

    @action(detail=False, methods=['post'])
    def assign_dogs(self, request):
        """Assign one or more dogs to a specified staff member.
        Accepts optional 'date' in body (YYYY-MM-DD), defaults to today.
        Requires can_assign_dogs permission.

        Also writes a persistent DogWeekdayPickup entry for recurring dogs so
        the assignment repeats forever until explicitly changed. If a roster
        entry for (dog, weekday) already exists pointing at a different staff
        member, only the single-day assignment is created and the roster is
        left alone (use ``reassign`` with scope=from_now_on to change it).
        """
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to assign dogs to other staff members.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        from datetime import date
        date_str = request.data.get('date')
        if date_str:
            try:
                target_date = date.fromisoformat(date_str)
            except ValueError:
                return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
        else:
            target_date = timezone.localdate()

        dog_ids = request.data.get('dog_ids', [])
        staff_member_id = request.data.get('staff_member_id')

        if not dog_ids:
            return Response({'detail': 'dog_ids is required'}, status=400)
        if not staff_member_id:
            return Response({'detail': 'staff_member_id is required'}, status=400)

        from django.contrib.auth.models import User
        try:
            target_staff = User.objects.get(id=staff_member_id, is_staff=True)
        except User.DoesNotExist:
            return Response({'detail': 'Staff member not found'}, status=404)

        # Nobody attends on a CLOSED closure day — refuse rather than create
        # assignments roster materialisation would never produce (B14).
        from .models import ClosureDay
        if ClosureDay.objects.filter(date=target_date, closure_type='CLOSED').exists():
            return Response({'detail': 'The daycare is closed on that date.'}, status=400)

        weekday = target_date.isoweekday()
        is_past = target_date < timezone.localdate()
        created = []
        skipped = []
        for dog_id in dog_ids:
            try:
                dog = Dog.objects.get(id=dog_id)
            except Dog.DoesNotExist:
                continue

            # Same past-day rules as assign_to_me: recording the driver on an
            # already-attended day is open to assigners, but making a past day
            # (newly or via a REMOVED row) billable needs the payments
            # permission, and history must never rewrite the weekly roster.
            if is_past:
                existing_row = DailyDogAssignment.objects.filter(dog=dog, date=target_date).first()
                changes_billing = existing_row is None or existing_row.status == 'REMOVED'
                if changes_billing and not _user_can_manage_payments(request.user):
                    skipped.append({'dog': dog.name, 'reason': 'Past day — only staff who manage payments can add attendance'})
                    continue

            if dog.schedule_type != 'ad_hoc' and not is_past:
                existing = DogWeekdayPickup.objects.filter(dog=dog, weekday=weekday).first()
                if existing is None:
                    DogWeekdayPickup.objects.create(
                        dog=dog,
                        weekday=weekday,
                        staff_member=target_staff,
                        created_by=request.user,
                    )

            assignment, was_created = DailyDogAssignment.objects.get_or_create(
                dog=dog,
                date=target_date,
                defaults={'staff_member': target_staff},
            )
            if was_created:
                created.append(assignment)
            elif assignment.status in ('REMOVED', 'UNASSIGNED'):
                assignment.status = 'ASSIGNED'
                assignment.staff_member = target_staff
                assignment.save(update_fields=['status', 'staff_member', 'updated_at'])
                created.append(assignment)
            else:
                skipped.append({'dog': dog.name, 'reason': f'Already assigned to {assignment.staff_member.first_name or assignment.staff_member.username}'})

        serializer = self.get_serializer(created, many=True)
        data = serializer.data
        if skipped:
            return Response({'created': data, 'skipped': skipped}, status=200)
        return Response(data, status=201)

    @action(detail=False, methods=['post'])
    def mark_removed(self, request):
        """Mark a dog as removed from a specific day without first creating
        a regular assignment. Used to skip a rostered dog (e.g. a daycare-day
        dog that won't be coming this particular day) directly from the
        unassigned list.

        Body:
          dog_id: int (required)
          date: str (YYYY-MM-DD, required)

        Creates a DailyDogAssignment with status='REMOVED' so the dog will
        not be re-materialised by ``_materialize_roster_for_date``. If a row
        already exists for (dog, date), it is updated to REMOVED.

        Requires can_assign_dogs permission.
        """
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to remove dogs from a day.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        from datetime import date as date_cls
        dog_id = request.data.get('dog_id')
        date_str = request.data.get('date')
        if not dog_id:
            return Response({'detail': 'dog_id is required'}, status=400)
        if not date_str:
            return Response({'detail': 'date is required'}, status=400)
        try:
            target_date = date_cls.fromisoformat(date_str)
        except ValueError:
            return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)

        # Removing a past day takes it off the invoice — a billing-history
        # edit reserved for payment managers (same rule as the dog calendar).
        if target_date < timezone.localdate() and not _user_can_manage_payments(request.user):
            return Response({'detail': 'Only staff who can manage payments can remove past days.'}, status=403)

        try:
            dog = Dog.objects.get(id=dog_id)
        except Dog.DoesNotExist:
            return Response({'detail': 'Dog not found'}, status=404)

        assignment, _ = DailyDogAssignment.objects.get_or_create(
            dog=dog,
            date=target_date,
            defaults={'staff_member': request.user, 'status': 'REMOVED'},
        )
        if assignment.status != 'REMOVED':
            assignment.status = 'REMOVED'
            assignment.save(update_fields=['status', 'updated_at'])

        # Removing a dog frees a spot — let the waitlist know. Not for past
        # days: nobody can be offered a spot on a day that already happened.
        if target_date >= timezone.localdate():
            try:
                from .scheduling import process_waitlist_for_date
                process_waitlist_for_date(target_date)
            except Exception as e:
                print(f"Failed to process waitlist: {e}")
        return Response(status=204)

    @action(detail=True, methods=['post'])
    def reassign(self, request, pk=None):
        """Reassign a dog to a different staff member.

        Body:
          staff_member_id: int (required)
          scope: 'just_this_day' | 'from_now_on' (optional, default 'just_this_day')

        ``just_this_day`` only touches the single assignment.
        ``from_now_on`` also updates the persistent weekday roster and
        cascades to future same-weekday assignments still in ASSIGNED status.

        Requires can_assign_dogs permission.
        """
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to reassign dogs.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        assignment = self.get_object()
        staff_member_id = request.data.get('staff_member_id')
        if not staff_member_id:
            return Response({'detail': 'staff_member_id is required'}, status=400)

        scope = request.data.get('scope', 'just_this_day')
        if scope not in ('just_this_day', 'from_now_on'):
            return Response({'detail': 'Invalid scope. Use just_this_day or from_now_on.'}, status=400)

        from django.contrib.auth.models import User
        try:
            new_staff = User.objects.get(id=staff_member_id, is_staff=True)
        except User.DoesNotExist:
            return Response({'detail': 'Staff member not found'}, status=404)

        assignment.staff_member = new_staff
        assignment.save()

        if scope == 'from_now_on':
            weekday = assignment.date.isoweekday()
            dog = assignment.dog
            if dog.schedule_type != 'ad_hoc':
                DogWeekdayPickup.objects.update_or_create(
                    dog=dog,
                    weekday=weekday,
                    defaults={'staff_member': new_staff, 'created_by': request.user},
                )
            DailyDogAssignment.objects.filter(
                dog=dog,
                date__gt=assignment.date,
                date__iso_week_day=weekday,
                status='ASSIGNED',
            ).update(staff_member=new_staff)

        return Response(self.get_serializer(assignment).data)

    @action(detail=True, methods=['post'])
    def unassign(self, request, pk=None):
        """Unassign a dog (delete the assignment).

        Body:
          scope: 'just_this_day' | 'from_now_on' (optional, default 'just_this_day')

        ``just_this_day`` only deletes the single assignment — the persistent
        weekday roster stays intact, so next week's materialization will
        recreate the assignment.
        ``from_now_on`` also deletes the DogWeekdayPickup roster entry and
        purges future same-weekday assignments still in ASSIGNED status.

        Requires can_assign_dogs permission.
        """
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to unassign dogs.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        scope = request.data.get('scope', 'just_this_day')
        if scope not in ('just_this_day', 'from_now_on'):
            return Response({'detail': 'Invalid scope. Use just_this_day or from_now_on.'}, status=400)

        assignment = self.get_object()
        dog = assignment.dog
        assignment_date = assignment.date
        weekday = assignment_date.isoweekday()

        # from_now_on deletes this row outright; on a past date that erases
        # billed attendance, so it needs the payments permission. just_this_day
        # only flips to UNASSIGNED (still attended, still billed) — fine for
        # any assigner.
        from datetime import date as date_cls
        if scope == 'from_now_on' and assignment_date < timezone.localdate() and not _user_can_manage_payments(request.user):
            return Response({'detail': 'Only staff who can manage payments can delete past attendance.'}, status=403)

        if scope == 'from_now_on':
            assignment.delete()
            DogWeekdayPickup.objects.filter(dog=dog, weekday=weekday).delete()
            DailyDogAssignment.objects.filter(
                dog=dog,
                date__gt=assignment_date,
                date__iso_week_day=weekday,
                status='ASSIGNED',
            ).delete()
        else:
            # Mark as UNASSIGNED instead of deleting so that
            # _materialize_roster_for_date does not re-create the row. The dog
            # is still attending this day (it surfaces in unassigned_dogs) —
            # this used to set REMOVED, which reads as "not coming today" and
            # made the dog vanish from the day board entirely.
            assignment.status = 'UNASSIGNED'
            assignment.save(update_fields=['status', 'updated_at'])

        return Response(status=204)

    @action(detail=False, methods=['get'])
    def suggested_assignments(self, request):
        """Get suggested staff member for each unassigned dog based on history.
        Prioritises the most recent assignment for the same day of the week
        (e.g. last Monday's assignments are suggested for this Monday), so that
        weekly rosters repeat by default.  Falls back to the overall most
        frequent staff member for dogs with no same-weekday history.
        Returns a mapping of dog_id -> {staff_member_id, staff_member_name, source}.
        Accepts optional ?date=YYYY-MM-DD, defaults to today."""
        target_date, error = self._parse_date(request)
        if error:
            return error

        from django.db.models import Count
        from django.db.models.functions import ExtractIsoWeekDay

        day_number = target_date.isoweekday()  # Monday=1 … Sunday=7

        # 1) Most recent same-weekday assignment per dog. Days nobody drove
        # (a boarding arrival still waiting for a driver, or a day whose
        # driver has since been deleted) teach nothing — and being the most
        # recent, they would otherwise shadow the last real assignment.
        same_weekday_history = (
            DailyDogAssignment.objects
            .annotate(weekday=ExtractIsoWeekDay('date'))
            .filter(weekday=day_number, staff_member__isnull=False)
            .exclude(date=target_date)
            .order_by('dog_id', '-date')
            .values('dog_id', 'staff_member_id', 'staff_member__username', 'staff_member__first_name')
        )

        suggestions = {}
        for entry in same_weekday_history:
            dog_id = entry['dog_id']
            if dog_id not in suggestions:
                name = entry['staff_member__first_name'] or entry['staff_member__username']
                suggestions[dog_id] = {
                    'staff_member_id': entry['staff_member_id'],
                    'staff_member_name': name,
                    'source': 'same_weekday',
                }

        # 2) Fallback: overall most-frequent staff member for remaining dogs
        fallback_history = (
            DailyDogAssignment.objects
            .filter(staff_member__isnull=False)
            .values('dog_id', 'staff_member_id', 'staff_member__username', 'staff_member__first_name')
            .annotate(times=Count('id'))
            .order_by('dog_id', '-times')
        )

        for entry in fallback_history:
            dog_id = entry['dog_id']
            if dog_id not in suggestions:
                name = entry['staff_member__first_name'] or entry['staff_member__username']
                suggestions[dog_id] = {
                    'staff_member_id': entry['staff_member_id'],
                    'staff_member_name': name,
                    'source': 'frequency',
                }

        return Response(suggestions)

    @action(detail=False, methods=['post'])
    def auto_assign(self, request):
        """Auto-assign all unassigned dogs for a date based on history.
        Prioritises the most recent same-weekday assignment so that weekly
        rosters repeat by default.  Falls back to overall most-frequent staff
        member for dogs with no same-weekday history.
        Requires can_assign_dogs permission.
        Accepts optional 'date' in body (YYYY-MM-DD), defaults to today."""
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to assign dogs.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        from datetime import date
        from django.db.models import Count
        from django.db.models.functions import ExtractIsoWeekDay

        date_str = request.data.get('date')
        if date_str:
            try:
                target_date = date.fromisoformat(date_str)
            except ValueError:
                return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
        else:
            target_date = timezone.localdate()

        # Materialize the persistent weekday roster first so auto_assign only
        # needs to fill in dogs that don't already have a default staff member.
        self._materialize_roster_for_date(target_date)

        day_number = target_date.isoweekday()

        # Get unassigned dogs for this date (same logic as unassigned_dogs)
        daycare_dogs = Dog.objects.filter(daycare_days__contains=[day_number])
        boarding_dogs = Dog.objects.filter(
            boarding_requests__status='APPROVED',
            boarding_requests__start_date__lte=target_date,
            boarding_requests__end_date__gte=target_date,
        )
        add_day_dogs = self._added_dogs_for_date(target_date)
        cancelled_dog_ids = self._cancelled_dog_ids_for_date(target_date)

        scheduled_dogs = (daycare_dogs | boarding_dogs | add_day_dogs).exclude(
            id__in=cancelled_dog_ids
        ).distinct()

        assigned_dog_ids = DailyDogAssignment.objects.filter(
            date=target_date
        ).exclude(status='UNASSIGNED').values_list('dog_id', flat=True)

        unassigned = scheduled_dogs.exclude(id__in=assigned_dog_ids)

        # 1) Most recent same-weekday assignment per dog
        same_weekday_history = (
            DailyDogAssignment.objects
            .annotate(weekday=ExtractIsoWeekDay('date'))
            .filter(weekday=day_number, staff_member__isnull=False)
            .exclude(date=target_date)
            .order_by('dog_id', '-date')
            .values('dog_id', 'staff_member_id')
        )
        best_staff = {}
        for entry in same_weekday_history:
            dog_id = entry['dog_id']
            if dog_id not in best_staff:
                best_staff[dog_id] = entry['staff_member_id']

        # 2) Fallback: overall most-frequent staff member for remaining dogs
        fallback_history = (
            DailyDogAssignment.objects
            .filter(staff_member__isnull=False)
            .values('dog_id', 'staff_member_id')
            .annotate(times=Count('id'))
            .order_by('dog_id', '-times')
        )
        for entry in fallback_history:
            dog_id = entry['dog_id']
            if dog_id not in best_staff:
                best_staff[dog_id] = entry['staff_member_id']

        created = []
        skipped = []
        for dog in unassigned:
            staff_id = best_staff.get(dog.id)
            if staff_id:
                from django.contrib.auth.models import User
                try:
                    staff = User.objects.get(id=staff_id, is_staff=True)
                except User.DoesNotExist:
                    skipped.append(dog.id)
                    continue
                assignment, was_created = DailyDogAssignment.objects.get_or_create(
                    dog=dog,
                    date=target_date,
                    defaults={'staff_member': staff},
                )
                if was_created:
                    created.append(assignment)
                elif assignment.status == 'UNASSIGNED':
                    # Dog was unassigned for the day — revive the row rather
                    # than silently leaving it unassigned.
                    assignment.status = 'ASSIGNED'
                    assignment.staff_member = staff
                    assignment.save(update_fields=['status', 'staff_member', 'updated_at'])
                    created.append(assignment)
            else:
                skipped.append(dog.id)

        serializer = self.get_serializer(created, many=True)
        return Response({
            'assigned': serializer.data,
            'skipped_dog_ids': skipped,
        }, status=201)

    @action(detail=False, methods=['post'])
    def swap_staff(self, request):
        """Bulk-swap one staff member's pickups to another.

        Body:
          from_staff_id: int (required)
          to_staff_id:   int (required)
          scope:         'just_this_day' | 'this_weekday_forever' | 'all_weekdays_forever'
          date:          'YYYY-MM-DD' (required unless scope='all_weekdays_forever')

        Swap moves ALL DailyDogAssignment rows owned by the source staff in
        the target window — including rows that originated from boarding or
        ADD_DAY requests — not just rows created from the roster. PICKED_UP
        dogs move too (keeping their status), so a run can be handed to
        another driver mid-day; only DROPPED_OFF rows (dogs already returned
        home) are left untouched.

        Requires can_assign_dogs permission.
        """
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to swap staff.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        from datetime import date as date_cls

        from_staff_id = request.data.get('from_staff_id')
        to_staff_id = request.data.get('to_staff_id')
        scope = request.data.get('scope')

        if not from_staff_id or not to_staff_id:
            return Response({'detail': 'from_staff_id and to_staff_id are required'}, status=400)
        # Normalise types before comparing so a mix of int/str ids can't slip
        # past the no-op guard and "swap" a staff member with themselves (B27).
        try:
            from_staff_id = int(from_staff_id)
            to_staff_id = int(to_staff_id)
        except (TypeError, ValueError):
            return Response({'detail': 'from_staff_id and to_staff_id must be integers'}, status=400)
        if from_staff_id == to_staff_id:
            return Response({'detail': 'from_staff_id and to_staff_id must differ'}, status=400)
        if scope not in ('just_this_day', 'this_weekday_forever', 'all_weekdays_forever'):
            return Response({
                'detail': 'scope must be one of just_this_day, this_weekday_forever, all_weekdays_forever',
            }, status=400)

        from django.contrib.auth.models import User
        try:
            from_staff = User.objects.get(id=from_staff_id, is_staff=True)
        except User.DoesNotExist:
            return Response({'detail': 'from_staff not found'}, status=404)
        try:
            to_staff = User.objects.get(id=to_staff_id, is_staff=True)
        except User.DoesNotExist:
            return Response({'detail': 'to_staff not found'}, status=404)

        target_date = None
        if scope != 'all_weekdays_forever':
            date_str = request.data.get('date')
            if not date_str:
                return Response({'detail': 'date is required for this scope'}, status=400)
            try:
                target_date = date_cls.fromisoformat(date_str)
            except ValueError:
                return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)

        from django.db import transaction
        roster_updated = 0
        assignments_updated = 0
        with transaction.atomic():
            # ASSIGNED and PICKED_UP both move: after the morning run every
            # dog is PICKED_UP, and the whole point of a mid-day swap is to
            # hand those dogs to another driver. Their status carries over.
            swappable = ('ASSIGNED', 'PICKED_UP')
            if scope == 'just_this_day':
                assignments_updated = DailyDogAssignment.objects.filter(
                    staff_member=from_staff,
                    date=target_date,
                    status__in=swappable,
                ).update(staff_member=to_staff)
            elif scope == 'this_weekday_forever':
                weekday = target_date.isoweekday()
                roster_updated = DogWeekdayPickup.objects.filter(
                    staff_member=from_staff,
                    weekday=weekday,
                ).update(staff_member=to_staff)
                assignments_updated = DailyDogAssignment.objects.filter(
                    staff_member=from_staff,
                    date__gte=target_date,
                    date__iso_week_day=weekday,
                    status__in=swappable,
                ).update(staff_member=to_staff)
            else:  # all_weekdays_forever
                roster_updated = DogWeekdayPickup.objects.filter(
                    staff_member=from_staff,
                ).update(staff_member=to_staff)
                assignments_updated = DailyDogAssignment.objects.filter(
                    staff_member=from_staff,
                    date__gte=timezone.localdate(),
                    status__in=swappable,
                ).update(staff_member=to_staff)

        return Response({
            'roster_rows_updated': roster_updated,
            'assignment_rows_updated': assignments_updated,
        })

    @action(detail=False, methods=['get'])
    def weekday_roster(self, request):
        """Return the persistent DogWeekdayPickup roster.

        Optional filters: ?weekday=<1-7>, ?staff_member_id=<id>.
        Used by the mobile swap-staff dialog to preview which dogs are affected.
        """
        qs = DogWeekdayPickup.objects.select_related('dog', 'staff_member').all()
        weekday = request.query_params.get('weekday')
        if weekday:
            try:
                qs = qs.filter(weekday=int(weekday))
            except ValueError:
                return Response({'detail': 'Invalid weekday'}, status=400)
        staff_id = request.query_params.get('staff_member_id')
        if staff_id:
            try:
                qs = qs.filter(staff_member_id=int(staff_id))
            except ValueError:
                return Response({'detail': 'Invalid staff_member_id'}, status=400)
        serializer = DogWeekdayPickupSerializer(qs, many=True)
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def staff_members(self, request):
        """Get list of staff members for assignment dropdown."""
        from django.contrib.auth.models import User
        staff = User.objects.filter(is_staff=True).values(
            'id', 'username', 'first_name', 'profile__staff_color'
        )
        return Response([
            {
                'id': s['id'],
                'username': s['username'],
                'first_name': s['first_name'],
                'staff_color': s['profile__staff_color'] or '',
            }
            for s in staff
        ])

    @action(detail=False, methods=['post'])
    def reorder(self, request):
        """Persist custom sort order for assignments.

        Accepts: {"assignment_ids": [4, 7, 2, ...]}
        Sets sort_order = 0, 1, 2, ... in the given sequence.
        """
        assignment_ids = request.data.get('assignment_ids', [])
        if not isinstance(assignment_ids, list) or not assignment_ids:
            return Response({'detail': 'assignment_ids list is required.'}, status=400)

        from django.db import transaction

        # Load the assignments so we can recover dog/staff/date for the
        # roster write-back (the payload is only ordered assignment ids).
        assignments = {
            a.id: a
            for a in DailyDogAssignment.objects.filter(
                id__in=assignment_ids
            ).select_related('dog')
        }
        ordered = [assignments[aid] for aid in assignment_ids if aid in assignments]

        with transaction.atomic():
            for position, a in enumerate(ordered):
                DailyDogAssignment.objects.filter(id=a.id).update(sort_order=position)
                # Remember this position on the persistent weekday roster so it
                # carries forward to future weeks. No-ops for dogs not on the
                # roster, or assignments reassigned to a non-roster staff member.
                DogWeekdayPickup.objects.filter(
                    dog_id=a.dog_id,
                    weekday=a.date.isoweekday(),
                    staff_member_id=a.staff_member_id,
                ).update(sort_order=position)

        return Response({'detail': 'Order saved.'})

    @action(detail=False, methods=['post'])
    def send_traffic_alert(self, request):
        """Send a traffic delay notification to owners on the requesting staff member's route."""
        alert_type = request.data.get('alert_type')
        if alert_type not in ('pickup', 'dropoff'):
            return Response({'detail': 'alert_type must be "pickup" or "dropoff"'}, status=400)

        target_date, error = self._parse_date(request)
        if error:
            return error

        detail_text = request.data.get('detail', '')
        dog_ids = request.data.get('dog_ids')
        from .notifications import send_traffic_alert
        send_traffic_alert(alert_type, target_date, staff_member=request.user, detail=detail_text, dog_ids=dog_ids)
        return Response({'detail': 'Traffic alert sent successfully.'})


class SupportQueryViewSet(viewsets.ModelViewSet):
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        from .serializers import SupportQuerySerializer, SupportQueryListSerializer
        if self.action == 'list':
            return SupportQueryListSerializer
        return SupportQuerySerializer

    def get_queryset(self):
        from .models import SupportQuery
        queryset = SupportQuery.objects.prefetch_related('messages')
        if self.request.user.is_staff:
            return queryset
        return queryset.filter(owner=self.request.user)

    def perform_create(self, serializer):
        # Staff can create queries on behalf of an owner
        if self.request.user.is_staff and 'owner_id' in self.request.data:
            from django.contrib.auth.models import User
            try:
                owner = User.objects.get(id=self.request.data['owner_id'])
            except User.DoesNotExist:
                from rest_framework.exceptions import ValidationError
                raise ValidationError({'owner_id': 'User not found'})
            query = serializer.save(owner=owner)
        else:
            query = serializer.save(owner=self.request.user)

        # Create initial message if provided
        initial_message = self.request.data.get('initial_message')
        if initial_message:
            from .models import SupportMessage
            SupportMessage.objects.create(
                query=query, sender=self.request.user, text=initial_message
            )

        # A new query from an owner is unread for staff
        if not self.request.user.is_staff:
            query.staff_has_unread = True
            query.save()

    @action(detail=True, methods=['post'])
    def add_message(self, request, pk=None):
        """Add a message to a query thread."""
        from .models import SupportMessage, SupportQuery
        from .serializers import SupportQuerySerializer

        query = self.get_object()
        text = request.data.get('text')
        if not text:
            return Response({'detail': 'Text is required'}, status=400)

        user = request.user
        if user != query.owner:
            if not user.is_staff:
                return Response({'detail': 'You do not have permission to reply.'}, status=403)
            if not hasattr(user, 'profile') or not user.profile.can_reply_queries:
                return Response({'detail': 'You do not have permission to reply to queries.'}, status=403)

        SupportMessage.objects.create(query=query, sender=user, text=text)
        # Mark unread for the owner when staff replies, clear when owner replies
        # (and vice versa for the staff-side unread flag)
        if user.is_staff:
            query.has_unread_reply = True
            query.staff_has_unread = False
        else:
            query.has_unread_reply = False
            query.staff_has_unread = True
        query.save()  # Update updated_at timestamp
        # Refresh from DB to clear prefetch cache and include the new message
        query.refresh_from_db()
        query = SupportQuery.objects.prefetch_related('messages').get(pk=query.pk)
        return Response(SupportQuerySerializer(query, context={'request': request}).data)

    @action(detail=True, methods=['post'])
    def mark_read(self, request, pk=None):
        """Mark a query as read by the owner and/or staff."""
        from .serializers import SupportQuerySerializer
        query = self.get_object()
        changed = False
        if request.user == query.owner:
            query.has_unread_reply = False
            changed = True
        if request.user.is_staff:
            query.staff_has_unread = False
            changed = True
        if changed:
            query.save()
        return Response(SupportQuerySerializer(query, context={'request': request}).data)

    @action(detail=True, methods=['post'])
    def resolve(self, request, pk=None):
        """Mark a query as resolved."""
        from .serializers import SupportQuerySerializer

        if not request.user.is_staff:
            return Response({'detail': 'Only staff can resolve queries.'}, status=403)

        query = self.get_object()
        from django.utils import timezone
        query.status = 'RESOLVED'
        query.resolved_by = request.user
        query.resolved_at = timezone.now()
        query.save()

        from .notifications import send_push_notification
        staff_name = request.user.first_name or request.user.username
        # Typed 'support_query_reply' (not a bespoke 'resolved' type) so tapping
        # the notification deep-links to the owner's queries screen in the app.
        send_push_notification(query.owner, "Query Resolved",
            f"Your query '{query.subject}' has been resolved by {staff_name}.",
            {'type': 'support_query_reply', 'id': str(query.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'})

        return Response(SupportQuerySerializer(query, context={'request': request}).data)

    @action(detail=True, methods=['post'])
    def reopen(self, request, pk=None):
        """Reopen a resolved query."""
        from .serializers import SupportQuerySerializer

        query = self.get_object()
        if request.user != query.owner and not request.user.is_staff:
            return Response({'detail': 'You do not have permission to reopen this query.'}, status=403)

        query.status = 'OPEN'
        query.resolved_by = None
        query.resolved_at = None
        query.save()
        return Response(SupportQuerySerializer(query, context={'request': request}).data)

    @action(detail=False, methods=['get'])
    def unresolved_count(self, request):
        """Get count of queries with unread replies for badge display."""
        from .models import SupportQuery
        if request.user.is_staff:
            count = SupportQuery.objects.filter(status='OPEN', staff_has_unread=True).count()
        else:
            count = SupportQuery.objects.filter(owner=request.user, has_unread_reply=True).count()
        return Response({'count': count})


class ClosureDayViewSet(viewsets.ModelViewSet):
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        from .models import ClosureDay
        queryset = ClosureDay.objects.all()
        # Optional date range filtering
        from_date = self.request.query_params.get('from_date')
        to_date = self.request.query_params.get('to_date')
        if from_date:
            queryset = queryset.filter(date__gte=from_date)
        if to_date:
            queryset = queryset.filter(date__lte=to_date)
        return queryset

    def get_serializer_class(self):
        from .serializers import ClosureDaySerializer
        return ClosureDaySerializer

    def get_permissions(self):
        if self.action in ('create', 'update', 'partial_update', 'destroy'):
            return [IsAdminUser()]
        return [IsAuthenticated()]

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    def perform_destroy(self, instance):
        target_date = instance.date
        instance.delete()
        # Lifting a closure can free spots (or the whole day) — let the
        # waitlist know.
        try:
            from .scheduling import process_waitlist_for_date
            process_waitlist_for_date(target_date)
        except Exception as e:
            print(f"Failed to process waitlist: {e}")


class VaccinationRecordViewSet(viewsets.ModelViewSet):
    """Vaccination records for dogs. Staff write; owners read their dogs'.

    Filter with ?dog=<id>. Expiry reminders are sent by the daily
    send_vaccination_reminders management command.
    """
    permission_classes = [IsAuthenticated]
    pagination_class = OptInPagination

    def get_serializer_class(self):
        from .serializers import VaccinationRecordSerializer
        return VaccinationRecordSerializer

    def get_permissions(self):
        if self.action in ('create', 'update', 'partial_update', 'destroy'):
            return [IsAdminUser()]
        return [IsAuthenticated()]

    def get_queryset(self):
        from .models import VaccinationRecord
        from django.db.models import Q
        base = VaccinationRecord.objects.select_related('dog', 'created_by')
        dog_id = self.request.query_params.get('dog')
        if dog_id:
            base = base.filter(dog_id=dog_id)
        if self.request.user.is_staff:
            return base
        return base.filter(
            Q(dog__owner=self.request.user) | Q(dog__additional_owners=self.request.user)
        ).distinct()

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    def perform_update(self, serializer):
        old_expiry = serializer.instance.expiry_date
        instance = serializer.save()
        if instance.expiry_date != old_expiry:
            # Renewal recorded — re-arm the reminder flags.
            instance.reminder_30_sent = False
            instance.reminder_7_sent = False
            instance.expired_notice_sent = False
            instance.save(update_fields=['reminder_30_sent', 'reminder_7_sent', 'expired_notice_sent'])


class WaitlistEntryViewSet(mixins.CreateModelMixin, mixins.ListModelMixin,
                           mixins.DestroyModelMixin, viewsets.GenericViewSet):
    """Waitlist for full days. Owners join/leave for their own dogs;
    staff can list everything (filter with ?date=YYYY-MM-DD)."""
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        from .serializers import WaitlistEntrySerializer
        return WaitlistEntrySerializer

    def get_queryset(self):
        from .models import WaitlistEntry
        from django.db.models import Q
        base = WaitlistEntry.objects.select_related('dog')
        date_param = self.request.query_params.get('date')
        if date_param:
            base = base.filter(date=date_param)
        if self.request.user.is_staff:
            return base
        return base.filter(
            Q(dog__owner=self.request.user) | Q(dog__additional_owners=self.request.user)
        ).distinct()

    def create(self, request, *args, **kwargs):
        from datetime import date as date_cls
        from .models import WaitlistEntry
        from .scheduling import ScheduleIndex

        dog_id = request.data.get('dog')
        date_str = request.data.get('date')
        if not dog_id or not date_str:
            return Response({'detail': 'dog and date are required.'}, status=400)
        try:
            target_date = date_cls.fromisoformat(str(date_str))
        except ValueError:
            return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
        if target_date <= timezone.localdate():
            return Response({'detail': 'You can only join the waitlist for future dates.'}, status=400)

        try:
            dog = Dog.objects.get(id=dog_id)
        except Dog.DoesNotExist:
            return Response({'detail': 'Dog not found.'}, status=404)
        is_owner = (
            dog.owner_id == request.user.id
            or dog.additional_owners.filter(id=request.user.id).exists()
        )
        if not is_owner and not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('You can only join the waitlist for your own dogs.')

        index = ScheduleIndex(target_date, target_date)
        closure = index.closure(target_date)
        if closure and closure.closure_type == 'CLOSED':
            return Response({'detail': 'The daycare is closed on that day.'}, status=400)
        if dog.id in index.attending_dog_ids(target_date):
            return Response({'detail': f'{dog.name} is already booked for that day.'}, status=400)

        entry, created = WaitlistEntry.objects.update_or_create(
            dog=dog, date=target_date,
            defaults={'requested_by': request.user, 'status': 'WAITING', 'notified_at': None},
        )
        serializer = self.get_serializer(entry)
        return Response(serializer.data, status=201 if created else 200)


class DogNoteViewSet(viewsets.ModelViewSet):
    permission_classes = [IsAdminUser]

    def get_queryset(self):
        from django.db.models import Q
        from .models import DogNote
        queryset = DogNote.objects.select_related('dog', 'related_dog', 'created_by')
        dog_id = self.request.query_params.get('dog_id')
        if dog_id:
            # Compatibility notes describe a relationship between two dogs and
            # should surface on both dogs' profiles.
            queryset = queryset.filter(
                Q(dog_id=dog_id)
                | Q(note_type='COMPATIBILITY', related_dog_id=dog_id)
            )
        note_type = self.request.query_params.get('note_type')
        if note_type:
            queryset = queryset.filter(note_type=note_type)
        return queryset

    def get_serializer_class(self):
        from .serializers import DogNoteSerializer
        return DogNoteSerializer

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)


class StaffAvailabilityViewSet(viewsets.ModelViewSet):
    permission_classes = [IsAdminUser]

    def _can_manage_others(self):
        """Only staff managers may edit someone else's availability — the same
        rule the set_staff_availability action below enforces."""
        profile = getattr(self.request.user, 'profile', None)
        return bool(self.request.user.is_superuser or (profile and profile.can_manage_staff))

    def get_queryset(self):
        from .models import StaffAvailability
        queryset = StaffAvailability.objects.select_related('staff_member')
        staff_id = self.request.query_params.get('staff_member')
        if staff_id:
            queryset = queryset.filter(staff_member_id=staff_id)
        # Everyone may *read* the rota — the day board and roster screens need
        # it. Writes are restricted below.
        if self.request.method in ('GET', 'HEAD', 'OPTIONS'):
            return queryset
        # A row saying a staff member is unavailable suppresses all their push
        # notifications (notifications._is_staff_working_today), so letting any
        # staff account PATCH a colleague's row is a real insider vector.
        if not self._can_manage_others():
            queryset = queryset.filter(staff_member=self.request.user)
        return queryset

    def get_serializer_class(self):
        from .serializers import StaffAvailabilitySerializer
        return StaffAvailabilitySerializer

    def perform_create(self, serializer):
        # staff_member is writable on the serializer, so pin it to the caller
        # unless they are allowed to manage other people's availability.
        target = serializer.validated_data.get('staff_member')
        if target is None or (target != self.request.user and not self._can_manage_others()):
            serializer.save(staff_member=self.request.user)
            return
        serializer.save()

    def perform_update(self, serializer):
        target = serializer.validated_data.get('staff_member', serializer.instance.staff_member)
        if target != self.request.user and not self._can_manage_others():
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff managers can change someone else's availability.")
        serializer.save()

    @staticmethod
    def _apply_availability(staff_member, availability_data):
        """Upsert weekly availability rows for a staff member. Returns the
        saved objects."""
        from .models import StaffAvailability

        results = []
        for entry in availability_data:
            # Coerce defensively — a JSON client may send day_of_week/is_available
            # as strings, which would otherwise raise a TypeError 500 (B24).
            try:
                day = int(entry.get('day_of_week'))
            except (TypeError, ValueError):
                continue
            if day < 1 or day > 7:
                continue
            is_available = bool(entry.get('is_available', True))
            obj, _ = StaffAvailability.objects.update_or_create(
                staff_member=staff_member,
                day_of_week=day,
                defaults={
                    'is_available': is_available,
                    'is_available_daycare': is_available,
                    'is_available_boarding': False,
                    'note': entry.get('note', ''),
                },
            )
            results.append(obj)
        return results

    @action(detail=False, methods=['post'])
    def set_my_availability(self, request):
        """Set the current staff member's availability for multiple days at once.
        Accepts: {"availability": [{"day_of_week": 1, "is_available": true, "note": ""}, ...]}"""
        from .serializers import StaffAvailabilitySerializer

        availability_data = request.data.get('availability', [])
        if not availability_data:
            return Response({'detail': 'availability list is required'}, status=drf_status.HTTP_400_BAD_REQUEST)

        results = self._apply_availability(request.user, availability_data)
        serializer = StaffAvailabilitySerializer(results, many=True)
        return Response(serializer.data)

    @action(detail=False, methods=['post'])
    def set_staff_availability(self, request):
        """Set another staff member's weekly availability (staff managers only).
        Accepts: {"staff_member": <user id>, "availability": [{"day_of_week": 1,
        "is_available": true, "note": ""}, ...]}"""
        from .serializers import StaffAvailabilitySerializer

        profile = getattr(request.user, 'profile', None)
        if not (request.user.is_superuser or (profile and profile.can_manage_staff)):
            return Response({'detail': 'Not authorized to manage staff availability.'},
                            status=drf_status.HTTP_403_FORBIDDEN)

        try:
            staff_id = int(request.data.get('staff_member'))
        except (TypeError, ValueError):
            return Response({'detail': 'staff_member is required'}, status=drf_status.HTTP_400_BAD_REQUEST)

        try:
            staff_member = User.objects.get(pk=staff_id, is_staff=True)
        except User.DoesNotExist:
            return Response({'detail': 'Staff member not found'}, status=drf_status.HTTP_404_NOT_FOUND)

        availability_data = request.data.get('availability', [])
        if not availability_data:
            return Response({'detail': 'availability list is required'}, status=drf_status.HTTP_400_BAD_REQUEST)

        results = self._apply_availability(staff_member, availability_data)
        serializer = StaffAvailabilitySerializer(results, many=True)
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def my_availability(self, request):
        """Get the current staff member's availability."""
        from .models import StaffAvailability
        from .serializers import StaffAvailabilitySerializer

        availability = StaffAvailability.objects.filter(staff_member=request.user)
        serializer = StaffAvailabilitySerializer(availability, many=True)
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def coverage(self, request):
        """Get a summary of staff coverage per day of week.
        Returns: {"1": {"available": ["Alice", "Bob"], "unavailable": ["Charlie"]}, ...}"""
        from .models import StaffAvailability
        from django.contrib.auth.models import User

        staff = User.objects.filter(is_staff=True)
        day_map = {1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday', 5: 'Friday', 6: 'Saturday', 7: 'Sunday'}

        # Pre-fetch all availability records
        all_availability = {}
        for a in StaffAvailability.objects.all():
            all_availability[(a.staff_member_id, a.day_of_week)] = a.is_available_daycare

        coverage = {}
        for day_num in range(1, 8):
            available = []
            unavailable = []
            for s in staff:
                name = s.first_name or s.username
                is_avail = all_availability.get((s.id, day_num), True)
                entry = {'id': s.id, 'name': name}
                if is_avail:
                    available.append(entry)
                else:
                    unavailable.append(entry)
            coverage[str(day_num)] = {
                'day_name': day_map[day_num],
                'available': available,
                'unavailable': unavailable,
            }

        return Response(coverage)

    @action(detail=False, methods=['get'], url_path=r'available_staff/(?P<date_str>[0-9-]+)')
    def available_staff(self, request, date_str=None):
        """Get staff members available for dog assignment on a specific date.

        "Available" here means *not on approved time off*. A staff member is
        excluded only if they have an APPROVED day-off request for the date.
        The weekly working-days pattern (StaffAvailability) deliberately does
        NOT grey staff out here — it only feeds the Team Coverage view and
        notification filtering. (A regular non-working day is not the same as
        booked time off, so it should not mark someone unavailable to assign.)
        """
        from .models import DayOffRequest
        from datetime import datetime

        try:
            target_date = datetime.strptime(date_str, '%Y-%m-%d').date()
        except (ValueError, TypeError):
            return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=drf_status.HTTP_400_BAD_REQUEST)

        # Staff with an approved day-off request for this date are unavailable;
        # everyone else is available regardless of their weekly pattern.
        approved_off = set(
            DayOffRequest.objects.filter(date=target_date, status='APPROVED')
            .values_list('staff_member_id', flat=True)
        )

        available = []
        for s in User.objects.filter(is_staff=True):
            if s.id not in approved_off:
                name = s.first_name or s.username
                available.append({'id': s.id, 'name': name, 'username': s.username})

        return Response(available)

    @action(detail=False, methods=['get'])
    def team_off(self, request):
        """Approved staff time off within a date range, grouped by date.

        Visible to all staff (read-only) for the shared team calendar. Only
        approved day-off requests are returned, names only — pending/denied
        requests and reasons are never exposed here.

        Query params: start, end (YYYY-MM-DD).
        Returns: {"2026-06-14": ["Alice", "Bob"], ...}
        Dates with nobody off are omitted."""
        from .models import DayOffRequest
        from datetime import datetime, timedelta

        start_str = request.query_params.get('start')
        end_str = request.query_params.get('end')
        try:
            start = datetime.strptime(start_str, '%Y-%m-%d').date()
            end = datetime.strptime(end_str, '%Y-%m-%d').date()
        except (ValueError, TypeError):
            return Response(
                {'detail': 'start and end query params are required (YYYY-MM-DD).'},
                status=drf_status.HTTP_400_BAD_REQUEST,
            )

        if end < start:
            return Response({'detail': 'end must be on or after start.'}, status=drf_status.HTTP_400_BAD_REQUEST)
        if (end - start) > timedelta(days=100):
            return Response({'detail': 'Date range too large (max 100 days).'}, status=drf_status.HTTP_400_BAD_REQUEST)

        requests = (
            DayOffRequest.objects
            .filter(status='APPROVED', date__gte=start, date__lte=end)
            .select_related('staff_member')
            .order_by('date', 'staff_member__first_name')
        )

        result = {}
        for req in requests:
            name = req.staff_member.first_name or req.staff_member.username
            result.setdefault(req.date.isoformat(), []).append(name)

        return Response(result)


class DayOffRequestViewSet(viewsets.ModelViewSet):
    """ViewSet for day-off requests.
    Staff can create/view their own requests.
    Managers (is_staff + has canAssignDogs equivalent) can view all and approve/deny."""
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        from .models import DayOffRequest
        qs = DayOffRequest.objects.select_related('staff_member', 'reviewed_by')
        user = self.request.user
        if not user.is_staff:
            return qs.none()
        profile = getattr(user, 'profile', None)
        if profile and profile.can_manage_staff:
            return qs.all()
        # Ordinary staff only see (and can touch) their own requests; this scopes
        # retrieve/update/destroy so private day-off reasons can't be read or
        # tampered with by enumerating ids (B4).
        return qs.filter(staff_member=user)

    def get_serializer_class(self):
        from .serializers import DayOffRequestSerializer
        return DayOffRequestSerializer

    def list(self, request):
        """List all day-off requests (staff with can_manage_staff permission)."""
        from .models import DayOffRequest
        if not request.user.is_staff:
            return Response({'detail': 'Not authorized'}, status=drf_status.HTTP_403_FORBIDDEN)

        profile = getattr(request.user, 'profile', None)
        if not profile or not profile.can_manage_staff:
            return Response({'detail': 'Not authorized'}, status=drf_status.HTTP_403_FORBIDDEN)

        queryset = DayOffRequest.objects.select_related('staff_member', 'reviewed_by').all()
        serializer = self.get_serializer(queryset, many=True)
        return Response(serializer.data)

    def create(self, request):
        """Create a day-off request for the current user.
        Accepts: {"date": "2024-03-15", "reason": "optional"}
        For date ranges, the Flutter app creates one request per date."""
        from .models import DayOffRequest
        from .serializers import DayOffRequestSerializer

        date_str = request.data.get('date')
        if not date_str:
            return Response({'detail': 'date is required'}, status=drf_status.HTTP_400_BAD_REQUEST)

        from datetime import datetime
        try:
            target_date = datetime.strptime(date_str, '%Y-%m-%d').date()
        except ValueError:
            return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=drf_status.HTTP_400_BAD_REQUEST)

        # Check for duplicate
        existing = DayOffRequest.objects.filter(
            staff_member=request.user,
            date=target_date,
            status__in=['PENDING', 'APPROVED'],
        ).first()
        if existing:
            return Response(
                {'detail': f'You already have a {existing.get_status_display().lower()} request for this date.'},
                status=drf_status.HTTP_400_BAD_REQUEST,
            )

        from django.db import IntegrityError
        try:
            obj = DayOffRequest.objects.create(
                staff_member=request.user,
                date=target_date,
                reason=request.data.get('reason', ''),
            )
        except IntegrityError:
            # Lost the race against a concurrent identical request; the DB
            # constraint (B16) is the backstop for the check above.
            return Response(
                {'detail': 'You already have an active request for this date.'},
                status=drf_status.HTTP_400_BAD_REQUEST,
            )
        serializer = DayOffRequestSerializer(obj)
        return Response(serializer.data, status=drf_status.HTTP_201_CREATED)

    def destroy(self, request, pk=None):
        """Cancel (delete) a pending day-off request. Only the owner can cancel."""
        from .models import DayOffRequest

        try:
            obj = DayOffRequest.objects.get(pk=pk)
        except DayOffRequest.DoesNotExist:
            return Response(status=drf_status.HTTP_404_NOT_FOUND)

        if obj.staff_member != request.user:
            return Response({'detail': 'Not authorized'}, status=drf_status.HTTP_403_FORBIDDEN)
        if obj.status != 'PENDING':
            return Response({'detail': 'Only pending requests can be cancelled.'}, status=drf_status.HTTP_400_BAD_REQUEST)

        obj.delete()
        return Response(status=drf_status.HTTP_204_NO_CONTENT)

    @action(detail=False, methods=['get'])
    def my_requests(self, request):
        """Get the current user's day-off requests."""
        from .models import DayOffRequest
        queryset = DayOffRequest.objects.filter(staff_member=request.user).select_related('reviewed_by')
        serializer = self.get_serializer(queryset, many=True)
        return Response(serializer.data)

    @action(detail=True, methods=['post'])
    def approve(self, request, pk=None):
        """Approve a day-off request (managers only)."""
        return self._review(request, pk, 'APPROVED')

    @action(detail=True, methods=['post'])
    def deny(self, request, pk=None):
        """Deny a day-off request (managers only)."""
        return self._review(request, pk, 'DENIED')

    def _review(self, request, pk, new_status):
        from .models import DayOffRequest
        from django.utils import timezone

        profile = getattr(request.user, 'profile', None)
        if not (request.user.is_staff and profile and profile.can_manage_staff):
            return Response({'detail': 'Not authorized to review requests.'}, status=drf_status.HTTP_403_FORBIDDEN)

        try:
            obj = DayOffRequest.objects.select_related('staff_member', 'reviewed_by').get(pk=pk)
        except DayOffRequest.DoesNotExist:
            return Response(status=drf_status.HTTP_404_NOT_FOUND)

        if obj.status != 'PENDING':
            return Response({'detail': 'Only pending requests can be reviewed.'}, status=drf_status.HTTP_400_BAD_REQUEST)

        obj.status = new_status
        obj.reviewed_by = request.user
        obj.reviewed_at = timezone.now()
        obj.save()

        serializer = self.get_serializer(obj)
        return Response(serializer.data)


@api_view(['GET', 'PATCH'])
@perm_classes([IsAuthenticated])
def daycare_settings(request):
    """Facility-wide settings.

    GET: any authenticated user (the app needs the capacity to render the
    calendar). PATCH: superusers or staff with can_manage_requests; accepts
    {"default_daily_capacity": <int or null>} where null/0 means unlimited.
    """
    from .models import DaycareSettings

    settings_obj = DaycareSettings.load()
    if request.method == 'PATCH':
        profile = getattr(request.user, 'profile', None)
        allowed = request.user.is_superuser or (
            request.user.is_staff and profile and profile.can_manage_requests
        )
        if not allowed:
            return Response({'detail': 'Not authorized to change settings.'}, status=403)
        if 'default_daily_capacity' in request.data:
            value = request.data['default_daily_capacity']
            if value in (None, '', 0, '0'):
                settings_obj.default_daily_capacity = None
            else:
                try:
                    value = int(value)
                except (TypeError, ValueError):
                    return Response({'default_daily_capacity': 'Must be a positive number or null.'}, status=400)
                if value < 1:
                    return Response({'default_daily_capacity': 'Must be a positive number or null.'}, status=400)
                settings_obj.default_daily_capacity = value
            settings_obj.save()
    return Response({'default_daily_capacity': settings_obj.default_daily_capacity})


# =============================================================================
# PASSWORD RESET & CHANGE VIEWS
# =============================================================================

class PasswordResetRequestThrottle(AnonRateThrottle):
    """Limits OTP emails per client IP (rate set in DEFAULT_THROTTLE_RATES)."""
    scope = 'password_reset'


class PasswordResetConfirmThrottle(AnonRateThrottle):
    """Limits OTP/token verification attempts per client IP."""
    scope = 'password_reset_confirm'


def _user_for_reset_email(email):
    """Resolve the account a password-reset email belongs to, or None.

    Django's User.email carries no unique constraint, so duplicates and
    case-variants exist in the wild (and did in production when this was
    written). `User.objects.get()` would raise MultipleObjectsReturned — not
    caught by the DoesNotExist handlers — 500ing the request and locking *both*
    accounts out of password recovery permanently.

    When several accounts share an address the same person owns the mailbox, so
    picking one is safe; we pick the most recently used, falling back to the
    oldest, and log it so the duplicate can be cleaned up.
    """
    from django.db.models import F
    matches = list(
        User.objects.filter(email__iexact=email)
        .order_by(F('last_login').desc(nulls_last=True), 'id')[:2]
    )
    if not matches:
        return None
    if len(matches) > 1:
        logger.warning(
            'Password reset requested for %s, which matches multiple accounts; '
            'using the most recently active one. Merge or correct these accounts.',
            email,
        )
    return matches[0]


@api_view(['POST'])
@throttle_classes([PasswordResetRequestThrottle])
@perm_classes([AllowAny])
def request_password_reset(request):
    """Step 1: User provides email, receives a 6-digit OTP."""
    serializer = RequestPasswordResetSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    email = serializer.validated_data['email']

    # Always return success to prevent email enumeration
    user = _user_for_reset_email(email)
    if user is not None:
        otp_obj = PasswordResetOTP.create_for_user(user)
        try:
            send_mail(
                subject='Paws4Thought - Password Reset Code',
                message=(
                    f'Hi {user.first_name or user.username},\n\n'
                    f'Your password reset code is: {otp_obj.otp}\n\n'
                    f'This code expires in 15 minutes.\n\n'
                    f'If you did not request this, please ignore this email.\n\n'
                    f'Paws4Thought Dogs'
                ),
                from_email=getattr(settings, 'DEFAULT_FROM_EMAIL', 'noreply@paws4thoughtdogs.co.uk'),
                recipient_list=[user.email],
                fail_silently=False,
            )
        except Exception:
            # A send failure must not turn the deliberately-generic response
            # into a 500 — that would make this endpoint an email-enumeration
            # oracle (registered address 500s, unknown one 200s).
            logger.exception('Failed to send password reset email')

    return Response(
        {'detail': 'If an account with that email exists, a reset code has been sent.'},
        status=drf_status.HTTP_200_OK,
    )


@api_view(['POST'])
@throttle_classes([PasswordResetConfirmThrottle])
@perm_classes([AllowAny])
def verify_otp(request):
    """Step 2: User provides email + OTP, receives a temporary reset token."""
    serializer = VerifyOTPSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    email = serializer.validated_data['email']
    otp = serializer.validated_data['otp']

    user = _user_for_reset_email(email)
    if user is not None:
        otp_obj = PasswordResetOTP.objects.filter(
            user=user, otp=otp, is_used=False,
        ).order_by('-created_at').first()

        if otp_obj and otp_obj.is_valid():
            reset_token = otp_obj.generate_reset_token()
            return Response({'reset_token': reset_token}, status=drf_status.HTTP_200_OK)

    return Response(
        {'detail': 'Invalid or expired code.'},
        status=drf_status.HTTP_400_BAD_REQUEST,
    )


@api_view(['POST'])
@throttle_classes([PasswordResetConfirmThrottle])
@perm_classes([AllowAny])
def reset_password(request):
    """Step 3: User provides reset_token + new_password to set their new password."""
    serializer = ResetPasswordSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    reset_token = serializer.validated_data['reset_token']
    new_password = serializer.validated_data['new_password']

    try:
        otp_obj = PasswordResetOTP.objects.get(reset_token=reset_token, is_used=False)
    except PasswordResetOTP.DoesNotExist:
        return Response(
            {'detail': 'Invalid or expired reset token.'},
            status=drf_status.HTTP_400_BAD_REQUEST,
        )

    if otp_obj.is_expired():
        return Response(
            {'detail': 'Reset token has expired. Please request a new code.'},
            status=drf_status.HTTP_400_BAD_REQUEST,
        )

    user = otp_obj.user
    user.set_password(new_password)
    user.save()

    # Mark OTP as used. Other outstanding codes need no handling here —
    # PasswordResetOTP.create_for_user already invalidates and prunes a user's
    # previous codes, so at most one unused row exists at any time.
    otp_obj.is_used = True
    otp_obj.save()

    # Invalidate existing sessions — same rule as change_password (B3). DRF
    # tokens never expire and there is no session list, so without this someone
    # recovering a compromised account would leave the attacker's token valid
    # indefinitely. The user re-authenticates with their new password.
    from rest_framework.authtoken.models import Token
    Token.objects.filter(user=user).delete()

    return Response(
        {'detail': 'Password has been reset successfully.'},
        status=drf_status.HTTP_200_OK,
    )


@api_view(['POST'])
@perm_classes([IsAuthenticated])
def change_password(request):
    """Change password for the currently authenticated user."""
    serializer = ChangePasswordSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)

    user = request.user
    # Require the current password so a borrowed session / leaked token can't be
    # used to silently take over the account (B3).
    if not user.check_password(serializer.validated_data['old_password']):
        return Response(
            {'detail': 'Current password is incorrect.'},
            status=drf_status.HTTP_400_BAD_REQUEST,
        )
    user.set_password(serializer.validated_data['new_password'])
    user.save()

    # Rotate the auth token so any other session using the old token is logged
    # out, and hand the new token back for the client to store.
    from rest_framework.authtoken.models import Token
    Token.objects.filter(user=user).delete()
    new_token = Token.objects.create(user=user)

    return Response(
        {'detail': 'Password changed successfully.', 'token': new_token.key},
        status=drf_status.HTTP_200_OK,
    )


@api_view(['POST'])
@perm_classes([IsAuthenticated])
def delete_account(request):
    """Permanently delete the currently authenticated user's account.

    Requires password confirmation. Dogs owned by this user are NOT deleted: a
    remaining co-owner is promoted to primary owner where one exists (B20), and
    any dog with no remaining owner keeps owner=NULL (SET_NULL on the FK) and is
    surfaced via the admin owner filter so it isn't silently orphaned.
    The user is also removed from any additional_owners M2M relationships.
    """
    password = request.data.get('password')
    if not password:
        return Response(
            {'detail': 'Password is required to confirm account deletion.'},
            status=drf_status.HTTP_400_BAD_REQUEST,
        )

    user = request.user
    if not user.check_password(password):
        return Response(
            {'detail': 'Incorrect password.'},
            status=drf_status.HTTP_400_BAD_REQUEST,
        )

    # All-or-nothing. Without the transaction, the co-owner promotion below
    # commits and *then* user.delete() can fail — leaving the customer with an
    # account they can still log into but whose dog now belongs to someone else.
    from django.db import transaction
    from django.db.models import ProtectedError

    with transaction.atomic():
        # Promote a remaining co-owner to primary owner so the dog doesn't become an
        # invisible, un-ownable orphan when its only owner deletes their account (B20).
        for dog in Dog.objects.filter(owner=user):
            next_owner = dog.additional_owners.exclude(id=user.id).first()
            if next_owner is not None:
                dog.owner = next_owner
                dog.additional_owners.remove(next_owner)
                dog.save(update_fields=['owner'])

        # Remove user from additional_owners on any dogs (M2M cleanup)
        for dog in Dog.objects.filter(additional_owners=user):
            dog.additional_owners.remove(user)

        # Delete the user — cascades to profile, tokens, reactions, comments, etc.
        # Any dog still owned only by this user keeps owner=NULL (SET_NULL).
        try:
            user.delete()
        except ProtectedError:
            # Invoice.customer and DogWeekdayPickup.staff_member are PROTECT, so
            # anyone who has ever been invoiced (or driven a weekday route)
            # cannot be hard-deleted — invoices are statutory records. Anonymise
            # instead: the account becomes unusable and carries no personal data,
            # which satisfies an erasure request without destroying the ledger.
            _anonymise_user(user)
            return Response(
                {'detail': 'Account deleted successfully.'},
                status=drf_status.HTTP_200_OK,
            )

    return Response(
        {'detail': 'Account deleted successfully.'},
        status=drf_status.HTTP_200_OK,
    )


def _anonymise_user(user):
    """Strip personal data from an account that cannot be hard-deleted.

    Used when a user is referenced by records that must survive (invoices are
    kept for accounting). The account is deactivated, credentials are made
    unusable, and every identifying field is cleared, so nothing personal
    remains and the user can never sign in again.
    """
    from rest_framework.authtoken.models import Token

    Token.objects.filter(user=user).delete()
    user.username = f'deleted-user-{user.pk}'
    user.first_name = ''
    user.last_name = ''
    user.email = ''
    user.is_active = False
    user.set_unusable_password()
    user.save(update_fields=[
        'username', 'first_name', 'last_name', 'email', 'is_active', 'password',
    ])

    profile = getattr(user, 'profile', None)
    if profile is not None:
        profile.address = ''
        profile.phone_number = ''
        profile.pickup_instructions = ''
        if profile.profile_photo:
            profile.profile_photo.delete(save=False)
        profile.save(update_fields=[
            'address', 'phone_number', 'pickup_instructions', 'profile_photo',
        ])


# =============================================================================
# POSTCODE -> ADDRESS LOOKUP
# =============================================================================

# Postcode lookup + address geocoding live in api/geocoding.py (stdlib only,
# shared with the staff pickup map). Re-exported here for postcode_lookup below.
from .geocoding import (  # noqa: E402
    PostcodeLookupError,
    PostcodeNotFound,
    lookup_addresses,
)


@api_view(['GET'])
@perm_classes([IsAuthenticated])
def postcode_lookup(request):
    """Look up UK addresses for a postcode so the app can autofill a dog's
    registered-vet details.

    The provider API key lives server-side and is never shipped in the app: the
    Flutter client calls this endpoint, which proxies to the configured
    provider. Returns 503 when no key is configured, so the vet field degrades
    gracefully to a plain text box.

    Query param: ``postcode``.
    Response: ``{"postcode": "RG1 1AA", "addresses": [{"formatted": "...",
    "lines": [...], "postcode": "RG1 1AA"}, ...]}``.
    """
    postcode = (request.query_params.get('postcode') or '').strip()
    if not postcode:
        return Response(
            {'detail': 'A postcode query parameter is required.'},
            status=drf_status.HTTP_400_BAD_REQUEST,
        )

    api_key = getattr(settings, 'POSTCODE_LOOKUP_API_KEY', '')
    if not api_key:
        return Response(
            {'detail': 'Postcode lookup is not configured on the server.'},
            status=drf_status.HTTP_503_SERVICE_UNAVAILABLE,
        )

    provider = getattr(settings, 'POSTCODE_LOOKUP_PROVIDER', 'getaddress').lower()
    try:
        if provider == 'getaddress':
            addresses = lookup_addresses(postcode, api_key)
        else:
            return Response(
                {'detail': f'Unsupported postcode provider "{provider}".'},
                status=drf_status.HTTP_500_INTERNAL_SERVER_ERROR,
            )
    except PostcodeNotFound:
        return Response(
            {'detail': 'No addresses found for that postcode.'},
            status=drf_status.HTTP_404_NOT_FOUND,
        )
    except PostcodeLookupError as exc:
        return Response({'detail': str(exc)}, status=drf_status.HTTP_502_BAD_GATEWAY)

    return Response({'postcode': postcode.upper(), 'addresses': addresses})


class InquiryViewerPermission(BasePermission):
    """Staff with can_view_inquiries. Enforced at has_permission so it also
    covers the @action routes, not just the ones that go through get_queryset."""

    def has_permission(self, request, view):
        user = request.user
        if not (user and user.is_authenticated and user.is_staff):
            return False
        return bool(getattr(getattr(user, 'profile', None), 'can_view_inquiries', False))


class ContactInquiryViewSet(viewsets.ModelViewSet):
    """Staff-only access to website contact inquiries."""
    serializer_class = ContactInquirySerializer
    permission_classes = [InquiryViewerPermission]
    # 'post' is here only for the @action routes below (mark_read etc.), never
    # to create inquiries — the public form posts to submit_contact_inquiry.
    # While the viewset was IsAuthenticated, CreateModelMixin was live and never
    # consulted get_queryset, so any owner could POST blank rows that
    # push-notified every inquiry-managing staff member.
    http_method_names = ['get', 'delete', 'post']

    def create(self, request, *args, **kwargs):
        return Response(status=drf_status.HTTP_405_METHOD_NOT_ALLOWED)

    def get_queryset(self):
        return ContactInquiry.objects.all().order_by('-created_at')

    @action(detail=True, methods=['post'])
    def mark_read(self, request, pk=None):
        inquiry = self.get_object()
        inquiry.is_read = True
        inquiry.save()
        return Response(ContactInquirySerializer(inquiry).data)

    @action(detail=True, methods=['post'])
    def mark_unread(self, request, pk=None):
        inquiry = self.get_object()
        inquiry.is_read = False
        inquiry.save()
        return Response(ContactInquirySerializer(inquiry).data)

    @action(detail=True, methods=['post'])
    def mark_replied(self, request, pk=None):
        inquiry = self.get_object()
        inquiry.is_replied = True
        inquiry.is_read = True
        inquiry.save()
        return Response(ContactInquirySerializer(inquiry).data)

    @action(detail=False, methods=['get'])
    def unread_count(self, request):
        # Permission is handled by InquiryViewerPermission; this used to
        # dereference user.profile unguarded, which is an AttributeError 500 for
        # any user without one.
        return Response({'count': ContactInquiry.objects.filter(is_read=False).count()})


class ContactInquiryCreateThrottle(AnonRateThrottle):
    """Limits anonymous enquiry submissions per client IP (rate set in
    DEFAULT_THROTTLE_RATES)."""
    scope = 'contact_inquiry'


@api_view(['POST'])
@throttle_classes([ContactInquiryCreateThrottle])
@perm_classes([AllowAny])
def submit_contact_inquiry(request):
    """Public enquiry form on the app's logged-out landing page.

    Mirrors the website contact form (website/views.py): a tripped honeypot
    looks successful but saves nothing, and a real submission reaches staff
    the same two ways — the notification email below and the push sent by the
    ContactInquiry post_save signal."""
    serializer = PublicContactInquirySerializer(data=request.data)
    serializer.is_valid(raise_exception=True)

    if (serializer.validated_data.get('website') or '').strip():
        return Response(
            {'detail': 'Thank you! Your message has been received.'},
            status=drf_status.HTTP_201_CREATED,
        )

    inquiry = serializer.save()
    recipient = getattr(settings, 'CONTACT_INQUIRY_EMAIL', settings.DEFAULT_FROM_EMAIL)
    try:
        EmailMessage(
            subject=f'New Contact Inquiry: {inquiry.get_service_display()}',
            body=(
                f'Name: {inquiry.name}\n'
                f'Email: {inquiry.email}\n'
                f'Service: {inquiry.get_service_display()}\n\n'
                f'Message:\n{inquiry.message}'
            ),
            from_email=settings.DEFAULT_FROM_EMAIL,
            to=[recipient],
            reply_to=[inquiry.email],
        ).send(fail_silently=True)
    except Exception:
        pass

    return Response(
        {'detail': 'Thank you! Your message has been received.'},
        status=drf_status.HTTP_201_CREATED,
    )


class IsStaffReadOrVehicleManager(BasePermission):
    """All staff can read; writes require profile.can_manage_vehicles
    (superusers always allowed)."""

    def has_permission(self, request, view):
        user = request.user
        if not (user.is_authenticated and user.is_staff):
            return False
        if request.method in SAFE_METHODS:
            return True
        if user.is_superuser:
            return True
        return getattr(getattr(user, 'profile', None), 'can_manage_vehicles', False)


def _user_can_manage_vehicles(user):
    if user.is_superuser:
        return True
    return getattr(getattr(user, 'profile', None), 'can_manage_vehicles', False)


class VehicleViewSet(viewsets.ModelViewSet):
    """Fleet vehicles. All staff can view; users with can_manage_vehicles
    add/edit vehicles and update MOT/service due dates. Date changes are
    recorded as maintenance history and re-arm the reminder flags (reminders
    are sent by the daily send_fleet_reminders management command)."""
    permission_classes = [IsStaffReadOrVehicleManager]

    def get_serializer_class(self):
        from .serializers import VehicleSerializer
        return VehicleSerializer

    def get_queryset(self):
        from .models import Vehicle
        return Vehicle.objects.prefetch_related('defects')

    def perform_create(self, serializer):
        image_file = serializer.validated_data.get('image')
        if image_file:
            serializer.validated_data['image'] = process_image(image_file, max_size=(1280, 1280))
        serializer.save()

    def perform_update(self, serializer):
        from .models import VehicleMaintenanceRecord

        image_file = serializer.validated_data.get('image')
        if image_file:
            serializer.validated_data['image'] = process_image(image_file, max_size=(1280, 1280))

        old_mot = serializer.instance.mot_due_date
        old_service = serializer.instance.service_due_date
        instance = serializer.save()

        maintenance_notes = self.request.data.get('maintenance_notes')
        rearm_fields = []
        if instance.mot_due_date != old_mot:
            VehicleMaintenanceRecord.objects.create(
                vehicle=instance, event_type='MOT',
                previous_due_date=old_mot, new_due_date=instance.mot_due_date,
                notes=maintenance_notes, created_by=self.request.user,
            )
            instance.mot_reminder_30_sent = False
            instance.mot_reminder_7_sent = False
            instance.mot_overdue_notice_sent = False
            rearm_fields += ['mot_reminder_30_sent', 'mot_reminder_7_sent', 'mot_overdue_notice_sent']
        if instance.service_due_date != old_service:
            VehicleMaintenanceRecord.objects.create(
                vehicle=instance, event_type='SERVICE',
                previous_due_date=old_service, new_due_date=instance.service_due_date,
                notes=maintenance_notes, created_by=self.request.user,
            )
            instance.service_reminder_30_sent = False
            instance.service_reminder_7_sent = False
            instance.service_overdue_notice_sent = False
            rearm_fields += ['service_reminder_30_sent', 'service_reminder_7_sent', 'service_overdue_notice_sent']
        if rearm_fields:
            instance.save(update_fields=rearm_fields)

    @action(detail=True, methods=['get'])
    def history(self, request, pk=None):
        from .serializers import VehicleMaintenanceRecordSerializer
        vehicle = self.get_object()
        records = vehicle.maintenance_records.select_related('created_by')
        return Response(VehicleMaintenanceRecordSerializer(records, many=True).data)


class VehicleDefectViewSet(viewsets.ModelViewSet):
    """Vehicle defect reports. Any staff member can report a defect (with
    photos) and attach more photos; only vehicle managers can edit, delete
    or change defect status."""
    permission_classes = [IsAdminUser]

    def get_serializer_class(self):
        from .serializers import VehicleDefectSerializer
        return VehicleDefectSerializer

    def get_permissions(self):
        if self.action in ('update', 'partial_update', 'destroy'):
            return [IsStaffReadOrVehicleManager()]
        return [IsAdminUser()]

    def get_queryset(self):
        from .models import VehicleDefect
        qs = VehicleDefect.objects.select_related('vehicle', 'reported_by', 'resolved_by').prefetch_related('images', 'comments__user')
        vehicle_id = self.request.query_params.get('vehicle')
        if vehicle_id:
            qs = qs.filter(vehicle_id=vehicle_id)
        status_param = self.request.query_params.get('status')
        if status_param:
            qs = qs.filter(status=status_param)
        return qs

    def _attach_images(self, defect):
        from .models import VehicleDefectImage
        for image_file in self.request.FILES.getlist('images'):
            VehicleDefectImage.objects.create(
                defect=defect,
                image=process_image(image_file, max_size=(1280, 1280)),
                thumbnail=process_image(image_file, max_size=(400, 400), quality=70),
            )

    def perform_create(self, serializer):
        defect = serializer.save(reported_by=self.request.user)
        self._attach_images(defect)

        try:
            from .notifications import send_staff_notification
            reporter = self.request.user.first_name or self.request.user.username
            send_staff_notification(
                f"New defect: {defect.vehicle.name}",
                f"{reporter} reported '{defect.title}' ({defect.get_severity_display()} severity)",
                {'type': 'vehicle_defect', 'id': str(defect.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
                permission='can_manage_vehicles',
                exclude_user=self.request.user,
            )
        except Exception as e:
            print(f"Failed to send defect notification: {e}")

    @action(detail=True, methods=['post'])
    def add_images(self, request, pk=None):
        defect = self.get_object()
        self._attach_images(defect)
        defect = self.get_queryset().get(pk=defect.pk)
        return Response(self.get_serializer(defect).data)

    @action(detail=True, methods=['post'])
    def change_status(self, request, pk=None):
        from .models import VehicleDefect
        from rest_framework.exceptions import PermissionDenied

        if not _user_can_manage_vehicles(request.user):
            raise PermissionDenied("Only vehicle managers can change defect status")

        defect = self.get_object()
        new_status = request.data.get('status')
        if new_status not in dict(VehicleDefect.STATUS_CHOICES).keys():
            return Response({'detail': 'Invalid status'}, status=400)

        old_status = defect.status
        if old_status == new_status:
            return Response(self.get_serializer(defect).data)

        defect.status = new_status
        if new_status == 'RESOLVED':
            defect.resolved_by = request.user
            defect.resolved_at = timezone.now()
        else:
            defect.resolved_by = None
            defect.resolved_at = None
        defect.save()

        if defect.reported_by and defect.reported_by != request.user:
            try:
                from .notifications import send_push_notification
                send_push_notification(
                    defect.reported_by,
                    "Defect update",
                    f"'{defect.title}' on {defect.vehicle.name} is now {defect.get_status_display()}.",
                    {'type': 'vehicle_defect', 'id': str(defect.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
                )
            except Exception as e:
                print(f"Failed to send defect status notification: {e}")

        return Response(self.get_serializer(defect).data)

    @action(detail=True, methods=['post'])
    def comment(self, request, pk=None):
        """Add a progress comment to a vehicle defect (any staff member)."""
        from .models import VehicleDefectComment
        defect = self.get_object()
        text = (request.data.get('text') or '').strip()
        if not text:
            return Response({'detail': 'Text is required'}, status=400)
        comment = VehicleDefectComment.objects.create(defect=defect, user=request.user, text=text)
        try:
            from .notifications import notify_defect_comment
            notify_defect_comment(comment, defect, defect_type='vehicle')
        except Exception as e:
            print(f"Failed to send defect comment notification: {e}")
        defect = self.get_queryset().get(pk=defect.pk)
        return Response(self.get_serializer(defect).data)

    @action(detail=False, methods=['get'])
    def unresolved_count(self, request):
        from .models import VehicleDefect
        count = VehicleDefect.objects.exclude(status='RESOLVED').count()
        return Response({'count': count})


class FacilityDefectViewSet(viewsets.ModelViewSet):
    """General site/facility defect reports (e.g. a broken gate). Any staff
    member can report a defect with photos and change its status."""
    permission_classes = [IsAdminUser]

    def get_serializer_class(self):
        from .serializers import FacilityDefectSerializer
        return FacilityDefectSerializer

    def get_queryset(self):
        from .models import FacilityDefect
        qs = FacilityDefect.objects.select_related('reported_by', 'resolved_by').prefetch_related('images', 'comments__user')
        status_param = self.request.query_params.get('status')
        if status_param:
            qs = qs.filter(status=status_param)
        return qs

    def _attach_images(self, defect):
        from .models import FacilityDefectImage
        for image_file in self.request.FILES.getlist('images'):
            FacilityDefectImage.objects.create(
                defect=defect,
                image=process_image(image_file, max_size=(1280, 1280)),
                thumbnail=process_image(image_file, max_size=(400, 400), quality=70),
            )

    def perform_create(self, serializer):
        defect = serializer.save(reported_by=self.request.user)
        self._attach_images(defect)

        try:
            from .notifications import send_staff_notification
            reporter = self.request.user.first_name or self.request.user.username
            send_staff_notification(
                "New defect reported",
                f"{reporter} reported '{defect.title}' ({defect.get_severity_display()} severity)",
                {'type': 'facility_defect', 'id': str(defect.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
                exclude_user=self.request.user,
            )
        except Exception as e:
            print(f"Failed to send facility defect notification: {e}")

    @action(detail=True, methods=['post'])
    def add_images(self, request, pk=None):
        defect = self.get_object()
        self._attach_images(defect)
        defect = self.get_queryset().get(pk=defect.pk)
        return Response(self.get_serializer(defect).data)

    @action(detail=True, methods=['post'])
    def change_status(self, request, pk=None):
        from .models import FacilityDefect

        defect = self.get_object()
        new_status = request.data.get('status')
        if new_status not in dict(FacilityDefect.STATUS_CHOICES).keys():
            return Response({'detail': 'Invalid status'}, status=400)

        old_status = defect.status
        if old_status == new_status:
            return Response(self.get_serializer(defect).data)

        defect.status = new_status
        if new_status == 'RESOLVED':
            defect.resolved_by = request.user
            defect.resolved_at = timezone.now()
        else:
            defect.resolved_by = None
            defect.resolved_at = None
        defect.save()

        if defect.reported_by and defect.reported_by != request.user:
            try:
                from .notifications import send_push_notification
                send_push_notification(
                    defect.reported_by,
                    "Defect update",
                    f"'{defect.title}' is now {defect.get_status_display()}.",
                    {'type': 'facility_defect', 'id': str(defect.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
                )
            except Exception as e:
                print(f"Failed to send facility defect status notification: {e}")

        return Response(self.get_serializer(defect).data)

    @action(detail=True, methods=['post'])
    def comment(self, request, pk=None):
        """Add a progress comment to a facility defect (any staff member)."""
        from .models import FacilityDefectComment
        defect = self.get_object()
        text = (request.data.get('text') or '').strip()
        if not text:
            return Response({'detail': 'Text is required'}, status=400)
        comment = FacilityDefectComment.objects.create(defect=defect, user=request.user, text=text)
        try:
            from .notifications import notify_defect_comment
            notify_defect_comment(comment, defect, defect_type='facility')
        except Exception as e:
            print(f"Failed to send facility defect comment notification: {e}")
        defect = self.get_queryset().get(pk=defect.pk)
        return Response(self.get_serializer(defect).data)

    @action(detail=False, methods=['get'])
    def unresolved_count(self, request):
        from .models import FacilityDefect
        count = FacilityDefect.objects.exclude(status='RESOLVED').count()
        return Response({'count': count})


class IncidentViewSet(viewsets.ModelViewSet):
    """Staff-only incident log — scuffles, bites, injuries, escapes.

    ``permission_classes = [IsAdminUser]`` is the whole confidentiality story:
    owners get 403 on every route here, including the per-dog listing their own
    dog appears in. Nothing about an incident is surfaced through the
    owner-facing dog/feed serializers either, so an owner learns what happened
    from a conversation, not from the app.

    Filters: ``?dog=<id>`` (what the dog profile's "Incidents" link uses),
    ``?status=``, ``?severity=``, ``?type=``, ``?open=true``.
    """
    permission_classes = [IsAdminUser]

    def get_serializer_class(self):
        from .serializers import IncidentSerializer, IncidentSummarySerializer
        # Listing is a scan-and-tap-through view: the compact shape keeps a
        # year of incidents from dragging every photo and comment with it.
        if self.action == 'list':
            return IncidentSummarySerializer
        return IncidentSerializer

    def get_queryset(self):
        from .models import Incident

        qs = Incident.objects.select_related('reported_by', 'resolved_by')
        if self.action == 'list':
            qs = qs.prefetch_related('dog_entries__dog')
        else:
            qs = qs.prefetch_related(
                'media', 'comments__user', 'staff_present',
                'dog_entries__dog__owner',
            )
        params = self.request.query_params
        dog_id = params.get('dog')
        if dog_id:
            qs = qs.filter(dog_entries__dog_id=dog_id)
        if params.get('status'):
            qs = qs.filter(status=params['status'])
        if params.get('severity'):
            qs = qs.filter(severity=params['severity'])
        if params.get('type'):
            qs = qs.filter(incident_type=params['type'])
        if params.get('open') == 'true':
            qs = qs.exclude(status='RESOLVED')
        # distinct() only matters for the dog filter's join, but it is cheap
        # and keeps every branch returning one row per incident.
        return qs.distinct()

    # ---- media ----

    def _media_type_for(self, upload, declared=None):
        """PHOTO unless the file looks like a video (or the client says so)."""
        import os as _os
        from .validators import ALLOWED_VIDEO_EXTENSIONS

        if declared in ('PHOTO', 'VIDEO'):
            return declared
        ext = _os.path.splitext(getattr(upload, 'name', '') or '')[1].lower()
        return 'VIDEO' if ext in ALLOWED_VIDEO_EXTENSIONS else 'PHOTO'

    def _attach_media(self, incident):
        """Store every uploaded file against the incident.

        Photos are resized and thumbnailed like the rest of the app; videos are
        stored as-is with a first-frame thumbnail (best-effort — a missing
        thumbnail must never lose the evidence). Uploads are validated first,
        so a rejected file 400s instead of landing on disk.
        """
        from django.core.exceptions import ValidationError as DjangoValidationError
        from rest_framework.exceptions import ValidationError as DRFValidationError
        from .models import IncidentMedia
        from .validators import validate_media_upload

        files = self.request.FILES.getlist('media') or self.request.FILES.getlist('images')
        declared = self.request.data.get('media_type') if hasattr(self.request.data, 'get') else None
        created = []
        for upload in files:
            media_type = self._media_type_for(upload, declared)
            try:
                validate_media_upload(upload, media_type)
            except DjangoValidationError as exc:
                raise DRFValidationError({'media': exc.messages})

            if media_type == 'VIDEO':
                thumbnail = generate_video_thumbnail(upload)
                stored = upload
            else:
                stored, thumbnail = process_image_pair(upload, main_size=(1600, 1600))

            created.append(IncidentMedia.objects.create(
                incident=incident,
                media_type=media_type,
                file=stored,
                thumbnail=thumbnail,
                uploaded_by=self.request.user,
            ))
        return created

    def perform_create(self, serializer):
        incident = serializer.save(reported_by=self.request.user)
        self._attach_media(incident)
        self._notify_new_incident(incident)

    def perform_destroy(self, instance):
        """Only a superuser can delete an incident.

        An incident is the contemporaneous account of something that went
        wrong — the thing an owner, a vet or an insurer may ask about months
        later. Any staff member can correct one (edit the write-up, add
        photos) or close it out; taking it off the books entirely is a
        deliberate, admin-level act.
        """
        if not self.request.user.is_superuser:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('Only an administrator can delete an incident record.')
        instance.delete()

    def _notify_new_incident(self, incident):
        """Tell the rest of the team. Staff-wide on purpose: whoever has the
        dogs next needs to know, not just the managers."""
        try:
            from .notifications import send_staff_notification
            reporter = self.request.user.first_name or self.request.user.username
            dogs = ', '.join(entry.dog.name for entry in incident.dog_entries.select_related('dog'))
            body = f"{reporter} logged '{incident.title}'"
            if dogs:
                body += f" — {dogs}"
            body += f" ({incident.get_severity_display().lower()})"
            send_staff_notification(
                'Incident logged',
                body,
                {'type': 'incident', 'id': str(incident.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
                exclude_user=self.request.user,
            )
        except Exception as e:
            print(f"Failed to send incident notification: {e}")

    @action(detail=True, methods=['post'])
    def add_media(self, request, pk=None):
        incident = self.get_object()
        self._attach_media(incident)
        incident = self.get_queryset().get(pk=incident.pk)
        return Response(self.get_serializer(incident).data)

    @action(detail=True, methods=['delete'], url_path='media/(?P<media_id>[0-9]+)')
    def delete_media(self, request, pk=None, media_id=None):
        incident = self.get_object()
        deleted, _ = incident.media.filter(id=media_id).delete()
        if not deleted:
            return Response({'detail': 'Not found'}, status=404)
        incident = self.get_queryset().get(pk=incident.pk)
        return Response(self.get_serializer(incident).data)

    # ---- status / follow-up ----

    @action(detail=True, methods=['post'])
    def change_status(self, request, pk=None):
        from .models import Incident

        incident = self.get_object()
        new_status = request.data.get('status')
        if new_status not in dict(Incident.STATUS_CHOICES):
            return Response({'detail': 'Invalid status'}, status=400)

        notes = (request.data.get('resolution_notes') or '').strip()
        if incident.status == new_status and not notes:
            return Response(self.get_serializer(incident).data)

        incident.status = new_status
        if notes:
            incident.resolution_notes = notes
        if new_status == 'RESOLVED':
            incident.resolved_by = request.user
            incident.resolved_at = timezone.now()
        else:
            incident.resolved_by = None
            incident.resolved_at = None
        incident.save()

        if incident.reported_by and incident.reported_by != request.user:
            try:
                from .notifications import send_push_notification
                send_push_notification(
                    incident.reported_by,
                    'Incident update',
                    f"'{incident.title}' is now {incident.get_status_display()}.",
                    {'type': 'incident', 'id': str(incident.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
                )
            except Exception as e:
                print(f"Failed to send incident status notification: {e}")

        incident = self.get_queryset().get(pk=incident.pk)
        return Response(self.get_serializer(incident).data)

    @action(detail=True, methods=['post'])
    def comment(self, request, pk=None):
        from .models import IncidentComment

        incident = self.get_object()
        text = (request.data.get('text') or '').strip()
        if not text:
            return Response({'detail': 'Text is required'}, status=400)
        IncidentComment.objects.create(incident=incident, user=request.user, text=text)
        incident = self.get_queryset().get(pk=incident.pk)
        return Response(self.get_serializer(incident).data)

    @action(detail=True, methods=['post'])
    def owner_notified(self, request, pk=None):
        """Record that a dog's owner has been told (or un-record it).

        Body: ``{"dog": <dog id>, "notified": true}``. This only tracks the
        conversation staff had — no notification is sent to the owner from
        here, and nothing about the incident is exposed to them.
        """
        incident = self.get_object()
        dog_id = request.data.get('dog')
        entry = incident.dog_entries.filter(dog_id=dog_id).first()
        if entry is None:
            return Response({'detail': 'That dog is not on this incident.'}, status=404)
        notified = _truthy(request.data.get('notified', True))
        entry.owner_notified = notified
        entry.owner_notified_at = timezone.now() if notified else None
        entry.save(update_fields=['owner_notified', 'owner_notified_at'])
        incident = self.get_queryset().get(pk=incident.pk)
        return Response(self.get_serializer(incident).data)

    @action(detail=False, methods=['get'])
    def open_count(self, request):
        from .models import Incident
        return Response({'count': Incident.objects.exclude(status='RESOLVED').count()})


class IntakeRequestViewSet(viewsets.ModelViewSet):
    """The app's booking form: owners submit their contact details plus the
    dog(s) they want to enrol; staff approve (creating the Dog records) or
    deny. Owners can withdraw a submission while it's still pending."""
    serializer_class = IntakeRequestSerializer
    permission_classes = [IsAuthenticated]
    pagination_class = OptInPagination
    http_method_names = ['get', 'post', 'delete', 'head', 'options']

    def get_queryset(self):
        base = IntakeRequest.objects.select_related('owner', 'reviewed_by').prefetch_related('dogs')
        if self.request.user.is_staff:
            return base.all()
        return base.filter(owner=self.request.user)

    def perform_create(self, serializer):
        instance = serializer.save(owner=self.request.user)

        # The form doubles as the owner's contact details, so mirror them onto
        # the profile — the profile is what staff screens read from.
        try:
            profile = instance.owner.profile
            changed = False
            for src, dest in (
                ('phone_number', 'phone_number'),
                ('address', 'address'),
                ('pickup_instructions', 'pickup_instructions'),
            ):
                value = getattr(instance, src)
                if value and getattr(profile, dest) != value:
                    setattr(profile, dest, value)
                    changed = True
            if changed:
                profile.save()
        except UserProfile.DoesNotExist:
            pass

        # Tell managers there's a new booking form to review.
        try:
            from .notifications import send_push_notification
            dog_names = ', '.join(d.name for d in instance.dogs.all())
            owner_name = instance.owner.first_name or instance.owner.username
            title = 'New Booking Form'
            body = f"{owner_name} submitted a booking form for {dog_names}."
            data = {
                'type': 'intake_request',
                'id': str(instance.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            for user in User.objects.filter(is_staff=True, profile__can_manage_requests=True):
                send_push_notification(user, title, body, data)
        except Exception as e:
            print(f"Failed to send push notification: {e}")

    def perform_destroy(self, instance):
        # Owners can withdraw their own form only while it's pending; staff can
        # delete anything (e.g. clearing out duplicates).
        if not self.request.user.is_staff and instance.status != 'PENDING':
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('Only staff can delete a booking form that has been reviewed.')
        instance.delete()

    def _notify_owner_status(self, instance, approved):
        try:
            from .notifications import send_push_notification
            dog_names = ', '.join(d.name for d in instance.dogs.all())
            if approved:
                title = 'Booking Form Approved'
                body = f"Welcome aboard! {dog_names} {'have' if instance.dogs.count() > 1 else 'has'} been added to daycare."
            else:
                title = 'Booking Form Update'
                body = f"Your booking form for {dog_names} was not approved."
                if instance.denial_reason:
                    body += f" Reason: {instance.denial_reason}"
            data = {
                'type': 'intake_request_update',
                'id': str(instance.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            send_push_notification(instance.owner, title, body, data, category='bookings')
        except Exception as e:
            print(f"Failed to send push notification: {e}")

    @action(detail=True, methods=['post'])
    def approve(self, request, pk=None):
        """Approve a pending booking form, creating a Dog for each entry."""
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('Only staff can approve booking forms')

        instance = self.get_object()
        if instance.status != 'PENDING':
            return Response({'detail': 'This booking form has already been reviewed.'}, status=400)

        from django.utils import timezone
        for intake_dog in instance.dogs.all():
            dog = Dog.objects.create(
                owner=instance.owner,
                name=intake_dog.name,
                sex=intake_dog.sex,
                date_of_birth=intake_dog.date_of_birth,
                is_spayed=intake_dog.is_spayed,
                food_instructions=intake_dog.food_instructions or None,
                medical_notes=intake_dog.medical_notes or None,
                registered_vet=intake_dog.registered_vet or None,
                address=instance.address or None,
                postcode=instance.postcode,
                daycare_days=intake_dog.daycare_days,
                schedule_type=intake_dog.schedule_type,
            )
            intake_dog.created_dog = dog
            intake_dog.save(update_fields=['created_dog'])

        instance.status = 'APPROVED'
        instance.reviewed_by = request.user
        instance.reviewed_at = timezone.now()
        instance.save()

        self._notify_owner_status(instance, approved=True)
        return Response(self.get_serializer(instance).data)

    @action(detail=True, methods=['post'])
    def deny(self, request, pk=None):
        """Deny a pending booking form, optionally with a reason for the owner."""
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('Only staff can deny booking forms')

        instance = self.get_object()
        if instance.status != 'PENDING':
            return Response({'detail': 'This booking form has already been reviewed.'}, status=400)

        from django.utils import timezone
        instance.status = 'DENIED'
        instance.denial_reason = (request.data.get('reason') or '').strip()
        instance.reviewed_by = request.user
        instance.reviewed_at = timezone.now()
        instance.save()

        self._notify_owner_status(instance, approved=False)
        return Response(self.get_serializer(instance).data)


# =============================================================================
# CUSTOMER PAYMENTS (monthly invoices + Xero)
# =============================================================================

class IsPaymentsManager(BasePermission):
    """Staff with profile.can_manage_payments (superusers always allowed)."""

    def has_permission(self, request, view):
        user = request.user
        if not (user.is_authenticated and user.is_staff):
            return False
        if user.is_superuser:
            return True
        return getattr(getattr(user, 'profile', None), 'can_manage_payments', False)


def _user_can_manage_payments(user):
    if user.is_superuser:
        return True
    return user.is_staff and getattr(getattr(user, 'profile', None), 'can_manage_payments', False)


class InvoiceViewSet(viewsets.ReadOnlyModelViewSet):
    """Monthly customer invoices.

    Owners list/retrieve their own sent invoices (drafts stay staff-side until
    reviewed) and fetch the online payment URL. Staff with can_manage_payments
    see everything and drive the workflow through actions — invoices are never
    free-form edited, so the base viewset is read-only.
    """
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        from .serializers import InvoiceSerializer
        return InvoiceSerializer

    def get_queryset(self):
        from .models import Invoice

        qs = Invoice.objects.select_related('customer__profile').prefetch_related('lines__dog', 'payments__recorded_by')
        if _user_can_manage_payments(self.request.user):
            params = self.request.query_params
            if params.get('year'):
                qs = qs.filter(period_year=params['year'])
            if params.get('month'):
                qs = qs.filter(period_month=params['month'])
            if params.get('status'):
                qs = qs.filter(status=params['status'].upper())
            if params.get('customer'):
                qs = qs.filter(customer_id=params['customer'])
            return qs
        # Owners: own invoices only, and never unreviewed drafts.
        # SENDING is a draft that is mid-push to Xero — not yet the customer's.
        return qs.filter(customer=self.request.user).exclude(status__in=('DRAFT', 'SENDING'))

    def _require_manager(self):
        if not _user_can_manage_payments(self.request.user):
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied('You do not have permission to manage payments.')

    @staticmethod
    def _parse_period(request):
        try:
            year = int(request.data.get('year'))
            month = int(request.data.get('month'))
        except (TypeError, ValueError):
            return None, None
        if not (1 <= month <= 12) or not (2000 <= year <= 2100):
            return None, None
        return year, month

    @action(detail=False, methods=['post'])
    def generate(self, request):
        """Generate draft invoices for a month from attendance records.

        Optional ``customer`` (user id) restricts generation to one client —
        used to (re)issue a single invoice, e.g. after voiding it. That form
        also bypasses the customer's billing mode; the bulk form only bills
        APP-mode customers and reports MANUAL ones in ``manual``.
        """
        from . import billing

        self._require_manager()
        year, month = self._parse_period(request)
        if year is None:
            return Response({'detail': 'Provide a valid year and month.'}, status=400)
        customer = None
        if request.data.get('customer'):
            try:
                customer = User.objects.get(pk=request.data['customer'])
            except (User.DoesNotExist, ValueError, TypeError):
                return Response({'customer': 'No such customer.'}, status=400)
        created, skipped, manual = billing.generate_invoices_for_month(
            year, month, created_by=request.user, customer=customer)
        return Response({'created': len(created), 'skipped': skipped, 'manual': manual})

    @action(detail=True, methods=['post'])
    def send(self, request, pk=None):
        """Send a draft invoice: notify the owner and push to Xero."""
        from . import billing

        self._require_manager()
        invoice = self.get_object()
        if invoice.status != 'DRAFT':
            return Response({'detail': 'Only draft invoices can be sent.'}, status=400)
        try:
            billing.send_invoice(invoice, user=request.user)
        except billing.XeroSendFailed as exc:
            # The invoice is back in DRAFT — say so rather than reporting success
            # for something the customer will never receive.
            return Response({'detail': str(exc), 'code': 'xero_send_failed'}, status=502)
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=400)
        invoice.refresh_from_db()
        return Response(self.get_serializer(invoice).data)

    @action(detail=False, methods=['post'])
    def send_all(self, request):
        """Send every draft invoice for a period.

        Reports per-invoice outcomes. One customer's Xero failure must not abort
        the batch and leave the rest unsent with no record of how far it got.
        """
        from . import billing
        from .models import Invoice

        self._require_manager()
        year, month = self._parse_period(request)
        if year is None:
            return Response({'detail': 'Provide a valid year and month.'}, status=400)
        drafts = Invoice.objects.filter(status='DRAFT', period_year=year, period_month=month)
        sent = 0
        failed = []
        for invoice in drafts:
            try:
                billing.send_invoice(invoice, user=request.user)
                sent += 1
            except (billing.XeroSendFailed, ValueError) as exc:
                failed.append({
                    'invoice': invoice.id,
                    'customer': invoice.billed_name,
                    'detail': str(exc),
                })
        return Response({'sent': sent, 'failed': failed})

    @action(detail=True, methods=['post'])
    def regenerate(self, request, pk=None):
        """Rebuild a draft invoice's lines from current attendance data."""
        from . import billing

        self._require_manager()
        invoice = self.get_object()
        if invoice.status != 'DRAFT':
            return Response({'detail': 'Only draft invoices can be regenerated.'}, status=400)
        billing.regenerate_draft(invoice)
        return Response(self.get_serializer(invoice).data)

    @action(detail=True, methods=['post'])
    def record_payment(self, request, pk=None):
        """Record a manual payment (cash/bank transfer) against an invoice."""
        from decimal import Decimal, InvalidOperation
        from datetime import date as date_cls
        from . import billing
        from .models import PaymentRecord

        self._require_manager()
        invoice = self.get_object()
        if invoice.status in ('DRAFT', 'VOID'):
            return Response({'detail': 'Payments can only be recorded against sent invoices.'}, status=400)

        try:
            amount = Decimal(str(request.data.get('amount')))
        except (InvalidOperation, TypeError, ValueError):
            return Response({'amount': 'Enter a valid amount.'}, status=400)
        if amount <= 0:
            return Response({'amount': 'Amount must be greater than zero.'}, status=400)

        method = request.data.get('method', 'CASH')
        if method not in dict(PaymentRecord.METHOD_CHOICES):
            return Response({'method': 'Invalid payment method.'}, status=400)

        payment_date = None
        if request.data.get('payment_date'):
            try:
                payment_date = date_cls.fromisoformat(str(request.data['payment_date']))
            except ValueError:
                return Response({'payment_date': 'Enter a valid date (YYYY-MM-DD).'}, status=400)

        billing.record_manual_payment(
            invoice, amount, method,
            payment_date=payment_date,
            recorded_by=request.user,
            notes=(request.data.get('notes') or '')[:255],
        )
        invoice.refresh_from_db()
        return Response(self.get_serializer(invoice).data)

    @action(detail=True, methods=['post'])
    def void(self, request, pk=None):
        """Void an invoice (any status except PAID).

        Best-effort mirrors the void into Xero. Xero refuses to void invoices
        that already have payments applied — the response says whether the
        Xero copy was voided so staff know if a manual credit is needed.
        """
        from . import xero
        from .models import XeroConnection

        self._require_manager()
        invoice = self.get_object()
        if invoice.status == 'PAID':
            return Response({'detail': 'A paid invoice cannot be voided.'}, status=400)
        # A PART_PAID invoice used to void freely. Because the period's unique
        # constraints and generate_invoices_for_month both ignore VOID rows, the
        # month could then be regenerated at full price while the payments that
        # had already been collected stayed attached to the dead invoice —
        # money vanishes from the totals and the customer is chased for the lot.
        # Require an explicit acknowledgement, and say how much is at stake.
        collected = invoice.payments.aggregate(total=Sum('amount'))['total'] or Decimal('0.00')
        if collected > 0 and not _truthy(request.data.get('confirm_discard_payments')):
            return Response(
                {
                    'detail': (
                        f'£{collected} has already been recorded against this invoice. '
                        'Voiding it will leave that payment attached to a void invoice — '
                        'raise a credit note or move the payment first. '
                        'Send confirm_discard_payments=true to void anyway.'
                    ),
                    'code': 'invoice_has_payments',
                    'amount_paid': str(collected),
                },
                status=400,
            )
        invoice.status = 'VOID'
        invoice.save(update_fields=['status', 'updated_at'])

        xero_voided = False
        xero_error = ''
        if invoice.xero_invoice_id and XeroConnection.load().is_connected:
            try:
                xero.void_invoice(invoice.xero_invoice_id)
                xero_voided = True
                invoice.xero_sync_error = ''
            except xero.XeroError as exc:
                xero_error = str(exc)
                invoice.xero_sync_error = f'Void failed in Xero: {exc}'
            invoice.save(update_fields=['xero_sync_error', 'updated_at'])

        data = self.get_serializer(invoice).data
        data['xero_voided'] = xero_voided
        if xero_error:
            data['xero_void_error'] = xero_error
        return Response(data)

    @action(detail=True, methods=['post'])
    def add_line(self, request, pk=None):
        """Add a one-off charge or discount line to a draft invoice."""
        from decimal import Decimal, InvalidOperation
        from . import billing

        self._require_manager()
        invoice = self.get_object()
        try:
            amount = Decimal(str(request.data.get('amount')))
        except (InvalidOperation, TypeError, ValueError):
            return Response({'amount': 'Enter a valid amount.'}, status=400)
        try:
            billing.add_adjustment(invoice, request.data.get('description', ''), amount)
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=400)
        invoice.refresh_from_db()
        return Response(self.get_serializer(invoice).data)

    @action(detail=True, methods=['post'])
    def remove_line(self, request, pk=None):
        """Remove a staff-entered adjustment line from a draft invoice."""
        from . import billing

        self._require_manager()
        invoice = self.get_object()
        try:
            billing.remove_adjustment(invoice, request.data.get('line_id'))
        except ValueError as exc:
            return Response({'detail': str(exc)}, status=400)
        invoice.refresh_from_db()
        return Response(self.get_serializer(invoice).data)

    @action(detail=True, methods=['post'])
    def push_to_xero(self, request, pk=None):
        """Retry pushing an invoice to Xero after a failed/missing push (and
        the follow-up Xero email, if it hasn't gone out yet)."""
        from . import billing

        self._require_manager()
        invoice = self.get_object()
        if invoice.status in ('DRAFT', 'VOID'):
            return Response({'detail': 'Only sent invoices can be pushed to Xero.'}, status=400)
        ok = billing.push_invoice_to_xero(invoice)
        if ok:
            billing.email_invoice_from_xero(invoice)
        invoice.refresh_from_db()
        data = self.get_serializer(invoice).data
        data['pushed'] = ok
        return Response(data)

    @action(detail=False, methods=['post'])
    def sync_xero(self, request):
        """Pull payment status for open invoices back from Xero now."""
        from . import billing

        self._require_manager()
        counts = billing.sync_invoices_from_xero()
        return Response(counts)

    @action(detail=True, methods=['get'])
    def pay_url(self, request, pk=None):
        """The Xero online-invoice URL the owner pays through."""
        from . import xero
        from .models import XeroConnection

        invoice = self.get_object()  # queryset already scopes owners to their own
        if invoice.status in ('DRAFT', 'VOID', 'PAID'):
            return Response({'detail': 'Online payment is not available for this invoice.'}, status=404)
        if not invoice.xero_online_url and invoice.xero_invoice_id and XeroConnection.load().is_connected:
            try:
                invoice.xero_online_url = xero.get_online_invoice_url(invoice.xero_invoice_id)
                if invoice.xero_online_url:
                    invoice.save(update_fields=['xero_online_url', 'updated_at'])
            except xero.XeroError:
                pass
        if not invoice.xero_online_url:
            return Response({'detail': 'Online payment is not available for this invoice.'}, status=404)
        return Response({'url': invoice.xero_online_url})

    @action(detail=False, methods=['get'])
    def summary(self, request):
        """Aggregate stats for the staff payments dashboard, optionally
        filtered to one period via ?year=&month=."""
        from decimal import Decimal
        from django.db.models import Count, Q, Sum
        from django.utils import timezone
        from .models import Invoice

        self._require_manager()
        qs = Invoice.objects.exclude(status='VOID')
        params = request.query_params
        if params.get('year'):
            qs = qs.filter(period_year=params['year'])
        if params.get('month'):
            qs = qs.filter(period_month=params['month'])
        today = timezone.now().date()
        agg = qs.aggregate(
            draft=Count('id', filter=Q(status='DRAFT')),
            sent=Count('id', filter=Q(status='SENT')),
            part_paid=Count('id', filter=Q(status='PART_PAID')),
            paid=Count('id', filter=Q(status='PAID')),
            overdue_count=Count('id', filter=Q(status__in=('SENT', 'PART_PAID'), due_date__lt=today)),
            total_billed=Sum('total', filter=~Q(status='DRAFT')),
            total_collected=Sum('amount_paid', filter=~Q(status='DRAFT')),
        )
        billed = agg['total_billed'] or Decimal('0.00')
        collected = agg['total_collected'] or Decimal('0.00')
        return Response({
            'draft': agg['draft'], 'sent': agg['sent'],
            'part_paid': agg['part_paid'], 'paid': agg['paid'],
            'overdue_count': agg['overdue_count'],
            'total_billed': billed, 'total_collected': collected,
            'total_outstanding': billed - collected,
        })


@api_view(['GET'])
@perm_classes([IsAuthenticated])
def xero_status(request):
    """Xero connection status for the superuser settings screen."""
    from . import xero
    from .models import XeroConnection

    if not request.user.is_superuser:
        return Response({'detail': 'Only superusers can manage the Xero connection.'}, status=403)
    conn = XeroConnection.load()
    return Response({
        'configured': xero.is_configured(),
        'connected': conn.is_connected,
        'tenant_name': conn.tenant_name,
        'connected_at': conn.connected_at,
        'redirect_uri': getattr(settings, 'XERO_REDIRECT_URI', ''),
    })


@api_view(['POST'])
@perm_classes([IsAuthenticated])
def xero_connect(request):
    """Start the one-time Xero consent flow; returns the URL to open in a
    browser. The redirect back lands on xero_callback."""
    from . import xero

    if not request.user.is_superuser:
        return Response({'detail': 'Only superusers can manage the Xero connection.'}, status=403)
    if not xero.is_configured() or not getattr(settings, 'XERO_REDIRECT_URI', ''):
        return Response({'detail': 'Set XERO_CLIENT_ID, XERO_CLIENT_SECRET and XERO_REDIRECT_URI on the server first.'}, status=400)
    return Response({'authorize_url': xero.build_authorize_url()})


@api_view(['GET'])
@perm_classes([AllowAny])
def xero_callback(request):
    """Xero's browser redirect after consent. Arrives with no app session, so
    the single-use state token stored by xero_connect authenticates it. Plain
    HTML response — this renders in the superuser's browser, not the app."""
    from django.http import HttpResponse
    from . import xero

    error = request.query_params.get('error')
    if error:
        return HttpResponse('<h3>Xero connection cancelled.</h3><p>You can close this window.</p>', status=400)
    code = request.query_params.get('code', '')
    state = request.query_params.get('state', '')
    if not code:
        return HttpResponse('<h3>Missing authorisation code.</h3>', status=400)
    from django.utils.html import escape
    try:
        tenant_name = xero.handle_callback(code, state)
    except xero.XeroError as exc:
        return HttpResponse(f'<h3>Xero connection failed.</h3><p>{escape(str(exc))}</p>', status=400)
    return HttpResponse(f'<h3>Xero connected to {escape(tenant_name)}.</h3><p>You can close this window and return to the app.</p>')


@api_view(['POST'])
@perm_classes([IsAuthenticated])
def xero_disconnect(request):
    """Forget the stored Xero connection."""
    from . import xero

    if not request.user.is_superuser:
        return Response({'detail': 'Only superusers can manage the Xero connection.'}, status=403)
    xero.disconnect()
    return Response({'detail': 'Xero disconnected.'})


@api_view(['GET', 'PATCH'])
@perm_classes([IsAuthenticated])
def billing_settings(request):
    """Standard billing prices, editable in-app by payment managers.

    GET/PATCH {"day_care_price": "25.00", "boarding_price_per_night": "35.00"}.
    Backed by the website ServicePricing singleton, so the public site's
    pricing page stays in step with what invoicing charges.
    """
    from decimal import Decimal, InvalidOperation
    from website.models import ServicePricing

    if not _user_can_manage_payments(request.user):
        return Response({'detail': 'You do not have permission to manage payments.'}, status=403)

    pricing = ServicePricing.load()
    if request.method == 'PATCH':
        updated = False
        for field in ('day_care_price', 'boarding_price_per_night', 'owner_transport_discount'):
            if field not in request.data:
                continue
            try:
                value = Decimal(str(request.data[field]))
            except (InvalidOperation, TypeError, ValueError):
                return Response({field: 'Enter a valid amount.'}, status=400)
            if value < 0 or value > Decimal('9999.99'):
                return Response({field: 'Enter a valid amount.'}, status=400)
            setattr(pricing, field, value)
            updated = True
        if updated:
            pricing.save()
    return Response({
        'day_care_price': pricing.day_care_price,
        'boarding_price_per_night': pricing.boarding_price_per_night,
        'owner_transport_discount': pricing.owner_transport_discount,
    })


def _customer_rate_payload(profile):
    return {
        'user_id': profile.user_id,
        'username': profile.user.username,
        'first_name': profile.user.first_name,
        'email': profile.user.email,
        'daycare_rate': profile.daycare_rate,
        'boarding_rate': profile.boarding_rate,
        'billing_mode': profile.billing_mode,
        'xero_contact_id': profile.xero_contact_id,
        'dog_names': sorted(d.name for d in profile.user.dogs.all()),
    }


@api_view(['GET', 'POST'])
@perm_classes([IsAuthenticated])
def customer_rates(request):
    """Per-customer billing rates (discounts), payment managers only.

    GET: every customer (non-staff user with dogs, plus anyone already given a
    rate), with their rates — blank means the standard price applies.
    POST ?user_id=<id> {"daycare_rate": "22.00", "boarding_rate": null}:
    set/clear a customer's rates (null or '' clears back to standard).
    POST also accepts {"billing_mode": "APP"|"MANUAL"} — MANUAL customers are
    invoiced by hand in Xero and skipped by monthly generation.
    """
    from decimal import Decimal, InvalidOperation
    from django.db.models import Q

    if not _user_can_manage_payments(request.user):
        return Response({'detail': 'You do not have permission to manage payments.'}, status=403)

    if request.method == 'GET':
        return Response([_customer_rate_payload(p) for p in _billable_customer_profiles()])

    user_id = request.query_params.get('user_id')
    if not user_id:
        return Response({'detail': 'user_id query parameter required'}, status=400)
    try:
        profile = UserProfile.objects.select_related('user').prefetch_related('user__dogs').get(user_id=user_id)
    except (UserProfile.DoesNotExist, ValueError):
        return Response({'detail': 'User profile not found'}, status=404)

    for field in ('daycare_rate', 'boarding_rate'):
        if field not in request.data:
            continue
        value = request.data[field]
        if value in (None, ''):
            setattr(profile, field, None)
            continue
        try:
            value = Decimal(str(value))
        except (InvalidOperation, TypeError, ValueError):
            return Response({field: 'Enter a valid amount, or blank for the standard price.'}, status=400)
        if value < 0 or value > Decimal('9999.99'):
            return Response({field: 'Enter a valid amount, or blank for the standard price.'}, status=400)
        setattr(profile, field, value)
    if 'billing_mode' in request.data:
        mode = request.data['billing_mode']
        if mode not in dict(UserProfile.BILLING_MODE_CHOICES):
            return Response({'billing_mode': 'Choose APP or MANUAL.'}, status=400)
        profile.billing_mode = mode
    profile.save()
    return Response(_customer_rate_payload(profile))


def _billable_customer_profiles():
    """The same customer set the rates screen shows: non-staff users with dogs,
    plus anyone already given a per-customer rate."""
    from django.db.models import Q

    return (
        UserProfile.objects
        .filter(Q(user__dogs__isnull=False) | Q(daycare_rate__isnull=False) | Q(boarding_rate__isnull=False))
        .filter(user__is_staff=False)
        .select_related('user')
        .prefetch_related('user__dogs')
        .distinct()
        .order_by('user__first_name', 'user__username')
    )


def _contact_summary(contact):
    return {
        'contact_id': contact.get('ContactID', ''),
        'name': contact.get('Name', ''),
        'email': contact.get('EmailAddress', ''),
    }


@api_view(['GET'])
@perm_classes([IsAuthenticated])
def xero_contact_matches(request):
    """Match every billable customer against the org's existing Xero contacts.

    The go-live reconciliation step for the invoicing transition: customers
    were invoiced by hand in Xero for years, so their contacts already exist
    there — often under a different email or name spelling than their app
    account. Pushing an invoice against an unmatched customer would create a
    duplicate contact, so staff review this list and pin the right contact
    before flipping anyone to APP billing.

    One bulk contact fetch, matched locally per customer:
    ``pinned`` (ContactID stored), ``email``/``name`` (single confident
    match), ``ambiguous`` (several candidates), ``none``.
    """
    from . import xero

    if not _user_can_manage_payments(request.user):
        return Response({'detail': 'You do not have permission to manage payments.'}, status=403)
    from .models import XeroConnection
    if not XeroConnection.load().is_connected:
        return Response({'connected': False, 'customers': []})
    try:
        contacts = xero.fetch_all_contacts()
    except xero.XeroError as exc:
        return Response({'detail': f'Could not fetch Xero contacts: {exc}'}, status=502)

    by_id = {}
    by_email = {}
    by_name = {}
    for contact in contacts:
        by_id[contact.get('ContactID', '')] = contact
        email = (contact.get('EmailAddress') or '').strip().lower()
        if email:
            by_email.setdefault(email, []).append(contact)
        name = (contact.get('Name') or '').strip().lower()
        if name:
            by_name.setdefault(name, []).append(contact)

    customers = []
    for profile in _billable_customer_profiles():
        user = profile.user
        entry = _customer_rate_payload(profile)
        entry['match_status'] = 'none'
        entry['matched_contact'] = None
        entry['candidates'] = []

        if profile.xero_contact_id:
            entry['match_status'] = 'pinned'
            pinned = by_id.get(profile.xero_contact_id)
            entry['matched_contact'] = _contact_summary(pinned) if pinned else {
                'contact_id': profile.xero_contact_id, 'name': '', 'email': '',
            }
        else:
            display_name = f"{user.first_name} {user.last_name}".strip() or user.username
            email_hits = by_email.get((user.email or '').strip().lower(), []) if user.email else []
            name_hits = by_name.get(display_name.lower(), [])
            if len(email_hits) == 1:
                entry['match_status'] = 'email'
                entry['matched_contact'] = _contact_summary(email_hits[0])
            elif len(email_hits) > 1:
                entry['match_status'] = 'ambiguous'
                entry['candidates'] = [_contact_summary(c) for c in email_hits]
            elif len(name_hits) == 1:
                entry['match_status'] = 'name'
                entry['matched_contact'] = _contact_summary(name_hits[0])
            elif len(name_hits) > 1:
                entry['match_status'] = 'ambiguous'
                entry['candidates'] = [_contact_summary(c) for c in name_hits]
        customers.append(entry)
    return Response({'connected': True, 'customers': customers})


@api_view(['POST'])
@perm_classes([IsAuthenticated])
def xero_pin_contact(request):
    """Pin (or clear) a customer's Xero contact.

    {"user_id": 5, "contact_id": "..."} pins after verifying the contact
    exists in Xero; {"user_id": 5, "contact_id": ""} unpins (e.g. a stale pin
    whose contact was deleted in Xero), falling back to email/name matching
    on the next push.
    """
    from . import xero

    if not _user_can_manage_payments(request.user):
        return Response({'detail': 'You do not have permission to manage payments.'}, status=403)
    try:
        profile = UserProfile.objects.select_related('user').prefetch_related('user__dogs').get(
            user_id=request.data.get('user_id'))
    except (UserProfile.DoesNotExist, ValueError, TypeError):
        return Response({'detail': 'User profile not found'}, status=404)

    contact_id = (request.data.get('contact_id') or '').strip()
    contact = None
    if contact_id:
        try:
            contact = xero.get_contact(contact_id)
        except xero.XeroError as exc:
            return Response({'contact_id': f'Xero rejected this contact: {exc}'}, status=400)
    profile.xero_contact_id = contact_id
    profile.save(update_fields=['xero_contact_id'])

    payload = _customer_rate_payload(profile)
    payload['matched_contact'] = _contact_summary(contact) if contact else None
    return Response(payload)


@api_view(['GET'])
@perm_classes([IsAuthenticated])
def xero_contact_search(request):
    """Search Xero contacts by name/email fragment, for manual pinning when
    automatic matching finds nothing. GET ?q=<term>."""
    from . import xero

    if not _user_can_manage_payments(request.user):
        return Response({'detail': 'You do not have permission to manage payments.'}, status=403)
    term = (request.query_params.get('q') or '').strip()
    if len(term) < 2:
        return Response({'detail': 'Give at least two characters to search for.'}, status=400)
    try:
        contacts = xero.search_contacts(term)
    except xero.XeroError as exc:
        return Response({'detail': f'Xero contact search failed: {exc}'}, status=502)
    return Response({'contacts': [_contact_summary(c) for c in contacts[:25]]})


# ─── Roadworks ──────────────────────────────────────────────────────────────

@api_view(['GET'])
@perm_classes([IsAuthenticated])
def roadworks_for_date(request):
    """Roadworks disrupting the day's routes, with the staff they affect.

    One call serves all three surfaces that show this: the dashboard ring, the
    banner on a staff member's dog list, and the pickup map. Each item carries
    the staff and dog ids it was matched to, so the client filters locally
    rather than re-querying per staff member.

    Only staff see this — an owner has no route to be disrupted.

    Query param: ``date`` (YYYY-MM-DD, defaults to today).
    """
    from datetime import date as date_cls
    from django.utils import timezone
    from .roadworks import match_issues_to_routes

    if not request.user.is_staff:
        return Response({'detail': 'Staff only.'}, status=drf_status.HTTP_403_FORBIDDEN)

    raw_date = request.query_params.get('date')
    if raw_date:
        try:
            on_date = date_cls.fromisoformat(raw_date)
        except ValueError:
            return Response({'detail': 'date must be YYYY-MM-DD.'},
                            status=drf_status.HTTP_400_BAD_REQUEST)
    else:
        on_date = timezone.localdate()

    matches = match_issues_to_routes(on_date)

    # Worst first, so a client taking the top item shows the most severe.
    severity_rank = {'HIGH': 0, 'MEDIUM': 1, 'LOW': 2}
    items = sorted(
        matches.values(),
        key=lambda m: (severity_rank.get(m['issue'].severity, 3), m['issue'].street),
    )

    results = [{
        'id': m['issue'].id,
        'description': m['issue'].description,
        'street': m['issue'].street,
        'town': m['issue'].town,
        'latitude': m['issue'].latitude,
        'longitude': m['issue'].longitude,
        'start_date': m['issue'].start_date,
        'end_date': m['issue'].end_date,
        'severity': m['issue'].severity,
        'severity_label': m['issue'].get_severity_display(),
        'traffic_management': m['issue'].traffic_management,
        'affected_staff_ids': sorted(m['staff_ids']),
        'affected_dog_ids': sorted(m['dog_ids']),
    } for m in items]

    return Response({'date': on_date, 'results': results})


class SnsWebhookThrottle(AnonRateThrottle):
    """Generous throttle for the SNS webhook.

    The default 60/min anon rate is far too tight for a national roadworks
    feed, and throttling is actively harmful here: a 429 tells SNS the delivery
    failed, so it redelivers, which drives the rate higher still. This keeps a
    ceiling against outright flooding while leaving normal feed bursts alone.
    """
    scope = 'sns_webhook'


@api_view(['POST'])
@perm_classes([AllowAny])
@throttle_classes([SnsWebhookThrottle])
def street_manager_webhook(request):
    """Receive DfT Street Manager open-data events pushed over AWS SNS.

    Public by necessity — AWS posts here with no credential of ours. Trust comes
    entirely from the SNS signature check, so nothing in the body is read until
    `verify_message` has passed.

    Returns 200 for anything genuinely from our topic, including messages we
    choose to ignore: a non-2xx tells SNS to retry, and retrying an event we
    understood but didn't want is pointless.
    """
    from .sns import (
        SnsVerificationError, confirm_subscription, parse_message_body, verify_message,
    )
    from .roadwork_ingest import ingest_event, topic_arns

    allowed = topic_arns()
    if not allowed:
        # Refuse to run wide open: with no configured topic, any valid AWS SNS
        # message from any topic would be accepted.
        logger.warning('Street Manager webhook called but STREET_MANAGER_TOPIC_ARNS is unset')
        return Response({'detail': 'Not configured.'}, status=drf_status.HTTP_503_SERVICE_UNAVAILABLE)

    try:
        message = parse_message_body(request.body)
        verify_message(message, allowed_topic_arns=allowed)
    except SnsVerificationError as exc:
        logger.warning('Rejected SNS message: %s', exc)
        return Response({'detail': 'Invalid message.'}, status=drf_status.HTTP_403_FORBIDDEN)

    msg_type = message.get('Type')

    if msg_type == 'SubscriptionConfirmation':
        confirmed = confirm_subscription(message)
        logger.info('SNS subscription confirmation for %s: %s', message.get('TopicArn'), confirmed)
        return Response({'confirmed': confirmed})

    if msg_type != 'Notification':
        return Response({'ignored': msg_type})

    import json as _json
    try:
        event = _json.loads(message.get('Message') or '{}')
    except ValueError:
        logger.warning('SNS notification carried a non-JSON Message')
        return Response({'ignored': 'unparseable'})

    if not isinstance(event, dict):
        return Response({'ignored': 'unparseable'})

    try:
        outcome = ingest_event(event)
    except Exception:
        # A malformed record must not wedge the subscription in a retry loop.
        logger.exception('Failed to ingest Street Manager event')
        return Response({'ignored': 'error'})

    return Response({'result': outcome})


# --- Staff management (HR) ---

class IsStaffManager(BasePermission):
    """Staff members who hold can_manage_staff (or superusers).

    Gates the HR section: pay, employment details, appraisals, sickness and
    training records are visible only to managers — not to ordinary staff."""

    def has_permission(self, request, view):
        user = request.user
        if not (user and user.is_authenticated and user.is_staff):
            return False
        profile = getattr(user, 'profile', None)
        return bool(user.is_superuser or (profile and profile.can_manage_staff))


def _is_staff_manager(user):
    profile = getattr(user, 'profile', None)
    return bool(user.is_staff and (user.is_superuser or (profile and profile.can_manage_staff)))


def _holiday_summary(staff_user, hr_record, year=None):
    """Holiday allowance vs. approved day-off days for a calendar year."""
    from .models import DayOffRequest

    year = year or timezone.localdate().year
    used = DayOffRequest.objects.filter(
        staff_member=staff_user, status='APPROVED',
        date__year=year,
    ).count()
    allowance = hr_record.holiday_allowance_days if hr_record else None
    remaining = None
    if allowance is not None:
        remaining = float(allowance) - used
    return {
        'year': year,
        'allowance_days': float(allowance) if allowance is not None else None,
        'used_days': used,
        'remaining_days': remaining,
    }


class StaffHRRecordViewSet(viewsets.GenericViewSet,
                           mixins.ListModelMixin,
                           mixins.RetrieveModelMixin,
                           mixins.UpdateModelMixin):
    """Employment records, manager-only. Records are created lazily via
    `for_staff`, so there is no create route; no destroy either — an employee
    who leaves gets an employment_end_date, keeping the record."""

    permission_classes = [IsStaffManager]

    def get_queryset(self):
        from .models import StaffHRRecord
        return StaffHRRecord.objects.select_related('user')

    def get_serializer_class(self):
        from .serializers import StaffHRRecordSerializer
        return StaffHRRecordSerializer

    @action(detail=False, methods=['get'])
    def for_staff(self, request):
        """Get (creating if needed) the HR record for ?staff_member=<user id>,
        plus this year's holiday summary."""
        from .models import StaffHRRecord

        try:
            staff_id = int(request.query_params.get('staff_member'))
        except (TypeError, ValueError):
            return Response({'detail': 'staff_member query param is required'},
                            status=drf_status.HTTP_400_BAD_REQUEST)
        try:
            staff_user = User.objects.get(pk=staff_id, is_staff=True)
        except User.DoesNotExist:
            return Response({'detail': 'Staff member not found'}, status=drf_status.HTTP_404_NOT_FOUND)

        record, _ = StaffHRRecord.objects.get_or_create(user=staff_user)
        data = self.get_serializer(record).data
        data['holiday'] = _holiday_summary(staff_user, record)
        return Response(data)

    @action(detail=False, methods=['get'])
    def team_overview(self, request):
        """One row per staff member with everything the management screen's
        list needs: pay, holiday, sickness, meetings, appraisal and training
        status. The P4TD house account is skipped — it isn't an employee."""
        from .models import (
            StaffHRRecord, SicknessAbsence, StaffAppraisal, StaffMeeting,
            StaffTrainingRecord, DayOffRequest,
        )
        from .scheduling import HOUSE_STAFF_USERNAME
        from django.db.models import Count, Q

        today = timezone.localdate()
        year = today.year
        staff = list(
            User.objects.filter(is_staff=True)
            .exclude(username__iexact=HOUSE_STAFF_USERNAME)
            .exclude(first_name__iexact=HOUSE_STAFF_USERNAME)
            .select_related('profile')
            .order_by('first_name', 'username')
        )
        records = {r.user_id: r for r in StaffHRRecord.objects.filter(user__in=staff)}

        holiday_used = dict(
            DayOffRequest.objects.filter(
                staff_member__in=staff, status='APPROVED', date__year=year,
            ).values_list('staff_member').annotate(n=Count('id'))
        )
        pending_requests = dict(
            DayOffRequest.objects.filter(staff_member__in=staff, status='PENDING')
            .values_list('staff_member').annotate(n=Count('id'))
        )
        off_sick = set(
            SicknessAbsence.objects.filter(
                staff_member__in=staff, start_date__lte=today,
            ).filter(Q(end_date__isnull=True) | Q(end_date__gte=today))
            .values_list('staff_member_id', flat=True)
        )
        expiring = dict(
            StaffTrainingRecord.objects.filter(
                staff_member__in=staff,
                expiry_date__isnull=False,
                expiry_date__lte=today + timezone.timedelta(days=60),
            ).values_list('staff_member').annotate(n=Count('id'))
        )
        latest_appraisals = {}
        for a in StaffAppraisal.objects.filter(staff_member__in=staff).order_by('appraisal_date'):
            latest_appraisals[a.staff_member_id] = a
        next_meetings = {}
        for m in (StaffMeeting.objects.filter(status='SCHEDULED', scheduled_for__gte=timezone.now())
                  .order_by('-scheduled_for').prefetch_related('attendees')):
            for u in m.attendees.all():
                next_meetings[u.id] = m  # descending order, so the last write is the soonest

        rows = []
        for s in staff:
            record = records.get(s.id)
            pay = record.current_pay_rate() if record else None
            appraisal = latest_appraisals.get(s.id)
            meeting = next_meetings.get(s.id)
            allowance = float(record.holiday_allowance_days) if record else None
            used = holiday_used.get(s.id, 0)
            profile = getattr(s, 'profile', None)
            photo = None
            if profile and profile.profile_photo:
                photo = request.build_absolute_uri(profile.profile_photo.url)
            rows.append({
                'staff_member': s.id,
                'name': s.first_name or s.username,
                'username': s.username,
                'profile_photo': photo,
                'job_title': record.job_title if record else '',
                'employment_start_date': record.employment_start_date if record else None,
                'employment_end_date': record.employment_end_date if record else None,
                'pay_type': pay.pay_type if pay else None,
                'pay_rate': str(pay.rate) if pay else None,
                'holiday': {
                    'year': year,
                    'allowance_days': allowance,
                    'used_days': used,
                    'remaining_days': (allowance - used) if allowance is not None else None,
                },
                'pending_day_off_requests': pending_requests.get(s.id, 0),
                'off_sick_today': s.id in off_sick,
                'training_expiring': expiring.get(s.id, 0),
                'last_appraisal_date': appraisal.appraisal_date if appraisal else None,
                'next_review_date': appraisal.next_review_date if appraisal else None,
                'next_meeting': {
                    'id': meeting.id,
                    'title': meeting.title,
                    'scheduled_for': meeting.scheduled_for,
                } if meeting else None,
            })
        return Response(rows)


class StaffPayRateViewSet(viewsets.ModelViewSet):
    """Pay history, manager-only. ?staff_member=<id> filters one person."""

    permission_classes = [IsStaffManager]

    def get_queryset(self):
        from .models import StaffPayRate
        qs = StaffPayRate.objects.select_related('staff_member', 'created_by')
        staff_id = self.request.query_params.get('staff_member')
        if staff_id:
            qs = qs.filter(staff_member_id=staff_id)
        return qs

    def get_serializer_class(self):
        from .serializers import StaffPayRateSerializer
        return StaffPayRateSerializer

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)


class StaffMeetingViewSet(viewsets.ModelViewSet):
    """Meetings. Managers manage all; other staff see meetings they attend."""

    permission_classes = [IsAdminUser]

    def get_permissions(self):
        if self.request.method not in SAFE_METHODS:
            return [IsStaffManager()]
        return super().get_permissions()

    def get_queryset(self):
        from .models import StaffMeeting
        qs = StaffMeeting.objects.prefetch_related('attendees').select_related('created_by')
        if not _is_staff_manager(self.request.user):
            qs = qs.filter(attendees=self.request.user)
        staff_id = self.request.query_params.get('staff_member')
        if staff_id:
            qs = qs.filter(attendees__id=staff_id)
        return qs.distinct()

    def get_serializer_class(self):
        from .serializers import StaffMeetingSerializer
        return StaffMeetingSerializer

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)


class StaffAppraisalViewSet(viewsets.ModelViewSet):
    """Appraisals. Managers draft and share; the staff member sees their own
    once shared, and can comment and acknowledge — not edit or delete."""

    permission_classes = [IsAdminUser]

    def get_permissions(self):
        # acknowledge/comment are the staff member's own actions; everything
        # else that writes is manager-only.
        if self.action in ('acknowledge', 'comment'):
            return [IsAdminUser()]
        if self.request.method not in SAFE_METHODS:
            return [IsStaffManager()]
        return super().get_permissions()

    def get_queryset(self):
        from .models import StaffAppraisal
        qs = StaffAppraisal.objects.select_related('staff_member', 'appraiser')
        if not _is_staff_manager(self.request.user):
            qs = qs.filter(staff_member=self.request.user).exclude(status='DRAFT')
        staff_id = self.request.query_params.get('staff_member')
        if staff_id:
            qs = qs.filter(staff_member_id=staff_id)
        return qs

    def get_serializer_class(self):
        from .serializers import StaffAppraisalSerializer
        return StaffAppraisalSerializer

    def perform_create(self, serializer):
        serializer.save(appraiser=self.request.user)

    @action(detail=True, methods=['post'])
    def share(self, request, pk=None):
        """Share a draft appraisal with its staff member (manager-only —
        share is a POST, so the manager gate in get_permissions applies)."""
        from .notifications import send_push_notification

        appraisal = self.get_object()
        if appraisal.status != 'DRAFT':
            return Response({'detail': 'Only draft appraisals can be shared.'},
                            status=drf_status.HTTP_400_BAD_REQUEST)
        appraisal.status = 'SHARED'
        appraisal.shared_at = timezone.now()
        appraisal.save()
        send_push_notification(
            appraisal.staff_member,
            'Appraisal shared',
            'Your appraisal is ready to read in the app.',
            {'type': 'staff_appraisal', 'id': str(appraisal.id),
             'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        )
        return Response(self.get_serializer(appraisal).data)

    @action(detail=True, methods=['post'])
    def comment(self, request, pk=None):
        """The appraised staff member adds/updates their own comments."""
        appraisal = self.get_object()
        if appraisal.staff_member != request.user:
            return Response({'detail': 'Only the appraised staff member can comment here.'},
                            status=drf_status.HTTP_403_FORBIDDEN)
        appraisal.staff_comments = str(request.data.get('staff_comments', ''))[:5000]
        appraisal.save()
        return Response(self.get_serializer(appraisal).data)

    @action(detail=True, methods=['post'])
    def acknowledge(self, request, pk=None):
        """The appraised staff member confirms they have read the appraisal."""
        appraisal = self.get_object()
        if appraisal.staff_member != request.user:
            return Response({'detail': 'Only the appraised staff member can acknowledge.'},
                            status=drf_status.HTTP_403_FORBIDDEN)
        if appraisal.status != 'SHARED':
            return Response({'detail': 'Only shared appraisals can be acknowledged.'},
                            status=drf_status.HTTP_400_BAD_REQUEST)
        if 'staff_comments' in request.data:
            appraisal.staff_comments = str(request.data.get('staff_comments', ''))[:5000]
        appraisal.status = 'ACKNOWLEDGED'
        appraisal.acknowledged_at = timezone.now()
        appraisal.save()
        return Response(self.get_serializer(appraisal).data)


class SicknessAbsenceViewSet(viewsets.ModelViewSet):
    """Sickness records. Managers manage all; staff can read their own."""

    permission_classes = [IsAdminUser]

    def get_permissions(self):
        if self.request.method not in SAFE_METHODS:
            return [IsStaffManager()]
        return super().get_permissions()

    def get_queryset(self):
        from .models import SicknessAbsence
        qs = SicknessAbsence.objects.select_related('staff_member', 'recorded_by')
        if not _is_staff_manager(self.request.user):
            qs = qs.filter(staff_member=self.request.user)
        staff_id = self.request.query_params.get('staff_member')
        if staff_id:
            qs = qs.filter(staff_member_id=staff_id)
        return qs

    def get_serializer_class(self):
        from .serializers import SicknessAbsenceSerializer
        return SicknessAbsenceSerializer

    def perform_create(self, serializer):
        serializer.save(recorded_by=self.request.user)


class StaffTrainingRecordViewSet(viewsets.ModelViewSet):
    """Training/qualifications. Managers manage all; staff can read their own."""

    permission_classes = [IsAdminUser]

    def get_permissions(self):
        if self.request.method not in SAFE_METHODS:
            return [IsStaffManager()]
        return super().get_permissions()

    def get_queryset(self):
        from .models import StaffTrainingRecord
        qs = StaffTrainingRecord.objects.select_related('staff_member', 'created_by')
        if not _is_staff_manager(self.request.user):
            qs = qs.filter(staff_member=self.request.user)
        staff_id = self.request.query_params.get('staff_member')
        if staff_id:
            qs = qs.filter(staff_member_id=staff_id)
        return qs

    def get_serializer_class(self):
        from .serializers import StaffTrainingRecordSerializer
        return StaffTrainingRecordSerializer

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)


# --- Safety & compliance register ---

class IsComplianceManager(BasePermission):
    """Staff who hold can_manage_compliance (or superusers). Gates managing
    the register itself; recording a completed check is open to all staff."""

    def has_permission(self, request, view):
        user = request.user
        if not (user and user.is_authenticated and user.is_staff):
            return False
        profile = getattr(user, 'profile', None)
        return bool(user.is_superuser or (profile and profile.can_manage_compliance))


class ComplianceCheckTypeViewSet(viewsets.ModelViewSet):
    """The safety & compliance register: fire alarm tests, extinguisher
    servicing, first aid kits, licence/insurance renewals, and so on.

    All staff can read it (the person doing the Monday fire alarm test needs
    the list); adding/editing/removing checks needs can_manage_compliance."""

    permission_classes = [IsAdminUser]

    def get_permissions(self):
        if self.request.method not in SAFE_METHODS:
            return [IsComplianceManager()]
        return super().get_permissions()

    def get_queryset(self):
        from .models import ComplianceCheckType, ComplianceCheckLog

        qs = ComplianceCheckType.objects.prefetch_related(
            # Newest-first so the serializer's latest_logs[0] is the last done.
            Prefetch(
                'logs',
                queryset=ComplianceCheckLog.objects.order_by('-performed_on', '-id'),
                to_attr='latest_logs',
            )
        )
        if self.request.query_params.get('include_inactive') not in ('1', 'true'):
            # Inactive checks stay out of the list by default but individual
            # retrieves still work (the edit sheet reactivates them).
            if self.action == 'list':
                qs = qs.filter(is_active=True)
        return qs

    def get_serializer_class(self):
        from .serializers import ComplianceCheckTypeSerializer
        return ComplianceCheckTypeSerializer

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)


class ComplianceCheckLogViewSet(viewsets.ModelViewSet):
    """Completions of compliance checks. Any staff member can log one and
    read the history; editing or deleting a past log is manager-only (the
    register is an audit trail)."""

    permission_classes = [IsAdminUser]

    def get_permissions(self):
        if self.request.method not in SAFE_METHODS and self.action != 'create':
            return [IsComplianceManager()]
        return super().get_permissions()

    def get_queryset(self):
        from .models import ComplianceCheckLog
        qs = ComplianceCheckLog.objects.select_related('check_type', 'performed_by')
        check_id = self.request.query_params.get('check_type')
        if check_id:
            qs = qs.filter(check_type_id=check_id)
        return qs

    def get_serializer_class(self):
        from .serializers import ComplianceCheckLogSerializer
        return ComplianceCheckLogSerializer

    def perform_create(self, serializer):
        serializer.save(performed_by=self.request.user)
