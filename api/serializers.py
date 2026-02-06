from rest_framework import serializers
from .models import Dog, Photo, UserProfile, DateChangeRequest, GroupMedia, MediaReaction, Comment

class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)
    first_name = serializers.CharField(source='user.first_name', required=False, allow_blank=True)
    is_staff = serializers.BooleanField(source='user.is_staff', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['username', 'first_name', 'email', 'address', 'phone_number', 'pickup_instructions', 'is_staff']

    def update(self, instance, validated_data):
        user_data = validated_data.pop('user', {})
        first_name = user_data.get('first_name')
        
        if first_name is not None:
            instance.user.first_name = first_name
            instance.user.save()
            
        return super().update(instance, validated_data)

class OwnerDetailSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    first_name = serializers.CharField(source='user.first_name', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)
    user_id = serializers.IntegerField(source='user.id', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['user_id', 'username', 'first_name', 'email', 'address', 'phone_number', 'pickup_instructions']
        read_only_fields = ['user_id', 'username', 'first_name', 'email']

class UserSummarySerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    first_name = serializers.CharField(source='user.first_name', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)
    user_id = serializers.IntegerField(source='user.id', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['user_id', 'username', 'first_name', 'email']

class DogSerializer(serializers.ModelSerializer):
    owner_details = serializers.SerializerMethodField()

    class Meta:
        model = Dog
        fields = ['id', 'owner', 'owner_details', 'name', 'profile_image', 'food_instructions', 'medical_notes', 'daycare_days', 'created_at']
        read_only_fields = ['created_at']
        extra_kwargs = {
            'owner': {'required': False}
        }

    def get_owner_details(self, obj):
        try:
            return OwnerDetailSerializer(obj.owner.profile).data
        except:
            return None

    def validate_daycare_days(self, value):
        if isinstance(value, str):
            import json
            try:
                return json.loads(value)
            except ValueError:
                raise serializers.ValidationError("Invalid JSON for daycare_days")
        return value

class CommentSerializer(serializers.ModelSerializer):
    user_name = serializers.SerializerMethodField()

    class Meta:
        model = Comment
        fields = ['id', 'user', 'user_name', 'text', 'created_at']
        read_only_fields = ['user', 'created_at']

    def get_user_name(self, obj):
        if obj.user.first_name:
            return obj.user.first_name
        return obj.user.username

class PhotoSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    created_at = serializers.DateTimeField(read_only=True)
    comments = CommentSerializer(many=True, read_only=True)

    class Meta:
        model = Photo
        fields = ['id', 'dog', 'dog_name', 'media_type', 'file', 'thumbnail', 'taken_at', 'created_at', 'comments']
        read_only_fields = ['created_at']

class DateChangeRequestSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    owner_name = serializers.SerializerMethodField()
    approved_by_name = serializers.CharField(source='approved_by.username', read_only=True)
    approved_at = serializers.DateTimeField(read_only=True)

    class Meta:
        model = DateChangeRequest
        fields = ['id', 'dog', 'dog_name', 'owner_name', 'request_type', 'original_date', 'new_date', 'status', 'is_charged', 'approved_by_name', 'approved_at', 'created_at']
        read_only_fields = ['created_at', 'approved_by_name', 'approved_at', 'status']

    def get_owner_name(self, obj):
        user = obj.dog.owner
        if user.first_name:
            return user.first_name
        return user.username

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        request = self.context.get('request')
        # Only staff can modify status, regular users can't
        if request and not request.user.is_staff:
            self.fields['status'].read_only = True

class GroupMediaSerializer(serializers.ModelSerializer):
    uploaded_by_name = serializers.SerializerMethodField()
    reactions = serializers.SerializerMethodField()
    user_reaction = serializers.SerializerMethodField()
    comments = CommentSerializer(many=True, read_only=True)

    class Meta:
        model = GroupMedia
        fields = ['id', 'uploaded_by', 'uploaded_by_name', 'media_type', 'file', 'thumbnail', 'caption', 'reactions', 'user_reaction', 'comments', 'created_at']
        read_only_fields = ['uploaded_by', 'created_at']

    def get_uploaded_by_name(self, obj):
        if obj.uploaded_by.first_name:
            return obj.uploaded_by.first_name
        return obj.uploaded_by.username

    def get_reactions(self, obj):
        from django.db.models import Count
        reaction_counts = obj.reactions.values('emoji').annotate(count=Count('id'))
        return {r['emoji']: r['count'] for r in reaction_counts}

    def get_user_reaction(self, obj):
        request = self.context.get('request')
        if request and request.user.is_authenticated:
            reaction = obj.reactions.filter(user=request.user).first()
            if reaction:
                return reaction.emoji
        return None
