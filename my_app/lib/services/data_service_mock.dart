part of 'data_service.dart';

class MockDataService implements DataService {
  final _dogs = [
    Dog(
      id: '1',
      name: 'Buddy',
      ownerId: 'user1',
      profileImageUrl: 'https://images.unsplash.com/photo-1552053831-71594a27632d?auto=format&fit=crop&w=500&q=60',
    ),
    Dog(
      id: '2',
      name: 'Bella',
      ownerId: 'user1',
      profileImageUrl: 'https://images.unsplash.com/photo-1583511655857-d19b40a7a54e?auto=format&fit=crop&w=500&q=60',
    ),
  ];

  @override
  Future<List<Dog>> getDogs() async {
    await Future.delayed(const Duration(milliseconds: 500)); // Simulate network
    return _dogs;
  }
  
  @override
  Future<UserProfile> getProfile() async {
    return UserProfile(username: 'test', email: 'test@example.com');
  }

  @override
  Future<void> updateProfile(UserProfile profile) async {}

  @override
  Future<UserProfile> uploadProfilePhoto(Uint8List imageBytes, String imageName) async {
    return UserProfile(username: 'test', email: 'test@example.com');
  }

  @override
  Future<UserProfile> deleteProfilePhoto() async {
    return UserProfile(username: 'test', email: 'test@example.com');
  }

  @override
  Future<OwnerProfile> getOwnerProfile(int userId) async {
    return OwnerProfile(
      userId: userId,
      username: 'john_doe',
      email: 'john@example.com',
      address: '123 Main St',
      phoneNumber: '555-1234',
      pickupInstructions: 'Ring doorbell twice',
    );
  }

  @override
  Future<OwnerProfile> updateOwnerProfile(int userId, {String? address, String? phoneNumber, String? pickupInstructions}) async {
    return OwnerProfile(
      userId: userId,
      username: 'john_doe',
      email: 'john@example.com',
      address: address ?? '123 Main St',
      phoneNumber: phoneNumber ?? '555-1234',
      pickupInstructions: pickupInstructions ?? 'Ring doorbell twice',
    );
  }

  @override
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed, bool clearDateOfBirth = false}) async {
    await Future.delayed(const Duration(milliseconds: 300)); // Simulate network
    final index = _dogs.indexWhere((d) => d.id == dog.id);
    if (index == -1) {
      throw Exception('Dog not found');
    }
    final updatedDog = _dogs[index].copyWith(
      name: name,
      foodInstructions: foodInstructions,
      medicalNotes: medicalNotes,
      daysInDaycare: daysInDaycare,
      profileImageUrl: deletePhoto ? null : _dogs[index].profileImageUrl,
      sex: sex,
      dateOfBirth: clearDateOfBirth ? null : dateOfBirth,
      isSpayed: isSpayed,
    );
    _dogs[index] = updatedDog;
    return updatedDog;
  }

  @override
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare, String? ownerId, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed}) async {
    return Dog(
      id: '99',
      name: name,
      ownerId: 'user1',
      sex: sex,
      dateOfBirth: dateOfBirth,
      isSpayed: isSpayed ?? false,
    );
  }

  @override
  Future<UnspayedMalesResult> getUnspayedMales() async {
    return UnspayedMalesResult(count: 0, dogs: const []);
  }

  @override
  Future<void> deleteDog(String dogId) async {
    _dogs.removeWhere((d) => d.id == dogId);
  }

  @override
  Future<Dog> assignDogToUser(String dogId, {int? owner, List<int>? additionalOwners}) async {
    final index = _dogs.indexWhere((d) => d.id == dogId);
    if (index == -1) throw Exception('Dog not found');
    return _dogs[index];
  }

  @override
  Future<List<Photo>> getPhotos(String dogId) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return [
      Photo(
        id: 'p1',
        dogId: dogId,
        url: 'https://images.unsplash.com/photo-1548199973-03cce0bbc87b?auto=format&fit=crop&w=500&q=60',
        takenAt: DateTime.now().subtract(const Duration(days: 1)),
        comments: const [],
      ),
      Photo(
        id: 'p2',
        dogId: dogId,
        url: 'https://images.unsplash.com/photo-1591769225440-811ad7d6eca6?auto=format&fit=crop&w=500&q=60',
        takenAt: DateTime.now().subtract(const Duration(days: 3)),
        comments: const [],
      ),
      Photo(
        id: 'p3',
        dogId: dogId,
        url: 'https://images.unsplash.com/photo-1587300003388-59208cc962cb?auto=format&fit=crop&w=500&q=60',
        takenAt: DateTime.now().subtract(const Duration(days: 5)),
        comments: const [],
      ),
    ];
  }

  @override
  Future<Photo> uploadPhoto(String dogId, Uint8List imageBytes, String imageName, DateTime takenAt) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return Photo(
      id: 'p_new',
      dogId: dogId,
      url: 'https://images.unsplash.com/photo-1548199973-03cce0bbc87b?auto=format&fit=crop&w=500&q=60',
      takenAt: takenAt,
      comments: const [],
    );
  }

  @override
  Future<List<Photo>> uploadMultiplePhotos(String dogId, List<(Uint8List, String, DateTime)> images) async {
    await Future.delayed(const Duration(milliseconds: 500));
    final photos = <Photo>[];
    for (int i = 0; i < images.length; i++) {
      photos.add(Photo(
        id: 'p_new_$i',
        dogId: dogId,
        url: 'https://images.unsplash.com/photo-1548199973-03cce0bbc87b?auto=format&fit=crop&w=500&q=60',
        takenAt: images[i].$3,
        comments: const [],
      ));
    }
    return photos;
  }

  @override
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId}) async {
    return [];
  }

  @override
  Future<void> updateDateChangeRequestStatus(String requestId, String status) async {
    // Mock implementation
  }


  @override
  Future<List<gm.GroupMedia>> getFeed({String? dogId}) async => [];
  @override
  Future<Map<String, int>> getFeedTodayStats() async => {};

  @override
  Future<void> uploadGroupMedia({
    required Uint8List fileBytes,
    required String fileName,
    required bool isVideo,
    String? caption,
    Uint8List? thumbnailBytes,
    List<String>? taggedDogIds,
  }) async {}

  @override
  Future<List<({int index, String fileName, Object error})>>
      uploadMultipleGroupMedia({
    required List<(Uint8List, String)> files,
    String? caption,
    List<String?>? captionsByFile,
    List<List<String>>? taggedDogIdsByFile,
    void Function(int completed, int total)? onProgress,
  }) async => [];

  @override
  Future<void> deleteGroupMedia(String mediaId) async {}

  @override
  Future<gm.GroupMedia> updateGroupMedia(String mediaId, {String? caption, List<String>? taggedDogIds}) async {
    throw UnimplementedError();
  }

  @override
  Future<gm.GroupMedia> toggleReaction(String mediaId, String emoji) async {
    throw UnimplementedError();
  }

  @override
  Future<List<Map<String, dynamic>>> getReactionDetails(String mediaId) async {
    return [];
  }

  @override
  Future<List<BoardingRequest>> getBoardingRequests() async {
    return [];
  }

  @override
  Future<void> createBoardingRequest({
    required List<int> dogIds,
    required DateTime startDate,
    required DateTime endDate,
    String? specialInstructions,
    int? ownerId,
  }) async {}

  @override
  Future<List<OwnerProfile>> getOwners() async {
    return [
      OwnerProfile(userId: 1, username: 'user1', email: 'user1@example.com'),
      OwnerProfile(userId: 2, username: 'user2', email: 'user2@example.com'),
    ];
  }

  @override
  Future<void> addComment(String mediaId, String text, {bool isProfilePhoto = false}) async {}

  @override
  Future<void> deleteComment(String commentId) async {}

  @override
  Future<void> registerDeviceToken(String token, String deviceType) async {}

  @override
  Future<List<DailyDogAssignment>> getMyAssignments({DateTime? date}) async => [];

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) async => [];

  @override
  Future<List<CompatibilityConflict>> getCompatibilityConflicts({DateTime? date}) async => [];

  @override
  Future<List<Dog>> getUnassignedDogs({DateTime? date}) async => [];

  @override
  Future<AssignDogsResult> assignDogsToMe(List<int> dogIds, {DateTime? date}) async => AssignDogsResult(created: []);

  @override
  Future<AssignDogsResult> assignDogs(List<int> dogIds, int staffMemberId, {DateTime? date}) async => AssignDogsResult(created: []);

  @override
  Future<List<Map<String, dynamic>>> getStaffMembers() async => [];

  @override
  Future<DailyDogAssignment> updateAssignmentStatus(int assignmentId, AssignmentStatus status) async {
    throw UnimplementedError();
  }

  @override
  Future<DailyDogAssignment> setAssignmentTransport(
    int assignmentId, {
    required bool? ownerBrings,
    required bool? ownerCollects,
    required TimeOfDay? ownerBringsTime,
    required TimeOfDay? ownerCollectsTime,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<DailyDogAssignment> reassignDog(
    int assignmentId,
    int newStaffMemberId, {
    AssignmentScope scope = AssignmentScope.justThisDay,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> unassignDog(
    int assignmentId, {
    AssignmentScope scope = AssignmentScope.justThisDay,
  }) async {}

  @override
  Future<void> removeDogFromDay(int dogId, DateTime date) async {}

  @override
  Future<Map<String, dynamic>> swapStaff({
    required int fromStaffId,
    required int toStaffId,
    required SwapScope scope,
    DateTime? date,
  }) async =>
      {'roster_rows_updated': 0, 'assignment_rows_updated': 0};

  @override
  Future<List<Map<String, dynamic>>> getWeekdayRoster({int? weekday, int? staffMemberId}) async => [];

  @override
  Future<Map<String, dynamic>> getSuggestedAssignments({DateTime? date}) async => {};

  @override
  Future<Map<String, dynamic>> autoAssign({DateTime? date}) async => {};

  @override
  Future<void> sendTrafficAlert(String alertType, {DateTime? date, String? detail, List<int>? dogIds}) async {}

  @override
  Future<void> reorderAssignments(List<int> assignmentIds) async {}

  @override
  Future<List<SupportQuery>> getSupportQueries() async => [];
  @override
  Future<SupportQuery> getSupportQuery(int queryId) async => throw UnimplementedError();
  @override
  Future<SupportQuery> createSupportQuery({required String subject, required String initialMessage}) async => throw UnimplementedError();
  @override
  Future<SupportQuery> createStaffQuery({required int ownerId, required String subject, required String initialMessage}) async => throw UnimplementedError();
  @override
  Future<SupportQuery> addQueryMessage(int queryId, String text) async => throw UnimplementedError();
  @override
  Future<SupportQuery> resolveQuery(int queryId) async => throw UnimplementedError();
  @override
  Future<SupportQuery> reopenQuery(int queryId) async => throw UnimplementedError();
  @override
  Future<void> markQueryRead(int queryId) async {}
  @override
  Future<int> getUnresolvedQueryCount() async => 0;

  // Contact Inquiries
  @override
  Future<List<ContactInquiry>> getContactInquiries() async => [];
  @override
  Future<ContactInquiry> markInquiryRead(int inquiryId) async => throw UnimplementedError();
  @override
  Future<ContactInquiry> markInquiryUnread(int inquiryId) async => throw UnimplementedError();
  @override
  Future<int> getUnreadInquiryCount() async => 0;
  @override
  Future<ContactInquiry> markInquiryReplied(int inquiryId) async => throw UnimplementedError();
  @override
  Future<void> deleteInquiry(int inquiryId) async {}

  // Closure Days
  @override
  Future<List<ClosureDay>> getClosureDays({DateTime? fromDate, DateTime? toDate}) async => [];
  @override
  Future<ClosureDay> createClosureDay({required DateTime date, required ClosureType closureType, String reason = ''}) async => throw UnimplementedError();
  @override
  Future<void> deleteClosureDay(int id) async {}

  // Dog Notes
  @override
  Future<List<DogNote>> getDogNotes({int? dogId, String? noteType}) async => [];
  @override
  Future<DogNote> createDogNote({required int dogId, int? relatedDogId, required DogNoteType noteType, required String text, bool isPositive = true}) async => throw UnimplementedError();
  @override
  Future<void> updateDogNote(int noteId, {String? text, bool? isPositive}) async {}
  @override
  Future<void> deleteDogNote(int noteId) async {}

  // Staff Availability
  @override
  Future<List<StaffAvailability>> getMyAvailability() async => [];
  @override
  Future<List<StaffAvailability>> setMyAvailability(List<Map<String, dynamic>> availability) async => [];
  @override
  Future<Map<String, dynamic>> getStaffCoverage() async => {};
  @override
  Future<List<Map<String, dynamic>>> getAvailableStaffForDate(DateTime date) async => [];
  @override
  Future<List<DayOffRequest>> getMyDayOffRequests() async => [];
  @override
  Future<DayOffRequest> requestDayOff({required DateTime date, String? reason}) async =>
      DayOffRequest(id: 1, staffMemberId: 1, staffMemberName: 'Test', date: date, createdAt: DateTime.now());
  @override
  Future<void> cancelDayOffRequest(int requestId) async {}
  @override
  Future<List<DayOffRequest>> getAllDayOffRequests() async => [];
  @override
  Future<DayOffRequest> approveDayOffRequest(int requestId) async =>
      DayOffRequest(id: requestId, staffMemberId: 1, staffMemberName: 'Test', date: DateTime.now(), status: DayOffStatus.approved, createdAt: DateTime.now());
  @override
  Future<DayOffRequest> denyDayOffRequest(int requestId) async =>
      DayOffRequest(id: requestId, staffMemberId: 1, staffMemberName: 'Test', date: DateTime.now(), status: DayOffStatus.denied, createdAt: DateTime.now());

  // Dog Profile Change Requests
  @override
  Future<List<DogProfileChangeRequest>> getDogProfileChangeRequests({String? status}) async => [];
  @override
  Future<DogProfileChangeRequest> approveDogProfileChange(int requestId) async =>
      DogProfileChangeRequest(id: requestId, dogId: 1, dogName: 'Test', requestedById: 1, requestedByName: 'Test', proposedChanges: {}, status: 'APPROVED', createdAt: DateTime.now());
  @override
  Future<DogProfileChangeRequest> rejectDogProfileChange(int requestId) async =>
      DogProfileChangeRequest(id: requestId, dogId: 1, dogName: 'Test', requestedById: 1, requestedByName: 'Test', proposedChanges: {}, status: 'REJECTED', createdAt: DateTime.now());
  @override
  Future<int> getPendingDogProfileChangeCount() async => 0;

  // Staff Permissions (superuser only)
  @override
  Future<List<StaffPermission>> listStaffPermissions() async => [];
  @override
  Future<StaffPermission> updateStaffPermissions(int userId, Map<String, bool> permissions) async =>
      StaffPermission(userId: userId, username: 'test', email: 'test@example.com');
}
