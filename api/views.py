from rest_framework import viewsets, mixins
from rest_framework.response import Response
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated, IsAdminUser
from .models import Dog, Photo, UserProfile, DateChangeRequest, DateChangeRequestHistory, GroupMedia
from .serializers import DogSerializer, PhotoSerializer, UserProfileSerializer, DateChangeRequestSerializer, GroupMediaSerializer, OwnerDetailSerializer
from django.utils import timezone
from django.core.files.base import ContentFile
import io
from PIL import Image
import os
import tempfile
import subprocess

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

class DogViewSet(viewsets.ModelViewSet):
    serializer_class = DogSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        # Staff can see all dogs, Clients only see their own
        if self.request.user.is_staff:
            return Dog.objects.all()
        return Dog.objects.filter(owner=self.request.user)

    def perform_create(self, serializer):
        # Automatically assign the owner
        serializer.save(owner=self.request.user)

class PhotoViewSet(viewsets.ModelViewSet):
    serializer_class = PhotoSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        if self.request.user.is_staff:
            return Photo.objects.all()
        return Photo.objects.filter(dog__owner=self.request.user)

    def perform_create(self, serializer):
        # Validate that user owns the dog or is staff
        dog = serializer.validated_data['dog']
        if dog.owner != self.request.user and not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("You can only upload photos for your own dogs")
        
        # Generate thumbnail for videos
        media_type = serializer.validated_data.get('media_type', 'PHOTO')
        if media_type == 'VIDEO':
            self._generate_video_thumbnail(serializer)
        
        serializer.save()

    def _generate_video_thumbnail(self, serializer):
        """Generate a thumbnail for video uploads"""
        try:
            file_obj = serializer.validated_data.get('file')
            if not file_obj:
                return
            
            # Save video temporarily to disk
            with tempfile.NamedTemporaryFile(suffix='.mp4', delete=False) as tmp_video:
                # Reset file pointer to beginning
                if hasattr(file_obj, 'seek'):
                    file_obj.seek(0)
                
                # Write file content
                if hasattr(file_obj, 'read'):
                    tmp_video.write(file_obj.read())
                else:
                    for chunk in file_obj.chunks():
                        tmp_video.write(chunk)
                
                tmp_video_path = tmp_video.name
            
            try:
                # Create thumbnail file path
                thumb_path = tempfile.mktemp(suffix='.jpg')
                
                # Generate thumbnail at 1 second mark using ffmpeg
                result = subprocess.run([
                    'ffmpeg', '-i', tmp_video_path, 
                    '-ss', '00:00:01', 
                    '-vframes', '1', 
                    '-s', '320x320', 
                    '-y',  # Overwrite output file
                    thumb_path
                ], capture_output=True, timeout=30, text=True)
                
                # Check if thumbnail was created successfully
                if os.path.exists(thumb_path) and os.path.getsize(thumb_path) > 0:
                    with open(thumb_path, 'rb') as f:
                        thumb_content = ContentFile(f.read(), name='thumbnail.jpg')
                        serializer.validated_data['thumbnail'] = thumb_content
                    os.unlink(thumb_path)
                else:
                    if result.returncode != 0 and result.stderr:
                        print(f"FFmpeg error: {result.stderr}")
            finally:
                # Clean up temporary video file
                if os.path.exists(tmp_video_path):
                    try:
                        os.unlink(tmp_video_path)
                    except:
                        pass
        except FileNotFoundError:
            print("FFmpeg not found - install it to enable video thumbnails: sudo apt-get install ffmpeg")
        except Exception as e:
            print(f"Error generating video thumbnail: {e}")
            import traceback
            traceback.print_exc()

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
        if dog.owner != request.user and not request.user.is_staff:
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
        return DateChangeRequest.objects.filter(dog__owner=self.request.user)

    def perform_create(self, serializer):
        # Verify user owns the dog
        dog = serializer.validated_data['dog']
        if dog.owner != self.request.user and not self.request.user.is_staff:
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
        else:
            instance.approved_by = None
            instance.approved_at = None

        instance.status = new_status
        instance.save()

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
        serializer.save(uploaded_by=self.request.user)
