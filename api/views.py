from rest_framework import viewsets, mixins
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from .models import Dog, Booking, Photo, UserProfile
from .serializers import DogSerializer, BookingSerializer, PhotoSerializer, UserProfileSerializer

class UserProfileViewSet(mixins.RetrieveModelMixin, mixins.UpdateModelMixin, viewsets.GenericViewSet):
    serializer_class = UserProfileSerializer
    permission_classes = [IsAuthenticated]

    def get_object(self):
        # Always return the profile of the current user
        return self.request.user.profile

    def list(self, request, *args, **kwargs):
        # Override list to return current user's profile (singleton pattern)
        instance = self.get_object()
        serializer = self.get_serializer(instance)
        return Response(serializer.data)

    def create(self, request, *args, **kwargs):
        # Use create endpoint for PATCH/PUT since we're using list route
        return self.partial_update(request, *args, **kwargs)

    def partial_update(self, request, *args, **kwargs):
        instance = self.get_object()
        serializer = self.get_serializer(instance, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)

class DogViewSet(viewsets.ModelViewSet):
    serializer_class = DogSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        # Staff can see all dogs, Clients only see their own
        if self.request.user.is_staff:
            return Dog.objects.all()
        return Dog.objects.filter(owner=self.request.user)

    def perform_create(self, serializer):
        # Automatically assign the owner
        serializer.save(owner=self.request.user)

class BookingViewSet(viewsets.ModelViewSet):
    serializer_class = BookingSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        if self.request.user.is_staff:
            return Booking.objects.all()
        return Booking.objects.filter(dog__owner=self.request.user)

class PhotoViewSet(viewsets.ModelViewSet):
    serializer_class = PhotoSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        if self.request.user.is_staff:
            return Photo.objects.all()
        return Photo.objects.filter(dog__owner=self.request.user)
