from django.contrib import admin
from django.contrib.sitemaps.views import sitemap
from django.http import HttpResponse
from django.urls import path, include, re_path
from django.conf import settings
from django.conf.urls.static import static
from djoser.views import (
    TokenCreateView as DjoserTokenCreateView,
    TokenDestroyView as DjoserTokenDestroyView,
    UserViewSet as DjoserUserViewSet,
)
from rest_framework.throttling import AnonRateThrottle

from api.throttles import LoginIPThrottle, LoginUsernameThrottle, admin_login_blocked

from website.sitemaps import BlogPostSitemap, StaticPagesSitemap

sitemaps = {
    'blog': BlogPostSitemap,
    'static': StaticPagesSitemap,
}


def healthz(request):
    """Liveness probe for Docker/compose healthchecks and the deploy script.

    Returns a plain 200 with no database or external dependency so it stays
    cheap and reflects only that the WSGI app is up and serving requests.
    """
    return HttpResponse('ok', content_type='text/plain')


class ThrottledTokenCreateView(DjoserTokenCreateView):
    """Token login, limited per client IP and per username.

    The project default (AnonRateThrottle) skips any request that carries a
    valid token, and sign-up is self-service — so password guessing against
    someone else's account was unthrottled for anyone who sent their own
    token along. These two count every attempt, signed in or not.
    """
    throttle_classes = [AnonRateThrottle, LoginIPThrottle, LoginUsernameThrottle]


# The Django admin sign-in is a plain view the DRF throttles never see. After
# ADMIN_LOGIN_MAX_FAILURES failed attempts from one address (counted by the
# user_login_failed receiver in api/throttles.py) further attempts are refused
# until the window passes; a correct password is never counted.
_admin_login = admin.site.login


def _throttled_admin_login(request, extra_context=None):
    if request.method == 'POST' and admin_login_blocked(request):
        return HttpResponse(
            'Too many failed sign-in attempts. Try again in 15 minutes.',
            status=429, content_type='text/plain')
    return _admin_login(request, extra_context)


admin.site.login = _throttled_admin_login


urlpatterns = [
    path('healthz/', healthz, name='healthz'),
    path('admin/', admin.site.urls),
    path('summernote/', include('django_summernote.urls')),
    path('api/', include('api.urls')),
    # Only the two djoser surfaces the app uses: sign-up and token login/logout.
    # The full `djoser.urls` router also mounted /auth/users/me/ (PATCH/DELETE
    # the account without the safeguards in api.views.delete_account),
    # set_username, set_password and an email-link reset_password flow that
    # 500s here because PASSWORD_RESET_CONFIRM_URL was never configured — the
    # app's password reset is the OTP flow under /api/password/reset/.
    path('auth/users/', DjoserUserViewSet.as_view({'post': 'create'}), name='user-create'),
    # djoser.urls.authtoken's two routes, spelt out so login can be throttled.
    # (Same patterns as djoser's, optional trailing slash included.)
    re_path(r'^auth/token/login/?$', ThrottledTokenCreateView.as_view(), name='login'),
    re_path(r'^auth/token/logout/?$', DjoserTokenDestroyView.as_view(), name='logout'),
    path('sitemap.xml', sitemap, {'sitemaps': sitemaps},
         name='django.contrib.sitemaps.views.sitemap'),
    path('', include('website.urls')),
]

# Always serve media files through Django (shared Caddy reverse proxy
# doesn't have access to the media volume)
urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
if not settings.DEBUG:
    from django.urls import re_path
    from django.views.static import serve
    urlpatterns += [
        re_path(r'^media/(?P<path>.*)$', serve, {'document_root': settings.MEDIA_ROOT}),
    ]
