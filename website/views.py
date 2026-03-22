from django.shortcuts import render, get_object_or_404, redirect
from django.core.mail import send_mail
from django.conf import settings
from django.contrib import messages

from .models import BlogPost, SiteSettings
from .forms import ContactForm


def home(request):
    featured_posts = BlogPost.objects.filter(
        status='published'
    ).order_by('-published_at')[:2]
    site_settings = SiteSettings.load()
    return render(request, 'website/home.html', {
        'featured_posts': featured_posts,
        'site_settings': site_settings,
    })


def blog_list(request):
    posts = BlogPost.objects.filter(status='published')
    return render(request, 'website/blog_list.html', {
        'posts': posts,
    })


def blog_detail(request, slug):
    post = get_object_or_404(BlogPost, slug=slug, status='published')
    return render(request, 'website/blog_detail.html', {
        'post': post,
    })


def field_hire(request):
    return render(request, 'website/field_hire.html')


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
