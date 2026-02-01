from django.db import models
from django.contrib.auth.models import User

from django.db.models.signals import post_save
from django.dispatch import receiver

class UserProfile(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name='profile')
    address = models.TextField(blank=True, null=True)
    phone_number = models.CharField(max_length=20, blank=True, null=True)
    pickup_instructions = models.TextField(blank=True, null=True)

    def __str__(self):
        return f"Profile for {self.user.username}"

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

    owner = models.ForeignKey(User, on_delete=models.CASCADE, related_name='dogs')
    name = models.CharField(max_length=100)
    profile_image = models.ImageField(upload_to='dog_profiles/', null=True, blank=True)
    food_instructions = models.TextField(blank=True, null=True)
    medical_notes = models.TextField(blank=True, null=True)
    daycare_days = models.JSONField(default=list, blank=True, help_text='List of day numbers (1-7) for daycare attendance')
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

from django.core.exceptions import ObjectDoesNotExist

@receiver(post_save, sender=User)
def create_user_profile(sender, instance, created, **kwargs):
    if created:
        UserProfile.objects.create(user=instance)

@receiver(post_save, sender=User)
def save_user_profile(sender, instance, **kwargs):
    try:
        instance.profile.save()
    except ObjectDoesNotExist:
        UserProfile.objects.create(user=instance)

class Photo(models.Model):
    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='photos')
    image = models.ImageField(upload_to='dog_photos/')
    taken_at = models.DateTimeField()
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Photo of {self.dog.name} at {self.taken_at}"

class DateChangeRequest(models.Model):
    REQUEST_TYPE_CHOICES = [
        ('CANCEL', 'Cancellation'),
        ('CHANGE', 'Date Change'),
    ]

    STATUS_CHOICES = [
        ('PENDING', 'Pending'),
        ('APPROVED', 'Approved'),
        ('DENIED', 'Denied'),
    ]

    dog = models.ForeignKey(Dog, on_delete=models.CASCADE, related_name='date_change_requests')
    request_type = models.CharField(max_length=10, choices=REQUEST_TYPE_CHOICES)
    original_date = models.DateField()
    new_date = models.DateField(null=True, blank=True)
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='PENDING')
    is_charged = models.BooleanField(default=False, help_text='Whether the original date is within 1 month and will be charged')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        if self.request_type == 'CANCEL':
            return f"{self.dog.name} - Cancel {self.original_date}"
        return f"{self.dog.name} - Change {self.original_date} to {self.new_date}"

class GroupMedia(models.Model):
    MEDIA_TYPE_CHOICES = [
        ('PHOTO', 'Photo'),
        ('VIDEO', 'Video'),
    ]

    uploaded_by = models.ForeignKey(User, on_delete=models.CASCADE, related_name='uploaded_media')
    media_type = models.CharField(max_length=10, choices=MEDIA_TYPE_CHOICES)
    file = models.FileField(upload_to='group_media/')
    thumbnail = models.ImageField(upload_to='group_media/thumbnails/', null=True, blank=True)
    caption = models.TextField(blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']
        verbose_name_plural = 'Group media'

    def __str__(self):
        return f"{self.media_type} by {self.uploaded_by.username} at {self.created_at}"
