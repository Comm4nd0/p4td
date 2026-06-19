from django.core.paginator import Paginator
from django.shortcuts import render, get_object_or_404, redirect
from django.core.cache import cache
from django.core.mail import EmailMessage
from django.conf import settings
from django.contrib import messages
from django.views.decorators.cache import cache_control

from .models import BlogPost, ServicePricing, SiteSettings, Testimonial
from .forms import ContactForm

# Per-IP throttle on the contact form: at most CONTACT_RATE_LIMIT submissions
# per CONTACT_RATE_WINDOW seconds.
CONTACT_RATE_LIMIT = 5
CONTACT_RATE_WINDOW = 60 * 60  # 1 hour


def _client_ip(request):
    """Best-effort client IP, honouring the first X-Forwarded-For hop."""
    forwarded = request.META.get('HTTP_X_FORWARDED_FOR', '')
    if forwarded:
        return forwarded.split(',')[0].strip()
    return request.META.get('REMOTE_ADDR', '') or 'unknown'


def home(request):
    featured_posts = BlogPost.objects.filter(
        status='published'
    ).order_by('-published_at')[:2]
    site_settings = SiteSettings.load()
    testimonials = Testimonial.objects.filter(is_active=True)[:6]
    return render(request, 'website/home.html', {
        'featured_posts': featured_posts,
        'site_settings': site_settings,
        'testimonials': testimonials,
    })


def blog_list(request):
    all_posts = BlogPost.objects.filter(status='published')
    paginator = Paginator(all_posts, 6)
    page_number = request.GET.get('page')
    posts = paginator.get_page(page_number)
    return render(request, 'website/blog_list.html', {
        'posts': posts,
    })


def blog_detail(request, slug):
    post = get_object_or_404(BlogPost, slug=slug, status='published')
    related_posts = BlogPost.objects.filter(
        status='published'
    ).exclude(pk=post.pk).order_by('-published_at')[:3]
    return render(request, 'website/blog_detail.html', {
        'post': post,
        'related_posts': related_posts,
    })


def services(request):
    pricing = ServicePricing.load()
    return render(request, 'website/services.html', {'pricing': pricing})


def field_hire(request):
    pricing = ServicePricing.load()
    return render(request, 'website/field_hire.html', {'pricing': pricing})


def contact(request):
    if request.method == 'POST':
        # Per-IP rate limit before doing any real work.
        cache_key = f'contact-rl:{_client_ip(request)}'
        attempts = cache.get(cache_key, 0)
        if attempts >= CONTACT_RATE_LIMIT:
            form = ContactForm(request.POST)
            messages.error(
                request,
                'You have sent several messages recently. '
                'Please try again later.'
            )
            return render(request, 'website/contact.html', {
                'form': form,
            }, status=429)

        form = ContactForm(request.POST)
        if form.is_valid():
            # Count every valid submission attempt against the throttle.
            cache.set(cache_key, attempts + 1, CONTACT_RATE_WINDOW)

            # Honeypot tripped -> silently drop as spam (look successful, but
            # don't save or email).
            if form.is_spam():
                messages.success(
                    request,
                    'Thank you! Your message has been received. '
                    'We will be in touch soon.'
                )
                return redirect('website:contact')

            inquiry = form.save()
            recipient = getattr(
                settings, 'CONTACT_INQUIRY_EMAIL', settings.DEFAULT_FROM_EMAIL
            )
            try:
                email = EmailMessage(
                    subject=f'New Contact Inquiry: {inquiry.get_service_display()}',
                    body=(
                        f'Name: {inquiry.name}\n'
                        f'Email: {inquiry.email}\n'
                        f'Service: {inquiry.get_service_display()}\n\n'
                        f'Message:\n{inquiry.message}'
                    ),
                    from_email=settings.DEFAULT_FROM_EMAIL,
                    to=[recipient],
                    reply_to=[inquiry.email],
                )
                email.send(fail_silently=True)
            except Exception:
                pass
            messages.success(
                request,
                'Thank you! Your message has been received. We will be in touch soon.'
            )
            return redirect('website:contact')
    else:
        form = ContactForm()
    return render(request, 'website/contact.html', {
        'form': form,
    })


def privacy_policy(request):
    return render(request, 'website/privacy_policy.html')


@cache_control(max_age=86400)
def robots_txt(request):
    return render(request, 'website/robots.txt', content_type='text/plain')
