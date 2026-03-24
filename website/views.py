from django.core.cache import cache
from django.core.paginator import Paginator
from django.shortcuts import render, get_object_or_404, redirect
from django.core.mail import send_mail
from django.conf import settings
from django.contrib import messages
from django.views.decorators.cache import cache_control

from .models import BlogPost, SiteSettings, Testimonial
from .forms import ContactForm


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


def field_hire(request):
    return render(request, 'website/field_hire.html')


def _get_client_ip(request):
    x_forwarded = request.META.get('HTTP_X_FORWARDED_FOR')
    return x_forwarded.split(',')[0].strip() if x_forwarded else request.META.get('REMOTE_ADDR')


def contact(request):
    if request.method == 'POST':
        # Rate limit: max 3 submissions per IP per hour
        ip = _get_client_ip(request)
        cache_key = f'contact_rate_{ip}'
        submissions = cache.get(cache_key, 0)
        if submissions >= 3:
            messages.error(
                request,
                'Too many submissions. Please try again later.'
            )
            return redirect('website:contact')

        form = ContactForm(request.POST)
        if form.is_valid():
            inquiry = form.save()
            cache.set(cache_key, submissions + 1, 3600)  # 1 hour TTL
            try:
                send_mail(
                    subject=f'New Contact Inquiry: {inquiry.get_service_display()}',
                    message=(
                        f'Name: {inquiry.name}\n'
                        f'Email: {inquiry.email}\n'
                        f'Service: {inquiry.get_service_display()}\n\n'
                        f'Message:\n{inquiry.message}'
                    ),
                    from_email=settings.DEFAULT_FROM_EMAIL,
                    recipient_list=[settings.DEFAULT_FROM_EMAIL],
                    fail_silently=True,
                )
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
