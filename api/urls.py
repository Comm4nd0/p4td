from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import DogViewSet, BookingViewSet, PhotoViewSet, UserProfileViewSet, BreedViewSet

router = DefaultRouter()
router.register(r'breeds', BreedViewSet, basename='breed')
router.register(r'profile', UserProfileViewSet, basename='profile')
router.register(r'dogs', DogViewSet, basename='dog')
router.register(r'bookings', BookingViewSet, basename='booking')
router.register(r'photos', PhotoViewSet, basename='photo')

urlpatterns = [
    path('', include(router.urls)),
]
