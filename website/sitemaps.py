from django.contrib.sitemaps import Sitemap
from django.urls import reverse

from .models import BlogPost


class BlogPostSitemap(Sitemap):
    changefreq = 'weekly'
    priority = 0.8

    def items(self):
        return BlogPost.objects.filter(status='published')

    def lastmod(self, obj):
        return obj.updated_at


class StaticPagesSitemap(Sitemap):
    changefreq = 'monthly'
    priority = 0.6

    def items(self):
        return ['website:home', 'website:blog_list', 'website:field_hire',
                'website:contact', 'website:privacy_policy']

    def location(self, item):
        return reverse(item)
