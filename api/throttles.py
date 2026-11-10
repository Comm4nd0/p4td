"""Throttles that count every caller, signed in or not.

DRF's ``AnonRateThrottle`` skips any request that carries a valid token. Sign-up
is self-service, so on a public endpoint that made the limit optional: create
an account, send its token, and the password-reset code check (a six-digit
code) or the contact form could be hammered without ever being counted. The
classes here key on the client IP (``get_ident``, which honours
``NUM_PROXIES``) or on the account being targeted, and never look at
``request.user``.

Rates live in ``REST_FRAMEWORK['DEFAULT_THROTTLE_RATES']`` under each class's
``scope``.
"""
from django.contrib.auth.signals import user_login_failed
from django.dispatch import receiver
from rest_framework.throttling import SimpleRateThrottle


class IdentRateThrottle(SimpleRateThrottle):
    """Per client IP, whoever is (or isn't) signed in."""

    def get_cache_key(self, request, view):
        return self.cache_format % {'scope': self.scope, 'ident': self.get_ident(request)}


class TargetRateThrottle(SimpleRateThrottle):
    """Per account being targeted — the ``target_field`` of the request body
    (an email or username), case-insensitive — from any number of IPs. A
    request without the field isn't counted here; the view's own validation
    rejects it."""
    target_field = 'email'

    def get_cache_key(self, request, view):
        data = request.data
        value = data.get(self.target_field) if hasattr(data, 'get') else None
        if not isinstance(value, str) or not value.strip():
            return None
        # Hashed: cache keys have a length limit and may not hold spaces.
        import hashlib
        digest = hashlib.sha256(value.strip().lower().encode('utf-8')).hexdigest()
        return self.cache_format % {'scope': self.scope, 'ident': digest}


class PasswordResetRequestThrottle(IdentRateThrottle):
    """Reset-code emails per client IP."""
    scope = 'password_reset'


class PasswordResetRequestEmailThrottle(TargetRateThrottle):
    """Reset-code emails per mailbox — each one replaces the last code, so
    without this anyone could keep a customer's code permanently stale (and
    their inbox full) from a pool of addresses."""
    scope = 'password_reset_email'


class PasswordResetConfirmThrottle(IdentRateThrottle):
    """Code / reset-token attempts per client IP."""
    scope = 'password_reset_confirm'


class PasswordResetConfirmEmailThrottle(TargetRateThrottle):
    """Code attempts per account, from anywhere."""
    scope = 'password_reset_confirm_email'


class LoginIPThrottle(IdentRateThrottle):
    scope = 'login_ip'


class LoginUsernameThrottle(TargetRateThrottle):
    """Sign-in attempts per account, from anywhere — password guessing spread
    over many addresses still lands on one username."""
    scope = 'login_username'
    target_field = 'username'


class ContactInquiryCreateThrottle(IdentRateThrottle):
    """Enquiry submissions per client IP."""
    scope = 'contact_inquiry'


ADMIN_LOGIN_SCOPE = 'admin_login'
ADMIN_LOGIN_MAX_FAILURES = 10
ADMIN_LOGIN_WINDOW_SECONDS = 15 * 60


def _admin_login_key(request):
    from rest_framework.throttling import BaseThrottle
    return 'throttle_%s_%s' % (ADMIN_LOGIN_SCOPE, BaseThrottle().get_ident(request))


def admin_login_blocked(request):
    """True once this IP has used up its failed Django-admin sign-ins.

    The admin is a plain Django view, so DRF throttles never see it; this
    counts *failed* attempts only (via ``user_login_failed`` below), so a
    working password is never locked out by its own success.
    """
    from django.core.cache import cache
    return cache.get(_admin_login_key(request), 0) >= ADMIN_LOGIN_MAX_FAILURES


@receiver(user_login_failed, dispatch_uid='api.throttles.count_admin_login_failure')
def _count_admin_login_failure(sender, credentials=None, request=None, **kwargs):
    if request is None or not request.path.startswith('/admin/'):
        return
    from django.core.cache import cache
    key = _admin_login_key(request)
    if cache.add(key, 1, ADMIN_LOGIN_WINDOW_SECONDS):
        return
    try:
        cache.incr(key)
    except ValueError:
        cache.set(key, 1, ADMIN_LOGIN_WINDOW_SECONDS)


from rest_framework.throttling import UserRateThrottle  # noqa: E402


class PostcodeLookupThrottle(UserRateThrottle):
    """Address lookups per signed-in user — each one that misses the cache is
    a paid call to the provider."""
    scope = 'postcode_lookup'
