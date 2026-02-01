from rest_framework import serializers
from .models import Dog, Booking, Photo, Breed, UserProfile

class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['username', 'email', 'address', 'phone_number', 'pickup_instructions']

class BreedSerializer(serializers.ModelSerializer):
    class Meta:
        model = Breed
        fields = '__all__'

class DogSerializer(serializers.ModelSerializer):
    breed = serializers.SlugRelatedField(
        queryset=Breed.objects.all(),
        slug_field='name'
    )

    class Meta:
        model = Dog
        fields = ['id', 'owner', 'name', 'breed', 'profile_image', 'food_instructions', 'medical_notes', 'daycare_days', 'created_at']
        read_only_fields = ['owner', 'created_at']

class BookingSerializer(serializers.ModelSerializer):
    class Meta:
        model = Booking
        fields = '__all__'

class PhotoSerializer(serializers.ModelSerializer):
    class Meta:
        model = Photo
        fields = '__all__'
