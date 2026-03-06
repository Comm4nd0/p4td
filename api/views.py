from rest_framework import viewsets, mixins, status as drf_status
from rest_framework.response import Response
from rest_framework.decorators import action, api_view, permission_classes as perm_classes
from rest_framework.permissions import IsAuthenticated, IsAdminUser, AllowAny
from django.contrib.auth.models import User
from django.core.mail import send_mail
from django.conf import settings
from .models import Dog, Photo, UserProfile, DateChangeRequest, DateChangeRequestHistory, GroupMedia, MediaReaction, Comment, BoardingRequest, BoardingRequestHistory, DeviceToken, DailyDogAssignment, PasswordResetOTP
from .serializers import DogSerializer, PhotoSerializer, UserProfileSerializer, DateChangeRequestSerializer, GroupMediaSerializer, OwnerDetailSerializer, CommentSerializer, BoardingRequestSerializer, DeviceTokenSerializer, DailyDogAssignmentSerializer, RequestPasswordResetSerializer, VerifyOTPSerializer, ResetPasswordSerializer, ChangePasswordSerializer

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
                    existing.save()
                # Determine device_type from request if available and not set
                device_type = request.data.get('device_type')
                if device_type and existing.device_type != device_type:
                    existing.device_type = device_type
                    existing.save()
                
                # Return the existing token with 200 OK
                serializer = self.get_serializer(existing)
                return Response(serializer.data)
        
        # Otherwise create new
        return super().create(request, *args, **kwargs)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)
from django.utils import timezone
from django.core.files.base import ContentFile
import io
from PIL import Image
import os
import tempfile
import subprocess

def process_image(image_file, max_size=(1280, 1280), quality=85):
    """Resizes and compresses an image while maintaining aspect ratio."""
    try:
        image_file.seek(0)
        img = Image.open(image_file)

        # Apply EXIF orientation so photos from phones are not rotated
        from PIL import ImageOps
        img = ImageOps.exif_transpose(img)

        # Convert to RGB if necessary (e.g., for PNGs with transparency)
        if img.mode in ("RGBA", "P"):
            img = img.convert("RGB")

        # Resize while maintaining aspect ratio if it's larger than max_size
        if img.width > max_size[0] or img.height > max_size[1]:
            img.thumbnail(max_size, Image.Resampling.LANCZOS)
        
        # Save to a BytesIO object with compression
        output = io.BytesIO()
        img.save(output, format='JPEG', quality=quality, optimize=True)
        output.seek(0)
        
        # Return a new ContentFile that can be saved to a Django FileField
        new_name = os.path.splitext(image_file.name)[0] + '.jpg'
        return ContentFile(output.read(), name=new_name)
    except Exception as e:
        print(f"Error processing image: {e}")
        image_file.seek(0)
        return image_file

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
        serializer.save()
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def get_owners(self, request):
        """Staff-only endpoint to get list of all owners: GET /profile/get_owners/"""
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can view owner list")

        profiles = UserProfile.objects.all()
        # You might want to filter this later, e.g. .select_related('user')
        from .serializers import UserSummarySerializer
        serializer = UserSummarySerializer(profiles, many=True, context={'request': request})
        return Response(serializer.data)

class DogViewSet(viewsets.ModelViewSet):
    serializer_class = DogSerializer
    permission_classes = [IsAuthenticated]

    def get_permissions(self):
        # Only staff can create or delete dogs
        if self.action in ('create', 'destroy'):
            return [IsAdminUser()]
        return super().get_permissions()

    def get_queryset(self):
        # Staff can see all dogs, Clients see dogs they own or co-own
        if self.request.user.is_staff:
            return Dog.objects.all()
        from django.db.models import Q
        return Dog.objects.filter(
            Q(owner=self.request.user) | Q(additional_owners=self.request.user)
        ).distinct()

    @action(detail=False, methods=['post'])
    def bulk_import(self, request):
        """Staff-only endpoint to bulk import dog names.
        Accepts: {"names": ["Buddy", "Max", "Luna"], "owner": 1}
        Owner is optional."""
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
            serializer.save()
        else:
            serializer.save(owner=self.request.user)

    def perform_update(self, serializer):
        self._handle_image_upload(serializer)
        # Attach the requesting user so the care-instructions signal can
        # include who made the change in the staff notification.
        serializer.instance._changed_by = self.request.user
        serializer.save()

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

class PhotoViewSet(viewsets.ModelViewSet):
    serializer_class = PhotoSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        if self.request.user.is_staff:
            return Photo.objects.all()
        from django.db.models import Q
        return Photo.objects.filter(
            Q(dog__owner=self.request.user) | Q(dog__additional_owners=self.request.user)
        ).distinct()

    def perform_create(self, serializer):
        # Validate that user owns the dog or is staff
        dog = serializer.validated_data['dog']
        if dog.owner != self.request.user and not self.request.user.is_staff and not dog.additional_owners.filter(id=self.request.user.id).exists():
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("You can only upload photos for your own dogs")
        
        # Generate thumbnail and resize for photos
        media_type = serializer.validated_data.get('media_type', 'PHOTO')
        if media_type == 'VIDEO':
            thumb = generate_video_thumbnail(serializer.validated_data.get('file'))
            if thumb:
                serializer.validated_data['thumbnail'] = thumb
        elif media_type == 'PHOTO':
            image_file = serializer.validated_data.get('file')
            if image_file:
                # Resize main photo to max 1280x1280
                processed_image = process_image(image_file, max_size=(1280, 1280))
                serializer.validated_data['file'] = processed_image

                # Generate a 400x400 thumbnail for the photo
                thumbnail = process_image(image_file, max_size=(400, 400), quality=70)
                serializer.validated_data['thumbnail'] = thumbnail

        serializer.save()

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

    def get_queryset(self):
        if self.request.user.is_staff:
            return DateChangeRequest.objects.all()
        from django.db.models import Q
        return DateChangeRequest.objects.filter(
            Q(dog__owner=self.request.user) | Q(dog__additional_owners=self.request.user)
        ).distinct()

    def perform_create(self, serializer):
        # Verify user owns the dog
        dog = serializer.validated_data['dog']
        if dog.owner != self.request.user and not self.request.user.is_staff and not dog.additional_owners.filter(id=self.request.user.id).exists():
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("You can only create requests for your own dogs")
        serializer.save()

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

        # Update approved metadata
        from django.utils import timezone
        if new_status == 'APPROVED':
            instance.approved_by = request.user
            instance.approved_at = timezone.now()
        instance.status = new_status
        instance.save()

        # Send push notification to all owners
        try:
            from .notifications import send_push_notification
            title = f"Request {new_status.title()}"
            if instance.request_type == 'ADD_DAY':
                body = f"Your additional day request for {instance.dog.name} on {instance.new_date} has been {new_status.lower()}."
            else:
                body = f"Your {instance.request_type.lower()} request for {instance.dog.name} on {instance.original_date} has been {new_status.lower()}."
            data = {'type': 'date_change_status', 'id': str(instance.id)}
            if instance.dog.owner:
                send_push_notification(instance.dog.owner, title, body, data)
            for additional_owner in instance.dog.additional_owners.all():
                send_push_notification(additional_owner, title, body, data)
        except Exception as e:
            print(f"Failed to send push notification: {e}")

        # Record history
        from .models import DateChangeRequestHistory
        DateChangeRequestHistory.objects.create(
            request=instance,
            changed_by=request.user,
            from_status=old_status,
            to_status=new_status,
        )

        serializer = self.get_serializer(instance)
        return Response(serializer.data)

class GroupMediaViewSet(viewsets.ModelViewSet):
    serializer_class = GroupMediaSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return GroupMedia.objects.all()

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
                    # Resize main photo to max 1280x1280
                    processed_image = process_image(image_file, max_size=(1280, 1280))
                    serializer.validated_data['file'] = processed_image

                    # Generate a 400x400 thumbnail for the photo
                    thumbnail = process_image(image_file, max_size=(400, 400), quality=70)
                    serializer.validated_data['thumbnail'] = thumbnail

            instance = serializer.save(uploaded_by=self.request.user)

            # Send push notification to other users
            try:
                from .notifications import notify_new_post
                notify_new_post(instance)
            except Exception as e:
                print(f"Failed to send notification: {e}")

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

        return Response(self.get_serializer(media).data)

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

class BoardingRequestViewSet(viewsets.ModelViewSet):
    serializer_class = BoardingRequestSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        if self.request.user.is_staff:
            return BoardingRequest.objects.all()
        return BoardingRequest.objects.filter(owner=self.request.user)

    def perform_create(self, serializer):
        # Ensure owner is set to current user (unless staff)
        if self.request.user.is_staff and 'owner' in self.request.data:
             serializer.save()
        else:
             serializer.save(owner=self.request.user)

    @action(detail=True, methods=['post'])
    def change_status(self, request, pk=None):
        if not request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("Only staff can change request status")

        instance = self.get_object()
        new_status = request.data.get('status')
        if new_status not in dict(BoardingRequest.STATUS_CHOICES).keys():
            return Response({'detail': 'Invalid status'}, status=400)

        old_status = instance.status
        if old_status == new_status:
             return Response({'detail': 'Status unchanged'}, status=200)

        from django.utils import timezone
        if new_status == 'APPROVED':
            instance.approved_by = request.user
            instance.approved_at = timezone.now()
        instance.status = new_status
        instance.save()

        # Send push notification to owner
        try:
            from .notifications import send_push_notification
            title = f"Boarding Request {new_status.title()}"
            body = f"Your boarding request for {', '.join([d.name for d in instance.dogs.all()])} has been {new_status.lower()}."
            send_push_notification(instance.owner, title, body, {'type': 'boarding_status', 'id': str(instance.id)})
        except Exception as e:
            print(f"Failed to send push notification: {e}")

        # Record history
        BoardingRequestHistory.objects.create(
            request=instance,
            changed_by=request.user,
            from_status=old_status,
            to_status=new_status,
        )

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

    def perform_create(self, serializer):
        serializer.save()

    def _parse_date(self, request):
        """Parse a date from query params, defaulting to today."""
        from datetime import date, timedelta
        date_str = request.query_params.get('date')
        if date_str:
            try:
                target = date.fromisoformat(date_str)
            except ValueError:
                return None, Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
            # Only allow up to 14 days in the future
            max_date = date.today() + timedelta(days=14)
            if target > max_date:
                return None, Response({'detail': 'Cannot view assignments more than 14 days in advance.'}, status=400)
            return target, None
        return date.today(), None

    def _create_recurring_assignments(self, dog_ids, staff_member, start_date, num_weeks=3):
        """Create assignments for the same weekday on future weeks.

        After a dog is assigned to a staff member on a given date, this
        creates the same assignment for the next ``num_weeks`` occurrences
        of that weekday so the roster automatically repeats.
        """
        from datetime import timedelta
        for week_offset in range(1, num_weeks + 1):
            future_date = start_date + timedelta(weeks=week_offset)
            for dog_id in dog_ids:
                DailyDogAssignment.objects.get_or_create(
                    dog_id=dog_id,
                    date=future_date,
                    defaults={'staff_member': staff_member},
                )

    @action(detail=False, methods=['get'])
    def today(self, request):
        """Get all assignments for a date. Accepts optional ?date=YYYY-MM-DD, defaults to today."""
        target_date, error = self._parse_date(request)
        if error:
            return error
        assignments = self.get_queryset().filter(date=target_date)
        serializer = self.get_serializer(assignments, many=True)
        return Response(serializer.data)

    @action(detail=False, methods=['get'])
    def my_assignments(self, request):
        """Get current staff member's assignments for a date. Accepts optional ?date=YYYY-MM-DD."""
        target_date, error = self._parse_date(request)
        if error:
            return error
        assignments = self.get_queryset().filter(
            staff_member=request.user, date=target_date
        )
        serializer = self.get_serializer(assignments, many=True)
        return Response(serializer.data)

    @action(detail=True, methods=['post'])
    def update_status(self, request, pk=None):
        """Update the status of an assignment."""
        assignment = self.get_object()
        new_status = request.data.get('status')
        valid_statuses = dict(DailyDogAssignment.STATUS_CHOICES).keys()
        if new_status not in valid_statuses:
            return Response({'detail': 'Invalid status'}, status=400)
        assignment.status = new_status
        assignment.save()
        return Response(self.get_serializer(assignment).data)

    @action(detail=False, methods=['get'])
    def unassigned_dogs(self, request):
        """Get dogs scheduled for a date that have no assignment yet.
        Accepts optional ?date=YYYY-MM-DD, defaults to today."""
        target_date, error = self._parse_date(request)
        if error:
            return error
        day_number = target_date.isoweekday()  # Monday=1, Sunday=7

        # Dogs with this weekday in their daycare_days
        daycare_dogs = Dog.objects.filter(daycare_days__contains=[day_number])

        # Dogs with approved boarding that spans the target date
        boarding_dogs = Dog.objects.filter(
            boarding_requests__status='APPROVED',
            boarding_requests__start_date__lte=target_date,
            boarding_requests__end_date__gte=target_date,
        )

        # Dogs with approved cancellations for the target date
        cancelled_dog_ids = DateChangeRequest.objects.filter(
            request_type='CANCEL',
            status='APPROVED',
            original_date=target_date,
        ).values_list('dog_id', flat=True)

        # Combine daycare + boarding, exclude cancelled
        scheduled_dogs = (daycare_dogs | boarding_dogs).exclude(
            id__in=cancelled_dog_ids
        ).distinct()

        # Exclude dogs already assigned for that date
        assigned_dog_ids = DailyDogAssignment.objects.filter(
            date=target_date
        ).values_list('dog_id', flat=True)

        unassigned = scheduled_dogs.exclude(id__in=assigned_dog_ids)
        serializer = DogSerializer(unassigned, many=True, context={'request': request})
        return Response(serializer.data)

    @action(detail=False, methods=['post'])
    def assign_to_me(self, request):
        """Assign one or more dogs to the current staff member.
        Accepts optional 'date' in body (YYYY-MM-DD), defaults to today.
        Automatically repeats assignments for the same weekday on future weeks."""
        from datetime import date, timedelta
        date_str = request.data.get('date')
        if date_str:
            try:
                target_date = date.fromisoformat(date_str)
            except ValueError:
                return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
            max_date = date.today() + timedelta(days=14)
            if target_date > max_date:
                return Response({'detail': 'Cannot assign more than 14 days in advance.'}, status=400)
        else:
            target_date = date.today()

        dog_ids = request.data.get('dog_ids', [])
        if not dog_ids:
            return Response({'detail': 'dog_ids is required'}, status=400)

        created = []
        created_dog_ids = []
        for dog_id in dog_ids:
            assignment, was_created = DailyDogAssignment.objects.get_or_create(
                dog_id=dog_id,
                date=target_date,
                defaults={'staff_member': request.user},
            )
            if was_created:
                created.append(assignment)
                created_dog_ids.append(dog_id)

        # Auto-repeat for future weeks on the same weekday
        if created_dog_ids:
            self._create_recurring_assignments(created_dog_ids, request.user, target_date)

        serializer = self.get_serializer(created, many=True)
        return Response(serializer.data, status=201)

    @action(detail=False, methods=['post'])
    def assign_dogs(self, request):
        """Assign one or more dogs to a specified staff member.
        Accepts optional 'date' in body (YYYY-MM-DD), defaults to today.
        Requires can_assign_dogs permission.
        Automatically repeats assignments for the same weekday on future weeks."""
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to assign dogs to other staff members.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        from datetime import date, timedelta
        date_str = request.data.get('date')
        if date_str:
            try:
                target_date = date.fromisoformat(date_str)
            except ValueError:
                return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
            max_date = date.today() + timedelta(days=14)
            if target_date > max_date:
                return Response({'detail': 'Cannot assign more than 14 days in advance.'}, status=400)
        else:
            target_date = date.today()

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

        created = []
        created_dog_ids = []
        for dog_id in dog_ids:
            assignment, was_created = DailyDogAssignment.objects.get_or_create(
                dog_id=dog_id,
                date=target_date,
                defaults={'staff_member': target_staff},
            )
            if was_created:
                created.append(assignment)
                created_dog_ids.append(dog_id)

        # Auto-repeat for future weeks on the same weekday
        if created_dog_ids:
            self._create_recurring_assignments(created_dog_ids, target_staff, target_date)

        serializer = self.get_serializer(created, many=True)
        return Response(serializer.data, status=201)

    @action(detail=True, methods=['post'])
    def reassign(self, request, pk=None):
        """Reassign a dog to a different staff member.
        Also updates future same-weekday assignments that are still in ASSIGNED status.
        Requires can_assign_dogs permission."""
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to reassign dogs.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        assignment = self.get_object()
        staff_member_id = request.data.get('staff_member_id')
        if not staff_member_id:
            return Response({'detail': 'staff_member_id is required'}, status=400)

        from django.contrib.auth.models import User
        try:
            new_staff = User.objects.get(id=staff_member_id, is_staff=True)
        except User.DoesNotExist:
            return Response({'detail': 'Staff member not found'}, status=404)

        old_staff = assignment.staff_member
        assignment.staff_member = new_staff
        assignment.save()

        # Also reassign future same-weekday assignments still in ASSIGNED status
        DailyDogAssignment.objects.filter(
            dog=assignment.dog,
            staff_member=old_staff,
            date__gt=assignment.date,
            date__iso_week_day=assignment.date.isoweekday(),
            status='ASSIGNED',
        ).update(staff_member=new_staff)

        return Response(self.get_serializer(assignment).data)

    @action(detail=True, methods=['post'])
    def unassign(self, request, pk=None):
        """Unassign a dog (delete the assignment).
        Also removes future same-weekday assignments that are still in ASSIGNED status.
        Requires can_assign_dogs permission."""
        try:
            if not request.user.profile.can_assign_dogs:
                return Response({'detail': 'You do not have permission to unassign dogs.'}, status=403)
        except Exception:
            return Response({'detail': 'Permission check failed.'}, status=403)

        assignment = self.get_object()
        dog = assignment.dog
        assignment_date = assignment.date
        weekday = assignment_date.isoweekday()

        assignment.delete()

        # Also delete future same-weekday assignments still in ASSIGNED status
        DailyDogAssignment.objects.filter(
            dog=dog,
            date__gt=assignment_date,
            date__iso_week_day=weekday,
            status='ASSIGNED',
        ).delete()

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

        # 1) Most recent same-weekday assignment per dog
        same_weekday_history = (
            DailyDogAssignment.objects
            .annotate(weekday=ExtractIsoWeekDay('date'))
            .filter(weekday=day_number)
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

        from datetime import date, timedelta
        from django.db.models import Count
        from django.db.models.functions import ExtractIsoWeekDay

        date_str = request.data.get('date')
        if date_str:
            try:
                target_date = date.fromisoformat(date_str)
            except ValueError:
                return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=400)
            max_date = date.today() + timedelta(days=14)
            if target_date > max_date:
                return Response({'detail': 'Cannot assign more than 14 days in advance.'}, status=400)
        else:
            target_date = date.today()

        day_number = target_date.isoweekday()

        # Get unassigned dogs for this date (same logic as unassigned_dogs)
        daycare_dogs = Dog.objects.filter(daycare_days__contains=[day_number])
        boarding_dogs = Dog.objects.filter(
            boarding_requests__status='APPROVED',
            boarding_requests__start_date__lte=target_date,
            boarding_requests__end_date__gte=target_date,
        )
        cancelled_dog_ids = DateChangeRequest.objects.filter(
            request_type='CANCEL',
            status='APPROVED',
            original_date=target_date,
        ).values_list('dog_id', flat=True)

        scheduled_dogs = (daycare_dogs | boarding_dogs).exclude(
            id__in=cancelled_dog_ids
        ).distinct()

        assigned_dog_ids = DailyDogAssignment.objects.filter(
            date=target_date
        ).values_list('dog_id', flat=True)

        unassigned = scheduled_dogs.exclude(id__in=assigned_dog_ids)

        # 1) Most recent same-weekday assignment per dog
        same_weekday_history = (
            DailyDogAssignment.objects
            .annotate(weekday=ExtractIsoWeekDay('date'))
            .filter(weekday=day_number)
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
            else:
                skipped.append(dog.id)

        serializer = self.get_serializer(created, many=True)
        return Response({
            'assigned': serializer.data,
            'skipped_dog_ids': skipped,
        }, status=201)

    @action(detail=False, methods=['get'])
    def staff_members(self, request):
        """Get list of staff members for assignment dropdown."""
        from django.contrib.auth.models import User
        staff = User.objects.filter(is_staff=True).values('id', 'username', 'first_name')
        return Response(list(staff))

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
        from .notifications import send_traffic_alert
        send_traffic_alert(alert_type, target_date, staff_member=request.user, detail=detail_text)
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
            serializer.save(owner=owner)
        else:
            serializer.save(owner=self.request.user)

    @action(detail=True, methods=['post'])
    def add_message(self, request, pk=None):
        """Add a message to a query thread."""
        from .models import SupportMessage
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
        query.save()  # Update updated_at timestamp
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
        send_push_notification(query.owner, "Query Resolved",
            f"Your query '{query.subject}' has been resolved by {staff_name}.",
            {'type': 'support_query_resolved', 'id': str(query.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'})

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
        """Get count of open queries for badge display."""
        from .models import SupportQuery
        if request.user.is_staff:
            count = SupportQuery.objects.filter(status='OPEN').count()
        else:
            count = SupportQuery.objects.filter(owner=request.user, status='OPEN').count()
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


class DogNoteViewSet(viewsets.ModelViewSet):
    permission_classes = [IsAdminUser]

    def get_queryset(self):
        from .models import DogNote
        queryset = DogNote.objects.select_related('dog', 'related_dog', 'created_by')
        dog_id = self.request.query_params.get('dog_id')
        if dog_id:
            from django.db.models import Q
            queryset = queryset.filter(Q(dog_id=dog_id) | Q(related_dog_id=dog_id))
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

    def get_queryset(self):
        from .models import StaffAvailability
        queryset = StaffAvailability.objects.select_related('staff_member')
        staff_id = self.request.query_params.get('staff_member')
        if staff_id:
            queryset = queryset.filter(staff_member_id=staff_id)
        return queryset

    def get_serializer_class(self):
        from .serializers import StaffAvailabilitySerializer
        return StaffAvailabilitySerializer

    def perform_create(self, serializer):
        serializer.save()

    @action(detail=False, methods=['post'])
    def set_my_availability(self, request):
        """Set the current staff member's availability for multiple days at once.
        Accepts: {"availability": [{"day_of_week": 1, "is_available": true, "note": ""}, ...]}"""
        from .models import StaffAvailability
        from .serializers import StaffAvailabilitySerializer

        availability_data = request.data.get('availability', [])
        if not availability_data:
            return Response({'detail': 'availability list is required'}, status=drf_status.HTTP_400_BAD_REQUEST)

        results = []
        for entry in availability_data:
            day = entry.get('day_of_week')
            if day is None or day < 1 or day > 7:
                continue
            is_available = entry.get('is_available', True)
            obj, _ = StaffAvailability.objects.update_or_create(
                staff_member=request.user,
                day_of_week=day,
                defaults={
                    'is_available': is_available,
                    'is_available_daycare': is_available,
                    'is_available_boarding': False,
                    'note': entry.get('note', ''),
                },
            )
            results.append(obj)

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
        """Get staff members available on a specific date.
        Considers day-of-week availability and approved day-off requests."""
        from .models import StaffAvailability, DayOffRequest
        from datetime import datetime

        try:
            target_date = datetime.strptime(date_str, '%Y-%m-%d').date()
        except (ValueError, TypeError):
            return Response({'detail': 'Invalid date format. Use YYYY-MM-DD.'}, status=drf_status.HTTP_400_BAD_REQUEST)

        dow = target_date.isoweekday()  # 1=Mon..7=Sun
        staff = User.objects.filter(is_staff=True)

        # Get day-of-week availability
        avail_map = {}
        for a in StaffAvailability.objects.filter(day_of_week=dow):
            avail_map[a.staff_member_id] = a.is_available_daycare

        # Get approved day-off requests for this date
        approved_off = set(
            DayOffRequest.objects.filter(date=target_date, status='APPROVED')
            .values_list('staff_member_id', flat=True)
        )

        available = []
        for s in staff:
            is_avail = avail_map.get(s.id, True)  # Default available if no record
            if is_avail and s.id not in approved_off:
                name = s.first_name or s.username
                available.append({'id': s.id, 'name': name, 'username': s.username})

        return Response(available)


class DayOffRequestViewSet(viewsets.ModelViewSet):
    """ViewSet for day-off requests.
    Staff can create/view their own requests.
    Managers (is_staff + has canAssignDogs equivalent) can view all and approve/deny."""
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        from .models import DayOffRequest
        return DayOffRequest.objects.select_related('staff_member', 'reviewed_by').all()

    def get_serializer_class(self):
        from .serializers import DayOffRequestSerializer
        return DayOffRequestSerializer

    def list(self, request):
        """List all day-off requests (staff with can_approve_timeoff permission)."""
        from .models import DayOffRequest
        if not request.user.is_staff:
            return Response({'detail': 'Not authorized'}, status=drf_status.HTTP_403_FORBIDDEN)

        profile = getattr(request.user, 'profile', None)
        if not profile or not profile.can_approve_timeoff:
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

        obj = DayOffRequest.objects.create(
            staff_member=request.user,
            date=target_date,
            reason=request.data.get('reason', ''),
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
        if not (request.user.is_staff and profile and profile.can_approve_timeoff):
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


# =============================================================================
# PASSWORD RESET & CHANGE VIEWS
# =============================================================================

@api_view(['POST'])
@perm_classes([AllowAny])
def request_password_reset(request):
    """Step 1: User provides email, receives a 6-digit OTP."""
    serializer = RequestPasswordResetSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    email = serializer.validated_data['email']

    # Always return success to prevent email enumeration
    try:
        user = User.objects.get(email__iexact=email)
        otp_obj = PasswordResetOTP.create_for_user(user)
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
    except User.DoesNotExist:
        pass  # Don't reveal whether the email exists

    return Response(
        {'detail': 'If an account with that email exists, a reset code has been sent.'},
        status=drf_status.HTTP_200_OK,
    )


@api_view(['POST'])
@perm_classes([AllowAny])
def verify_otp(request):
    """Step 2: User provides email + OTP, receives a temporary reset token."""
    serializer = VerifyOTPSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    email = serializer.validated_data['email']
    otp = serializer.validated_data['otp']

    try:
        user = User.objects.get(email__iexact=email)
        otp_obj = PasswordResetOTP.objects.filter(
            user=user, otp=otp, is_used=False,
        ).order_by('-created_at').first()

        if otp_obj and otp_obj.is_valid():
            reset_token = otp_obj.generate_reset_token()
            return Response({'reset_token': reset_token}, status=drf_status.HTTP_200_OK)
    except User.DoesNotExist:
        pass

    return Response(
        {'detail': 'Invalid or expired code.'},
        status=drf_status.HTTP_400_BAD_REQUEST,
    )


@api_view(['POST'])
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

    # Mark OTP as used
    otp_obj.is_used = True
    otp_obj.save()

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
    if not user.check_password(serializer.validated_data['current_password']):
        return Response(
            {'current_password': ['Current password is incorrect.']},
            status=drf_status.HTTP_400_BAD_REQUEST,
        )

    user.set_password(serializer.validated_data['new_password'])
    user.save()

    return Response(
        {'detail': 'Password changed successfully.'},
        status=drf_status.HTTP_200_OK,
    )
