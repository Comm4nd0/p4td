part of 'data_service.dart';

/// One file of a batch upload that failed after all retries.
typedef UploadFailure = ({int index, String fileName, Object error});

/// Outcome of a multi-photo upload: which photos made it, which files didn't.
typedef PhotoBatchResult = ({List<Photo> uploaded, List<UploadFailure> failures});

abstract class DataService {
  Future<List<Dog>> getDogs();
  Future<Dog> getDogById(String dogId);

  /// Synchronous reads of the offline cache, for rendering instantly before a
  /// network refresh completes. Null means cache miss. [CachedEntry.cachedAt]
  /// drives "saved data from HH:mm" staleness indicators.
  CachedEntry<List<Dog>>? cachedDogs();
  CachedEntry<Dog>? cachedDogById(String dogId);
  CachedEntry<List<DailyDogAssignment>>? cachedTodayAssignments(DateTime date);
  Future<List<Photo>> getPhotos(String dogId);
  Future<Photo> uploadPhoto(String dogId, Uint8List imageBytes, String imageName, DateTime takenAt);
  Future<PhotoBatchResult> uploadMultiplePhotos(
    String dogId,
    List<(Uint8List, String, DateTime)> images, {
    void Function(int completed, int total)? onProgress,
  });
  Future<UserProfile> getProfile();
  Future<void> updateProfile(UserProfile profile);
  Future<void> updateStaffColor(String hexColor);
  Future<UserProfile> uploadProfilePhoto(Uint8List imageBytes, String imageName);
  Future<UserProfile> deleteProfilePhoto();
  Future<OwnerProfile> getOwnerProfile(int userId);
  Future<OwnerProfile> updateOwnerProfile(int userId, {String? address, String? phoneNumber, String? pickupInstructions});
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, String? registeredVet, String? contactNumber, String? emergencyContactNumber, String? address, String? postcode, String? accessInstructions, String? vanPlacement, String? generalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed, bool clearDateOfBirth = false, DateTime? lastVaccinationDate, bool clearLastVaccinationDate = false});
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, String? registeredVet, String? contactNumber, String? emergencyContactNumber, String? address, String? postcode, String? accessInstructions, String? vanPlacement, String? generalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare, String? ownerId, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed, DateTime? lastVaccinationDate});
  /// Staff dashboard: neutered status to confirm + vaccinations over a year old.
  Future<DogHealthFlags> getDogHealthFlags();
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

  /// Past dates the dog actually attended (staff-only). Feeds the profile
  /// calendar's past booked days so payment managers can edit history.
  Future<List<DateTime>> getDogPastAttendance(String dogId, {DateTime? from});
  Future<List<gm.GroupMedia>> getFeed({String? dogId});
  Future<FeedPage> getFeedPage({String? dogId, int page = 1});
  Future<void> uploadGroupMedia({
    required Uint8List fileBytes,
    required String fileName,
    required bool isVideo,
    String? caption,
    Uint8List? thumbnailBytes,
    List<String>? taggedDogIds,
    void Function(int sentBytes, int totalBytes)? onSendProgress,
  });
  Future<List<UploadFailure>> uploadMultipleGroupMedia({
    required List<(Uint8List, String)> files,
    String? caption,
    List<String?>? captionsByFile,
    List<List<String>>? taggedDogIdsByFile,
    void Function(int completed, int total)? onProgress,
    void Function(int index, int sentBytes, int totalBytes)? onFileProgress,
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

  /// Photo-tagging progress for a day: how many of the day's dogs have been
  /// tagged in feed media posted that day, and which still need tagging.
  Future<PhotoTaggingStatus> getPhotoTagging({DateTime? date});

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

  // Vaccination certificates (private files — see VaccinationCertificate)
  Future<List<VaccinationCertificate>> getVaccinationCertificates(String dogId);
  Future<VaccinationCertificate> uploadVaccinationCertificate({
    required String dogId,
    required Uint8List bytes,
    required String filename,
    DateTime? vaccinationDate,
  });
  Future<void> deleteVaccinationCertificate(int id);
  /// The file bytes, fetched with the auth token through the gated download view.
  Future<Uint8List> downloadVaccinationCertificate(int id);

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
  /// Weekly availability rows for another staff member (staff managers).
  Future<List<StaffAvailability>> getStaffAvailability(int staffId);
  /// Set another staff member's weekly availability (staff managers).
  Future<List<StaffAvailability>> setStaffAvailability(int staffId, List<Map<String, dynamic>> availability);
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

  // Incidents (staff only — the API refuses owners outright)
  Future<List<Incident>> getIncidents({String? dogId, String? status, bool openOnly = false});
  Future<Incident> getIncident(int id);
  Future<Incident> createIncident({
    required String title,
    required String incidentType,
    required String severity,
    required DateTime occurredAt,
    required List<IncidentDogEntry> dogs,
    String? location,
    String? description,
    String? injuries,
    String? actionTaken,
    bool vetRequired = false,
    String? vetDetails,
    List<int> staffPresentIds = const [],
    List<(Uint8List, String)> media = const [],
  });
  Future<Incident> addIncidentMedia(int incidentId, List<(Uint8List, String)> media);
  Future<Incident> changeIncidentStatus(int incidentId, String status, {String? resolutionNotes});
  Future<Incident> addIncidentComment(int incidentId, String text);
  Future<Incident> setIncidentOwnerNotified(int incidentId, String dogId, bool notified);
  Future<int> getOpenIncidentCount();

  // Customer payments (owners see their own invoices; workflow actions
  // require can_manage_payments)
  Future<List<Invoice>> getInvoices({int? year, int? month, String? status, int? customerId});
  Future<Invoice> getInvoice(int id);
  /// Generate draft invoices for a month from attendance: the whole month,
  /// one [customerId], or one [dogId] (in the dog's name — the draft lands in
  /// Xero for the business to assign the customer there).
  Future<InvoiceGenerationResult> generateInvoices(int year, int month, {int? customerId, int? dogId});
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

  /// Roadworks disrupting the day's routes, already matched by the server to
  /// the staff and dogs they affect. Staff-only; owners get a 403.
  Future<List<RoadworkIssue>> getRoadworks({DateTime? date});

  // Xero contact reconciliation (invoicing transition): match app customers
  // to their existing Xero contacts and pin the right one.
  Future<XeroContactMatches> getXeroContactMatches();
  Future<CustomerRate> pinXeroContact(int userId, String contactId);
  Future<List<XeroContact>> searchXeroContacts(String query);

  // --- Staff management (HR) — manager-only, gated by can_manage_staff ---
  Future<List<TeamMemberOverview>> getStaffTeamOverview();
  Future<StaffHrRecord> getStaffHrRecord(int staffId);
  Future<StaffHrRecord> updateStaffHrRecord(int recordId, Map<String, dynamic> fields);
  Future<List<StaffPayRate>> getStaffPayRates(int staffId);
  Future<StaffPayRate> createStaffPayRate(Map<String, dynamic> fields);
  Future<void> deleteStaffPayRate(int id);
  Future<List<StaffMeeting>> getStaffMeetings({int? staffId});
  Future<StaffMeeting> createStaffMeeting(Map<String, dynamic> fields);
  Future<StaffMeeting> updateStaffMeeting(int id, Map<String, dynamic> fields);
  Future<void> deleteStaffMeeting(int id);
  Future<List<StaffAppraisal>> getStaffAppraisals({int? staffId});
  Future<StaffAppraisal> createStaffAppraisal(Map<String, dynamic> fields);
  Future<StaffAppraisal> updateStaffAppraisal(int id, Map<String, dynamic> fields);
  Future<StaffAppraisal> shareStaffAppraisal(int id);
  Future<List<SicknessAbsence>> getSicknessAbsences({int? staffId});
  Future<SicknessAbsence> createSicknessAbsence(Map<String, dynamic> fields);
  Future<SicknessAbsence> updateSicknessAbsence(int id, Map<String, dynamic> fields);
  Future<void> deleteSicknessAbsence(int id);
  Future<List<StaffTrainingRecord>> getStaffTrainingRecords({int? staffId});
  Future<StaffTrainingRecord> createStaffTrainingRecord(Map<String, dynamic> fields);
  Future<void> deleteStaffTrainingRecord(int id);

  // --- Safety & compliance register ---
  Future<List<ComplianceCheck>> getComplianceChecks({bool includeInactive = false});
  Future<ComplianceCheck> createComplianceCheck(Map<String, dynamic> fields);
  Future<ComplianceCheck> updateComplianceCheck(int id, Map<String, dynamic> fields);
  Future<List<ComplianceLog>> getComplianceLogs(int checkTypeId);
  Future<ComplianceLog> logComplianceCheck(Map<String, dynamic> fields);
}
