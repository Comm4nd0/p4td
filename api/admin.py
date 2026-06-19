from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from django.contrib.auth.models import User
from django.utils.html import format_html
from django.utils import timezone
from datetime import date
from .models import (
    Dog, Photo, UserProfile, DateChangeRequest, DateChangeRequestHistory,
    GroupMedia, MediaReaction, Comment, BoardingRequest, BoardingRequestHistory,
    DailyDogAssignment, DeviceToken, SupportQuery, SupportMessage,
    ClosureDay, DogNote, StaffAvailability, DayOffRequest, DogProfileChangeRequest,
    VaccinationRecord, WaitlistEntry, DaycareSettings,
    Vehicle, VehicleMaintenanceRecord, VehicleDefect, VehicleDefectImage,
    FacilityDefect, FacilityDefectImage,
)


class PhotoInline(admin.TabularInline):
    model = Photo
    extra = 0
    fields = ('media_type', 'file', 'thumbnail', 'taken_at', 'created_at')
    readonly_fields = ('created_at',)
    ordering = ['-taken_at']


class DogAssignmentInline(admin.TabularInline):
    """Inline showing recent assignments for a dog."""
    model = DailyDogAssignment
    fk_name = 'dog'
    extra = 0
    fields = ('staff_member', 'date', 'status')
    readonly_fields = ('staff_member', 'date', 'status')
    ordering = ['-date']
    verbose_name = 'Recent Assignment'
    verbose_name_plural = 'Recent Assignments'

    def get_queryset(self, request):
        from datetime import timedelta
        cutoff = date.today() - timedelta(days=14)
        return super().get_queryset(request).select_related('staff_member').filter(date__gte=cutoff).order_by('-date')

    def has_add_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False


@admin.register(Dog)
class DogAdmin(admin.ModelAdmin):
    list_display = ('name', 'owner_name', 'daycare_days_display', 'profile_image_preview', 'created_at')
    list_filter = ('created_at',)
    search_fields = ('name', 'owner__username', 'owner__first_name', 'owner__last_name')
    raw_id_fields = ('owner',)
    filter_horizontal = ('additional_owners',)
    readonly_fields = ('created_at', 'profile_image_preview_large')
    list_per_page = 30
    ordering = ['name']
    inlines = [PhotoInline, DogAssignmentInline]
    fieldsets = (
        (None, {
            'fields': ('name', 'owner', 'additional_owners', 'profile_image', 'profile_image_preview_large'),
        }),
        ('About', {
            'fields': ('sex', 'date_of_birth', 'is_spayed'),
        }),
        ('Daycare', {
            'fields': ('daycare_days', 'schedule_type'),
        }),
        ('Transport', {
            'fields': (
                ('owner_brings_default', 'owner_brings_default_time'),
                ('owner_collects_default', 'owner_collects_default_time'),
                'van_placement',
            ),
            'description': 'Owner-perspective defaults. Per-day overrides live on each Daily Dog Assignment.',
        }),
        ('Home Access', {
            'fields': ('address', 'access_instructions'),
        }),
        ('Care Instructions', {
            'fields': ('food_instructions', 'medical_notes', 'registered_vet', 'general_notes'),
        }),
        ('Metadata', {
            'fields': ('created_at',),
        }),
    )

    def owner_name(self, obj):
        if obj.owner is None:
            return format_html('<span style="color: #999;">No owner</span>')
        name = obj.owner.get_full_name() or obj.owner.username
        return name
    owner_name.short_description = 'Owner'
    owner_name.admin_order_field = 'owner__first_name'

    def daycare_days_display(self, obj):
        if not obj.daycare_days:
            return format_html('<span style="color: #999;">None</span>')
        day_map = {1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri', 6: 'Sat', 7: 'Sun'}
        days = [day_map.get(d, '?') for d in sorted(obj.daycare_days)]
        return ', '.join(days)
    daycare_days_display.short_description = 'Daycare Days'

    def profile_image_preview(self, obj):
        if obj.profile_image:
            return format_html('<img src="{}" style="width: 40px; height: 40px; border-radius: 50%; object-fit: cover;" />', obj.profile_image.url)
        return format_html('<span style="color: #999;">No image</span>')
    profile_image_preview.short_description = 'Photo'

    def profile_image_preview_large(self, obj):
        if obj.profile_image:
            return format_html('<img src="{}" style="max-width: 200px; max-height: 200px; border-radius: 8px; object-fit: cover;" />', obj.profile_image.url)
        return format_html('<span style="color: #999;">No image</span>')
    profile_image_preview_large.short_description = 'Preview'


class DailyDogAssignmentInline(admin.TabularInline):
    model = DailyDogAssignment
    fk_name = 'staff_member'
    extra = 0
    fields = ('dog', 'date', 'status')
    readonly_fields = ('dog', 'date', 'status')
    ordering = ['-date', 'dog__name']
    verbose_name = 'Dog Assignment'
    verbose_name_plural = 'Dog Assignments'

    def get_queryset(self, request):
        return super().get_queryset(request).select_related('dog').filter(date=date.today())

    def has_add_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False


class StaffUserAdmin(BaseUserAdmin):
    inlines = list(BaseUserAdmin.inlines or []) + [DailyDogAssignmentInline]

    def get_list_display(self, request):
        return ('username', 'first_name', 'last_name', 'todays_dogs')

    def todays_dogs(self, obj):
        assignments = obj.dog_assignments.filter(date=date.today()).select_related('dog')
        if not assignments.exists():
            return format_html('<span style="color: #999;">None</span>')
        dogs = []
        for a in assignments:
            color = {
                'ASSIGNED': '#ffc107',
                'PICKED_UP': '#0d6efd',
                'DROPPED_OFF': '#198754',
            }.get(a.status, '#6c757d')
            dogs.append(format_html(
                '<span style="background-color: {}; padding: 2px 6px; border-radius: 3px; color: white; margin-right: 4px;">{}</span>',
                color, a.dog.name
            ))
        return format_html(''.join(str(d) for d in dogs))
    todays_dogs.short_description = "Today's Dogs"


# Unregister the default User admin; register our customised one
admin.site.unregister(User)
admin.site.register(User, StaffUserAdmin)


@admin.register(DailyDogAssignment)
class DailyDogAssignmentAdmin(admin.ModelAdmin):
    list_display = ('dog_name', 'owner_name', 'staff_member_name', 'date', 'status_display', 'transport_display')
    list_filter = ('date', 'status', 'staff_member', 'owner_brings', 'owner_collects')
    search_fields = ('dog__name', 'dog__owner__username', 'staff_member__username', 'staff_member__first_name')
    list_per_page = 30
    date_hierarchy = 'date'
    ordering = ['-date', 'dog__name']
    raw_id_fields = ('dog', 'staff_member')
    fieldsets = (
        (None, {
            'fields': ('dog', 'staff_member', 'date', 'status'),
        }),
        ('Transport overrides', {
            'fields': (
                ('owner_brings', 'owner_brings_time'),
                ('owner_collects', 'owner_collects_time'),
            ),
            'description': 'Leave booleans blank to use the dog default. Times are the expected owner arrival / departure.',
        }),
    )

    def dog_name(self, obj):
        return obj.dog.name
    dog_name.short_description = 'Dog'
    dog_name.admin_order_field = 'dog__name'

    def owner_name(self, obj):
        return obj.dog.owner.username if obj.dog.owner else '—'
    owner_name.short_description = 'Owner'
    owner_name.admin_order_field = 'dog__owner__username'

    def staff_member_name(self, obj):
        return obj.staff_member.get_full_name() or obj.staff_member.username
    staff_member_name.short_description = 'Staff Member'
    staff_member_name.admin_order_field = 'staff_member__first_name'

    def status_display(self, obj):
        colors = {
            'ASSIGNED': '#ffc107',
            'PICKED_UP': '#0d6efd',
            'DROPPED_OFF': '#198754',
        }
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display()
        )
    status_display.short_description = 'Status'
    status_display.admin_order_field = 'status'

    def transport_display(self, obj):
        parts = []
        if obj.effective_owner_brings:
            t = obj.effective_owner_brings_time
            parts.append(format_html('<span title="Owner brings">&#127968;&rarr; {}</span>', t.strftime('%H:%M') if t else '—'))
        if obj.effective_owner_collects:
            t = obj.effective_owner_collects_time
            parts.append(format_html('<span title="Owner collects">&larr;&#127968; {}</span>', t.strftime('%H:%M') if t else '—'))
        if not parts:
            return format_html('<span style="color: #999;">staff</span>')
        return format_html(' &nbsp; '.join(str(p) for p in parts))
    transport_display.short_description = 'Transport'


@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ('user', 'phone_number', 'address', 'can_manage_requests', 'can_add_feed_media', 'can_assign_dogs', 'can_reply_queries', 'can_approve_timeoff', 'can_manage_vehicles')
    # Permission flags are shown read-only here and edited deliberately on the
    # detail page. They are NOT list_editable: a bulk-toggle from the changelist
    # let anyone with 'change userprofile' self-escalate in one Save (B42).
    list_select_related = ('user',)
    list_per_page = 50
    search_fields = ('user__username', 'phone_number', 'address')

@admin.register(DateChangeRequest)
class DateChangeRequestAdmin(admin.ModelAdmin):
    list_display = ('dog', 'owner_name', 'request_type_display', 'original_date', 'new_date', 'status_display', 'is_charged', 'created_at')
    list_filter = ('status', 'request_type', 'is_charged', 'created_at')
    search_fields = ('dog__name', 'dog__owner__username')
    readonly_fields = ('dog', 'request_type', 'original_date', 'new_date', 'is_charged', 'created_at', 'updated_at')
    list_per_page = 20
    ordering = ['-created_at']
    actions = ['approve_requests', 'deny_requests']

    def get_readonly_fields(self, request, obj=None):
        readonly = super().get_readonly_fields(request, obj)
        if request.user.is_superuser:
            return readonly
        # Check permission
        if hasattr(request.user, 'profile') and request.user.profile.can_manage_requests:
            return readonly
        # If no permission, make status read-only
        return readonly + ('status',)

    def get_actions(self, request):
        actions = super().get_actions(request)
        if request.user.is_superuser:
            return actions
        if hasattr(request.user, 'profile') and request.user.profile.can_manage_requests:
            return actions
        # Remove approve/deny actions if no permission
        if 'approve_requests' in actions:
            del actions['approve_requests']
        if 'deny_requests' in actions:
            del actions['deny_requests']
        return actions

    def owner_name(self, obj):
        return obj.dog.owner.username if obj.dog.owner else '—'
    owner_name.short_description = 'Owner'

    def request_type_display(self, obj):
        if obj.request_type == 'CANCEL':
            return format_html('<span style="color: #dc3545;">Cancellation</span>')
        if obj.request_type == 'ADD_DAY':
            return format_html('<span style="color: #198754;">Additional Day</span>')
        return format_html('<span style="color: #0d6efd;">Date Change</span>')
    request_type_display.short_description = 'Type'

    def status_display(self, obj):
        colors = {
            'PENDING': '#ffc107',
            'APPROVED': '#198754',
            'DENIED': '#dc3545',
        }
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display()
        )
    status_display.short_description = 'Status'

    def approve_requests(self, request, queryset):
        if not request.user.is_superuser and (not hasattr(request.user, 'profile') or not request.user.profile.can_manage_requests):
            self.message_user(request, "You do not have permission to approve requests.", level='ERROR')
            return
        
        pending = queryset.filter(status='PENDING')

        # Unassign-cancellations and the bulk approval run in one transaction so
        # a mid-loop failure can't leave assignments deleted with the requests
        # still PENDING (B41).
        from django.db import transaction
        with transaction.atomic():
            cancel_requests = pending.filter(request_type='CANCEL', original_date__isnull=False)
            for req in cancel_requests:
                DailyDogAssignment.objects.filter(
                    dog=req.dog,
                    date=req.original_date,
                ).delete()

            updated = pending.update(status='APPROVED', approved_by=request.user, approved_at=timezone.now())
        self.message_user(request, f'{updated} request(s) approved.')
    approve_requests.short_description = 'Approve selected requests'

    def deny_requests(self, request, queryset):
        if not request.user.is_superuser and (not hasattr(request.user, 'profile') or not request.user.profile.can_manage_requests):
            self.message_user(request, "You do not have permission to deny requests.", level='ERROR')
            return

        updated = queryset.filter(status='PENDING').update(status='DENIED', approved_by=None, approved_at=None)
        self.message_user(request, f'{updated} request(s) denied.')
    deny_requests.short_description = 'Deny selected requests'


class SupportMessageInline(admin.TabularInline):
    model = SupportMessage
    extra = 0
    fields = ('sender', 'text', 'created_at')
    readonly_fields = ('sender', 'created_at')
    ordering = ['created_at']


@admin.register(SupportQuery)
class SupportQueryAdmin(admin.ModelAdmin):
    list_display = ('subject', 'owner_name', 'status_display', 'message_count', 'created_at', 'updated_at')
    list_filter = ('status', 'created_at')
    search_fields = ('subject', 'owner__username', 'owner__first_name')
    raw_id_fields = ('owner', 'resolved_by')
    readonly_fields = ('owner', 'created_at', 'updated_at')
    list_per_page = 20
    ordering = ['-updated_at']
    inlines = [SupportMessageInline]

    def owner_name(self, obj):
        return obj.owner.first_name or obj.owner.username
    owner_name.short_description = 'Owner'
    owner_name.admin_order_field = 'owner__first_name'

    def message_count(self, obj):
        return obj.messages.count()
    message_count.short_description = 'Messages'

    def status_display(self, obj):
        colors = {'OPEN': '#ffc107', 'RESOLVED': '#198754'}
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display()
        )
    status_display.short_description = 'Status'


@admin.register(SupportMessage)
class SupportMessageAdmin(admin.ModelAdmin):
    list_display = ('query_subject', 'sender_name', 'text_preview', 'created_at')
    list_filter = ('created_at',)
    search_fields = ('text', 'sender__username', 'query__subject')
    raw_id_fields = ('query', 'sender')
    readonly_fields = ('created_at',)
    list_per_page = 30
    ordering = ['-created_at']

    def query_subject(self, obj):
        return obj.query.subject[:50]
    query_subject.short_description = 'Conversation'

    def sender_name(self, obj):
        return obj.sender.first_name or obj.sender.username
    sender_name.short_description = 'Sender'

    def text_preview(self, obj):
        return obj.text[:80] + '...' if len(obj.text) > 80 else obj.text
    text_preview.short_description = 'Message'


@admin.register(Photo)
class PhotoAdmin(admin.ModelAdmin):
    list_display = ('dog_name', 'media_type', 'thumbnail_preview', 'taken_at', 'created_at')
    list_filter = ('media_type', 'created_at')
    search_fields = ('dog__name', 'dog__owner__username')
    raw_id_fields = ('dog',)
    readonly_fields = ('created_at', 'thumbnail_preview_large')
    list_per_page = 30
    ordering = ['-taken_at']

    def dog_name(self, obj):
        return obj.dog.name
    dog_name.short_description = 'Dog'
    dog_name.admin_order_field = 'dog__name'

    def thumbnail_preview(self, obj):
        url = obj.thumbnail.url if obj.thumbnail else (obj.file.url if obj.file else None)
        if url:
            return format_html('<img src="{}" style="width: 40px; height: 40px; border-radius: 4px; object-fit: cover;" />', url)
        return '-'
    thumbnail_preview.short_description = 'Preview'

    def thumbnail_preview_large(self, obj):
        url = obj.thumbnail.url if obj.thumbnail else (obj.file.url if obj.file else None)
        if url:
            return format_html('<img src="{}" style="max-width: 300px; max-height: 300px; border-radius: 8px; object-fit: cover;" />', url)
        return '-'
    thumbnail_preview_large.short_description = 'Preview'


@admin.register(Comment)
class CommentAdmin(admin.ModelAdmin):
    list_display = ('user', 'text_preview', 'target_display', 'created_at')
    list_filter = ('created_at',)
    search_fields = ('user__username', 'text')
    raw_id_fields = ('user', 'group_media', 'photo')
    readonly_fields = ('created_at',)
    list_per_page = 30
    ordering = ['-created_at']

    def text_preview(self, obj):
        return obj.text[:80] + '...' if len(obj.text) > 80 else obj.text
    text_preview.short_description = 'Comment'

    def target_display(self, obj):
        if obj.group_media:
            return format_html('Feed post #{}', obj.group_media.id)
        elif obj.photo:
            return format_html('Photo of {}', obj.photo.dog.name)
        return '-'
    target_display.short_description = 'On'


@admin.register(DeviceToken)
class DeviceTokenAdmin(admin.ModelAdmin):
    list_display = ('user', 'device_type', 'token_preview', 'created_at', 'updated_at')
    list_filter = ('device_type', 'created_at')
    search_fields = ('user__username', 'token')
    raw_id_fields = ('user',)
    readonly_fields = ('created_at', 'updated_at')
    list_per_page = 30
    ordering = ['-updated_at']

    def token_preview(self, obj):
        return obj.token[:20] + '...' if len(obj.token) > 20 else obj.token
    token_preview.short_description = 'Token'


@admin.register(DateChangeRequestHistory)
class DateChangeRequestHistoryAdmin(admin.ModelAdmin):
    list_display = ('request', 'changed_by', 'from_status', 'to_status', 'changed_at')
    list_filter = ('from_status', 'to_status', 'changed_at')
    search_fields = ('request__dog__name', 'changed_by__username')
    raw_id_fields = ('request', 'changed_by')
    readonly_fields = ('request', 'changed_by', 'from_status', 'to_status', 'reason', 'changed_at')
    list_per_page = 30
    ordering = ['-changed_at']


@admin.register(BoardingRequestHistory)
class BoardingRequestHistoryAdmin(admin.ModelAdmin):
    list_display = ('request', 'changed_by', 'from_status', 'to_status', 'changed_at')
    list_filter = ('from_status', 'to_status', 'changed_at')
    search_fields = ('request__owner__username', 'changed_by__username')
    raw_id_fields = ('request', 'changed_by')
    readonly_fields = ('request', 'changed_by', 'from_status', 'to_status', 'changed_at')
    list_per_page = 30
    ordering = ['-changed_at']

@admin.register(GroupMedia)
class GroupMediaAdmin(admin.ModelAdmin):
    list_display = ('id', 'media_type', 'uploaded_by', 'caption_preview', 'created_at')
    list_filter = ('media_type', 'created_at')
    search_fields = ('caption', 'uploaded_by__username')
    readonly_fields = ('uploaded_by', 'created_at')
    ordering = ['-created_at']

    def has_add_permission(self, request):
        if request.user.is_superuser:
            return True
        if hasattr(request.user, 'profile') and request.user.profile.can_add_feed_media:
            return True
        return False

    def has_change_permission(self, request, obj=None):
        if request.user.is_superuser:
            return True
        if hasattr(request.user, 'profile') and request.user.profile.can_add_feed_media:
            return True
        return False

    def has_delete_permission(self, request, obj=None):
        if request.user.is_superuser:
            return True
        if hasattr(request.user, 'profile') and request.user.profile.can_add_feed_media:
            return True
        return False

    def caption_preview(self, obj):
        if obj.caption:
            return obj.caption[:50] + '...' if len(obj.caption) > 50 else obj.caption
        return '-'
    caption_preview.short_description = 'Caption'

    def save_model(self, request, obj, form, change):
        if not change:
            obj.uploaded_by = request.user
        super().save_model(request, obj, form, change)

@admin.register(BoardingRequest)
class BoardingRequestAdmin(admin.ModelAdmin):
    list_display = ('owner_name', 'dog_names', 'start_date', 'end_date', 'status_display', 'created_at')
    list_filter = ('status', 'start_date', 'created_at')
    search_fields = ('owner__username', 'dogs__name')
    readonly_fields = ('owner', 'dogs', 'start_date', 'end_date', 'special_instructions', 'created_at', 'updated_at', 'approved_by', 'approved_at')
    list_per_page = 20
    ordering = ['-created_at']
    actions = ['approve_requests', 'deny_requests']

    def get_readonly_fields(self, request, obj=None):
        readonly = super().get_readonly_fields(request, obj)
        if request.user.is_superuser:
            return readonly
        if hasattr(request.user, 'profile') and request.user.profile.can_manage_requests:
            return readonly
        return readonly + ('status',)

    def get_actions(self, request):
        actions = super().get_actions(request)
        if request.user.is_superuser:
            return actions
        if hasattr(request.user, 'profile') and request.user.profile.can_manage_requests:
            return actions
        if 'approve_requests' in actions:
            del actions['approve_requests']
        if 'deny_requests' in actions:
            del actions['deny_requests']
        return actions

    def owner_name(self, obj):
        return obj.owner.username
    owner_name.short_description = 'Owner'

    def dog_names(self, obj):
        return ", ".join([d.name for d in obj.dogs.all()])
    dog_names.short_description = 'Dogs'

    def status_display(self, obj):
        colors = {
            'PENDING': '#ffc107',
            'APPROVED': '#198754',
            'DENIED': '#dc3545',
        }
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display()
        )
    status_display.short_description = 'Status'

    def approve_requests(self, request, queryset):
        if not request.user.is_superuser and (not hasattr(request.user, 'profile') or not request.user.profile.can_manage_requests):
            self.message_user(request, "You do not have permission to approve requests.", level='ERROR')
            return

        from django.utils import timezone
        updated = queryset.filter(status='PENDING').update(
            status='APPROVED',
            approved_by=request.user,
            approved_at=timezone.now()
        )
        self.message_user(request, f'{updated} request(s) approved.')
    approve_requests.short_description = 'Approve selected requests'

    def deny_requests(self, request, queryset):
        if not request.user.is_superuser and (not hasattr(request.user, 'profile') or not request.user.profile.can_manage_requests):
            self.message_user(request, "You do not have permission to deny requests.", level='ERROR')
            return

        updated = queryset.filter(status='PENDING').update(
            status='DENIED',
            approved_by=None,
            approved_at=None
        )
        self.message_user(request, f'{updated} request(s) denied.')
    deny_requests.short_description = 'Deny selected requests'


@admin.register(ClosureDay)
class ClosureDayAdmin(admin.ModelAdmin):
    list_display = ('date', 'closure_type_display', 'reason', 'capacity_override', 'created_by_name', 'created_at')
    list_filter = ('closure_type', 'date')
    search_fields = ('reason',)
    ordering = ['-date']
    list_per_page = 30

    def closure_type_display(self, obj):
        colors = {'CLOSED': '#dc3545', 'REDUCED': '#ffc107'}
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.closure_type, '#6c757d'),
            obj.get_closure_type_display()
        )
    closure_type_display.short_description = 'Type'

    def created_by_name(self, obj):
        if obj.created_by:
            return obj.created_by.first_name or obj.created_by.username
        return '-'
    created_by_name.short_description = 'Created By'


@admin.register(DogNote)
class DogNoteAdmin(admin.ModelAdmin):
    list_display = ('dog_name', 'related_dog_name', 'note_type', 'sentiment_display', 'text_preview', 'created_by_name', 'created_at')
    list_filter = ('note_type', 'is_positive', 'created_at')
    search_fields = ('dog__name', 'related_dog__name', 'text')
    raw_id_fields = ('dog', 'related_dog', 'created_by')
    ordering = ['-created_at']
    list_per_page = 30

    def dog_name(self, obj):
        return obj.dog.name
    dog_name.short_description = 'Dog'
    dog_name.admin_order_field = 'dog__name'

    def related_dog_name(self, obj):
        return obj.related_dog.name if obj.related_dog else '-'
    related_dog_name.short_description = 'Related Dog'

    def sentiment_display(self, obj):
        if obj.is_positive:
            return format_html('<span style="color: #198754;">Positive</span>')
        return format_html('<span style="color: #dc3545;">Negative</span>')
    sentiment_display.short_description = 'Sentiment'

    def text_preview(self, obj):
        return obj.text[:80] + '...' if len(obj.text) > 80 else obj.text
    text_preview.short_description = 'Note'

    def created_by_name(self, obj):
        if obj.created_by:
            return obj.created_by.first_name or obj.created_by.username
        return '-'
    created_by_name.short_description = 'By'


@admin.register(StaffAvailability)
class StaffAvailabilityAdmin(admin.ModelAdmin):
    list_display = ('staff_name', 'day_display', 'availability_display', 'note')
    list_filter = ('day_of_week', 'is_available')
    search_fields = ('staff_member__username', 'staff_member__first_name')
    ordering = ['staff_member__first_name', 'day_of_week']
    list_per_page = 50

    def staff_name(self, obj):
        return obj.staff_member.first_name or obj.staff_member.username
    staff_name.short_description = 'Staff Member'
    staff_name.admin_order_field = 'staff_member__first_name'

    def day_display(self, obj):
        day_map = {1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday', 5: 'Friday', 6: 'Saturday', 7: 'Sunday'}
        return day_map.get(obj.day_of_week, '?')
    day_display.short_description = 'Day'
    day_display.admin_order_field = 'day_of_week'

    def availability_display(self, obj):
        if obj.is_available:
            return format_html('<span style="color: #198754;">Available</span>')
        return format_html('<span style="color: #dc3545;">Unavailable</span>')
    availability_display.short_description = 'Status'


@admin.register(DayOffRequest)
class DayOffRequestAdmin(admin.ModelAdmin):
    """Staff holiday / day-off requests. Managers approve or deny them here;
    the requesting staff member is notified automatically on status change."""
    list_display = ('staff_name', 'date', 'reason_preview', 'status_display', 'reviewed_by_name', 'created_at')
    list_filter = ('status', 'staff_member', 'date')
    search_fields = ('staff_member__username', 'staff_member__first_name', 'staff_member__last_name', 'reason')
    date_hierarchy = 'date'
    readonly_fields = ('staff_member', 'date', 'reason', 'reviewed_by', 'reviewed_at', 'created_at')
    list_per_page = 30
    ordering = ['-date']
    actions = ['approve_requests', 'deny_requests']

    def get_readonly_fields(self, request, obj=None):
        readonly = super().get_readonly_fields(request, obj)
        if request.user.is_superuser:
            return readonly
        if hasattr(request.user, 'profile') and request.user.profile.can_approve_timeoff:
            return readonly
        # Without permission, status cannot be changed either.
        return readonly + ('status',)

    def get_actions(self, request):
        actions = super().get_actions(request)
        if request.user.is_superuser:
            return actions
        if hasattr(request.user, 'profile') and request.user.profile.can_approve_timeoff:
            return actions
        if 'approve_requests' in actions:
            del actions['approve_requests']
        if 'deny_requests' in actions:
            del actions['deny_requests']
        return actions

    def staff_name(self, obj):
        return obj.staff_member.get_full_name() or obj.staff_member.username
    staff_name.short_description = 'Staff Member'
    staff_name.admin_order_field = 'staff_member__first_name'

    def reason_preview(self, obj):
        if not obj.reason:
            return format_html('<span style="color: #999;">&mdash;</span>')
        return obj.reason[:60] + '...' if len(obj.reason) > 60 else obj.reason
    reason_preview.short_description = 'Reason'

    def reviewed_by_name(self, obj):
        if obj.reviewed_by:
            return obj.reviewed_by.get_full_name() or obj.reviewed_by.username
        return '-'
    reviewed_by_name.short_description = 'Reviewed By'

    def status_display(self, obj):
        colors = {
            'PENDING': '#ffc107',
            'APPROVED': '#198754',
            'DENIED': '#dc3545',
        }
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display()
        )
    status_display.short_description = 'Status'
    status_display.admin_order_field = 'status'

    def save_model(self, request, obj, form, change):
        # Stamp reviewer/timestamp when a manager changes the status via the form.
        if 'status' in form.changed_data:
            if obj.status in ('APPROVED', 'DENIED'):
                obj.reviewed_by = request.user
                obj.reviewed_at = timezone.now()
            else:
                obj.reviewed_by = None
                obj.reviewed_at = None
        super().save_model(request, obj, form, change)

    def approve_requests(self, request, queryset):
        if not request.user.is_superuser and (not hasattr(request.user, 'profile') or not request.user.profile.can_approve_timeoff):
            self.message_user(request, "You do not have permission to review time-off requests.", level='ERROR')
            return
        count = 0
        for req in queryset.filter(status='PENDING'):
            req.status = 'APPROVED'
            req.reviewed_by = request.user
            req.reviewed_at = timezone.now()
            req.save()  # fires signals -> notifies the staff member
            count += 1
        self.message_user(request, f'{count} request(s) approved.')
    approve_requests.short_description = 'Approve selected requests'

    def deny_requests(self, request, queryset):
        if not request.user.is_superuser and (not hasattr(request.user, 'profile') or not request.user.profile.can_approve_timeoff):
            self.message_user(request, "You do not have permission to review time-off requests.", level='ERROR')
            return
        count = 0
        for req in queryset.filter(status='PENDING'):
            req.status = 'DENIED'
            req.reviewed_by = request.user
            req.reviewed_at = timezone.now()
            req.save()
            count += 1
        self.message_user(request, f'{count} request(s) denied.')
    deny_requests.short_description = 'Deny selected requests'


@admin.register(DogProfileChangeRequest)
class DogProfileChangeRequestAdmin(admin.ModelAdmin):
    list_display = ('dog_name', 'requested_by_name', 'changes_summary', 'status_display', 'created_at')
    list_filter = ('status', 'created_at')
    search_fields = ('dog__name', 'requested_by__username', 'requested_by__first_name')
    raw_id_fields = ('dog', 'requested_by', 'reviewed_by')
    readonly_fields = ('dog', 'requested_by', 'proposed_changes', 'proposed_image', 'delete_image', 'created_at', 'reviewed_by', 'reviewed_at')
    list_per_page = 20
    ordering = ['-created_at']

    def dog_name(self, obj):
        return obj.dog.name
    dog_name.short_description = 'Dog'
    dog_name.admin_order_field = 'dog__name'

    def requested_by_name(self, obj):
        return obj.requested_by.first_name or obj.requested_by.username
    requested_by_name.short_description = 'Requested By'
    requested_by_name.admin_order_field = 'requested_by__first_name'

    def changes_summary(self, obj):
        parts = list(obj.proposed_changes.keys()) if obj.proposed_changes else []
        if obj.proposed_image:
            parts.append('photo')
        if obj.delete_image:
            parts.append('remove photo')
        return ', '.join(parts) if parts else '-'
    changes_summary.short_description = 'Changes'

    def status_display(self, obj):
        colors = {
            'PENDING': '#ffc107',
            'APPROVED': '#198754',
            'REJECTED': '#dc3545',
        }
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display()
        )
    status_display.short_description = 'Status'


@admin.register(VaccinationRecord)
class VaccinationRecordAdmin(admin.ModelAdmin):
    list_display = ('dog_name', 'name', 'date_administered', 'expiry_date', 'status_display', 'created_by_name', 'created_at')
    list_filter = ('name', 'expiry_date')
    search_fields = ('dog__name', 'name')
    raw_id_fields = ('dog', 'created_by')
    ordering = ['expiry_date']
    list_per_page = 30

    def dog_name(self, obj):
        return obj.dog.name
    dog_name.short_description = 'Dog'
    dog_name.admin_order_field = 'dog__name'

    def created_by_name(self, obj):
        if obj.created_by:
            return obj.created_by.first_name or obj.created_by.username
        return '-'
    created_by_name.short_description = 'Recorded By'

    def status_display(self, obj):
        colors = {'expired': '#dc3545', 'expiring_soon': '#ffc107', 'up_to_date': '#198754'}
        labels = {'expired': 'Expired', 'expiring_soon': 'Expiring soon', 'up_to_date': 'Up to date'}
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            labels.get(obj.status, obj.status),
        )
    status_display.short_description = 'Status'


@admin.register(WaitlistEntry)
class WaitlistEntryAdmin(admin.ModelAdmin):
    list_display = ('dog_name', 'date', 'status', 'requested_by_name', 'created_at', 'notified_at')
    list_filter = ('status', 'date')
    search_fields = ('dog__name', 'requested_by__username')
    raw_id_fields = ('dog', 'requested_by')
    ordering = ['date', 'created_at']
    list_per_page = 30

    def dog_name(self, obj):
        return obj.dog.name
    dog_name.short_description = 'Dog'
    dog_name.admin_order_field = 'dog__name'

    def requested_by_name(self, obj):
        if obj.requested_by:
            return obj.requested_by.first_name or obj.requested_by.username
        return '-'
    requested_by_name.short_description = 'Requested By'


@admin.register(DaycareSettings)
class DaycareSettingsAdmin(admin.ModelAdmin):
    list_display = ('__str__', 'default_daily_capacity', 'updated_at')

    def has_add_permission(self, request):
        return not DaycareSettings.objects.exists()

    def has_delete_permission(self, request, obj=None):
        return False


class VehicleDefectInline(admin.TabularInline):
    model = VehicleDefect
    extra = 0
    fields = ('title', 'severity', 'status', 'reported_by', 'created_at')
    readonly_fields = ('title', 'severity', 'status', 'reported_by', 'created_at')
    show_change_link = True

    def has_add_permission(self, request, obj=None):
        return False


class VehicleMaintenanceRecordInline(admin.TabularInline):
    model = VehicleMaintenanceRecord
    extra = 0
    fields = ('event_type', 'previous_due_date', 'new_due_date', 'notes', 'created_by', 'created_at')
    readonly_fields = ('created_at',)
    raw_id_fields = ('created_by',)


@admin.register(Vehicle)
class VehicleAdmin(admin.ModelAdmin):
    list_display = ('name', 'registration', 'status', 'mot_due_date', 'mot_badge', 'service_due_date', 'service_badge', 'open_defects', 'image_preview')
    list_filter = ('status', 'mot_due_date', 'service_due_date')
    search_fields = ('name', 'registration', 'make', 'model')
    readonly_fields = ('created_at', 'updated_at', 'image_preview_large')
    list_per_page = 30
    inlines = [VehicleDefectInline, VehicleMaintenanceRecordInline]
    fieldsets = (
        (None, {'fields': ('name', 'registration', 'make', 'model', 'status', 'notes', 'image', 'image_preview_large')}),
        ('Maintenance', {'fields': ('mot_due_date', 'service_due_date')}),
        ('Metadata', {'fields': ('created_at', 'updated_at')}),
    )

    def _due_badge(self, status):
        colors = {'overdue': '#dc3545', 'due_soon': '#ffc107', 'ok': '#198754'}
        labels = {'overdue': 'Overdue', 'due_soon': 'Due soon', 'ok': 'OK'}
        if status is None:
            return format_html('<span style="color: #999;">-</span>')
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(status, '#6c757d'),
            labels.get(status, status),
        )

    def mot_badge(self, obj):
        return self._due_badge(obj.mot_status)
    mot_badge.short_description = 'MOT'

    def service_badge(self, obj):
        return self._due_badge(obj.service_status)
    service_badge.short_description = 'Service'

    def open_defects(self, obj):
        return obj.defects.exclude(status='RESOLVED').count()
    open_defects.short_description = 'Open Defects'

    def image_preview(self, obj):
        if obj.image:
            return format_html('<img src="{}" style="width: 50px; height: 38px; object-fit: cover; border-radius: 4px;" />', obj.image.url)
        return 'No image'
    image_preview.short_description = 'Image'

    def image_preview_large(self, obj):
        if obj.image:
            return format_html('<img src="{}" style="max-width: 300px; border-radius: 8px;" />', obj.image.url)
        return 'No image'
    image_preview_large.short_description = 'Image Preview'


class VehicleDefectImageInline(admin.TabularInline):
    model = VehicleDefectImage
    extra = 0
    fields = ('image', 'thumbnail_preview', 'created_at')
    readonly_fields = ('thumbnail_preview', 'created_at')

    def thumbnail_preview(self, obj):
        if obj.thumbnail:
            return format_html('<img src="{}" style="width: 60px; height: 60px; object-fit: cover; border-radius: 4px;" />', obj.thumbnail.url)
        if obj.image:
            return format_html('<img src="{}" style="width: 60px; height: 60px; object-fit: cover; border-radius: 4px;" />', obj.image.url)
        return 'No image'
    thumbnail_preview.short_description = 'Preview'


@admin.register(VehicleDefect)
class VehicleDefectAdmin(admin.ModelAdmin):
    list_display = ('vehicle', 'title', 'severity', 'status_display', 'reported_by_name', 'created_at')
    list_filter = ('status', 'severity', 'vehicle')
    search_fields = ('title', 'description', 'vehicle__name', 'vehicle__registration')
    raw_id_fields = ('reported_by', 'resolved_by')
    readonly_fields = ('created_at', 'updated_at')
    list_per_page = 30
    inlines = [VehicleDefectImageInline]

    def reported_by_name(self, obj):
        if obj.reported_by:
            return obj.reported_by.first_name or obj.reported_by.username
        return '-'
    reported_by_name.short_description = 'Reported By'

    def status_display(self, obj):
        colors = {'REPORTED': '#dc3545', 'IN_PROGRESS': '#ffc107', 'RESOLVED': '#198754'}
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display(),
        )
    status_display.short_description = 'Status'


class FacilityDefectImageInline(admin.TabularInline):
    model = FacilityDefectImage
    extra = 0
    fields = ('image', 'thumbnail_preview', 'created_at')
    readonly_fields = ('thumbnail_preview', 'created_at')

    def thumbnail_preview(self, obj):
        if obj.thumbnail:
            return format_html('<img src="{}" style="width: 60px; height: 60px; object-fit: cover; border-radius: 4px;" />', obj.thumbnail.url)
        if obj.image:
            return format_html('<img src="{}" style="width: 60px; height: 60px; object-fit: cover; border-radius: 4px;" />', obj.image.url)
        return 'No image'
    thumbnail_preview.short_description = 'Preview'


@admin.register(FacilityDefect)
class FacilityDefectAdmin(admin.ModelAdmin):
    list_display = ('title', 'location', 'severity', 'status_display', 'reported_by_name', 'created_at')
    list_filter = ('status', 'severity')
    search_fields = ('title', 'description', 'location')
    raw_id_fields = ('reported_by', 'resolved_by')
    readonly_fields = ('created_at', 'updated_at')
    list_per_page = 30
    inlines = [FacilityDefectImageInline]

    def reported_by_name(self, obj):
        if obj.reported_by:
            return obj.reported_by.first_name or obj.reported_by.username
        return '-'
    reported_by_name.short_description = 'Reported By'

    def status_display(self, obj):
        colors = {'REPORTED': '#dc3545', 'IN_PROGRESS': '#ffc107', 'RESOLVED': '#198754'}
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display(),
        )
    status_display.short_description = 'Status'
