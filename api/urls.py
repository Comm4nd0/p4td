from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import DogViewSet, PhotoViewSet, UserProfileViewSet, DateChangeRequestViewSet, GroupMediaViewSet

router = DefaultRouter()
router.register(r'profile', UserProfileViewSet, basename='profile')
router.register(r'dogs', DogViewSet, basename='dog')
router.register(r'photos', PhotoViewSet, basename='photo')
router.register(r'date-change-requests', DateChangeRequestViewSet, basename='date-change-request')
router.register(r'feed', GroupMediaViewSet, basename='feed')

urlpatterns = [
    path('', include(router.urls)),
]
