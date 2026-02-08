from django.contrib import admin
from django.utils.html import format_html
from .models import Dog, Photo, UserProfile, DateChangeRequest, GroupMedia, BoardingRequest

@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ('user', 'phone_number', 'address', 'can_manage_requests')
    list_editable = ('can_manage_requests',)
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

@admin.register(GroupMedia)
class GroupMediaAdmin(admin.ModelAdmin):
    list_display = ('id', 'media_type', 'uploaded_by', 'caption_preview', 'created_at')
    list_filter = ('media_type', 'created_at')
    search_fields = ('caption', 'uploaded_by__username')
    readonly_fields = ('uploaded_by', 'created_at')
    ordering = ['-created_at']

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
