part of 'data_service.dart';

abstract class DataService {
  Future<List<Dog>> getDogs();
  Future<Dog> getDogById(String dogId);
  Future<List<Photo>> getPhotos(String dogId);
  Future<Photo> uploadPhoto(String dogId, Uint8List imageBytes, String imageName, DateTime takenAt);
  Future<List<Photo>> uploadMultiplePhotos(String dogId, List<(Uint8List, String, DateTime)> images);
  Future<UserProfile> getProfile();
  Future<void> updateProfile(UserProfile profile);
  Future<void> updateStaffColor(String hexColor);
  Future<UserProfile> uploadProfilePhoto(Uint8List imageBytes, String imageName);
  Future<UserProfile> deleteProfilePhoto();
  Future<OwnerProfile> getOwnerProfile(int userId);
  Future<OwnerProfile> updateOwnerProfile(int userId, {String? address, String? phoneNumber, String? pickupInstructions});
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, String? registeredVet, String? address, String? postcode, String? accessInstructions, String? vanPlacement, String? generalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed, bool clearDateOfBirth = false});
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, String? registeredVet, String? address, String? postcode, String? accessInstructions, String? vanPlacement, String? generalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare, String? ownerId, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed});
  Future<UnspayedMalesResult> getUnspayedMales();
  Future<List<PostcodeAddress>> lookupPostcode(String postcode);
  Future<void> deleteDog(String dogId);
  Future<Dog> assignDogToUser(String dogId, {int? owner, List<int>? additionalOwners, bool removeOwner = false});
  Future<List<OwnerProfile>> getOwners();
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId});
  Future<void> updateDateChangeRequestStatus(String requestId, String status);
  Future<void> submitDateChangeRequest({
    required String dogId,
    required DateTime originalDate,
    DateTime? newDate,
  });
  Future<void> submitAdditionalDayRequest({
    required String dogId,
    required DateTime requestedDate,
  });
  Future<List<gm.GroupMedia>> getFeed({String? dogId});
  Future<FeedPage> getFeedPage({String? dogId, int page = 1});
  Future<void> uploadGroupMedia({
    required Uint8List fileBytes,
    required String fileName,
    required bool isVideo,
    String? caption,
    Uint8List? thumbnailBytes,
    List<String>? taggedDogIds,
  });
  Future<List<({int index, String fileName, Object error})>>
      uploadMultipleGroupMedia({
    required List<(Uint8List, String)> files,
    String? caption,
    List<String?>? captionsByFile,
    List<List<String>>? taggedDogIdsByFile,
    void Function(int completed, int total)? onProgress,
  });
  Future<void> deleteGroupMedia(String mediaId);
  Future<gm.GroupMedia> updateGroupMedia(String mediaId, {String? caption, List<String>? taggedDogIds});
  Future<gm.GroupMedia> toggleReaction(String mediaId, String emoji);
  Future<void> addComment(String mediaId, String text, {bool isProfilePhoto = false});
  Future<void> deleteComment(String commentId);
  Future<List<BoardingRequest>> getBoardingRequests();
  Future<void> updateBoardingRequestStatus(int requestId, String status, {int? assignedStaffId});
  Future<void> assignBoardingStaff(int requestId, int? staffId);
  Future<void> deleteBoardingRequest(int requestId);
  Future<void> updateBoardingRequest(
    int requestId, {
    DateTime? startDate,
    DateTime? endDate,
    String? specialInstructions,
  });
  Future<void> createBoardingRequest({
    required List<int> dogIds,
    required DateTime startDate,
    required DateTime endDate,
    String? specialInstructions,
    int? ownerId,
  });
  Future<List<Map<String, dynamic>>> getReactionDetails(String mediaId);
  Future<void> registerDeviceToken(String token, String deviceType);
  Future<void> deregisterDeviceToken(String token);
  Future<List<DailyDogAssignment>> getMyAssignments({DateTime? date});
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date});
  Future<List<Dog>> getUnassignedDogs({DateTime? date});
  Future<AssignDogsResult> assignDogsToMe(List<int> dogIds, {DateTime? date});
  Future<AssignDogsResult> assignDogs(List<int> dogIds, int staffMemberId, {DateTime? date});
  Future<List<Map<String, dynamic>>> getStaffMembers();
  Future<DailyDogAssignment> updateAssignmentStatus(int assignmentId, AssignmentStatus status);
  Future<DailyDogAssignment> setAssignmentTransport(
    int assignmentId, {
    required bool? ownerBrings,
    required bool? ownerCollects,
    required TimeOfDay? ownerBringsTime,
    required TimeOfDay? ownerCollectsTime,
  });
  Future<DailyDogAssignment> reassignDog(
    int assignmentId,
    int newStaffMemberId, {
    AssignmentScope scope = AssignmentScope.justThisDay,
  });
  Future<void> unassignDog(
    int assignmentId, {
    AssignmentScope scope = AssignmentScope.justThisDay,
  });
  Future<void> removeDogFromDay(int dogId, DateTime date);
  Future<Map<String, dynamic>> swapStaff({
    required int fromStaffId,
    required int toStaffId,
    required SwapScope scope,
    DateTime? date,
  });
  Future<List<Map<String, dynamic>>> getWeekdayRoster({int? weekday, int? staffMemberId});
  Future<Map<String, dynamic>> getSuggestedAssignments({DateTime? date});
  Future<Map<String, dynamic>> autoAssign({DateTime? date});
  Future<void> sendTrafficAlert(String alertType, {DateTime? date, String? detail, List<int>? dogIds});
  Future<void> reorderAssignments(List<int> assignmentIds);
  Future<List<CompatibilityConflict>> getCompatibilityConflicts({DateTime? date});

  // Support Queries
  Future<List<SupportQuery>> getSupportQueries();
  Future<SupportQuery> getSupportQuery(int queryId);
  Future<SupportQuery> createSupportQuery({required String subject, required String initialMessage});
  Future<SupportQuery> createStaffQuery({required int ownerId, required String subject, required String initialMessage});
  Future<SupportQuery> addQueryMessage(int queryId, String text);
  Future<SupportQuery> resolveQuery(int queryId);
  Future<SupportQuery> reopenQuery(int queryId);
  Future<void> markQueryRead(int queryId);
  Future<int> getUnresolvedQueryCount();

  // Contact Inquiries
  Future<List<ContactInquiry>> getContactInquiries();
  Future<ContactInquiry> markInquiryRead(int inquiryId);
  Future<ContactInquiry> markInquiryUnread(int inquiryId);
  Future<ContactInquiry> markInquiryReplied(int inquiryId);
  Future<void> deleteInquiry(int inquiryId);
  Future<int> getUnreadInquiryCount();

  // Feed Stats
  Future<Map<String, int>> getFeedTodayStats();

  // Closure Days
  Future<List<ClosureDay>> getClosureDays({DateTime? fromDate, DateTime? toDate});
  Future<ClosureDay> createClosureDay({required DateTime date, required ClosureType closureType, String reason = '', int? capacityOverride});
  Future<void> deleteClosureDay(int id);

  // Vaccinations
  Future<List<VaccinationRecord>> getVaccinations(String dogId);
  Future<VaccinationRecord> createVaccination({required String dogId, required String name, required DateTime dateAdministered, required DateTime expiryDate, String? notes});
  Future<VaccinationRecord> updateVaccination(int id, {String? name, DateTime? dateAdministered, DateTime? expiryDate, String? notes});
  Future<void> deleteVaccination(int id);

  // Owner calendar & waitlist
  Future<OwnerCalendar> getOwnerCalendar({DateTime? start, DateTime? end});
  Future<WaitlistEntry> joinWaitlist({required String dogId, required DateTime date});
  Future<void> leaveWaitlist(int entryId);

  // Dog Notes
  Future<List<DogNote>> getDogNotes({int? dogId, String? noteType});
  Future<DogNote> createDogNote({required int dogId, int? relatedDogId, required DogNoteType noteType, required String text, bool isPositive = true});
  Future<void> updateDogNote(int noteId, {String? text, bool? isPositive});
  Future<void> deleteDogNote(int noteId);

  // Staff Availability
  Future<List<StaffAvailability>> getMyAvailability();
  Future<List<StaffAvailability>> setMyAvailability(List<Map<String, dynamic>> availability);
  Future<Map<String, dynamic>> getStaffCoverage();
  Future<List<Map<String, dynamic>>> getAvailableStaffForDate(DateTime date);
  /// Approved staff time off in [start]..[end], grouped by date (names only).
  /// Visible to all staff for the shared team calendar.
  Future<Map<DateTime, List<String>>> getTeamTimeOff({required DateTime start, required DateTime end});

  // Day Off Requests
  Future<List<DayOffRequest>> getMyDayOffRequests();
  Future<DayOffRequest> requestDayOff({required DateTime date, String? reason});
  Future<void> cancelDayOffRequest(int requestId);
  Future<List<DayOffRequest>> getAllDayOffRequests();
  Future<DayOffRequest> approveDayOffRequest(int requestId);
  Future<DayOffRequest> denyDayOffRequest(int requestId);

  // Booking Forms (intake requests)
  Future<List<IntakeRequest>> getIntakeRequests();
  Future<IntakeRequest> submitIntakeRequest({
    String? phoneNumber,
    String? address,
    String? postcode,
    String? pickupInstructions,
    String? additionalInfo,
    required List<IntakeDog> dogs,
  });
  Future<IntakeRequest> approveIntakeRequest(int requestId);
  Future<IntakeRequest> denyIntakeRequest(int requestId, {String? reason});
  Future<void> deleteIntakeRequest(int requestId);

  // Dog Profile Change Requests
  Future<List<DogProfileChangeRequest>> getDogProfileChangeRequests({String? status});
  Future<DogProfileChangeRequest> approveDogProfileChange(int requestId);
  Future<DogProfileChangeRequest> rejectDogProfileChange(int requestId);
  Future<int> getPendingDogProfileChangeCount();

  // Staff Permissions (superuser only)
  Future<List<StaffPermission>> listStaffPermissions();
  Future<StaffPermission> updateStaffPermissions(int userId, Map<String, bool> permissions);

  // Fleet (staff only; writes require can_manage_vehicles)
  Future<List<Vehicle>> getVehicles();
  Future<Vehicle> getVehicle(int id);
  Future<Vehicle> createVehicle({required String name, required String registration, String? make, String? model, String? notes, String? status, DateTime? motDueDate, DateTime? serviceDueDate, Uint8List? imageBytes, String? imageName});
  Future<Vehicle> updateVehicle(int id, {String? name, String? registration, String? make, String? model, String? notes, String? status, DateTime? motDueDate, DateTime? serviceDueDate, String? maintenanceNotes, Uint8List? imageBytes, String? imageName});
  Future<void> deleteVehicle(int id);
  Future<List<VehicleMaintenanceRecord>> getVehicleHistory(int vehicleId);
  Future<List<VehicleDefect>> getVehicleDefects({int? vehicleId, String? status});
  Future<VehicleDefect> getVehicleDefect(int id);
  Future<VehicleDefect> createVehicleDefect({required int vehicleId, required String title, String? description, String? severity, List<(Uint8List, String)> images = const []});
  Future<VehicleDefect> addDefectImages(int defectId, List<(Uint8List, String)> images);
  Future<VehicleDefect> changeDefectStatus(int defectId, String status);
  Future<VehicleDefect> addVehicleDefectComment(int defectId, String text);
  Future<int> getUnresolvedVehicleDefectCount();
  Future<List<FacilityDefect>> getFacilityDefects({String? status});
  Future<FacilityDefect> getFacilityDefect(int id);
  Future<FacilityDefect> createFacilityDefect({required String title, String? location, String? description, String? severity, List<(Uint8List, String)> images = const []});
  Future<FacilityDefect> addFacilityDefectImages(int defectId, List<(Uint8List, String)> images);
  Future<FacilityDefect> changeFacilityDefectStatus(int defectId, String status);
  Future<FacilityDefect> addFacilityDefectComment(int defectId, String text);
  Future<int> getUnresolvedFacilityDefectCount();

  // Customer payments (owners see their own invoices; workflow actions
  // require can_manage_payments)
  Future<List<Invoice>> getInvoices({int? year, int? month, String? status, int? customerId});
  Future<Invoice> getInvoice(int id);
  Future<({int created, int skipped, int manual})> generateInvoices(int year, int month, {int? customerId});
  Future<Invoice> sendInvoice(int id);
  Future<int> sendAllInvoices(int year, int month);
  Future<Invoice> regenerateInvoice(int id);
  Future<Invoice> recordInvoicePayment(int id, {required double amount, required String method, DateTime? paymentDate, String? notes});
  Future<Invoice> voidInvoice(int id);
  Future<Invoice> addInvoiceLine(int id, {required String description, required double amount});
  Future<Invoice> removeInvoiceLine(int id, int lineId);
  Future<Invoice> pushInvoiceToXero(int id);
  Future<Map<String, dynamic>> syncXeroInvoices();
  Future<String> getInvoicePayUrl(int id);
  Future<InvoiceSummary> getInvoiceSummary({int? year, int? month});
  Future<BillingSettings> getBillingSettings();
  Future<BillingSettings> updateBillingSettings({double? dayCarePrice, double? boardingPricePerNight, double? ownerTransportDiscount});
  Future<List<CustomerRate>> getCustomerRates();
  Future<CustomerRate> updateCustomerRates(int userId, {required double? daycareRate, required double? boardingRate, String? billingMode});

  // Xero contact reconciliation (invoicing transition): match app customers
  // to their existing Xero contacts and pin the right one.
  Future<XeroContactMatches> getXeroContactMatches();
  Future<CustomerRate> pinXeroContact(int userId, String contactId);
  Future<List<XeroContact>> searchXeroContacts(String query);
}
