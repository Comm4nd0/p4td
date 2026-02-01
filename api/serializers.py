from rest_framework import serializers
from .models import Dog, Photo, UserProfile, DateChangeRequest

class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)
    is_staff = serializers.BooleanField(source='user.is_staff', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['username', 'email', 'address', 'phone_number', 'pickup_instructions', 'is_staff']

class OwnerDetailSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)
    user_id = serializers.IntegerField(source='user.id', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['user_id', 'username', 'email', 'address', 'phone_number', 'pickup_instructions']
        read_only_fields = ['user_id', 'username', 'email']

class DogSerializer(serializers.ModelSerializer):
    owner_details = serializers.SerializerMethodField()

    class Meta:
        model = Dog
        fields = ['id', 'owner', 'owner_details', 'name', 'profile_image', 'food_instructions', 'medical_notes', 'daycare_days', 'created_at']
        read_only_fields = ['owner', 'created_at']

    def get_owner_details(self, obj):
        try:
            return OwnerDetailSerializer(obj.owner.profile).data
        except:
            return None

class PhotoSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    created_at = serializers.DateTimeField(read_only=True)

    class Meta:
        model = Photo
        fields = ['id', 'dog', 'dog_name', 'image', 'taken_at', 'created_at']
        read_only_fields = ['created_at']

class DateChangeRequestSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    owner_name = serializers.CharField(source='dog.owner.username', read_only=True)
    approved_by_name = serializers.CharField(source='approved_by.username', read_only=True)
    approved_at = serializers.DateTimeField(read_only=True)

    class Meta:
        model = DateChangeRequest
        fields = ['id', 'dog', 'dog_name', 'owner_name', 'request_type', 'original_date', 'new_date', 'status', 'is_charged', 'approved_by_name', 'approved_at', 'created_at']
        read_only_fields = ['created_at', 'approved_by_name', 'approved_at', 'status']

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Status is writeable only via the staff endpoint; never allow direct status changes through regular update/partial_update
        self.fields['status'].read_only = True
