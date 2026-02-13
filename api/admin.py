from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from django.contrib.auth.models import User
from django.utils.html import format_html
from datetime import date
from .models import (
    Dog, Photo, UserProfile, DateChangeRequest, DateChangeRequestHistory,
    GroupMedia, MediaReaction, Comment, BoardingRequest, BoardingRequestHistory,
    DailyDogAssignment, DeviceToken,
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
    readonly_fields = ('created_at', 'profile_image_preview_large')
    list_per_page = 30
    ordering = ['name']
    inlines = [PhotoInline, DogAssignmentInline]
    fieldsets = (
        (None, {
            'fields': ('name', 'owner', 'profile_image', 'profile_image_preview_large'),
        }),
        ('Daycare', {
            'fields': ('daycare_days',),
        }),
        ('Care Instructions', {
            'fields': ('food_instructions', 'medical_notes'),
        }),
        ('Metadata', {
            'fields': ('created_at',),
        }),
    )

    def owner_name(self, obj):
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
                'AT_DAYCARE': '#6f42c1',
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
    list_display = ('dog_name', 'owner_name', 'staff_member_name', 'date', 'status_display')
    list_filter = ('date', 'status', 'staff_member')
    search_fields = ('dog__name', 'dog__owner__username', 'staff_member__username', 'staff_member__first_name')
    list_per_page = 30
    date_hierarchy = 'date'
    ordering = ['-date', 'dog__name']
    raw_id_fields = ('dog', 'staff_member')

    def dog_name(self, obj):
        return obj.dog.name
    dog_name.short_description = 'Dog'
    dog_name.admin_order_field = 'dog__name'

    def owner_name(self, obj):
        return obj.dog.owner.username
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
            'AT_DAYCARE': '#6f42c1',
            'DROPPED_OFF': '#198754',
        }
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display()
        )
    status_display.short_description = 'Status'
    status_display.admin_order_field = 'status'


@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ('user', 'phone_number', 'address', 'can_manage_requests', 'can_add_feed_media', 'can_assign_dogs')
    list_editable = ('can_manage_requests', 'can_add_feed_media', 'can_assign_dogs')
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
        return obj.dog.owner.username
    owner_name.short_description = 'Owner'

    def request_type_display(self, obj):
        if obj.request_type == 'CANCEL':
            return format_html('<span style="color: #dc3545;">Cancellation</span>')
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
        
        updated = queryset.filter(status='PENDING').update(status='APPROVED', approved_by=request.user, approved_at=timezone.now())
        self.message_user(request, f'{updated} request(s) approved.')
    approve_requests.short_description = 'Approve selected requests'

    def deny_requests(self, request, queryset):
        if not request.user.is_superuser and (not hasattr(request.user, 'profile') or not request.user.profile.can_manage_requests):
            self.message_user(request, "You do not have permission to deny requests.", level='ERROR')
            return

        updated = queryset.filter(status='PENDING').update(status='DENIED', approved_by=None, approved_at=None)
        self.message_user(request, f'{updated} request(s) denied.')
    deny_requests.short_description = 'Deny selected requests'


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
