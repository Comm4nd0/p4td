from django.db import models
from django.utils import timezone
from django.utils.text import slugify


class BlogPost(models.Model):
    STATUS_CHOICES = [
        ('draft', 'Draft'),
        ('published', 'Published'),
    ]

    title = models.CharField(max_length=200)
    slug = models.SlugField(max_length=200, unique=True, blank=True)
    excerpt = models.TextField(
        max_length=300,
        help_text='Short summary shown on the blog listing page.',
    )
    body = models.TextField(help_text='Full blog post content. HTML is allowed.')
    featured_image = models.ImageField(
        upload_to='blog/',
        blank=True,
        null=True,
        help_text='Main image for the blog post.',
    )
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='draft')
    published_at = models.DateTimeField(blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-published_at']

    def __str__(self):
        return self.title

    def save(self, *args, **kwargs):
        if not self.slug:
            self.slug = slugify(self.title)
        if self.status == 'published' and not self.published_at:
            self.published_at = timezone.now()
        super().save(*args, **kwargs)


class ContactInquiry(models.Model):
    SERVICE_CHOICES = [
        ('daycare', 'Daycare'),
        ('one2one', 'One 2 One Training'),
        ('puppy_classes', 'Puppy Classes'),
        ('field_hire', 'Field Hire'),
        ('other', 'Other'),
    ]

    name = models.CharField(max_length=100)
    email = models.EmailField()
    service = models.CharField(max_length=20, choices=SERVICE_CHOICES)
    message = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)
    is_read = models.BooleanField(default=False)

    class Meta:
        ordering = ['-created_at']
        verbose_name = 'Contact inquiry'
        verbose_name_plural = 'Contact inquiries'

    def __str__(self):
        return f"{self.name} - {self.get_service_display()} ({self.created_at:%Y-%m-%d})"
