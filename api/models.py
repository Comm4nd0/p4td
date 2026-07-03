import secrets
from django.db import models
from django.contrib.auth.models import User
from django.utils import timezone

from django.db.models.signals import post_save, pre_save
from django.dispatch import receiver

class UserProfile(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name='profile')
    address = models.TextField(blank=True, null=True)
    phone_number = models.CharField(max_length=20, blank=True, null=True)
    pickup_instructions = models.TextField(blank=True, null=True)
    profile_photo = models.ImageField(upload_to='staff_photos/', null=True, blank=True)
    can_manage_requests = models.BooleanField(default=False, help_text='Designates whether this user can approve/deny requests.')
    can_add_feed_media = models.BooleanField(default=False, help_text='Designates whether this user can upload media to the feed.')
    can_assign_dogs = models.BooleanField(default=False, help_text='Designates whether this user can assign dogs to other staff members.')
    can_reply_queries = models.BooleanField(default=False, help_text='Designates whether this user can reply to support queries.')
    can_approve_timeoff = models.BooleanField(default=False, help_text='Designates whether this user can approve/deny time off requests.')
    can_view_inquiries = models.BooleanField(default=False, help_text='Designates whether this user can view and respond to website contact inquiries.')
    can_manage_vehicles = models.BooleanField(default=False, help_text='Designates whether this user can manage fleet vehicles, MOT/service dates and defect statuses.')

    # Personal identity colour used across the staff app (map pins, day board,
    # dashboard cards). Blank = automatic palette colour by staff id.
    staff_color = models.CharField(max_length=7, blank=True, default='', help_text='Hex colour (#RRGGBB) identifying this staff member across the app. Blank = automatic.')

    # Notification preferences (all enabled by default)
    notify_feed = models.BooleanField(default=True, help_text='Receive notifications for new feed posts and comments.')
    notify_traffic = models.BooleanField(default=True, help_text='Receive traffic delay alerts for pickups and drop-offs.')
    notify_bookings = models.BooleanField(default=True, help_text='Receive updates on date change and boarding requests.')
    notify_dog_updates = models.BooleanField(default=True, help_text='Receive updates when your dog is picked up, at daycare, or dropped off.')

    # Legal acceptance — recorded when the user agrees to the Privacy Policy at
    # sign-up. Null for accounts created before this was required (e.g. staff).
    accepted_privacy_at = models.DateTimeField(null=True, blank=True, help_text='When the user accepted the Privacy Policy.')
    accepted_privacy_version = models.CharField(max_length=20, blank=True, null=True, help_text='Version/date of the Privacy Policy the user accepted.')

    def __str__(self):
        return f"Profile for {self.user.username}"

class PasswordResetOTP(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='password_reset_otps')
    otp = models.CharField(max_length=6)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    is_used = models.BooleanField(default=False)
    # Temporary token returned after OTP verification, used to authorize the password change
    reset_token = models.CharField(max_length=64, blank=True, null=True, unique=True)

    class Meta:
        ordering = ['-created_at']
        indexes = [
            # Supports the user+otp verification and the invalidation update (B23).
            models.Index(fields=['user', 'is_used']),
        ]

    def is_expired(self):
        return timezone.now() > self.expires_at

    def is_valid(self):
        return not self.is_used and not self.is_expired()

    @classmethod
    def create_for_user(cls, user):
        # Invalidate any existing unused OTPs for this user
        cls.objects.filter(user=user, is_used=False).update(is_used=True)
        # Prune used/invalidated OTPs so the table (short-lived credentials)
        # doesn't grow unbounded (B23).
        cls.objects.filter(user=user, is_used=True).delete()
        otp = f"{secrets.randbelow(1000000):06d}"
        expires_at = timezone.now() + timezone.timedelta(minutes=15)
        return cls.objects.create(user=user, otp=otp, expires_at=expires_at)

    def generate_reset_token(self):
        self.reset_token = secrets.token_urlsafe(48)
        self.save()
        return self.reset_token

    def __str__(self):
        return f"OTP for {self.user.username} (expires {self.expires_at})"


class Dog(models.Model):
    # Daycare day choices: 1=Monday, 2=Tuesday, ..., 7=Sunday
    DAYCARE_DAY_CHOICES = [
        (1, 'Monday'),
        (2, 'Tuesday'),
        (3, 'Wednesday'),
        (4, 'Thursday'),
        (5, 'Friday'),
        (6, 'Saturday'),
        (7, 'Sunday'),
    ]

    SCHEDULE_TYPE_CHOICES = [
        ('weekly', 'Weekly'),
        ('fortnightly', 'Fortnightly'),
        ('ad_hoc', 'Ad Hoc'),
    ]

    SEX_CHOICES = [
        ('M', 'Male'),
        ('F', 'Female'),
    ]

    owner = models.ForeignKey(User, on_delete=models.SET_NULL, related_name='dogs', null=True, blank=True)
    additional_owners = models.ManyToManyField(User, related_name='additional_dogs', blank=True)
    name = models.CharField(max_length=100)
    profile_image = models.ImageField(upload_to='dog_profiles/', null=True, blank=True)
    food_instructions = models.TextField(blank=True, null=True)
    medical_notes = models.TextField(blank=True, null=True)
    registered_vet = models.TextField(blank=True, null=True, help_text="Owner's registered vet — typically the practice name, address and phone number.")
    address = models.TextField(blank=True, null=True, help_text="Home address used for pickups/drop-offs of this dog.")
    postcode = models.CharField(max_length=10, blank=True, help_text="UK postcode of the pickup address; drives placement on the staff map (preferred over parsing the free-text address).")
    access_instructions = models.TextField(blank=True, null=True, help_text="How to access the home — keys, codes, gates, where the dog is kept.")
    van_placement = models.TextField(blank=True, null=True, help_text="Where the dog should sit in the van and any companion/seating notes.")
    general_notes = models.TextField(blank=True, null=True, help_text="General notes about the dog (behaviour, handling, misc).")
    daycare_days = models.JSONField(default=list, blank=True, help_text='List of day numbers (1-7) for daycare attendance')
    schedule_type = models.CharField(max_length=20, choices=SCHEDULE_TYPE_CHOICES, default='weekly', help_text='How often the dog attends: weekly, fortnightly, or ad hoc')
    owner_brings_default = models.BooleanField(default=False, help_text='Owner usually drops this dog off at daycare (no staff pickup).')
    owner_collects_default = models.BooleanField(default=False, help_text='Owner usually collects this dog from daycare (no staff drop-off home).')
    owner_brings_default_time = models.TimeField(null=True, blank=True, help_text='Expected default drop-off time when owner brings the dog.')
    owner_collects_default_time = models.TimeField(null=True, blank=True, help_text='Expected default pick-up time when owner collects the dog.')
    sex = models.CharField(max_length=1, choices=SEX_CHOICES, blank=True, null=True)
    date_of_birth = models.DateField(null=True, blank=True)
    is_spayed = models.BooleanField(default=False, help_text='Whether the dog has been spayed/neutered. Staff-only field.')
    # Cached geocoding of `address` for the staff pickup map. Populated by the
    # geocode_dogs management command and refreshed when `address` changes.
    GEOCODE_SOURCE_CHOICES = [
        ('house', 'House-level match'),
        ('postcode', 'Postcode centroid'),
        ('failed', 'Could not geocode'),
    ]
    latitude = models.FloatField(null=True, blank=True, help_text='Cached latitude of the pickup address.')
    longitude = models.FloatField(null=True, blank=True, help_text='Cached longitude of the pickup address.')
    geocoded_at = models.DateTimeField(null=True, blank=True, help_text='When the address was last geocoded.')
    geocode_source = models.CharField(max_length=10, choices=GEOCODE_SOURCE_CHOICES, blank=True, help_text='Precision of the cached coordinates.')
    geocoded_address = models.TextField(blank=True, null=True, help_text='The effective postcode the cached coordinates were derived from, used to detect staleness.')
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

from django.core.exceptions import ObjectDoesNotExist

@receiver(post_save, sender=User)
def create_user_profile(sender, instance, created, **kwargs):
    if created:
        UserProfile.objects.get_or_create(user=instance)

    # Note: the profile is intentionally NOT re-saved on every User save. Code
    # that edits the profile saves it explicitly; an implicit save on each User
    # write was a wasted query and could clobber concurrent edits (B21).

class Photo(models.Model):
    MEDIA_TYPE_CHOICES = [
        ('PHOTO', 'Photo'),
        ('VIDEO', 'Video'),
    ]
    
    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='photos')
    media_type = models.CharField(max_length=10, choices=MEDIA_TYPE_CHOICES, default='PHOTO')
    file = models.FileField(upload_to='dog_photos/', max_length=150)
    thumbnail = models.ImageField(upload_to='dog_photos/thumbnails/', max_length=150, null=True, blank=True)
    taken_at = models.DateTimeField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.get_media_type_display()} of {self.dog.name} at {self.taken_at}"

class DateChangeRequest(models.Model):
    REQUEST_TYPE_CHOICES = [
        ('CANCEL', 'Cancellation'),
        ('CHANGE', 'Date Change'),
        ('ADD_DAY', 'Additional Day'),
    ]

    STATUS_CHOICES = [
        ('PENDING', 'Pending'),
        ('APPROVED', 'Approved'),
        ('DENIED', 'Denied'),
    ]

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='date_change_requests')
    request_type = models.CharField(max_length=10, choices=REQUEST_TYPE_CHOICES)
    original_date = models.DateField(null=True, blank=True)
    new_date = models.DateField(null=True, blank=True)
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='PENDING')
    is_charged = models.BooleanField(default=False, help_text='Whether the original date is within 1 month and will be charged')
    approved_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='approved_date_change_requests')
    approved_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['status', 'original_date']),
            models.Index(fields=['status', 'new_date']),
        ]

    def __str__(self):
        if self.request_type == 'CANCEL':
            return f"{self.dog.name} - Cancel {self.original_date}"
        if self.request_type == 'ADD_DAY':
            return f"{self.dog.name} - Add {self.new_date}"
        return f"{self.dog.name} - Change {self.original_date} to {self.new_date}"


class DateChangeRequestHistory(models.Model):
    request = models.ForeignKey(DateChangeRequest, on_delete=models.CASCADE, related_name='history')
    changed_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True)
    from_status = models.CharField(max_length=10, choices=DateChangeRequest.STATUS_CHOICES)
    to_status = models.CharField(max_length=10, choices=DateChangeRequest.STATUS_CHOICES)
    reason = models.TextField(blank=True, null=True)
    changed_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-changed_at']


class GroupMedia(models.Model):
    MEDIA_TYPE_CHOICES = [
        ('PHOTO', 'Photo'),
        ('VIDEO', 'Video'),
    ]

    uploaded_by = models.ForeignKey(User, on_delete=models.CASCADE, related_name='uploaded_media')
    media_type = models.CharField(max_length=10, choices=MEDIA_TYPE_CHOICES)
    file = models.FileField(upload_to='group_media/', max_length=150)
    thumbnail = models.ImageField(upload_to='group_media/thumbnails/', max_length=150, null=True, blank=True)
    caption = models.TextField(blank=True, null=True)
    tagged_dogs = models.ManyToManyField('Dog', related_name='media_appearances', blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at', '-id']
        verbose_name_plural = 'Group media'

    def __str__(self):
        return f"{self.media_type} by {self.uploaded_by.username} at {self.created_at}"

class MediaReaction(models.Model):
    media = models.ForeignKey(GroupMedia, on_delete=models.CASCADE, related_name='reactions')
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='media_reactions')
    emoji = models.CharField(max_length=20)  # Stores the emoji string
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ('media', 'user', 'emoji')

class Comment(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='comments')
    text = models.TextField()
    group_media = models.ForeignKey(GroupMedia, on_delete=models.CASCADE, related_name='comments', null=True, blank=True)
    photo = models.ForeignKey(Photo, on_delete=models.CASCADE, related_name='comments', null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['created_at']
        constraints = [
            # A comment belongs to exactly one parent — group feed media OR a
            # dog photo, never both and never neither (B15).
            models.CheckConstraint(
                check=(
                    models.Q(group_media__isnull=False, photo__isnull=True)
                    | models.Q(group_media__isnull=True, photo__isnull=False)
                ),
                name='comment_exactly_one_parent',
            ),
        ]


    def __str__(self):
        target = self.group_media or self.photo
        return f"Comment by {self.user.username} on {target}"

class BoardingRequest(models.Model):
    STATUS_CHOICES = [
        ('PENDING', 'Pending'),
        ('APPROVED', 'Approved'),
        ('DENIED', 'Denied'),
    ]

    owner = models.ForeignKey(User, on_delete=models.CASCADE, related_name='boarding_requests')
    dogs = models.ManyToManyField(Dog, related_name='boarding_requests')
    start_date = models.DateField()
    end_date = models.DateField()
    special_instructions = models.TextField(blank=True, null=True)
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='PENDING')
    approved_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='approved_boarding_requests')
    approved_at = models.DateTimeField(null=True, blank=True)
    assigned_staff = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='assigned_boarding_requests', help_text='Staff member the dog boards with.')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"Boarding Request by {self.owner.username} for {self.start_date} to {self.end_date}"

class BoardingRequestHistory(models.Model):
    request = models.ForeignKey(BoardingRequest, on_delete=models.CASCADE, related_name='history')
    changed_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True)
    from_status = models.CharField(max_length=10, choices=BoardingRequest.STATUS_CHOICES)
    to_status = models.CharField(max_length=10, choices=BoardingRequest.STATUS_CHOICES)
    changed_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-changed_at']
class DailyDogAssignment(models.Model):
    STATUS_CHOICES = [
        ('ASSIGNED', 'Assigned'),
        ('PICKED_UP', 'With Team'),
        ('DROPPED_OFF', 'Returned'),
        # The dog is still attending this day but has no staff member yet
        # (single-day unassign). Kept as a row so roster materialization
        # doesn't silently re-create the assignment. Distinct from REMOVED,
        # which means the dog is NOT attending this day at all.
        ('UNASSIGNED', 'Unassigned'),
        ('REMOVED', 'Removed'),
    ]

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='daily_assignments')
    staff_member = models.ForeignKey(User, on_delete=models.CASCADE, related_name='dog_assignments')
    date = models.DateField()
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='ASSIGNED')
    owner_brings = models.BooleanField(null=True, blank=True, help_text='Override for this date. Null = fall back to Dog.owner_brings_default.')
    owner_collects = models.BooleanField(null=True, blank=True, help_text='Override for this date. Null = fall back to Dog.owner_collects_default.')
    owner_brings_time = models.TimeField(null=True, blank=True, help_text='Expected drop-off time when owner brings the dog on this date.')
    owner_collects_time = models.TimeField(null=True, blank=True, help_text='Expected pick-up time when owner collects the dog on this date.')
    sort_order = models.IntegerField(default=0, help_text='Custom sort order for staff pickup list. Lower numbers appear first.')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ('dog', 'date')
        ordering = ['sort_order', 'dog__name']
        indexes = [
            models.Index(fields=['date']),
            models.Index(fields=['date', 'staff_member']),
        ]

    def __str__(self):
        return f"{self.dog.name} assigned to {self.staff_member.username} on {self.date}"

    # The effective_* helpers below dereference self.dog, so any queryset that
    # serializes or iterates assignments must select_related('dog') (and
    # 'dog__owner__profile' for the serializer) or it issues a query per row.
    # The DailyDogAssignmentViewSet querysets and the notification signals do
    # this; new callers must too (B8).
    @property
    def effective_owner_brings(self) -> bool:
        return self.owner_brings if self.owner_brings is not None else self.dog.owner_brings_default

    @property
    def effective_owner_collects(self) -> bool:
        return self.owner_collects if self.owner_collects is not None else self.dog.owner_collects_default

    @property
    def effective_owner_brings_time(self):
        return self.owner_brings_time if self.owner_brings_time is not None else self.dog.owner_brings_default_time

    @property
    def effective_owner_collects_time(self):
        return self.owner_collects_time if self.owner_collects_time is not None else self.dog.owner_collects_default_time

    # ---- Boarding-aware transport legs ----
    # A boarding dog only travels on the edges of its stay: home → staff on the
    # first day, staff → home on the last day. In between it is already with
    # the boarding staff member, so neither leg exists. Consecutive approved
    # requests (one ends the day before the next starts) count as one stay.
    # These per-row properties each query BoardingRequest; bulk callers
    # (the roster serializer) pass precomputed per-date sets via context
    # instead — see DailyDogAssignmentSerializer / _boarding_context.

    def _boarding_covers(self, target_date):
        return BoardingRequest.objects.filter(
            dogs=self.dog_id,
            status='APPROVED',
            start_date__lte=target_date,
            end_date__gte=target_date,
        ).exists()

    @property
    def is_boarding_day(self) -> bool:
        return self._boarding_covers(self.date)

    @property
    def boarding_first_day(self) -> bool:
        from datetime import timedelta
        return self.is_boarding_day and not self._boarding_covers(self.date - timedelta(days=1))

    @property
    def boarding_last_day(self) -> bool:
        from datetime import timedelta
        return self.is_boarding_day and not self._boarding_covers(self.date + timedelta(days=1))

    @property
    def needs_staff_pickup(self) -> bool:
        """Staff collect this dog from home this morning."""
        if self.effective_owner_brings:
            return False
        return not self.is_boarding_day or self.boarding_first_day

    @property
    def needs_staff_dropoff(self) -> bool:
        """Staff return this dog home tonight."""
        if self.effective_owner_collects:
            return False
        return not self.is_boarding_day or self.boarding_last_day


class DogWeekdayPickup(models.Model):
    """Persistent default: who picks up <dog> every <weekday>.

    Materialized into DailyDogAssignment rows on demand when an admin views
    a day. Only applies to recurring dogs (not schedule_type='ad_hoc').
    """
    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='weekday_pickups')
    weekday = models.IntegerField(help_text='1=Monday … 7=Sunday (matches isoweekday())')
    staff_member = models.ForeignKey(User, on_delete=models.PROTECT, related_name='weekday_pickups')
    sort_order = models.IntegerField(default=0, help_text='Remembered route position for this weekday; copied into the daily assignment on materialization.')
    created_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='created_weekday_pickups')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ('dog', 'weekday')
        ordering = ['weekday', 'sort_order', 'dog__name']
        indexes = [models.Index(fields=['weekday', 'staff_member'])]

    def __str__(self):
        return f"{self.dog.name} → {self.staff_member.username} on weekday {self.weekday}"


class ClosureDay(models.Model):
    CLOSURE_TYPE_CHOICES = [
        ('CLOSED', 'Closed'),
        ('REDUCED', 'Reduced Capacity'),
    ]

    date = models.DateField(unique=True)
    closure_type = models.CharField(max_length=10, choices=CLOSURE_TYPE_CHOICES, default='CLOSED')
    reason = models.CharField(max_length=255, blank=True, default='')
    capacity_override = models.PositiveIntegerField(
        null=True, blank=True,
        help_text='For REDUCED days: maximum number of dogs that can attend. Empty = use the default daily capacity.',
    )
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, related_name='created_closures')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['date']

    def __str__(self):
        return f"{self.date} - {self.get_closure_type_display()}"


class DogNote(models.Model):
    NOTE_TYPE_CHOICES = [
        ('COMPATIBILITY', 'Compatibility'),
        ('BEHAVIORAL', 'Behavioral'),
        ('GROUPING', 'Grouping'),
    ]

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='notes')
    related_dog = models.ForeignKey(Dog, on_delete=models.CASCADE, null=True, blank=True, related_name='related_notes')
    note_type = models.CharField(max_length=15, choices=NOTE_TYPE_CHOICES)
    text = models.TextField()
    is_positive = models.BooleanField(default=True, help_text='Whether this is a positive or negative note (e.g. gets along vs does not get along)')
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, related_name='created_dog_notes')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        if self.related_dog:
            return f"{self.dog.name} & {self.related_dog.name} - {self.get_note_type_display()}"
        return f"{self.dog.name} - {self.get_note_type_display()}"


class StaffAvailability(models.Model):
    staff_member = models.ForeignKey(User, on_delete=models.CASCADE, related_name='availability')
    day_of_week = models.IntegerField(help_text='1=Monday, 2=Tuesday, ..., 7=Sunday')
    is_available = models.BooleanField(default=True)
    is_available_daycare = models.BooleanField(default=True)
    is_available_boarding = models.BooleanField(default=True)
    note = models.CharField(max_length=255, blank=True, default='')

    class Meta:
        unique_together = ('staff_member', 'day_of_week')
        ordering = ['day_of_week']
        verbose_name_plural = 'Staff availability'

    def __str__(self):
        day_map = {1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday', 5: 'Friday', 6: 'Saturday', 7: 'Sunday'}
        status = 'Available' if self.is_available else 'Unavailable'
        return f"{self.staff_member.username} - {day_map.get(self.day_of_week, '?')} ({status})"


class DayOffRequest(models.Model):
    STATUS_CHOICES = [
        ('PENDING', 'Pending'),
        ('APPROVED', 'Approved'),
        ('DENIED', 'Denied'),
    ]

    staff_member = models.ForeignKey(User, on_delete=models.CASCADE, related_name='day_off_requests')
    date = models.DateField()
    reason = models.CharField(max_length=500, blank=True, default='')
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='PENDING')
    reviewed_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='reviewed_day_off_requests')
    reviewed_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-date']
        constraints = [
            # Stop concurrent duplicate active requests for the same staff/date
            # at the DB level (a re-request after DENIED is still allowed) (B16).
            models.UniqueConstraint(
                fields=['staff_member', 'date'],
                condition=models.Q(status__in=['PENDING', 'APPROVED']),
                name='unique_active_day_off_per_staff_date',
            ),
        ]

    def __str__(self):
        return f"{self.staff_member.username} - {self.date} ({self.get_status_display()})"


class DogProfileChangeRequest(models.Model):
    """Stores proposed changes to a dog's profile submitted by an owner.

    Instead of editing the Dog record directly, non-staff users create one of
    these.  A staff member can then approve (applying the changes) or reject.
    """
    STATUS_CHOICES = [
        ('PENDING', 'Pending'),
        ('APPROVED', 'Approved'),
        ('REJECTED', 'Rejected'),
    ]

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='profile_change_requests')
    requested_by = models.ForeignKey(User, on_delete=models.CASCADE, related_name='dog_profile_change_requests')
    proposed_changes = models.JSONField(
        default=dict,
        help_text='Dict of field_name → new_value for text/JSON fields that differ from the current dog record.',
    )
    proposed_image = models.ImageField(
        upload_to='dog_profile_changes/',
        null=True, blank=True,
        help_text='New profile image if the owner uploaded one.',
    )
    delete_image = models.BooleanField(
        default=False,
        help_text='True when the owner wants to remove the current profile image.',
    )
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='PENDING')
    reviewed_by = models.ForeignKey(
        User, null=True, blank=True, on_delete=models.SET_NULL,
        related_name='reviewed_profile_changes',
    )
    reviewed_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"Profile change for {self.dog.name} by {self.requested_by.username} ({self.get_status_display()})"


class DeviceToken(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='device_tokens')
    token = models.CharField(max_length=255, unique=True)
    device_type = models.CharField(max_length=10, choices=[('IOS', 'iOS'), ('ANDROID', 'Android')], null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"Token for {self.user.username} ({self.device_type})"


class SupportQuery(models.Model):
    STATUS_CHOICES = [
        ('OPEN', 'Open'),
        ('RESOLVED', 'Resolved'),
    ]

    owner = models.ForeignKey(User, on_delete=models.CASCADE, related_name='support_queries')
    subject = models.CharField(max_length=255)
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='OPEN')
    has_unread_reply = models.BooleanField(default=False, help_text='True when staff has replied and user has not yet viewed')
    staff_has_unread = models.BooleanField(default=False, help_text='True when the owner has sent a message staff have not yet viewed')
    resolved_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='resolved_queries')
    resolved_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-updated_at']
        verbose_name = 'Contact staff message'
        verbose_name_plural = 'Contact staff messages'

    def __str__(self):
        return f"Message from {self.owner.username}: {self.subject}"


class SupportMessage(models.Model):
    query = models.ForeignKey(SupportQuery, on_delete=models.CASCADE, related_name='messages')
    sender = models.ForeignKey(User, on_delete=models.CASCADE, related_name='support_messages')
    text = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['created_at']
        verbose_name = 'Contact staff reply'
        verbose_name_plural = 'Contact staff replies'

    def __str__(self):
        return f"Reply by {self.sender.username} on #{self.query.id}"


# Signals for Staff Notifications
from .notifications import send_staff_notification, send_push_notification

@receiver(post_save, sender=DateChangeRequest)
def notify_staff_date_change(sender, instance, created, **kwargs):
    if created:
        # Skip the staff notification when staff has auto-approved their own
        # request — there's nothing for managers to action.
        if instance.status != 'PENDING':
            return
        dog_name = instance.dog.name
        request_type = instance.get_request_type_display()
        if instance.request_type == 'ADD_DAY':
            title = "New Additional Day Request"
            body = f"{dog_name}: {request_type} requested for {instance.new_date}."
        else:
            title = "New Date Change Request"
            body = f"{dog_name}: {request_type} requested."
        data = {
            'type': 'date_change_request',
            'id': str(instance.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
        from django.contrib.auth.models import User
        for user in User.objects.filter(is_staff=True, profile__can_manage_requests=True):
            send_push_notification(user, title, body, data)

@receiver(post_save, sender=BoardingRequest)
def notify_staff_boarding_request(sender, instance, created, **kwargs):
    if created:
        owner_name = instance.owner.username
        title = "New Boarding Request"
        body = f"{owner_name} requested boarding from {instance.start_date} to {instance.end_date}."
        data = {
            'type': 'boarding_request',
            'id': str(instance.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
        from django.contrib.auth.models import User
        for user in User.objects.filter(is_staff=True, profile__can_manage_requests=True):
            send_push_notification(user, title, body, data)

# --- User Notifications (Status Changes) ---

@receiver(pre_save, sender=DateChangeRequest)
def store_old_date_request_status(sender, instance, **kwargs):
    if instance.pk:
        try:
            old_instance = DateChangeRequest.objects.get(pk=instance.pk)
            instance._old_status = old_instance.status
        except DateChangeRequest.DoesNotExist:
            instance._old_status = None
    else:
        instance._old_status = None

@receiver(post_save, sender=DateChangeRequest)
def notify_user_date_request_status(sender, instance, created, **kwargs):
    if created:
        return # Already handled by staff notification, user knows they created it locally usually

    if hasattr(instance, '_old_status') and instance._old_status != instance.status:
        # Status changed!
        dog_name = instance.dog.name
        new_status = instance.get_status_display()

        title = "Request Update"
        body = f"Your request for {dog_name} is now {new_status}."

        data = {
            'type': 'date_change_request_update',
            'id': str(instance.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }

        # Notify all owners (primary + additional)
        owner = instance.dog.owner
        if owner:
            send_push_notification(owner, title, body, data, category='bookings')
        for additional_owner in instance.dog.additional_owners.all():
            send_push_notification(additional_owner, title, body, data, category='bookings')

# --- Contact Staff Notifications ---

@receiver(post_save, sender=SupportQuery)
def notify_staff_new_query(sender, instance, created, **kwargs):
    if created:
        owner_name = instance.owner.first_name or instance.owner.username
        title = "New Message from Owner"
        body = f"{owner_name}: {instance.subject}"
        data = {
            'type': 'support_query',
            'id': str(instance.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
        from django.contrib.auth.models import User
        for user in User.objects.filter(is_staff=True, profile__can_reply_queries=True):
            send_push_notification(user, title, body, data)

@receiver(post_save, sender=SupportMessage)
def notify_query_message(sender, instance, created, **kwargs):
    if not created:
        return
    query = instance.query
    sender_user = instance.sender
    if sender_user.is_staff:
        # Staff replied — notify the owner
        staff_name = sender_user.first_name or sender_user.username
        title = "Staff Reply"
        body = f"{staff_name} replied to: {query.subject}"
        data = {
            'type': 'support_query_reply',
            'id': str(query.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
        send_push_notification(query.owner, title, body, data)
    else:
        # Owner followed up — notify staff
        owner_name = sender_user.first_name or sender_user.username
        title = "New Reply from Owner"
        body = f"{owner_name} added a message to: {query.subject}"
        data = {
            'type': 'support_query_update',
            'id': str(query.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
        from django.contrib.auth.models import User
        for user in User.objects.filter(is_staff=True, profile__can_reply_queries=True):
            send_push_notification(user, title, body, data)

# Owner notification on boarding status changes lives in
# BoardingRequestViewSet._notify_owner_boarding_status — a pre_save/post_save
# signal pair here used to duplicate it, sending owners two pushes per change.

# --- Dog Status Change Notifications ---

@receiver(pre_save, sender=DailyDogAssignment)
def store_old_assignment_status(sender, instance, **kwargs):
    if instance.pk:
        try:
            old_instance = DailyDogAssignment.objects.get(pk=instance.pk)
            instance._old_status = old_instance.status
        except DailyDogAssignment.DoesNotExist:
            instance._old_status = None
    else:
        instance._old_status = None

@receiver(post_save, sender=DailyDogAssignment)
def notify_owner_dog_status_change(sender, instance, created, **kwargs):
    if created:
        return

    if hasattr(instance, '_old_status') and instance._old_status != instance.status:
        new_status = instance.get_status_display()
        dog_name = instance.dog.name

        title = f"{dog_name} Status Update"
        body = f"{dog_name} is now {new_status}."
        if instance.status in ('PICKED_UP', 'DROPPED_OFF'):
            body += "\n\nThis message might not reflect actual timing of drop off/pick up."

        data = {
            'type': 'dog_status_update',
            'id': str(instance.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }

        owner = instance.dog.owner
        if owner:
            send_push_notification(owner, title, body, data, category='dog_updates')
        for additional_owner in instance.dog.additional_owners.all():
            send_push_notification(additional_owner, title, body, data, category='dog_updates')

# --- Care Instructions Change Notifications ---

@receiver(pre_save, sender=Dog)
def store_old_care_instructions(sender, instance, **kwargs):
    if instance.pk:
        try:
            old_instance = Dog.objects.get(pk=instance.pk)
            instance._old_food_instructions = old_instance.food_instructions
            instance._old_medical_notes = old_instance.medical_notes
        except Dog.DoesNotExist:
            instance._old_food_instructions = None
            instance._old_medical_notes = None
    else:
        instance._old_food_instructions = None
        instance._old_medical_notes = None

@receiver(post_save, sender=Dog)
def notify_staff_care_instructions_changed(sender, instance, created, **kwargs):
    if created:
        return

    old_food = getattr(instance, '_old_food_instructions', None)
    old_medical = getattr(instance, '_old_medical_notes', None)

    food_changed = old_food != instance.food_instructions
    medical_changed = old_medical != instance.medical_notes

    if not food_changed and not medical_changed:
        return

    # Build a description of what changed
    changes = []
    if food_changed:
        changes.append('food instructions')
    if medical_changed:
        changes.append('medical notes')

    changed_by = getattr(instance, '_changed_by', None)
    if changed_by:
        user_name = changed_by.first_name or changed_by.username
    else:
        user_name = 'A user'

    title = "Care Instructions Updated"
    body = f"{user_name} updated {' and '.join(changes)} for {instance.name}."

    data = {
        'type': 'care_instructions_update',
        'dog_id': str(instance.id),
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    }

    send_staff_notification(title, body, data, permission='can_assign_dogs')

# --- Day-Off Request Notifications ---

@receiver(post_save, sender=DayOffRequest)
def notify_managers_new_dayoff_request(sender, instance, created, **kwargs):
    """Notify managers when a staff member submits a new day-off request."""
    if not created:
        return

    staff_name = instance.staff_member.first_name or instance.staff_member.username
    title = "New Day-Off Request"
    body = f"{staff_name} requested {instance.date} off."
    if instance.reason:
        body += f" Reason: {instance.reason}"
    data = {
        'type': 'day_off_request',
        'id': str(instance.id),
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    }
    from django.contrib.auth.models import User
    for user in User.objects.filter(is_staff=True, profile__can_approve_timeoff=True):
        send_push_notification(user, title, body, data)


@receiver(pre_save, sender=DayOffRequest)
def store_old_dayoff_request_status(sender, instance, **kwargs):
    if instance.pk:
        try:
            old_instance = DayOffRequest.objects.get(pk=instance.pk)
            instance._old_status = old_instance.status
        except DayOffRequest.DoesNotExist:
            instance._old_status = None
    else:
        instance._old_status = None


@receiver(post_save, sender=DayOffRequest)
def notify_staff_dayoff_request_status(sender, instance, created, **kwargs):
    """Notify the requesting staff member when their day-off request is approved or denied."""
    if created:
        return

    if hasattr(instance, '_old_status') and instance._old_status != instance.status:
        new_status = instance.get_status_display()

        title = "Day-Off Request Update"
        body = f"Your day-off request for {instance.date} has been {new_status.lower()}."

        data = {
            'type': 'day_off_request_update',
            'id': str(instance.id),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }

        send_push_notification(instance.staff_member, title, body, data)


class VaccinationRecord(models.Model):
    """A single vaccination (e.g. DHP, Leptospirosis) recorded for a dog.

    Staff create and maintain these; owners get read-only access plus expiry
    reminders via push notification (the send_vaccination_reminders command,
    run daily from cron).
    """
    EXPIRING_SOON_DAYS = 30

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='vaccinations')
    name = models.CharField(max_length=100, help_text='Vaccine name, e.g. DHP, Leptospirosis, Kennel Cough, Rabies')
    date_administered = models.DateField()
    expiry_date = models.DateField()
    notes = models.TextField(blank=True, null=True)
    created_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='created_vaccinations')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    # Reminder bookkeeping so the daily command never notifies twice for the
    # same milestone. Re-armed when the expiry date changes (renewal recorded).
    reminder_30_sent = models.BooleanField(default=False)
    reminder_7_sent = models.BooleanField(default=False)
    expired_notice_sent = models.BooleanField(default=False)

    class Meta:
        ordering = ['-expiry_date']
        indexes = [models.Index(fields=['expiry_date'])]

    def save(self, *args, **kwargs):
        # Re-arm reminder flags when the expiry date changes (e.g. a booster is
        # recorded) so the daily command notifies for the new milestone. Central
        # so no update path can forget to reset them (B22).
        if self.pk:
            old = type(self).objects.filter(pk=self.pk).values('expiry_date').first()
            if old and old['expiry_date'] != self.expiry_date:
                self.reminder_30_sent = False
                self.reminder_7_sent = False
                self.expired_notice_sent = False
        super().save(*args, **kwargs)

    @property
    def status(self):
        from datetime import date, timedelta
        today = date.today()
        if self.expiry_date < today:
            return 'expired'
        if self.expiry_date <= today + timedelta(days=self.EXPIRING_SOON_DAYS):
            return 'expiring_soon'
        return 'up_to_date'

    def __str__(self):
        return f"{self.dog.name} - {self.name} (expires {self.expiry_date})"


class DaycareSettings(models.Model):
    """Facility-wide settings singleton (always pk=1)."""
    default_daily_capacity = models.PositiveIntegerField(
        null=True, blank=True,
        help_text='Maximum number of dogs per day (daycare + boarding). Empty = unlimited.',
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = 'Daycare settings'
        verbose_name_plural = 'Daycare settings'

    def save(self, *args, **kwargs):
        self.pk = 1
        super().save(*args, **kwargs)

    @classmethod
    def load(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj

    def __str__(self):
        capacity = self.default_daily_capacity or 'unlimited'
        return f"Daycare settings (daily capacity: {capacity})"


class WaitlistEntry(models.Model):
    """A dog waiting for a spot on a full day.

    When something frees a spot (cancellation approved, dog removed from the
    day, closure lifted) the longest-waiting owners are notified and the entry
    flips to NOTIFIED — the owner still requests the day through the normal
    flow. Owners leave the waitlist by deleting the entry.
    """
    STATUS_CHOICES = [
        ('WAITING', 'Waiting'),
        ('NOTIFIED', 'Notified'),
    ]

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='waitlist_entries')
    date = models.DateField()
    requested_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='waitlist_entries')
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='WAITING')
    created_at = models.DateTimeField(auto_now_add=True)
    notified_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        unique_together = ('dog', 'date')
        ordering = ['date', 'created_at']
        indexes = [models.Index(fields=['date', 'status'])]
        verbose_name_plural = 'Waitlist entries'

    def __str__(self):
        return f"{self.dog.name} waitlisted for {self.date} ({self.status})"


class Vehicle(models.Model):
    """A work vehicle in the fleet.

    All staff can view vehicles and report defects; users with the
    can_manage_vehicles profile flag maintain the fleet (add/edit vehicles,
    update MOT/service dates, change defect statuses). MOT and service due
    dates trigger reminders via the send_fleet_reminders command, run daily
    from cron.
    """
    DUE_SOON_DAYS = 30

    STATUS_CHOICES = [
        ('ACTIVE', 'Active'),
        ('IN_SERVICE', 'In Service/Garage'),
        ('OFF_ROAD', 'Off Road'),
    ]

    name = models.CharField(max_length=100, help_text='Friendly name, e.g. "Blue Van"')
    registration = models.CharField(max_length=20, unique=True, help_text='Number plate')
    make = models.CharField(max_length=50, blank=True, null=True)
    model = models.CharField(max_length=50, blank=True, null=True)
    notes = models.TextField(blank=True, null=True)
    image = models.ImageField(upload_to='vehicle_images/', null=True, blank=True)
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='ACTIVE')
    mot_due_date = models.DateField(null=True, blank=True)
    service_due_date = models.DateField(null=True, blank=True)

    # Reminder bookkeeping so the daily command never notifies twice for the
    # same milestone. Re-armed when the corresponding due date changes.
    mot_reminder_30_sent = models.BooleanField(default=False)
    mot_reminder_7_sent = models.BooleanField(default=False)
    mot_overdue_notice_sent = models.BooleanField(default=False)
    service_reminder_30_sent = models.BooleanField(default=False)
    service_reminder_7_sent = models.BooleanField(default=False)
    service_overdue_notice_sent = models.BooleanField(default=False)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['name']
        indexes = [
            models.Index(fields=['mot_due_date']),
            models.Index(fields=['service_due_date']),
        ]

    def save(self, *args, **kwargs):
        # Re-arm MOT/service reminder flags when the corresponding due date
        # changes, centrally instead of relying on each caller (B22).
        if self.pk:
            old = type(self).objects.filter(pk=self.pk).values(
                'mot_due_date', 'service_due_date'
            ).first()
            if old:
                if old['mot_due_date'] != self.mot_due_date:
                    self.mot_reminder_30_sent = False
                    self.mot_reminder_7_sent = False
                    self.mot_overdue_notice_sent = False
                if old['service_due_date'] != self.service_due_date:
                    self.service_reminder_30_sent = False
                    self.service_reminder_7_sent = False
                    self.service_overdue_notice_sent = False
        super().save(*args, **kwargs)

    def _date_status(self, due_date):
        from datetime import date, timedelta
        if due_date is None:
            return None
        today = date.today()
        if due_date < today:
            return 'overdue'
        if due_date <= today + timedelta(days=self.DUE_SOON_DAYS):
            return 'due_soon'
        return 'ok'

    @property
    def mot_status(self):
        return self._date_status(self.mot_due_date)

    @property
    def service_status(self):
        return self._date_status(self.service_due_date)

    def __str__(self):
        return f"{self.name} ({self.registration})"


class VehicleMaintenanceRecord(models.Model):
    """History entry created whenever a vehicle's MOT or service due date changes."""
    EVENT_CHOICES = [
        ('MOT', 'MOT'),
        ('SERVICE', 'Service'),
    ]

    vehicle = models.ForeignKey(Vehicle, on_delete=models.CASCADE, related_name='maintenance_records')
    event_type = models.CharField(max_length=10, choices=EVENT_CHOICES)
    previous_due_date = models.DateField(null=True, blank=True)
    new_due_date = models.DateField(null=True, blank=True)
    notes = models.TextField(blank=True, null=True)
    created_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='vehicle_maintenance_records')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.vehicle.name} {self.event_type} due {self.new_due_date}"


class VehicleDefect(models.Model):
    """A defect reported against a fleet vehicle. Any staff member can report."""
    STATUS_CHOICES = [
        ('REPORTED', 'Reported'),
        ('IN_PROGRESS', 'In Progress'),
        ('RESOLVED', 'Resolved'),
    ]

    SEVERITY_CHOICES = [
        ('LOW', 'Low'),
        ('MEDIUM', 'Medium'),
        ('HIGH', 'High'),
    ]

    vehicle = models.ForeignKey(Vehicle, on_delete=models.CASCADE, related_name='defects')
    title = models.CharField(max_length=200)
    description = models.TextField(blank=True, null=True)
    severity = models.CharField(max_length=10, choices=SEVERITY_CHOICES, default='MEDIUM')
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='REPORTED')
    reported_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='reported_defects')
    resolved_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='resolved_defects')
    resolved_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.vehicle.name}: {self.title} ({self.status})"


class VehicleDefectImage(models.Model):
    """A photo attached to a defect report."""
    defect = models.ForeignKey(VehicleDefect, on_delete=models.CASCADE, related_name='images')
    image = models.ImageField(upload_to='vehicle_defects/', max_length=150)
    thumbnail = models.ImageField(upload_to='vehicle_defects/thumbnails/', max_length=150, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['created_at']

    def __str__(self):
        return f"Image for defect #{self.defect_id}"


class VehicleDefectComment(models.Model):
    """A staff comment on a vehicle defect — used to track progress
    (e.g. 'part ordered, awaiting delivery')."""
    defect = models.ForeignKey(VehicleDefect, on_delete=models.CASCADE, related_name='comments')
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='vehicle_defect_comments')
    text = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['created_at']

    def __str__(self):
        return f"Comment on defect #{self.defect_id} by {self.user_id}"


class FacilityDefect(models.Model):
    """A general site/facility defect (e.g. a broken gate). Any staff member
    can report one and change its status."""
    STATUS_CHOICES = [
        ('REPORTED', 'Reported'),
        ('IN_PROGRESS', 'In Progress'),
        ('RESOLVED', 'Resolved'),
    ]

    SEVERITY_CHOICES = [
        ('LOW', 'Low'),
        ('MEDIUM', 'Medium'),
        ('HIGH', 'High'),
    ]

    title = models.CharField(max_length=200)
    location = models.CharField(max_length=200, blank=True, null=True)
    description = models.TextField(blank=True, null=True)
    severity = models.CharField(max_length=10, choices=SEVERITY_CHOICES, default='MEDIUM')
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='REPORTED')
    reported_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='reported_facility_defects')
    resolved_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='resolved_facility_defects')
    resolved_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.title} ({self.status})"


class FacilityDefectImage(models.Model):
    """A photo attached to a facility defect report."""
    defect = models.ForeignKey(FacilityDefect, on_delete=models.CASCADE, related_name='images')
    image = models.ImageField(upload_to='facility_defects/', max_length=150)
    thumbnail = models.ImageField(upload_to='facility_defects/thumbnails/', max_length=150, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['created_at']

    def __str__(self):
        return f"Image for facility defect #{self.defect_id}"


class FacilityDefectComment(models.Model):
    """A staff comment on a facility defect — used to track progress
    (e.g. 'contractor booked for Tuesday')."""
    defect = models.ForeignKey(FacilityDefect, on_delete=models.CASCADE, related_name='comments')
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='facility_defect_comments')
    text = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['created_at']

    def __str__(self):
        return f"Comment on facility defect #{self.defect_id} by {self.user_id}"


class IntakeRequest(models.Model):
    """An owner-submitted booking form asking to enrol one or more dogs.

    This is the app's "Booking Form": after registering an account (step one),
    owners whose dogs aren't in the daycare yet fill this in (step two) with
    their contact details and each dog's care information. Staff review the
    submission; approving it creates the Dog records and attaches them to the
    owner, denying it records a reason the owner can see.
    """
    STATUS_CHOICES = [
        ('PENDING', 'Pending'),
        ('APPROVED', 'Approved'),
        ('DENIED', 'Denied'),
    ]

    owner = models.ForeignKey(User, on_delete=models.CASCADE, related_name='intake_requests')
    phone_number = models.CharField(max_length=20, blank=True)
    address = models.TextField(blank=True, help_text='Home address used for pickups/drop-offs; copied to each dog on approval.')
    postcode = models.CharField(max_length=10, blank=True, help_text='UK postcode of the pickup address; copied to each dog on approval.')
    pickup_instructions = models.TextField(blank=True, help_text='How staff should collect the dog(s) — keys, gates, where the dog waits.')
    additional_info = models.TextField(blank=True, help_text='Anything else the owner wants staff to know.')
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='PENDING')
    denial_reason = models.TextField(blank=True)
    reviewed_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name='reviewed_intake_requests')
    reviewed_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"Booking form from {self.owner.username} ({self.get_status_display()})"


class IntakeDog(models.Model):
    """One dog on a booking form. Mirrors the owner-supplied Dog fields so a
    Dog record can be created verbatim when the request is approved."""
    request = models.ForeignKey(IntakeRequest, on_delete=models.CASCADE, related_name='dogs')
    name = models.CharField(max_length=100)
    sex = models.CharField(max_length=1, choices=Dog.SEX_CHOICES, blank=True, null=True)
    date_of_birth = models.DateField(null=True, blank=True)
    is_spayed = models.BooleanField(default=False)
    food_instructions = models.TextField(blank=True)
    medical_notes = models.TextField(blank=True)
    registered_vet = models.TextField(blank=True)
    daycare_days = models.JSONField(default=list, blank=True, help_text='Requested day numbers (1-7) for daycare attendance.')
    schedule_type = models.CharField(max_length=20, choices=Dog.SCHEDULE_TYPE_CHOICES, default='weekly')
    created_dog = models.ForeignKey(Dog, null=True, blank=True, on_delete=models.SET_NULL, related_name='intake_dogs', help_text='The Dog record created when the request was approved.')

    class Meta:
        ordering = ['id']

    def __str__(self):
        return f"{self.name} on booking form #{self.request_id}"
