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


class SiteSettings(models.Model):
    # Hero Section
    hero_video = models.FileField(
        upload_to='website/',
        blank=True,
        null=True,
        help_text='Background video for the homepage hero section (MP4 recommended).',
    )
    hero_title = models.CharField(
        max_length=200,
        default='Dog Day Care in Berkshire & Buckinghamshire',
        help_text='Main heading displayed over the hero image/video.',
    )

    # Welcome Section
    welcome_title = models.CharField(
        max_length=200,
        default='Welcome',
        help_text='Heading for the welcome section.',
    )
    welcome_text = models.TextField(
        default=(
            'Welcome to our dog day care website, serving the Berkshire and '
            'Buckinghamshire area! As a pet owner, you know that your dog deserves '
            'the best care and attention possible, and that\'s exactly what we '
            'provide. Our dog day care services offer a safe and fun environment '
            'for your dog to play, exercise and socialize with other dogs, all '
            'under the watchful eye of our experienced and caring staff. Whether '
            'you\'re at work, running errands or simply need a break, we\'re here '
            'to give your pup the attention and care they need, so you can have '
            'peace of mind knowing that your dog is happy and well taken care of.'
        ),
        help_text='Welcome section body text. HTML is allowed.',
    )

    # Day Care Section
    daycare_title = models.CharField(
        max_length=200,
        default='Day Care',
        help_text='Heading for the day care section.',
    )
    daycare_text = models.TextField(
        default=(
            '<p>At our dog day care centre, we understand that every dog is unique '
            'and has different needs. That\'s why we offer specialized areas for '
            'play, learning, exercise and agility, all designed to cater to your '
            'dog\'s individual requirements. Our outdoor facilities cover 10 acres '
            'of land, providing ample space for dogs of all sizes to run and play '
            'in a secure environment.</p>'
            '<p>We also have multiple fields that are divided into groups, so your '
            'dog can play and socialize with dogs of similar size and temperament.</p>'
            '<p>Our staff are highly trained and experienced in handling dogs of all '
            'breeds and personalities, and are committed to providing the highest '
            'standard of care to your dog. And to make things even more convenient '
            'for you, we offer pick up and drop off services, so you don\'t have to '
            'worry about transportation. With our dog day care services, your dog '
            'will receive the love, attention, and care they deserve, all while '
            'having a blast with their dog.</p>'
        ),
        help_text='Day care section body text. HTML is allowed.',
    )

    # Puppy Classes Section
    puppy_classes_title = models.CharField(
        max_length=200,
        default='Puppy Classes',
        help_text='Heading for the puppy classes section.',
    )
    puppy_classes_text = models.TextField(
        default=(
            '<p>Our puppy classes are a great way to give your dog a head start in '
            'life. Our classes run on-site for a duration of four weeks, providing '
            'a comprehensive training program that covers all the essential skills '
            'your puppy needs to learn. We use positive reinforcement techniques to '
            'teach your pup basic commands like sit, stay, come, and lose lead '
            'walking, as well as important socialization skills such as proper '
            'behaviour around other dogs and humans.</p>'
            '<p>Puppy classes are ideal because they provide a structured and safe '
            'environment for your pup to learn and develop, and it also provides '
            'the opportunity for you to bond with your dog. By attending our puppy '
            'classes, you\'ll not only be helping your puppy to become a '
            'well-behaved and obedient companion but also ensuring that they have '
            'the necessary socialization skills to interact positively with other '
            'dogs and people throughout their life.</p>'
        ),
        help_text='Puppy classes section body text. HTML is allowed.',
    )

    # One 2 One Training Section
    training_title = models.CharField(
        max_length=200,
        default='One 2 One Training',
        help_text='Heading for the one-to-one training section.',
    )
    training_text = models.TextField(
        default=(
            '<p>At Paws 4 Thought Dogs, we understand that every dog has unique '
            'needs and personality traits, which is why we offer personalized '
            'one-to-one training sessions. We will work with you and your dog to '
            'identify any areas of concern or behaviour issues that need to be '
            'addressed. We use positive reinforcement techniques to teach your dog '
            'new commands and behaviours, as well as provide solutions to any '
            'problem behaviours your dog may be exhibiting.</p>'
            '<p>Our one-to-one training sessions are tailored to your specific '
            'needs, and can cover anything from basic obedience to advanced skills '
            'such as agility training. With our one-to-one training, you\'ll '
            'receive personalised attention and support throughout the entire '
            'training process, ensuring that you and your dog achieve your goals '
            'together. We are passionate about working with dogs and are committed '
            'to helping you develop a strong and positive relationship with your '
            'dog. Whether you\'re a first-time dog owner or a seasoned pro, our '
            'one-to-one training sessions are the perfect way to help your dog '
            'reach their full potential.</p>'
        ),
        help_text='One-to-one training section body text. HTML is allowed.',
    )

    # Contact CTA Section
    cta_title = models.CharField(
        max_length=200,
        default='Get in Touch',
        help_text='Heading for the contact call-to-action section.',
    )
    cta_subtitle = models.CharField(
        max_length=300,
        default="Interested in our services? We'd love to hear from you.",
        help_text='Subtitle text below the contact CTA heading.',
    )

    class Meta:
        verbose_name = 'Site settings'
        verbose_name_plural = 'Site settings'

    def __str__(self):
        return 'Site Settings'

    def save(self, *args, **kwargs):
        # Ensure only one instance exists
        self.pk = 1
        super().save(*args, **kwargs)

    @classmethod
    def load(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


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
