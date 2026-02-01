from rest_framework import serializers
from .models import Dog, Booking, Photo, UserProfile

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

class BookingSerializer(serializers.ModelSerializer):
    class Meta:
        model = Booking
        fields = '__all__'

class PhotoSerializer(serializers.ModelSerializer):
    class Meta:
        model = Photo
        fields = '__all__'
