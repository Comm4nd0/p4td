from django.contrib import admin
from django.utils.html import format_html
from .models import Dog, Photo, UserProfile, DateChangeRequest

@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ('user', 'phone_number', 'address')
    search_fields = ('user__username', 'phone_number', 'address')

@admin.register(Dog)
class DogAdmin(admin.ModelAdmin):
    list_display = ('name', 'owner', 'created_at')
    search_fields = ('name', 'owner__username')
    list_filter = ('created_at',)

@admin.register(Photo)
class PhotoAdmin(admin.ModelAdmin):
    list_display = ('dog', 'taken_at', 'created_at')
    list_filter = ('taken_at',)

@admin.register(DateChangeRequest)
class DateChangeRequestAdmin(admin.ModelAdmin):
    list_display = ('dog', 'owner_name', 'request_type_display', 'original_date', 'new_date', 'status_display', 'is_charged', 'created_at')
    list_filter = ('status', 'request_type', 'is_charged', 'created_at')
    search_fields = ('dog__name', 'dog__owner__username')
    readonly_fields = ('dog', 'request_type', 'original_date', 'new_date', 'is_charged', 'created_at', 'updated_at')
    list_per_page = 20
    ordering = ['-created_at']
    actions = ['approve_requests', 'deny_requests']

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

    @admin.action(description='Approve selected requests')
    def approve_requests(self, request, queryset):
        updated = queryset.filter(status='PENDING').update(status='APPROVED')
        self.message_user(request, f'{updated} request(s) approved.')

    @admin.action(description='Deny selected requests')
    def deny_requests(self, request, queryset):
        updated = queryset.filter(status='PENDING').update(status='DENIED')
        self.message_user(request, f'{updated} request(s) denied.')
