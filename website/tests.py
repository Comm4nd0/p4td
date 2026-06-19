from unittest import mock

from django.contrib.auth.models import User
from django.core import mail
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse

from .forms import ContactForm, MESSAGE_MAX_LENGTH
from .models import BlogPost, ContactInquiry, ServicePricing, SiteSettings

# Production uses a manifest static-files storage (whitenoise), which requires a
# built manifest from collectstatic. Tests render templates with {% static %}
# tags, so fall back to the plain storage that resolves paths without a manifest.
_TEST_STORAGES = {
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {
        'BACKEND': 'django.contrib.staticfiles.storage.StaticFilesStorage'
    },
}


def _patch_recaptcha():
    """Make django-recaptcha's field always validate, returning the patcher."""
    return mock.patch(
        'django_recaptcha.fields.ReCaptchaField.validate',
        return_value=True,
    )


def _patch_push():
    """Silence the post_save push-notification side effect."""
    return mock.patch(
        'api.notifications.send_push_notification',
        return_value=None,
    )


def _valid_payload(**overrides):
    data = {
        'name': 'Alice Example',
        'email': 'alice@example.com',
        'service': 'daycare',
        'message': 'I would like to book daycare for my dog.',
        'website': '',  # honeypot left empty
        'g-recaptcha-response': 'test-token',
    }
    data.update(overrides)
    return data


class ContactFormTests(TestCase):
    def setUp(self):
        cache.clear()

    @override_settings(RECAPTCHA_PRIVATE_KEY='')
    def test_captcha_dropped_when_key_blank(self):
        """W1: no captcha field when reCAPTCHA private key is unconfigured."""
        form = ContactForm()
        self.assertNotIn('captcha', form.fields)
        # Form still validates without a captcha token.
        form = ContactForm(data=_valid_payload())
        self.assertTrue(form.is_valid(), form.errors)

    @override_settings(RECAPTCHA_PRIVATE_KEY='configured-key')
    def test_captcha_present_when_key_set(self):
        """W1: captcha field kept when a private key is configured."""
        form = ContactForm()
        self.assertIn('captcha', form.fields)

    def test_message_max_length_enforced(self):
        """W2: message length is capped via the form field."""
        form = ContactForm(data=_valid_payload(message='x' * (MESSAGE_MAX_LENGTH + 1)))
        self.assertFalse(form.is_valid())
        self.assertIn('message', form.errors)

    def test_honeypot_detection(self):
        form = ContactForm(data=_valid_payload(website='http://spam.example'))
        self.assertTrue(form.is_valid(), form.errors)
        self.assertTrue(form.is_spam())


@override_settings(RECAPTCHA_PRIVATE_KEY='', STORAGES=_TEST_STORAGES)
class ContactViewTests(TestCase):
    def setUp(self):
        cache.clear()
        self.url = reverse('website:contact')

    def test_get_renders_form(self):
        resp = self.client.get(self.url)
        self.assertEqual(resp.status_code, 200)
        self.assertIsInstance(resp.context['form'], ContactForm)

    def test_post_happy_path_creates_inquiry_and_emails(self):
        with _patch_recaptcha(), _patch_push():
            resp = self.client.post(self.url, _valid_payload())
        self.assertEqual(resp.status_code, 302)
        self.assertEqual(ContactInquiry.objects.count(), 1)
        inquiry = ContactInquiry.objects.get()
        self.assertEqual(inquiry.email, 'alice@example.com')
        # W5: email sent with reply_to set to the inquirer.
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(mail.outbox[0].reply_to, ['alice@example.com'])

    def test_honeypot_drops_submission(self):
        with _patch_recaptcha(), _patch_push():
            resp = self.client.post(
                self.url, _valid_payload(website='http://spam.example')
            )
        self.assertEqual(resp.status_code, 302)
        self.assertEqual(ContactInquiry.objects.count(), 0)
        self.assertEqual(len(mail.outbox), 0)

    def test_rate_limit_kicks_in(self):
        with _patch_recaptcha(), _patch_push():
            for i in range(5):
                resp = self.client.post(
                    self.url, _valid_payload(email=f'user{i}@example.com')
                )
                self.assertEqual(resp.status_code, 302)
            # 6th submission within the window is throttled.
            resp = self.client.post(
                self.url, _valid_payload(email='blocked@example.com')
            )
        self.assertEqual(resp.status_code, 429)
        self.assertEqual(ContactInquiry.objects.count(), 5)


@override_settings(STORAGES=_TEST_STORAGES)
class BlogTests(TestCase):
    def setUp(self):
        cache.clear()
        self.published = BlogPost.objects.create(
            title='Published Post',
            excerpt='A published post.',
            body='<p>Hello world</p>',
            status='published',
        )
        self.draft = BlogPost.objects.create(
            title='Draft Post',
            excerpt='A draft post.',
            body='<p>Not live yet</p>',
            status='draft',
        )

    def test_blog_list_shows_only_published(self):
        resp = self.client.get(reverse('website:blog_list'))
        self.assertEqual(resp.status_code, 200)
        posts = list(resp.context['posts'])
        self.assertIn(self.published, posts)
        self.assertNotIn(self.draft, posts)

    def test_blog_detail_published(self):
        resp = self.client.get(
            reverse('website:blog_detail', args=[self.published.slug])
        )
        self.assertEqual(resp.status_code, 200)

    def test_blog_detail_draft_404(self):
        resp = self.client.get(
            reverse('website:blog_detail', args=[self.draft.slug])
        )
        self.assertEqual(resp.status_code, 404)

    def test_blog_detail_unknown_slug_404(self):
        resp = self.client.get(
            reverse('website:blog_detail', args=['does-not-exist'])
        )
        self.assertEqual(resp.status_code, 404)

    def test_save_sets_slug_and_published_at(self):
        post = BlogPost.objects.create(
            title='Fresh New Post',
            excerpt='x',
            body='<p>body</p>',
            status='published',
        )
        self.assertEqual(post.slug, 'fresh-new-post')
        self.assertIsNotNone(post.published_at)

    def test_save_sanitizes_script(self):
        post = BlogPost.objects.create(
            title='XSS Post',
            excerpt='x',
            body='<p>Safe</p><script>alert(1)</script>',
            status='published',
        )
        self.assertNotIn('<script>', post.body)
        self.assertIn('Safe', post.body)


class SiteSettingsTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_save_sanitizes_script(self):
        settings_obj = SiteSettings.load()
        settings_obj.welcome_text = '<p>Welcome</p><script>alert(1)</script>'
        settings_obj.save()
        refreshed = SiteSettings.objects.get(pk=1)
        self.assertNotIn('<script>', refreshed.welcome_text)
        self.assertIn('Welcome', refreshed.welcome_text)

    def test_load_is_cached(self):
        first = SiteSettings.load()
        cached = SiteSettings.load()
        self.assertEqual(first.pk, cached.pk)
        # A cold cache must still produce a working instance.
        cache.clear()
        self.assertIsNotNone(SiteSettings.load())

    def test_save_invalidates_cache(self):
        obj = SiteSettings.load()
        obj.hero_title = 'Updated Title'
        obj.save()
        self.assertEqual(SiteSettings.load().hero_title, 'Updated Title')


class ServicePricingTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_load_cached_and_save_refreshes(self):
        pricing = ServicePricing.load()
        self.assertIsNotNone(pricing)
        pricing.day_care_price = 99.99
        pricing.save()
        self.assertEqual(float(ServicePricing.load().day_care_price), 99.99)


class SitemapTests(TestCase):
    def setUp(self):
        cache.clear()
        self.published = BlogPost.objects.create(
            title='Sitemap Post',
            excerpt='x',
            body='<p>body</p>',
            status='published',
        )
        BlogPost.objects.create(
            title='Sitemap Draft',
            excerpt='x',
            body='<p>body</p>',
            status='draft',
        )

    def test_sitemap_includes_published_and_static_pages(self):
        resp = self.client.get('/sitemap.xml')
        self.assertEqual(resp.status_code, 200)
        content = resp.content.decode()
        # Published blog post present, draft absent.
        self.assertIn(self.published.slug, content)
        self.assertNotIn('sitemap-draft', content)
        # Expected static pages, including services (W6).
        for name in ('services', 'field-hire', 'contact', 'blog', 'privacy-policy'):
            self.assertIn(f'/{name}', content)


@override_settings(STORAGES=_TEST_STORAGES)
class BlogUnpublishAdminTests(TestCase):
    def setUp(self):
        cache.clear()
        self.admin = User.objects.create_superuser(
            'admin', 'admin@example.com', 'pass1234'
        )
        self.client.force_login(self.admin)

    def test_unpublish_action_only_affects_published(self):
        published = BlogPost.objects.create(
            title='Live Post', excerpt='x', body='<p>b</p>', status='published'
        )
        draft = BlogPost.objects.create(
            title='Draft Already', excerpt='x', body='<p>b</p>', status='draft'
        )
        resp = self.client.post(
            reverse('admin:website_blogpost_changelist'),
            {
                'action': 'unpublish_posts',
                '_selected_action': [published.pk, draft.pk],
            },
            follow=True,
        )
        self.assertEqual(resp.status_code, 200)
        published.refresh_from_db()
        self.assertEqual(published.status, 'draft')
        # Message should report only 1 post changed (the previously published one).
        messages_text = ' '.join(str(m) for m in resp.context['messages'])
        self.assertIn('1 post(s) set to draft', messages_text)
