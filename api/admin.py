from django.contrib import admin
from .models import Dog, Booking, Photo, UserProfile

@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ('user', 'phone_number', 'address')
    search_fields = ('user__username', 'phone_number', 'address')

@admin.register(Dog)
class DogAdmin(admin.ModelAdmin):
    list_display = ('name', 'owner', 'created_at')
    search_fields = ('name', 'owner__username')
    list_filter = ('created_at',)

@admin.register(Booking)
class BookingAdmin(admin.ModelAdmin):
    list_display = ('dog', 'date', 'status', 'created_at')
    list_filter = ('status', 'date')
    search_fields = ('dog__name', 'notes')

@admin.register(Photo)
class PhotoAdmin(admin.ModelAdmin):
    list_display = ('dog', 'taken_at', 'created_at')
    list_filter = ('taken_at',)
