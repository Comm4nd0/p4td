from rest_framework import viewsets, mixins
from rest_framework.response import Response
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated, IsAdminUser
from .models import Dog, Photo, UserProfile, DateChangeRequest, DateChangeRequestHistory, GroupMedia, MediaReaction, Comment
from .serializers import DogSerializer, PhotoSerializer, UserProfileSerializer, DateChangeRequestSerializer, GroupMediaSerializer, OwnerDetailSerializer, CommentSerializer
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
        img = Image.open(image_file)
        
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
        return image_file

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
        serializer = UserSummarySerializer(profiles, many=True)
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
        # Allow staff to assign owner, otherwise default to self
        self._handle_image_upload(serializer)
        if self.request.user.is_staff and 'owner' in self.request.data:
            # Owner is already validated by serializer if present
            serializer.save()
        else:
            serializer.save(owner=self.request.user)

    def perform_update(self, serializer):
        self._handle_image_upload(serializer)
        serializer.save()

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
        return Photo.objects.filter(dog__owner=self.request.user)

    def perform_create(self, serializer):
        # Validate that user owns the dog or is staff
        dog = serializer.validated_data['dog']
        if dog.owner != self.request.user and not self.request.user.is_staff:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("You can only upload photos for your own dogs")
        
        # Generate thumbnail and resize for photos
        media_type = serializer.validated_data.get('media_type', 'PHOTO')
        if media_type == 'VIDEO':
            self._generate_video_thumbnail(serializer)
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
        try:
            print(f"Creating GroupMedia for user: {self.request.user}")
            # Generate thumbnail and resize for photos
            media_type = serializer.validated_data.get('media_type', 'PHOTO')
            if media_type == 'VIDEO':
                self._generate_video_thumbnail(serializer)
            elif media_type == 'PHOTO':
                image_file = serializer.validated_data.get('file')
                if image_file:
                    # Resize main photo to max 1280x1280
                    processed_image = process_image(image_file, max_size=(1280, 1280))
                    serializer.validated_data['file'] = processed_image
                    
                    # Generate a 400x400 thumbnail for the photo
                    thumbnail = process_image(image_file, max_size=(400, 400), quality=70)
                    serializer.validated_data['thumbnail'] = thumbnail
            
            serializer.save(uploaded_by=self.request.user)
        except Exception as e:
            import traceback
            traceback.print_exc()
            raise e

    def _generate_video_thumbnail(self, serializer):
        """Generate a thumbnail for video uploads"""
        try:
            file_obj = serializer.validated_data.get('file')
            if not file_obj:
                return
            
            # Save video temporarily to disk
            import tempfile
            import subprocess
            import os
            from django.core.files.base import ContentFile

            # Create temp file with proper extension
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
                    print(f"Failed to generate thumbnail. Return code: {result.returncode}")
                    if result.stderr:
                        print(f"FFmpeg stderr: {result.stderr}")
            finally:
                # Clean up temporary video file
                if os.path.exists(tmp_video_path):
                    try:
                        os.unlink(tmp_video_path)
                    except:
                        pass
        except Exception as e:
            print(f"Error generating video thumbnail: {e}")
            # Don't fail the upload if thumbnail generation fails
            pass

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
        
        Comment.objects.create(user=request.user, group_media=media, text=text)
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
