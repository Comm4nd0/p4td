from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import (
    DogViewSet, PhotoViewSet, UserProfileViewSet, DateChangeRequestViewSet,
    GroupMediaViewSet, CommentViewSet, BoardingRequestViewSet, DeviceTokenViewSet,
    DailyDogAssignmentViewSet, SupportQueryViewSet, ContactInquiryViewSet,
    ClosureDayViewSet, DogNoteViewSet, StaffAvailabilityViewSet, DayOffRequestViewSet,
    DogProfileChangeRequestViewSet, VaccinationRecordViewSet, WaitlistEntryViewSet,
    VehicleViewSet, VehicleDefectViewSet, FacilityDefectViewSet, IntakeRequestViewSet,
    InvoiceViewSet,
    request_password_reset, verify_otp, reset_password, change_password,
    delete_account, postcode_lookup, daycare_settings,
    xero_status, xero_connect, xero_callback, xero_disconnect,
    billing_settings, customer_rates,
    xero_contact_matches, xero_pin_contact, xero_contact_search,
)

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
router.register(r'closure-days', ClosureDayViewSet, basename='closure-days')
router.register(r'dog-notes', DogNoteViewSet, basename='dog-notes')
router.register(r'staff-availability', StaffAvailabilityViewSet, basename='staff-availability')
router.register(r'day-off-requests', DayOffRequestViewSet, basename='day-off-requests')
router.register(r'contact-inquiries', ContactInquiryViewSet, basename='contact-inquiries')
router.register(r'dog-profile-changes', DogProfileChangeRequestViewSet, basename='dog-profile-changes')
router.register(r'vaccinations', VaccinationRecordViewSet, basename='vaccinations')
router.register(r'waitlist', WaitlistEntryViewSet, basename='waitlist')
router.register(r'vehicles', VehicleViewSet, basename='vehicles')
router.register(r'vehicle-defects', VehicleDefectViewSet, basename='vehicle-defects')
router.register(r'facility-defects', FacilityDefectViewSet, basename='facility-defects')
router.register(r'intake-requests', IntakeRequestViewSet, basename='intake-requests')
router.register(r'invoices', InvoiceViewSet, basename='invoices')

urlpatterns = [
    path('', include(router.urls)),
    path('daycare-settings/', daycare_settings, name='daycare-settings'),
    path('billing-settings/', billing_settings, name='billing-settings'),
    path('customer-rates/', customer_rates, name='customer-rates'),
    path('xero/status/', xero_status, name='xero-status'),
    path('xero/connect/', xero_connect, name='xero-connect'),
    path('xero/callback/', xero_callback, name='xero-callback'),
    path('xero/disconnect/', xero_disconnect, name='xero-disconnect'),
    path('xero/contact-matches/', xero_contact_matches, name='xero-contact-matches'),
    path('xero/pin-contact/', xero_pin_contact, name='xero-pin-contact'),
    path('xero/contacts/', xero_contact_search, name='xero-contact-search'),
    path('password/reset/request/', request_password_reset, name='password-reset-request'),
    path('password/reset/verify/', verify_otp, name='password-reset-verify'),
    path('password/reset/confirm/', reset_password, name='password-reset-confirm'),
    path('password/change/', change_password, name='password-change'),
    path('account/delete/', delete_account, name='account-delete'),
    path('postcode/lookup/', postcode_lookup, name='postcode-lookup'),
]
