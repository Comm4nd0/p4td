from django.core.paginator import Paginator
from django.shortcuts import render, get_object_or_404, redirect
from django.core.mail import send_mail
from django.conf import settings
from django.contrib import messages
from django.views.decorators.cache import cache_control

from .models import BlogPost, ServicePricing, SiteSettings, Testimonial
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


def services(request):
    pricing = ServicePricing.load()
    return render(request, 'website/services.html', {'pricing': pricing})


def field_hire(request):
    pricing = ServicePricing.load()
    return render(request, 'website/field_hire.html', {'pricing': pricing})


def contact(request):
    if request.method == 'POST':
        form = ContactForm(request.POST)
        if form.is_valid():
            inquiry = form.save()
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
