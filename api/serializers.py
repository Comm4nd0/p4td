from rest_framework import serializers
from .models import Dog, Photo, UserProfile, DateChangeRequest, GroupMedia

class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)
    is_staff = serializers.BooleanField(source='user.is_staff', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['username', 'email', 'address', 'phone_number', 'pickup_instructions', 'is_staff']

class DogSerializer(serializers.ModelSerializer):
    class Meta:
        model = Dog
        fields = ['id', 'owner', 'name', 'profile_image', 'food_instructions', 'medical_notes', 'daycare_days', 'created_at']
        read_only_fields = ['owner', 'created_at']

class PhotoSerializer(serializers.ModelSerializer):
    class Meta:
        model = Photo
        fields = '__all__'

class DateChangeRequestSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    owner_name = serializers.CharField(source='dog.owner.username', read_only=True)

    class Meta:
        model = DateChangeRequest
        fields = ['id', 'dog', 'dog_name', 'owner_name', 'request_type', 'original_date', 'new_date', 'status', 'is_charged', 'created_at']
        read_only_fields = ['created_at']

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        request = self.context.get('request')
        # Only staff can modify status, regular users can't
        if request and not request.user.is_staff:
            self.fields['status'].read_only = True

class GroupMediaSerializer(serializers.ModelSerializer):
    uploaded_by_name = serializers.CharField(source='uploaded_by.username', read_only=True)

    class Meta:
        model = GroupMedia
        fields = ['id', 'uploaded_by', 'uploaded_by_name', 'media_type', 'file', 'thumbnail', 'caption', 'created_at']
        read_only_fields = ['uploaded_by', 'created_at']
