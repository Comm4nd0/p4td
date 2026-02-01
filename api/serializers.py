from rest_framework import serializers
from .models import Dog, Photo, UserProfile, DateChangeRequest

class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['username', 'email', 'address', 'phone_number', 'pickup_instructions']

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
        read_only_fields = ['status', 'created_at']
