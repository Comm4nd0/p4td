from rest_framework import serializers
from .models import Dog, Photo, UserProfile, DateChangeRequest, GroupMedia, MediaReaction, Comment, BoardingRequest, BoardingRequestHistory, DeviceToken, DailyDogAssignment, SupportQuery, SupportMessage

class DeviceTokenSerializer(serializers.ModelSerializer):
    class Meta:
        model = DeviceToken
        fields = ['id', 'token', 'device_type', 'created_at', 'updated_at']
        read_only_fields = ['id', 'created_at', 'updated_at']

class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)
    first_name = serializers.CharField(source='user.first_name', required=False, allow_blank=True)
    is_staff = serializers.BooleanField(source='user.is_staff', read_only=True)

    class Meta:
        model = UserProfile
        fields = ['username', 'first_name', 'email', 'address', 'phone_number', 'pickup_instructions', 'is_staff', 'can_assign_dogs', 'can_add_feed_media', 'can_manage_requests', 'can_reply_queries']

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

class BoardingRequestHistorySerializer(serializers.ModelSerializer):
    changed_by_name = serializers.CharField(source='changed_by.username', read_only=True)

    class Meta:
        model = BoardingRequestHistory
        fields = ['id', 'changed_by', 'changed_by_name', 'from_status', 'to_status', 'changed_at']
        read_only_fields = ['id', 'changed_by', 'changed_by_name', 'from_status', 'to_status', 'changed_at']

class BoardingRequestSerializer(serializers.ModelSerializer):
    dog_names = serializers.SerializerMethodField()
    owner_name = serializers.SerializerMethodField()
    approved_by_name = serializers.CharField(source='approved_by.username', read_only=True)
    approved_at = serializers.DateTimeField(read_only=True)
    history = BoardingRequestHistorySerializer(many=True, read_only=True)
    dogs = serializers.PrimaryKeyRelatedField(many=True, queryset=Dog.objects.all())

    class Meta:
        model = BoardingRequest
        fields = ['id', 'owner', 'owner_name', 'dogs', 'dog_names', 'start_date', 'end_date', 'special_instructions', 'status', 'approved_by_name', 'approved_at', 'created_at', 'updated_at', 'history']
        read_only_fields = ['owner', 'status', 'approved_by_name', 'approved_at', 'created_at', 'updated_at', 'history']

    def get_dog_names(self, obj):
        return [dog.name for dog in obj.dogs.all()]

    def get_owner_name(self, obj):
        if obj.owner.first_name:
            return obj.owner.first_name
        return obj.owner.username

    def validate(self, data):
        if data['start_date'] > data['end_date']:
            raise serializers.ValidationError("Start date must be before end date")
        return data

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        request = self.context.get('request')
        if request and not request.user.is_staff:
             # Limit dog choices to owned dogs for non-staff
             self.fields['dogs'].queryset = Dog.objects.filter(owner=request.user)

class DailyDogAssignmentSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    dog_profile_image = serializers.ImageField(source='dog.profile_image', read_only=True)
    staff_member_name = serializers.SerializerMethodField()
    owner_name = serializers.SerializerMethodField()
    owner_address = serializers.SerializerMethodField()
    owner_phone = serializers.SerializerMethodField()
    pickup_instructions = serializers.SerializerMethodField()

    class Meta:
        model = DailyDogAssignment
        fields = [
            'id', 'dog', 'dog_name', 'dog_profile_image',
            'staff_member', 'staff_member_name',
            'owner_name', 'owner_address', 'owner_phone', 'pickup_instructions',
            'date', 'status', 'created_at', 'updated_at',
        ]
        read_only_fields = ['created_at', 'updated_at']

    def get_staff_member_name(self, obj):
        if obj.staff_member.first_name:
            return obj.staff_member.first_name
        return obj.staff_member.username

    def get_owner_name(self, obj):
        user = obj.dog.owner
        if user.first_name:
            return user.first_name
        return user.username

    def get_owner_address(self, obj):
        try:
            return obj.dog.owner.profile.address
        except Exception:
            return None

    def get_owner_phone(self, obj):
        try:
            return obj.dog.owner.profile.phone_number
        except Exception:
            return None

    def get_pickup_instructions(self, obj):
        try:
            return obj.dog.owner.profile.pickup_instructions
        except Exception:
            return None

class SupportMessageSerializer(serializers.ModelSerializer):
    sender_name = serializers.SerializerMethodField()
    is_staff = serializers.BooleanField(source='sender.is_staff', read_only=True)

    class Meta:
        model = SupportMessage
        fields = ['id', 'query', 'sender', 'sender_name', 'is_staff', 'text', 'created_at']
        read_only_fields = ['id', 'sender', 'created_at', 'query']

    def get_sender_name(self, obj):
        if obj.sender.first_name:
            return obj.sender.first_name
        return obj.sender.username

class SupportQuerySerializer(serializers.ModelSerializer):
    owner_name = serializers.SerializerMethodField()
    messages = SupportMessageSerializer(many=True, read_only=True)
    resolved_by_name = serializers.CharField(source='resolved_by.username', read_only=True, default=None)
    last_message_at = serializers.SerializerMethodField()
    message_count = serializers.SerializerMethodField()

    class Meta:
        model = SupportQuery
        fields = [
            'id', 'owner', 'owner_name', 'subject', 'status',
            'resolved_by_name', 'resolved_at',
            'messages', 'message_count', 'last_message_at',
            'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'owner', 'status', 'resolved_by_name', 'resolved_at', 'created_at', 'updated_at']

    def get_owner_name(self, obj):
        if obj.owner.first_name:
            return obj.owner.first_name
        return obj.owner.username

    def get_last_message_at(self, obj):
        last = obj.messages.order_by('-created_at').first()
        if last:
            return last.created_at.isoformat()
        return obj.created_at.isoformat()

    def get_message_count(self, obj):
        return obj.messages.count()

class SupportQueryListSerializer(serializers.ModelSerializer):
    owner_name = serializers.SerializerMethodField()
    last_message_at = serializers.SerializerMethodField()
    message_count = serializers.SerializerMethodField()

    class Meta:
        model = SupportQuery
        fields = [
            'id', 'owner', 'owner_name', 'subject', 'status',
            'message_count', 'last_message_at',
            'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'owner', 'status', 'created_at', 'updated_at']

    def get_owner_name(self, obj):
        if obj.owner.first_name:
            return obj.owner.first_name
        return obj.owner.username

    def get_last_message_at(self, obj):
        last = obj.messages.order_by('-created_at').first()
        if last:
            return last.created_at.isoformat()
        return obj.created_at.isoformat()

    def get_message_count(self, obj):
        return obj.messages.count()
