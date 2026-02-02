from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from django.views.generic import TemplateView

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('api.urls')),
    path('auth/', include('djoser.urls')),
    path('auth/', include('djoser.urls.authtoken')),
    path('privacy-policy/', TemplateView.as_view(template_name='privacy-policy.html'), name='privacy-policy'),
] + static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)

