part of 'data_service.dart';

abstract class DataService {
  Future<List<Dog>> getDogs();
  Future<List<Photo>> getPhotos(String dogId);
  Future<Photo> uploadPhoto(String dogId, Uint8List imageBytes, String imageName, DateTime takenAt);
  Future<List<Photo>> uploadMultiplePhotos(String dogId, List<(Uint8List, String, DateTime)> images);
  Future<UserProfile> getProfile();
  Future<void> updateProfile(UserProfile profile);
  Future<UserProfile> uploadProfilePhoto(Uint8List imageBytes, String imageName);
  Future<UserProfile> deleteProfilePhoto();
  Future<OwnerProfile> getOwnerProfile(int userId);
  Future<OwnerProfile> updateOwnerProfile(int userId, {String? address, String? phoneNumber, String? pickupInstructions});
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, String? registeredVet, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed, bool clearDateOfBirth = false});
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, String? registeredVet, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare, String? ownerId, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed});
  Future<UnspayedMalesResult> getUnspayedMales();
  Future<List<PostcodeAddress>> lookupPostcode(String postcode);
  Future<void> deleteDog(String dogId);
  Future<Dog> assignDogToUser(String dogId, {int? owner, List<int>? additionalOwners, bool removeOwner = false});
  Future<List<OwnerProfile>> getOwners();
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId});
  Future<void> updateDateChangeRequestStatus(String requestId, String status);
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
  Future<void> createBoardingRequest({
    required List<int> dogIds,
    required DateTime startDate,
    required DateTime endDate,
    String? specialInstructions,
    int? ownerId,
  });
  Future<List<Map<String, dynamic>>> getReactionDetails(String mediaId);
  Future<void> registerDeviceToken(String token, String deviceType);
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

  // Dog Profile Change Requests
  Future<List<DogProfileChangeRequest>> getDogProfileChangeRequests({String? status});
  Future<DogProfileChangeRequest> approveDogProfileChange(int requestId);
  Future<DogProfileChangeRequest> rejectDogProfileChange(int requestId);
  Future<int> getPendingDogProfileChangeCount();

  // Staff Permissions (superuser only)
  Future<List<StaffPermission>> listStaffPermissions();
  Future<StaffPermission> updateStaffPermissions(int userId, Map<String, bool> permissions);
}
