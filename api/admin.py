from django.contrib import admin
from .models import Dog, Photo, UserProfile

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
