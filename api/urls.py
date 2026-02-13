from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import DogViewSet, PhotoViewSet, UserProfileViewSet, DateChangeRequestViewSet, GroupMediaViewSet, CommentViewSet, BoardingRequestViewSet, DeviceTokenViewSet, DailyDogAssignmentViewSet, SupportQueryViewSet

router = DefaultRouter()
router.register(r'profile', UserProfileViewSet, basename='profile')
router.register(r'dogs', DogViewSet, basename='dog')
router.register(r'photos', PhotoViewSet, basename='photo')
router.register(r'date-change-requests', DateChangeRequestViewSet, basename='date-change-request')
router.register(r'feed', GroupMediaViewSet, basename='feed')
router.register(r'comments', CommentViewSet, basename='comment')
router.register(r'boarding-requests', BoardingRequestViewSet, basename='boarding-requests')
router.register(r'device-tokens', DeviceTokenViewSet, basename='device-tokens')
router.register(r'daily-assignments', DailyDogAssignmentViewSet, basename='daily-assignments')
router.register(r'support-queries', SupportQueryViewSet, basename='support-queries')

urlpatterns = [
    path('', include(router.urls)),
]
