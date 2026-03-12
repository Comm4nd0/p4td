from django.contrib import admin
from django.utils.html import format_html

from .models import BlogPost, ContactInquiry


@admin.register(BlogPost)
class BlogPostAdmin(admin.ModelAdmin):
    list_display = ('title', 'status_display', 'published_at', 'updated_at')
    list_filter = ('status', 'published_at')
    search_fields = ('title', 'body')
    prepopulated_fields = {'slug': ('title',)}
    readonly_fields = ('created_at', 'updated_at')
    list_per_page = 20
    ordering = ['-published_at']
    fieldsets = (
        (None, {
            'fields': ('title', 'slug', 'status', 'published_at'),
        }),
        ('Content', {
            'fields': ('excerpt', 'body', 'featured_image'),
        }),
        ('Metadata', {
            'fields': ('created_at', 'updated_at'),
            'classes': ('collapse',),
        }),
    )
    actions = ['publish_posts', 'unpublish_posts']

    def status_display(self, obj):
        colors = {'draft': '#ffc107', 'published': '#198754'}
        return format_html(
            '<span style="background-color: {}; padding: 3px 8px; '
            'border-radius: 3px; color: white;">{}</span>',
            colors.get(obj.status, '#6c757d'),
            obj.get_status_display()
        )
    status_display.short_description = 'Status'

    def publish_posts(self, request, queryset):
        from django.utils import timezone
        updated = queryset.filter(status='draft').update(
            status='published', published_at=timezone.now()
        )
        self.message_user(request, f'{updated} post(s) published.')
    publish_posts.short_description = 'Publish selected posts'

    def unpublish_posts(self, request, queryset):
        queryset.update(status='draft')
        self.message_user(request, 'Selected posts set to draft.')
    unpublish_posts.short_description = 'Unpublish selected posts'


@admin.register(ContactInquiry)
class ContactInquiryAdmin(admin.ModelAdmin):
    list_display = ('name', 'email', 'service_display', 'read_display', 'created_at')
    list_filter = ('service', 'is_read', 'created_at')
    search_fields = ('name', 'email', 'message')
    readonly_fields = ('name', 'email', 'service', 'message', 'created_at')
    list_per_page = 20
    ordering = ['-created_at']
    actions = ['mark_as_read']

    def service_display(self, obj):
        return obj.get_service_display()
    service_display.short_description = 'Service'

    def read_display(self, obj):
        if obj.is_read:
            return format_html('<span style="color: #198754;">Read</span>')
        return format_html(
            '<span style="color: #dc3545; font-weight: bold;">Unread</span>'
        )
    read_display.short_description = 'Status'

    def mark_as_read(self, request, queryset):
        updated = queryset.update(is_read=True)
        self.message_user(request, f'{updated} inquiry(ies) marked as read.')
    mark_as_read.short_description = 'Mark selected as read'

    def has_add_permission(self, request):
        return False
