from rest_framework import serializers
from django.contrib.auth.password_validation import validate_password
from djoser.serializers import UserCreateSerializer as DjoserUserCreateSerializer
from .models import Dog, Photo, UserProfile, DateChangeRequest, GroupMedia, MediaReaction, Comment, BoardingRequest, BoardingRequestHistory, DeviceToken, DailyDogAssignment, DogWeekdayPickup, SupportQuery, SupportMessage, ClosureDay, DogNote, StaffAvailability, DayOffRequest, DogProfileChangeRequest, VaccinationRecord, WaitlistEntry, Vehicle, VehicleMaintenanceRecord, VehicleDefect, VehicleDefectImage, VehicleDefectComment, FacilityDefect, FacilityDefectImage, FacilityDefectComment


class RequestPasswordResetSerializer(serializers.Serializer):
    email = serializers.EmailField()


class VerifyOTPSerializer(serializers.Serializer):
    email = serializers.EmailField()
    otp = serializers.CharField(max_length=6, min_length=6)


class ResetPasswordSerializer(serializers.Serializer):
    reset_token = serializers.CharField()
    new_password = serializers.CharField(min_length=10)

    def validate_new_password(self, value):
        validate_password(value)
        return value


class ChangePasswordSerializer(serializers.Serializer):
    old_password = serializers.CharField()
    new_password = serializers.CharField(min_length=10)

    def validate_new_password(self, value):
        validate_password(value)
        return value

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
    is_superuser = serializers.BooleanField(source='user.is_superuser', read_only=True)
    user_id = serializers.IntegerField(source='user.id', read_only=True)
    # Whether the server has a postcode-lookup provider configured, so the app
    # can show/hide the "look up postcode" button on the vet field accordingly.
    postcode_lookup_enabled = serializers.SerializerMethodField()

    class Meta:
        model = UserProfile
        fields = ['user_id', 'username', 'first_name', 'email', 'address', 'phone_number', 'pickup_instructions', 'profile_photo', 'is_staff', 'is_superuser', 'can_assign_dogs', 'can_add_feed_media', 'can_manage_requests', 'can_reply_queries', 'can_approve_timeoff', 'can_view_inquiries', 'can_manage_vehicles', 'notify_feed', 'notify_traffic', 'notify_bookings', 'notify_dog_updates', 'postcode_lookup_enabled']
        # Capability flags are assignable ONLY by a superuser via
        # update_staff_permissions. They must never be writable through this
        # self-service endpoint, or any authenticated user could PATCH their own
        # profile to grant themselves manager capabilities (privilege escalation).
        read_only_fields = [
            'can_assign_dogs', 'can_add_feed_media', 'can_manage_requests',
            'can_reply_queries', 'can_approve_timeoff', 'can_view_inquiries',
            'can_manage_vehicles',
        ]

    def get_postcode_lookup_enabled(self, obj):
        from django.conf import settings
        return bool(getattr(settings, 'POSTCODE_LOOKUP_API_KEY', ''))

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


class StaffPermissionsSerializer(serializers.ModelSerializer):
    user_id = serializers.IntegerField(source='user.id', read_only=True)
    username = serializers.CharField(source='user.username', read_only=True)
    first_name = serializers.CharField(source='user.first_name', read_only=True)
    email = serializers.CharField(source='user.email', read_only=True)
    is_superuser = serializers.BooleanField(source='user.is_superuser', read_only=True)

    class Meta:
        model = UserProfile
        fields = [
            'user_id', 'username', 'first_name', 'email', 'is_superuser',
            'can_assign_dogs', 'can_add_feed_media', 'can_manage_requests',
            'can_reply_queries', 'can_approve_timeoff', 'can_view_inquiries',
            'can_manage_vehicles',
        ]

class DogSerializer(serializers.ModelSerializer):
    owner_details = serializers.SerializerMethodField()
    additional_owners_details = serializers.SerializerMethodField()
    vaccination_summary = serializers.SerializerMethodField()
    cancelled_dates = serializers.SerializerMethodField()

    class Meta:
        model = Dog
        fields = ['id', 'owner', 'owner_details', 'additional_owners', 'additional_owners_details', 'name', 'profile_image', 'food_instructions', 'medical_notes', 'registered_vet', 'address', 'postcode', 'access_instructions', 'van_placement', 'general_notes', 'daycare_days', 'schedule_type', 'owner_brings_default', 'owner_collects_default', 'owner_brings_default_time', 'owner_collects_default_time', 'sex', 'date_of_birth', 'is_spayed', 'vaccination_summary', 'cancelled_dates', 'latitude', 'longitude', 'geocode_source', 'created_at']
        read_only_fields = ['created_at', 'latitude', 'longitude', 'geocode_source', 'cancelled_dates']
        extra_kwargs = {
            'owner': {'required': False},
            'additional_owners': {'required': False},
        }

    def get_owner_details(self, obj):
        if obj.owner is None:
            return None
        try:
            return OwnerDetailSerializer(obj.owner.profile).data
        except UserProfile.DoesNotExist:
            # Owner has no profile row — don't swallow other errors (B5).
            return None

    def get_additional_owners_details(self, obj):
        details = []
        for user in obj.additional_owners.all():
            try:
                details.append(OwnerDetailSerializer(user.profile).data)
            except UserProfile.DoesNotExist:
                pass
        return details

    def get_vaccination_summary(self, obj):
        records = list(obj.vaccinations.all())
        if not records:
            return None
        statuses = [r.status for r in records]
        return {
            'count': len(records),
            'expired': statuses.count('expired'),
            'expiring_soon': statuses.count('expiring_soon'),
            'next_expiry': min(r.expiry_date for r in records).isoformat(),
        }

    def get_cancelled_dates(self, obj):
        """Upcoming dates the dog has been removed from for the day.

        A staff "remove from day" creates a REMOVED DailyDogAssignment without a
        matching cancellation request, so the recurring-schedule view on the dog
        profile would otherwise still show the dog as booked. Surfacing these
        dates lets the app drop them from the upcoming bookings, keeping the
        profile in step with the staff dashboard (which excludes REMOVED rows).

        Reads ``obj.future_removed_assignments`` when the viewset has prefetched
        it (avoids an N+1 in dog listings); otherwise falls back to a query.
        """
        prefetched = getattr(obj, 'future_removed_assignments', None)
        if prefetched is not None:
            rows = prefetched
        else:
            from datetime import date as date_cls
            rows = obj.daily_assignments.filter(
                status='REMOVED', date__gte=date_cls.today()
            )
        return sorted({a.date.isoformat() for a in rows})

    def validate_daycare_days(self, value):
        # Normalise to a sorted list of unique ints in 1-7 so downstream roster
        # logic (ExtractIsoWeekDay membership tests) can rely on the contents
        # instead of silently misbehaving on '1'/0/8/duplicates (B18).
        if isinstance(value, str):
            import json
            try:
                value = json.loads(value)
            except ValueError:
                raise serializers.ValidationError("Invalid JSON for daycare_days")
        if value in (None, ''):
            return []
        if not isinstance(value, (list, tuple)):
            raise serializers.ValidationError("daycare_days must be a list of day numbers (1-7).")
        normalised = []
        for item in value:
            try:
                day = int(item)
            except (TypeError, ValueError):
                raise serializers.ValidationError("daycare_days must contain whole day numbers 1-7.")
            if day < 1 or day > 7:
                raise serializers.ValidationError("daycare_days values must be between 1 (Mon) and 7 (Sun).")
            if day not in normalised:
                normalised.append(day)
        return sorted(normalised)

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
        if user is None:
            return None
        if user.first_name:
            return user.first_name
        return user.username

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        request = self.context.get('request')
        # Only staff can modify status, regular users can't. is_charged drives
        # the late-change fee and is computed server-side for owner requests, so
        # a non-staff client must not be able to set it (B2).
        if request and not request.user.is_staff:
            self.fields['status'].read_only = True
            self.fields['is_charged'].read_only = True

    def validate(self, data):
        # Enforce request_type/date coherence so an incoherent combo can't skip
        # the capacity guard or unassign a dog with nowhere to go (B25).
        request_type = data.get('request_type', getattr(self.instance, 'request_type', None))
        original_date = data.get('original_date', getattr(self.instance, 'original_date', None))
        new_date = data.get('new_date', getattr(self.instance, 'new_date', None))
        if request_type == 'ADD_DAY' and not new_date:
            raise serializers.ValidationError({'new_date': 'An additional-day request needs a new date.'})
        if request_type == 'CANCEL' and not original_date:
            raise serializers.ValidationError({'original_date': 'A cancellation needs an original date.'})
        if request_type == 'CHANGE':
            if not original_date or not new_date:
                raise serializers.ValidationError('A date change needs both an original and a new date.')
            if original_date == new_date:
                raise serializers.ValidationError({'new_date': 'The new date must differ from the original date.'})
        return data

class GroupMediaSerializer(serializers.ModelSerializer):
    uploaded_by_name = serializers.SerializerMethodField()
    uploaded_by_profile_photo = serializers.SerializerMethodField()
    reactions = serializers.SerializerMethodField()
    user_reaction = serializers.SerializerMethodField()
    comments = CommentSerializer(many=True, read_only=True)
    tagged_dogs = serializers.SerializerMethodField()
    tagged_dog_ids = serializers.PrimaryKeyRelatedField(
        queryset=Dog.objects.all(), many=True, required=False, source='tagged_dogs', write_only=True,
    )

    class Meta:
        model = GroupMedia
        fields = ['id', 'uploaded_by', 'uploaded_by_name', 'uploaded_by_profile_photo', 'media_type', 'file', 'thumbnail', 'caption', 'tagged_dogs', 'tagged_dog_ids', 'reactions', 'user_reaction', 'comments', 'created_at']
        read_only_fields = ['uploaded_by', 'created_at']

    def get_uploaded_by_name(self, obj):
        if obj.uploaded_by.first_name:
            return obj.uploaded_by.first_name
        return obj.uploaded_by.username

    def get_uploaded_by_profile_photo(self, obj):
        try:
            if obj.uploaded_by.profile.profile_photo:
                request = self.context.get('request')
                if request:
                    return request.build_absolute_uri(obj.uploaded_by.profile.profile_photo.url)
                return obj.uploaded_by.profile.profile_photo.url
        except Exception:
            pass
        return None

    def get_reactions(self, obj):
        # Count from the prefetched reactions in Python so a page of items costs
        # one query for all reactions instead of one COUNT query per item.
        counts = {}
        for reaction in obj.reactions.all():
            counts[reaction.emoji] = counts.get(reaction.emoji, 0) + 1
        return counts

    def get_user_reaction(self, obj):
        request = self.context.get('request')
        if not (request and request.user.is_authenticated):
            return None
        # The viewset prefetches the current user's reactions into `my_reactions`
        # (see GroupMediaViewSet.get_queryset) to avoid a per-item query.
        my_reactions = getattr(obj, 'my_reactions', None)
        if my_reactions is not None:
            return my_reactions[0].emoji if my_reactions else None
        # Fallback for callers that didn't prefetch (e.g. single-object actions).
        reaction = obj.reactions.filter(user=request.user).first()
        return reaction.emoji if reaction else None

    def get_tagged_dogs(self, obj):
        request = self.context.get('request')
        result = []
        for dog in obj.tagged_dogs.all():
            entry = {'id': dog.id, 'name': dog.name, 'profile_image': None}
            if dog.profile_image and request:
                entry['profile_image'] = request.build_absolute_uri(dog.profile_image.url)
            result.append(entry)
        return result

    def to_representation(self, instance):
        data = super().to_representation(instance)
        request = self.context.get('request')
        if request:
            if instance.file:
                data['file'] = request.build_absolute_uri(instance.file.url)
            if instance.thumbnail:
                data['thumbnail'] = request.build_absolute_uri(instance.thumbnail.url)
        return data

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
    assigned_staff_name = serializers.SerializerMethodField()
    history = BoardingRequestHistorySerializer(many=True, read_only=True)
    dogs = serializers.PrimaryKeyRelatedField(many=True, queryset=Dog.objects.all())

    class Meta:
        model = BoardingRequest
        fields = ['id', 'owner', 'owner_name', 'dogs', 'dog_names', 'start_date', 'end_date', 'special_instructions', 'status', 'approved_by_name', 'approved_at', 'assigned_staff', 'assigned_staff_name', 'created_at', 'updated_at', 'history']
        read_only_fields = ['owner', 'status', 'approved_by_name', 'approved_at', 'assigned_staff', 'assigned_staff_name', 'created_at', 'updated_at', 'history']

    def get_dog_names(self, obj):
        return [dog.name for dog in obj.dogs.all()]

    def get_assigned_staff_name(self, obj):
        s = obj.assigned_staff
        if not s:
            return None
        return s.first_name or s.username

    def get_owner_name(self, obj):
        if obj.owner.first_name:
            return obj.owner.first_name
        return obj.owner.username

    def validate(self, data):
        # Fall back to the instance on partial updates so a PATCH that omits the
        # dates doesn't KeyError into a 500 (B28).
        start = data.get('start_date', getattr(self.instance, 'start_date', None))
        end = data.get('end_date', getattr(self.instance, 'end_date', None))
        if start and end and start > end:
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
    # Cached pickup coordinates (from the dog) for the staff map. Null when the
    # dog has no address or couldn't be geocoded — the app pins it at base.
    latitude = serializers.FloatField(source='dog.latitude', read_only=True, allow_null=True)
    longitude = serializers.FloatField(source='dog.longitude', read_only=True, allow_null=True)
    staff_member_name = serializers.SerializerMethodField()
    owner_name = serializers.SerializerMethodField()
    owner_address = serializers.SerializerMethodField()
    owner_phone = serializers.SerializerMethodField()
    pickup_instructions = serializers.SerializerMethodField()
    is_boarding = serializers.SerializerMethodField()
    effective_owner_brings = serializers.BooleanField(read_only=True)
    effective_owner_collects = serializers.BooleanField(read_only=True)
    effective_owner_brings_time = serializers.TimeField(read_only=True)
    effective_owner_collects_time = serializers.TimeField(read_only=True)

    class Meta:
        model = DailyDogAssignment
        fields = [
            'id', 'dog', 'dog_name', 'dog_profile_image', 'latitude', 'longitude',
            'staff_member', 'staff_member_name',
            'owner_name', 'owner_address', 'owner_phone', 'pickup_instructions',
            'date', 'status', 'is_boarding',
            'owner_brings', 'owner_collects', 'owner_brings_time', 'owner_collects_time',
            'effective_owner_brings', 'effective_owner_collects',
            'effective_owner_brings_time', 'effective_owner_collects_time',
            'sort_order', 'created_at', 'updated_at',
        ]
        read_only_fields = ['created_at', 'updated_at']

    def get_staff_member_name(self, obj):
        if obj.staff_member.first_name:
            return obj.staff_member.first_name
        return obj.staff_member.username

    def get_owner_name(self, obj):
        user = obj.dog.owner
        if user is None:
            return None
        if user.first_name:
            return user.first_name
        return user.username

    def get_owner_address(self, obj):
        # Pickup address lives on the dog, not the owner profile.
        return obj.dog.address or None

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

    def get_is_boarding(self, obj):
        # When the view supplies the per-date boarding set (computed once for the
        # whole roster), use it instead of an exists() query per row (B7).
        boarding = self.context.get('boarding_dog_ids')
        if boarding is not None:
            return obj.dog_id in boarding
        return BoardingRequest.objects.filter(
            dogs=obj.dog,
            status='APPROVED',
            start_date__lte=obj.date,
            end_date__gte=obj.date,
        ).exists()


class DogWeekdayPickupSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    staff_member_name = serializers.SerializerMethodField()

    class Meta:
        model = DogWeekdayPickup
        fields = [
            'id', 'dog', 'dog_name', 'weekday',
            'staff_member', 'staff_member_name',
            'created_at', 'updated_at',
        ]
        read_only_fields = ['created_at', 'updated_at']

    def get_staff_member_name(self, obj):
        if obj.staff_member.first_name:
            return obj.staff_member.first_name
        return obj.staff_member.username


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
            'has_unread_reply', 'staff_has_unread', 'resolved_by_name', 'resolved_at',
            'messages', 'message_count', 'last_message_at',
            'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'owner', 'status', 'has_unread_reply', 'staff_has_unread', 'resolved_by_name', 'resolved_at', 'created_at', 'updated_at']

    def get_owner_name(self, obj):
        if obj.owner.first_name:
            return obj.owner.first_name
        return obj.owner.username

    def get_last_message_at(self, obj):
        # Read from the prefetched messages cache instead of a fresh query/row (B29).
        msgs = list(obj.messages.all())
        if msgs:
            return max(m.created_at for m in msgs).isoformat()
        return obj.created_at.isoformat()

    def get_message_count(self, obj):
        return len(obj.messages.all())

class SupportQueryListSerializer(serializers.ModelSerializer):
    owner_name = serializers.SerializerMethodField()
    last_message_at = serializers.SerializerMethodField()
    message_count = serializers.SerializerMethodField()

    class Meta:
        model = SupportQuery
        fields = [
            'id', 'owner', 'owner_name', 'subject', 'status',
            'has_unread_reply', 'staff_has_unread', 'message_count', 'last_message_at',
            'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'owner', 'status', 'has_unread_reply', 'staff_has_unread', 'created_at', 'updated_at']

    def get_owner_name(self, obj):
        if obj.owner.first_name:
            return obj.owner.first_name
        return obj.owner.username

    def get_last_message_at(self, obj):
        # Read from the prefetched messages cache instead of a fresh query/row (B29).
        msgs = list(obj.messages.all())
        if msgs:
            return max(m.created_at for m in msgs).isoformat()
        return obj.created_at.isoformat()

    def get_message_count(self, obj):
        return len(obj.messages.all())


class ClosureDaySerializer(serializers.ModelSerializer):
    created_by_name = serializers.SerializerMethodField()

    class Meta:
        model = ClosureDay
        fields = ['id', 'date', 'closure_type', 'reason', 'capacity_override', 'created_by', 'created_by_name', 'created_at']
        read_only_fields = ['id', 'created_by', 'created_by_name', 'created_at']

    def get_created_by_name(self, obj):
        if obj.created_by:
            return obj.created_by.first_name or obj.created_by.username
        return None


class VaccinationRecordSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    status = serializers.CharField(read_only=True)
    created_by_name = serializers.SerializerMethodField()

    class Meta:
        model = VaccinationRecord
        fields = ['id', 'dog', 'dog_name', 'name', 'date_administered', 'expiry_date', 'notes', 'status', 'created_by_name', 'created_at']
        read_only_fields = ['id', 'created_by_name', 'created_at']

    def get_created_by_name(self, obj):
        if obj.created_by:
            return obj.created_by.first_name or obj.created_by.username
        return None

    def validate(self, attrs):
        administered = attrs.get('date_administered', getattr(self.instance, 'date_administered', None))
        expiry = attrs.get('expiry_date', getattr(self.instance, 'expiry_date', None))
        if administered and expiry and expiry <= administered:
            raise serializers.ValidationError({'expiry_date': 'Expiry date must be after the date administered.'})
        return attrs


class WaitlistEntrySerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)

    class Meta:
        model = WaitlistEntry
        fields = ['id', 'dog', 'dog_name', 'date', 'status', 'created_at', 'notified_at']
        read_only_fields = ['id', 'status', 'created_at', 'notified_at']


class DogNoteSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    related_dog_name = serializers.CharField(source='related_dog.name', read_only=True, default=None)
    created_by_name = serializers.SerializerMethodField()

    class Meta:
        model = DogNote
        fields = ['id', 'dog', 'dog_name', 'related_dog', 'related_dog_name', 'note_type', 'text', 'is_positive', 'created_by', 'created_by_name', 'created_at', 'updated_at']
        read_only_fields = ['id', 'created_by', 'created_by_name', 'created_at', 'updated_at']

    def get_created_by_name(self, obj):
        if obj.created_by:
            return obj.created_by.first_name or obj.created_by.username
        return None


class StaffAvailabilitySerializer(serializers.ModelSerializer):
    staff_member_name = serializers.SerializerMethodField()
    day_name = serializers.SerializerMethodField()

    class Meta:
        model = StaffAvailability
        fields = ['id', 'staff_member', 'staff_member_name', 'day_of_week', 'day_name', 'is_available', 'is_available_daycare', 'is_available_boarding', 'note']
        read_only_fields = ['id', 'staff_member_name', 'day_name']

    def get_staff_member_name(self, obj):
        if obj.staff_member.first_name:
            return obj.staff_member.first_name
        return obj.staff_member.username

    def get_day_name(self, obj):
        day_map = {1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday', 5: 'Friday', 6: 'Saturday', 7: 'Sunday'}
        return day_map.get(obj.day_of_week, 'Unknown')


class DayOffRequestSerializer(serializers.ModelSerializer):
    staff_member_name = serializers.SerializerMethodField()
    reviewed_by_name = serializers.SerializerMethodField()

    class Meta:
        model = DayOffRequest
        fields = [
            'id', 'staff_member', 'staff_member_name', 'date', 'reason',
            'status', 'reviewed_by', 'reviewed_by_name', 'reviewed_at', 'created_at',
        ]
        read_only_fields = ['id', 'staff_member', 'staff_member_name', 'status', 'reviewed_by', 'reviewed_by_name', 'reviewed_at', 'created_at']

    def get_staff_member_name(self, obj):
        if obj.staff_member.first_name:
            return obj.staff_member.first_name
        return obj.staff_member.username

    def get_reviewed_by_name(self, obj):
        if obj.reviewed_by:
            return obj.reviewed_by.first_name or obj.reviewed_by.username
        return None


class DogProfileChangeRequestSerializer(serializers.ModelSerializer):
    dog_name = serializers.CharField(source='dog.name', read_only=True)
    dog_profile_image = serializers.ImageField(source='dog.profile_image', read_only=True)
    requested_by_name = serializers.SerializerMethodField()
    reviewed_by_name = serializers.SerializerMethodField()

    class Meta:
        model = DogProfileChangeRequest
        fields = [
            'id', 'dog', 'dog_name', 'dog_profile_image',
            'requested_by', 'requested_by_name',
            'proposed_changes', 'proposed_image', 'delete_image',
            'status', 'reviewed_by', 'reviewed_by_name', 'reviewed_at',
            'created_at',
        ]
        read_only_fields = [
            'id', 'requested_by', 'requested_by_name',
            # proposed_changes/image/delete are only ever built server-side from
            # a fixed whitelist; never accept them from the client (B19).
            'proposed_changes', 'proposed_image', 'delete_image',
            'status', 'reviewed_by', 'reviewed_by_name', 'reviewed_at',
            'created_at',
        ]

    def get_requested_by_name(self, obj):
        if obj.requested_by.first_name:
            return obj.requested_by.first_name
        return obj.requested_by.username

    def get_reviewed_by_name(self, obj):
        if obj.reviewed_by:
            return obj.reviewed_by.first_name or obj.reviewed_by.username
        return None

    def to_representation(self, instance):
        data = super().to_representation(instance)
        request = self.context.get('request')
        if request:
            if instance.proposed_image:
                data['proposed_image'] = request.build_absolute_uri(instance.proposed_image.url)
            if instance.dog.profile_image:
                data['dog_profile_image'] = request.build_absolute_uri(instance.dog.profile_image.url)
        return data


class ContactInquirySerializer(serializers.ModelSerializer):
    service_display = serializers.CharField(source='get_service_display', read_only=True)

    class Meta:
        from website.models import ContactInquiry
        model = ContactInquiry
        fields = ['id', 'name', 'email', 'service', 'service_display', 'message', 'is_read', 'is_replied', 'created_at']
        read_only_fields = ['id', 'name', 'email', 'service', 'service_display', 'message', 'created_at']


# Current Privacy Policy version users must accept at sign-up. Bump this when
# the policy materially changes (matches the "Last updated" date on the page).
PRIVACY_POLICY_VERSION = '2026-02-02'


class UserCreateWithPrivacySerializer(DjoserUserCreateSerializer):
    """Djoser user-create serializer that also requires Privacy Policy
    acceptance and records when/which version was accepted on the profile."""

    accept_privacy = serializers.BooleanField(write_only=True, required=True)

    class Meta(DjoserUserCreateSerializer.Meta):
        # Include first/last name so they're saved at sign-up (djoser's default
        # create serializer omits them), plus our privacy acceptance flag.
        fields = tuple(DjoserUserCreateSerializer.Meta.fields) + (
            'first_name', 'last_name', 'accept_privacy',
        )

    def validate(self, attrs):
        # Remove our extra flag before djoser builds the User (User() has no
        # such kwarg), but require it to be explicitly true.
        accepted = attrs.pop('accept_privacy', False)
        if accepted is not True:
            raise serializers.ValidationError({
                'accept_privacy': 'You must accept the Privacy Policy to create an account.'
            })
        return super().validate(attrs)

    def create(self, validated_data):
        user = super().create(validated_data)
        # The post_save signal creates the profile; stamp the acceptance on it.
        from django.utils import timezone
        profile = user.profile
        profile.accepted_privacy_at = timezone.now()
        profile.accepted_privacy_version = PRIVACY_POLICY_VERSION
        profile.save(update_fields=['accepted_privacy_at', 'accepted_privacy_version'])
        return user


class VehicleMaintenanceRecordSerializer(serializers.ModelSerializer):
    created_by_name = serializers.SerializerMethodField()

    class Meta:
        model = VehicleMaintenanceRecord
        fields = ['id', 'vehicle', 'event_type', 'previous_due_date', 'new_due_date', 'notes', 'created_by_name', 'created_at']
        read_only_fields = ['id', 'created_by_name', 'created_at']

    def get_created_by_name(self, obj):
        if obj.created_by:
            return obj.created_by.first_name or obj.created_by.username
        return None


class VehicleDefectImageSerializer(serializers.ModelSerializer):
    class Meta:
        model = VehicleDefectImage
        fields = ['id', 'image', 'thumbnail', 'created_at']
        read_only_fields = ['id', 'created_at']

    def to_representation(self, instance):
        data = super().to_representation(instance)
        request = self.context.get('request')
        if request:
            if instance.image:
                data['image'] = request.build_absolute_uri(instance.image.url)
            if instance.thumbnail:
                data['thumbnail'] = request.build_absolute_uri(instance.thumbnail.url)
        return data


class VehicleDefectCommentSerializer(serializers.ModelSerializer):
    user_name = serializers.SerializerMethodField()

    class Meta:
        model = VehicleDefectComment
        fields = ['id', 'user', 'user_name', 'text', 'created_at']
        read_only_fields = ['id', 'user', 'created_at']

    def get_user_name(self, obj):
        return obj.user.first_name or obj.user.username


class VehicleDefectSerializer(serializers.ModelSerializer):
    vehicle_name = serializers.CharField(source='vehicle.name', read_only=True)
    reported_by_name = serializers.SerializerMethodField()
    resolved_by_name = serializers.SerializerMethodField()
    images = VehicleDefectImageSerializer(many=True, read_only=True)
    comments = VehicleDefectCommentSerializer(many=True, read_only=True)

    class Meta:
        model = VehicleDefect
        fields = [
            'id', 'vehicle', 'vehicle_name', 'title', 'description', 'severity',
            'status', 'reported_by_name', 'resolved_by_name', 'resolved_at',
            'images', 'comments', 'created_at', 'updated_at',
        ]
        # Status changes only happen through the change_status action so they
        # always stamp resolved_by/resolved_at and notify the reporter.
        read_only_fields = ['id', 'status', 'resolved_at', 'created_at', 'updated_at']

    def get_reported_by_name(self, obj):
        if obj.reported_by:
            return obj.reported_by.first_name or obj.reported_by.username
        return None

    def get_resolved_by_name(self, obj):
        if obj.resolved_by:
            return obj.resolved_by.first_name or obj.resolved_by.username
        return None


class FacilityDefectImageSerializer(serializers.ModelSerializer):
    class Meta:
        model = FacilityDefectImage
        fields = ['id', 'image', 'thumbnail', 'created_at']
        read_only_fields = ['id', 'created_at']

    def to_representation(self, instance):
        data = super().to_representation(instance)
        request = self.context.get('request')
        if request:
            if instance.image:
                data['image'] = request.build_absolute_uri(instance.image.url)
            if instance.thumbnail:
                data['thumbnail'] = request.build_absolute_uri(instance.thumbnail.url)
        return data


class FacilityDefectCommentSerializer(serializers.ModelSerializer):
    user_name = serializers.SerializerMethodField()

    class Meta:
        model = FacilityDefectComment
        fields = ['id', 'user', 'user_name', 'text', 'created_at']
        read_only_fields = ['id', 'user', 'created_at']

    def get_user_name(self, obj):
        return obj.user.first_name or obj.user.username


class FacilityDefectSerializer(serializers.ModelSerializer):
    reported_by_name = serializers.SerializerMethodField()
    resolved_by_name = serializers.SerializerMethodField()
    images = FacilityDefectImageSerializer(many=True, read_only=True)
    comments = FacilityDefectCommentSerializer(many=True, read_only=True)

    class Meta:
        model = FacilityDefect
        fields = [
            'id', 'title', 'location', 'description', 'severity',
            'status', 'reported_by_name', 'resolved_by_name', 'resolved_at',
            'images', 'comments', 'created_at', 'updated_at',
        ]
        # Status changes only happen through the change_status action so they
        # always stamp resolved_by/resolved_at and notify the reporter.
        read_only_fields = ['id', 'status', 'resolved_at', 'created_at', 'updated_at']

    def get_reported_by_name(self, obj):
        if obj.reported_by:
            return obj.reported_by.first_name or obj.reported_by.username
        return None

    def get_resolved_by_name(self, obj):
        if obj.resolved_by:
            return obj.resolved_by.first_name or obj.resolved_by.username
        return None


class VehicleSerializer(serializers.ModelSerializer):
    mot_status = serializers.CharField(read_only=True)
    service_status = serializers.CharField(read_only=True)
    open_defect_count = serializers.SerializerMethodField()

    class Meta:
        model = Vehicle
        fields = [
            'id', 'name', 'registration', 'make', 'model', 'notes', 'image',
            'status', 'mot_due_date', 'service_due_date', 'mot_status',
            'service_status', 'open_defect_count', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']

    def get_open_defect_count(self, obj):
        # Count in Python from the prefetched defects to avoid a per-vehicle query
        return sum(1 for d in obj.defects.all() if d.status != 'RESOLVED')

    def to_representation(self, instance):
        data = super().to_representation(instance)
        request = self.context.get('request')
        if request and instance.image:
            data['image'] = request.build_absolute_uri(instance.image.url)
        return data
