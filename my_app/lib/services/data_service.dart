import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;
import '../models/dog.dart';
import '../models/photo.dart';
import '../models/user_profile.dart';
import '../models/date_change_request.dart';
import '../models/owner_profile.dart';
import '../models/group_media.dart' as gm;
import '../models/boarding_request.dart';
import '../models/daily_dog_assignment.dart';
import '../models/support_query.dart';
import '../models/closure_day.dart';
import '../models/dog_note.dart';
import '../models/staff_availability.dart';
import '../models/day_off_request.dart';
import '../models/contact_inquiry.dart';
import 'auth_service.dart';
import 'cache_service.dart';

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
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime});
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare, String? ownerId, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType});
  Future<void> deleteDog(String dogId);
  Future<Dog> assignDogToUser(String dogId, {int? owner, List<int>? additionalOwners});
  Future<List<OwnerProfile>> getOwners();
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId});
  Future<void> updateDateChangeRequestStatus(String requestId, String status);
  Future<List<gm.GroupMedia>> getFeed({String? dogId});
  Future<void> uploadGroupMedia({
    required Uint8List fileBytes,
    required String fileName,
    required bool isVideo,
    String? caption,
    Uint8List? thumbnailBytes,
    List<String>? taggedDogIds,
  });
  Future<void> uploadMultipleGroupMedia({
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
  Future<ClosureDay> createClosureDay({required DateTime date, required ClosureType closureType, String reason = ''});
  Future<void> deleteClosureDay(int id);

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

  // Day Off Requests
  Future<List<DayOffRequest>> getMyDayOffRequests();
  Future<DayOffRequest> requestDayOff({required DateTime date, String? reason});
  Future<void> cancelDayOffRequest(int requestId);
  Future<List<DayOffRequest>> getAllDayOffRequests();
  Future<DayOffRequest> approveDayOffRequest(int requestId);
  Future<DayOffRequest> denyDayOffRequest(int requestId);
}

class ApiDataService implements DataService {
  final _authService = AuthService();

  Future<Map<String, String>> _getHeaders() async {
    final token = await _authService.getToken();
    return {
      'Authorization': 'Token $token',
      'Content-Type': 'application/json',
    };
  }

  List<Dog> _parseDogsList(List<dynamic> data) {
    return data.map((json) {
      final daysInDaycare = (json['daycare_days'] as List<dynamic>?)
          ?.map((day) => Weekday.values.firstWhere(
            (w) => w.dayNumber == day,
            orElse: () => Weekday.monday,
          ))
          .toList() ?? [];

      OwnerDetails? ownerDetails;
      if (json['owner_details'] != null) {
        ownerDetails = OwnerDetails.fromJson(json['owner_details']);
      }
      final additionalOwners = (json['additional_owners_details'] as List<dynamic>?)
          ?.map((o) => OwnerDetails.fromJson(o))
          .toList() ?? [];

      return Dog(
        id: json['id'].toString(),
        name: json['name'],
        ownerId: (json['owner'] ?? '').toString(),
        profileImageUrl: json['profile_image'],
        foodInstructions: json['food_instructions'],
        medicalNotes: json['medical_notes'],
        daysInDaycare: daysInDaycare,
        ownerDetails: ownerDetails,
        additionalOwners: additionalOwners,
        preferredDropoffTime: DropoffTimeExtension.fromApiValue(json['preferred_dropoff_time']),
        scheduleType: ScheduleTypeExtension.fromApiValue(json['schedule_type']),
        ownerBringsDefault: json['owner_brings_default'] ?? false,
        ownerCollectsDefault: json['owner_collects_default'] ?? false,
        ownerBringsDefaultTime: parseApiTime(json['owner_brings_default_time']),
        ownerCollectsDefaultTime: parseApiTime(json['owner_collects_default_time']),
      );
    }).toList();
  }

  @override
  Future<List<Dog>> getDogs() async {
    final cache = CacheService();
    try {
      final headers = await _getHeaders();
      final response = await http.get(Uri.parse('${AuthService.baseUrl}/api/dogs/'), headers: headers);

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        // Cache the raw JSON for offline use
        cache.cacheDogs(data.cast<Map<String, dynamic>>());
        return _parseDogsList(data);
      } else {
        throw Exception('Failed to load dogs');
      }
    } catch (e) {
      // On network error, try to return cached data
      final cached = cache.getCachedDogs();
      if (cached != null && cached.isNotEmpty) {
        return _parseDogsList(cached);
      }
      rethrow;
    }
  }

  @override
  Future<UserProfile> getProfile() async {
    final cache = CacheService();
    try {
      final headers = await _getHeaders();
      final response = await http.get(Uri.parse('${AuthService.baseUrl}/api/profile/'), headers: headers);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        cache.cacheProfile(Map<String, dynamic>.from(data));
        return UserProfile.fromJson(data);
      } else {
        throw Exception('Failed to load profile');
      }
    } catch (e) {
      final cached = cache.getCachedProfile();
      if (cached != null) {
        return UserProfile.fromJson(cached);
      }
      rethrow;
    }
  }

  @override
  Future<void> updateProfile(UserProfile profile) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/profile/'),
      headers: headers,
      body: json.encode(profile.toJson()),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to update profile: ${response.body}');
    }
  }

  @override
  Future<UserProfile> uploadProfilePhoto(Uint8List imageBytes, String imageName) async {
    final token = await _authService.getToken();
    var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/profile/'));
    request.headers['Authorization'] = 'Token $token';

    final filename = imageName;
    request.files.add(http.MultipartFile.fromBytes(
      'profile_photo',
      imageBytes,
      filename: filename,
      contentType: http_parser.MediaType('image', filename.endsWith('.png') ? 'png' : 'jpeg'),
    ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200 || response.statusCode == 201) {
      return UserProfile.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to upload profile photo: ${response.body}');
    }
  }

  @override
  Future<UserProfile> deleteProfilePhoto() async {
    final token = await _authService.getToken();
    var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/profile/'));
    request.headers['Authorization'] = 'Token $token';
    request.fields['profile_photo'] = '';

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200 || response.statusCode == 201) {
      return UserProfile.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to remove profile photo: ${response.body}');
    }
  }

  @override
  Future<OwnerProfile> getOwnerProfile(int userId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/profile/get_owner/?user_id=$userId'),
      headers: headers,
    );

    if (response.statusCode == 200) {
      return OwnerProfile.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to load owner profile');
    }
  }

  @override
  Future<OwnerProfile> updateOwnerProfile(int userId, {String? address, String? phoneNumber, String? pickupInstructions}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{};
    if (address != null) body['address'] = address;
    if (phoneNumber != null) body['phone_number'] = phoneNumber;
    if (pickupInstructions != null) body['pickup_instructions'] = pickupInstructions;

    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/profile/update_owner/?user_id=$userId'),
      headers: headers,
      body: json.encode(body),
    );

    if (response.statusCode == 200) {
      return OwnerProfile.fromJson(json.decode(response.body));
    } else {
      String errorMessage = 'Failed to update owner profile';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          errorMessage = errorData.values.first?.toString() ?? errorMessage;
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  @override
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime}) async {
    final token = await _authService.getToken();
    http.Response response;

    if (imageBytes != null || deletePhoto) {
      // Use multipart request for photo changes
      var request = http.MultipartRequest('PATCH', Uri.parse('${AuthService.baseUrl}/api/dogs/${dog.id}/'));
      request.headers['Authorization'] = 'Token $token';

      if (name != null) request.fields['name'] = name;
      if (foodInstructions != null) request.fields['food_instructions'] = foodInstructions;
      if (medicalNotes != null) request.fields['medical_notes'] = medicalNotes;
      if (daysInDaycare != null) request.fields['daycare_days'] = json.encode(daysInDaycare.map((d) => d.dayNumber).toList());
      if (preferredDropoffTime != null) request.fields['preferred_dropoff_time'] = preferredDropoffTime.apiValue;
      if (scheduleType != null) request.fields['schedule_type'] = scheduleType.apiValue;
      if (ownerBringsDefault != null) request.fields['owner_brings_default'] = ownerBringsDefault.toString();
      if (ownerCollectsDefault != null) request.fields['owner_collects_default'] = ownerCollectsDefault.toString();
      if (ownerBringsDefaultTime != null) request.fields['owner_brings_default_time'] = formatApiTime(ownerBringsDefaultTime);
      if (ownerCollectsDefaultTime != null) request.fields['owner_collects_default_time'] = formatApiTime(ownerCollectsDefaultTime);

      if (deletePhoto) {
        request.fields['profile_image'] = '';  // Empty string to clear the image
      } else if (imageBytes != null) {
        final filename = imageName ?? 'dog_photo.jpg';
        request.files.add(http.MultipartFile.fromBytes(
          'profile_image',
          imageBytes,
          filename: filename,
          contentType: http_parser.MediaType('image', filename.endsWith('.png') ? 'png' : 'jpeg'),
        ));
      }

      final streamedResponse = await request.send();
      response = await http.Response.fromStream(streamedResponse);
    } else {
      // No photo changes, use regular JSON request
      final headers = await _getHeaders();
      response = await http.patch(
        Uri.parse('${AuthService.baseUrl}/api/dogs/${dog.id}/'),
        headers: headers,
        body: json.encode({
          'name': name ?? dog.name,
          'food_instructions': foodInstructions ?? dog.foodInstructions,
          'medical_notes': medicalNotes ?? dog.medicalNotes,
          if (daysInDaycare != null) 'daycare_days': daysInDaycare.map((d) => d.dayNumber).toList(),
          if (preferredDropoffTime != null) 'preferred_dropoff_time': preferredDropoffTime.apiValue,
          if (scheduleType != null) 'schedule_type': scheduleType.apiValue,
          if (ownerBringsDefault != null) 'owner_brings_default': ownerBringsDefault,
          if (ownerCollectsDefault != null) 'owner_collects_default': ownerCollectsDefault,
          if (ownerBringsDefaultTime != null) 'owner_brings_default_time': formatApiTime(ownerBringsDefaultTime),
          if (ownerCollectsDefaultTime != null) 'owner_collects_default_time': formatApiTime(ownerCollectsDefaultTime),
        }),
      );
    }

    if (response.statusCode != 200) {
      throw Exception('Failed to update dog: ${response.body}');
    }

    final data = json.decode(response.body);
    final updatedDaysInDaycare = (data['daycare_days'] as List<dynamic>?)
        ?.map((day) => Weekday.values.firstWhere(
              (w) => w.dayNumber == day,
              orElse: () => Weekday.monday,
            ))
        .toList() ?? [];
    OwnerDetails? ownerDetails;
    if (data['owner_details'] != null) {
      ownerDetails = OwnerDetails.fromJson(data['owner_details']);
    }
    final additionalOwners = (data['additional_owners_details'] as List<dynamic>?)
        ?.map((o) => OwnerDetails.fromJson(o))
        .toList() ?? [];

    return Dog(
      id: data['id'].toString(),
      name: data['name'],
      ownerId: (data['owner'] ?? '').toString(),
      profileImageUrl: data['profile_image'],
      foodInstructions: data['food_instructions'],
      medicalNotes: data['medical_notes'],
      daysInDaycare: updatedDaysInDaycare,
      ownerDetails: ownerDetails,
      additionalOwners: additionalOwners,
      preferredDropoffTime: DropoffTimeExtension.fromApiValue(data['preferred_dropoff_time']),
      scheduleType: ScheduleTypeExtension.fromApiValue(data['schedule_type']),
      ownerBringsDefault: data['owner_brings_default'] ?? false,
      ownerCollectsDefault: data['owner_collects_default'] ?? false,
      ownerBringsDefaultTime: parseApiTime(data['owner_brings_default_time']),
      ownerCollectsDefaultTime: parseApiTime(data['owner_collects_default_time']),
    );
  }

  @override

  @override
  Future<List<Photo>> getPhotos(String dogId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/photos/by_dog/?dog_id=$dogId'),
      headers: headers,
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Photo.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load photos');
    }
  }

  @override
  Future<Photo> uploadPhoto(String dogId, Uint8List imageBytes, String imageName, DateTime takenAt) async {
    final token = await _authService.getToken();
    var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/photos/'));
    request.headers['Authorization'] = 'Token $token';

    // Determine media type from file extension
    final isVideo = imageName.toLowerCase().endsWith('.mp4') || 
                    imageName.toLowerCase().endsWith('.mov') ||
                    imageName.toLowerCase().endsWith('.avi');
    
    request.fields['dog'] = dogId;
    request.fields['taken_at'] = takenAt.toIso8601String();
    request.fields['media_type'] = isVideo ? 'VIDEO' : 'PHOTO';
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      imageBytes,
      filename: imageName,
    ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 201) {
      final data = json.decode(response.body);
      return Photo.fromJson(data);
    } else {
      String errorMessage = 'Failed to upload photo';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          errorMessage = errorData.values.first?.toString() ?? errorMessage;
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  @override
  Future<List<Photo>> uploadMultiplePhotos(String dogId, List<(Uint8List, String, DateTime)> images) async {
    final uploadedPhotos = <Photo>[];
    
    for (final (imageBytes, imageName, takenAt) in images) {
      try {
        final photo = await uploadPhoto(dogId, imageBytes, imageName, takenAt);
        uploadedPhotos.add(photo);
      } catch (e) {
        // Continue uploading remaining photos even if one fails
        rethrow;
      }
    }
    
    return uploadedPhotos;
  }

  @override
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare, String? ownerId, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType}) async {
    final token = await _authService.getToken();

    if (imageBytes != null) {
      // Use multipart request for file upload
      var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/dogs/'));
      request.headers['Authorization'] = 'Token $token';

      request.fields['name'] = name;
      if (foodInstructions != null) request.fields['food_instructions'] = foodInstructions;
      if (medicalNotes != null) request.fields['medical_notes'] = medicalNotes;
      if (daysInDaycare != null && daysInDaycare.isNotEmpty) request.fields['daycare_days'] = json.encode(daysInDaycare.map((d) => d.dayNumber).toList());
      if (ownerId != null) request.fields['owner'] = ownerId;
      if (preferredDropoffTime != null) request.fields['preferred_dropoff_time'] = preferredDropoffTime.apiValue;
      if (scheduleType != null) request.fields['schedule_type'] = scheduleType.apiValue;

      // Use bytes instead of file path for cross-platform compatibility
      final filename = imageName ?? 'dog_photo.jpg';
      request.files.add(http.MultipartFile.fromBytes(
        'profile_image',
        imageBytes,
        filename: filename,
        contentType: http_parser.MediaType('image', filename.endsWith('.png') ? 'png' : 'jpeg'),
      ));
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 201) {
        final data = json.decode(response.body);
        final daysInDaycareResult = (data['daycare_days'] as List<dynamic>?)
            ?.map((day) => Weekday.values.firstWhere(
              (w) => w.dayNumber == day,
              orElse: () => Weekday.monday,
            ))
            .toList() ?? [];
        
        OwnerDetails? ownerDetails;
        if (data['owner_details'] != null) {
          ownerDetails = OwnerDetails.fromJson(data['owner_details']);
        }
        final additionalOwners = (data['additional_owners_details'] as List<dynamic>?)
            ?.map((o) => OwnerDetails.fromJson(o))
            .toList() ?? [];

        return Dog(
          id: data['id'].toString(),
          name: data['name'],
          ownerId: data['owner'].toString(),
          profileImageUrl: data['profile_image'],
          foodInstructions: data['food_instructions'],
          medicalNotes: data['medical_notes'],
          daysInDaycare: daysInDaycareResult,
          ownerDetails: ownerDetails,
          additionalOwners: additionalOwners,
          preferredDropoffTime: DropoffTimeExtension.fromApiValue(data['preferred_dropoff_time']),
          scheduleType: ScheduleTypeExtension.fromApiValue(data['schedule_type']),
          ownerBringsDefault: data['owner_brings_default'] ?? false,
          ownerCollectsDefault: data['owner_collects_default'] ?? false,
          ownerBringsDefaultTime: parseApiTime(data['owner_brings_default_time']),
          ownerCollectsDefaultTime: parseApiTime(data['owner_collects_default_time']),
        );
      } else {
        throw Exception('Failed to create dog: ${response.body}');
      }
    } else {
      // No image, use regular JSON request
      final headers = await _getHeaders();
      final response = await http.post(
        Uri.parse('${AuthService.baseUrl}/api/dogs/'),
        headers: headers,
        body: json.encode({
          'name': name,
          'food_instructions': foodInstructions,
          'medical_notes': medicalNotes,
          if (daysInDaycare != null && daysInDaycare.isNotEmpty) 'daycare_days': daysInDaycare.map((d) => d.dayNumber).toList(),
          if (ownerId != null) 'owner': int.parse(ownerId),
          if (preferredDropoffTime != null) 'preferred_dropoff_time': preferredDropoffTime.apiValue,
          if (scheduleType != null) 'schedule_type': scheduleType.apiValue,
        }),
      );

      if (response.statusCode == 201) {
        final data = json.decode(response.body);
        final daysInDaycareResult = (data['daycare_days'] as List<dynamic>?)
            ?.map((day) => Weekday.values.firstWhere(
              (w) => w.dayNumber == day,
              orElse: () => Weekday.monday,
            ))
            .toList() ?? [];

        OwnerDetails? ownerDetails;
        if (data['owner_details'] != null) {
          ownerDetails = OwnerDetails.fromJson(data['owner_details']);
        }
        final additionalOwners = (data['additional_owners_details'] as List<dynamic>?)
            ?.map((o) => OwnerDetails.fromJson(o))
            .toList() ?? [];

        return Dog(
          id: data['id'].toString(),
          name: data['name'],
          ownerId: data['owner'].toString(),
          foodInstructions: data['food_instructions'],
          medicalNotes: data['medical_notes'],
          daysInDaycare: daysInDaycareResult,
          ownerDetails: ownerDetails,
          additionalOwners: additionalOwners,
          preferredDropoffTime: DropoffTimeExtension.fromApiValue(data['preferred_dropoff_time']),
          scheduleType: ScheduleTypeExtension.fromApiValue(data['schedule_type']),
          ownerBringsDefault: data['owner_brings_default'] ?? false,
          ownerCollectsDefault: data['owner_collects_default'] ?? false,
          ownerBringsDefaultTime: parseApiTime(data['owner_brings_default_time']),
          ownerCollectsDefaultTime: parseApiTime(data['owner_collects_default_time']),
        );
      } else {
        throw Exception('Failed to create dog: ${response.body}');
      }
    }
  }

  @override
  Future<void> deleteDog(String dogId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/dogs/$dogId/'),
      headers: headers,
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      String errorMessage = 'Failed to delete dog';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  @override
  Future<Dog> assignDogToUser(String dogId, {int? owner, List<int>? additionalOwners}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{};
    if (owner != null) body['owner'] = owner;
    if (additionalOwners != null) body['additional_owners'] = additionalOwners;

    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/dogs/$dogId/assign/'),
      headers: headers,
      body: json.encode(body),
    );

    if (response.statusCode != 200) {
      String errorMessage = 'Failed to assign dog';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }

    final data = json.decode(response.body);
    final daysInDaycare = (data['daycare_days'] as List<dynamic>?)
        ?.map((day) => Weekday.values.firstWhere(
              (w) => w.dayNumber == day,
              orElse: () => Weekday.monday,
            ))
        .toList() ?? [];
    OwnerDetails? ownerDetails;
    if (data['owner_details'] != null) {
      ownerDetails = OwnerDetails.fromJson(data['owner_details']);
    }
    final additionalOwnersList = (data['additional_owners_details'] as List<dynamic>?)
        ?.map((o) => OwnerDetails.fromJson(o))
        .toList() ?? [];

    return Dog(
      id: data['id'].toString(),
      name: data['name'],
      ownerId: (data['owner'] ?? '').toString(),
      profileImageUrl: data['profile_image'],
      foodInstructions: data['food_instructions'],
      medicalNotes: data['medical_notes'],
      daysInDaycare: daysInDaycare,
      ownerDetails: ownerDetails,
      additionalOwners: additionalOwnersList,
    );
  }

  Future<void> submitDateChangeRequest({
    required String dogId,
    required DateTime originalDate,
    DateTime? newDate,
  }) async {
    final headers = await _getHeaders();
    final now = DateTime.now();
    final oneMonthLater = DateTime(now.year, now.month + 1, now.day);
    final isCharged = originalDate.isBefore(oneMonthLater);

    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/date-change-requests/'),
      headers: headers,
      body: json.encode({
        'dog': int.parse(dogId),
        'request_type': newDate == null ? 'CANCEL' : 'CHANGE',
        'original_date': originalDate.toIso8601String().split('T')[0],
        if (newDate != null) 'new_date': newDate.toIso8601String().split('T')[0],
        'is_charged': isCharged,
      }),
    );

    if (response.statusCode != 201) {
      // Try to parse error message from JSON, otherwise show generic error
      String errorMessage = 'Failed to submit request';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          errorMessage = errorData.values.first?.toString() ?? errorMessage;
        }
      } catch (_) {
        // Response is not JSON (e.g., HTML error page)
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  Future<void> submitAdditionalDayRequest({
    required String dogId,
    required DateTime requestedDate,
  }) async {
    final headers = await _getHeaders();

    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/date-change-requests/'),
      headers: headers,
      body: json.encode({
        'dog': int.parse(dogId),
        'request_type': 'ADD_DAY',
        'new_date': requestedDate.toIso8601String().split('T')[0],
        'is_charged': false,
      }),
    );

    if (response.statusCode != 201) {
      String errorMessage = 'Failed to submit request';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          errorMessage = errorData.values.first?.toString() ?? errorMessage;
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  @override
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId}) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/date-change-requests/'),
      headers: headers,
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      var requests = data.map((json) => DateChangeRequest.fromJson(json)).toList();

      // Filter by dogId if specified
      if (dogId != null) {
        requests = requests.where((r) => r.dogId == dogId).toList();
      }

      return requests;
    } else {
      throw Exception('Failed to load requests');
    }
  }

  @override
  Future<void> updateDateChangeRequestStatus(String requestId, String status) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/date-change-requests/$requestId/change_status/'),
      headers: headers,
      body: json.encode({'status': status}),
    );

    if (response.statusCode != 200) {
      String errorMessage = 'Failed to update request';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          errorMessage = errorData.values.first?.toString() ?? errorMessage;
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  @override
  Future<List<gm.GroupMedia>> getFeed({String? dogId}) async {
    final cache = CacheService();
    try {
      final headers = await _getHeaders();
      var url = '${AuthService.baseUrl}/api/feed/';
      if (dogId != null) url += '?dog_id=$dogId';
      final response = await http.get(
        Uri.parse(url),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        cache.cacheFeed(data.cast<Map<String, dynamic>>());
        return data.map((json) => gm.GroupMedia.fromJson(json)).toList();
      } else {
        throw Exception('Failed to load feed');
      }
    } catch (e) {
      final cached = cache.getCachedFeed();
      if (cached != null && cached.isNotEmpty) {
        return cached.map((json) => gm.GroupMedia.fromJson(json)).toList();
      }
      rethrow;
    }
  }

  Future<void> uploadGroupMedia({
    required Uint8List fileBytes,
    required String fileName,
    required bool isVideo,
    String? caption,
    Uint8List? thumbnailBytes,
    List<String>? taggedDogIds,
  }) async {
    final token = await _authService.getToken();
    var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/feed/'));
    request.headers['Authorization'] = 'Token $token';

    request.fields['media_type'] = isVideo ? 'VIDEO' : 'PHOTO';
    if (caption != null && caption.isNotEmpty) {
      request.fields['caption'] = caption;
    }
    if (taggedDogIds != null && taggedDogIds.isNotEmpty) {
      for (final dogId in taggedDogIds) {
        request.files.add(http.MultipartFile.fromString('tagged_dog_ids', dogId));
      }
    }

    request.files.add(http.MultipartFile.fromBytes(
      'file',
      fileBytes,
      filename: fileName,
      contentType: isVideo
          ? http_parser.MediaType('video', 'mp4')
          : http_parser.MediaType('image', fileName.endsWith('.png') ? 'png' : 'jpeg'),
    ));

    if (thumbnailBytes != null) {
      request.files.add(http.MultipartFile.fromBytes(
        'thumbnail',
        thumbnailBytes,
        filename: 'thumbnail.jpg',
        contentType: http_parser.MediaType('image', 'jpeg'),
      ));
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 201) {
      String errorMessage = 'Failed to upload media';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          errorMessage = errorData.values.first?.toString() ?? errorMessage;
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  /// Upload multiple media files to the group feed
  /// [files] is a list of (bytes, filename) tuples
  /// [onProgress] is called after each file upload with (completed, total)
  Future<void> uploadMultipleGroupMedia({
    required List<(Uint8List, String)> files,
    String? caption,
    List<String?>? captionsByFile,
    List<List<String>>? taggedDogIdsByFile,
    void Function(int completed, int total)? onProgress,
  }) async {
    for (int i = 0; i < files.length; i++) {
      final (bytes, fileName) = files[i];
      final ext = fileName.toLowerCase();
      final isVideo = ext.endsWith('.mp4') || ext.endsWith('.mov') || ext.endsWith('.avi');
      // Per-file caption takes priority, then fall back to shared caption
      final fileCaption = (captionsByFile != null && i < captionsByFile.length)
          ? captionsByFile[i]
          : caption;
      await uploadGroupMedia(
        fileBytes: bytes,
        fileName: fileName,
        isVideo: isVideo,
        caption: fileCaption,
        taggedDogIds: taggedDogIdsByFile != null && i < taggedDogIdsByFile.length
            ? taggedDogIdsByFile[i]
            : null,
      );
      onProgress?.call(i + 1, files.length);
    }
  }

  @override
  Future<void> deleteGroupMedia(String mediaId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/feed/$mediaId/'),
      headers: headers,
    );

    if (response.statusCode != 204) {
      throw Exception('Failed to delete media');
    }
  }

  @override
  Future<gm.GroupMedia> updateGroupMedia(String mediaId, {String? caption, List<String>? taggedDogIds}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{};
    if (caption != null) body['caption'] = caption;
    if (taggedDogIds != null) body['tagged_dog_ids'] = taggedDogIds.map((id) => int.parse(id)).toList();

    final response = await http.patch(
      Uri.parse('${AuthService.baseUrl}/api/feed/$mediaId/'),
      headers: headers,
      body: json.encode(body),
    );

    if (response.statusCode == 200) {
      return gm.GroupMedia.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to update media');
    }
  }

  @override
  Future<gm.GroupMedia> toggleReaction(String mediaId, String emoji) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/feed/$mediaId/react/'),
      headers: headers,
      body: json.encode({'emoji': emoji}),
    );

    if (response.statusCode == 200) {
      return gm.GroupMedia.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to react: ${response.body}');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getReactionDetails(String mediaId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/feed/$mediaId/reaction_details/'),
      headers: headers,
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      throw Exception('Failed to load reaction details');
    }
  }


  @override
  Future<List<OwnerProfile>> getOwners() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/profile/get_owners/'),
      headers: headers,
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => OwnerProfile.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load owners');
    }
  }

  @override
  Future<void> addComment(String mediaId, String text, {bool isProfilePhoto = false}) async {
    final headers = await _getHeaders();
    final endpoint = isProfilePhoto ? 'photos' : 'feed';
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/$endpoint/$mediaId/comment/'),
      headers: headers,
      body: json.encode({'text': text}),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to add comment: ${response.body}');
    }
  }

  @override
  Future<void> deleteComment(String commentId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/comments/$commentId/'),
      headers: headers,
    );

    if (response.statusCode != 204) {
      throw Exception('Failed to delete comment');
    }
  }

  @override
  Future<List<BoardingRequest>> getBoardingRequests() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/boarding-requests/'),
      headers: headers,
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => BoardingRequest.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load boarding requests');
    }
  }

  @override
  Future<void> createBoardingRequest({
    required List<int> dogIds,
    required DateTime startDate,
    required DateTime endDate,
    String? specialInstructions,
    int? ownerId,
  }) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/boarding-requests/'),
      headers: headers,
      body: json.encode({
        'dogs': dogIds,
        'start_date': startDate.toIso8601String().split('T').first,
        'end_date': endDate.toIso8601String().split('T').first,
        if (specialInstructions != null) 'special_instructions': specialInstructions,
        if (ownerId != null) 'owner': ownerId,
      }),
    );

    if (response.statusCode != 201) {
      String errorMessage = 'Failed to create boarding request';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          errorMessage = errorData.values.first?.toString() ?? errorMessage;
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  Future<void> updateBoardingRequestStatus(int requestId, String status) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/boarding-requests/$requestId/change_status/'),
      headers: headers,
      body: json.encode({'status': status}),
    );

    if (response.statusCode != 200) {
      String errorMessage = 'Failed to update request';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          errorMessage = errorData.values.first?.toString() ?? errorMessage;
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  @override
  Future<void> registerDeviceToken(String token, String deviceType) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/device-tokens/'),
      headers: headers,
      body: json.encode({
        'token': token,
        'device_type': deviceType,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      if (kDebugMode) {
        print('Failed to register device token: ${response.body}');
      }
    }
  }

  String _dateParam(DateTime? date) {
    if (date == null) return '';
    return '?date=${date.toIso8601String().split('T')[0]}';
  }

  String _dateBody(DateTime? date) {
    if (date == null) return '';
    return date.toIso8601String().split('T')[0];
  }

  @override
  Future<List<DailyDogAssignment>> getMyAssignments({DateTime? date}) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/my_assignments/${_dateParam(date)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((j) => DailyDogAssignment.fromJson(j)).toList();
    } else {
      throw Exception('Failed to load assignments');
    }
  }

  @override
  Future<List<DailyDogAssignment>> getTodayAssignments({DateTime? date}) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/today/${_dateParam(date)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((j) => DailyDogAssignment.fromJson(j)).toList();
    } else {
      throw Exception('Failed to load today assignments');
    }
  }

  @override
  Future<List<Dog>> getUnassignedDogs({DateTime? date}) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/unassigned_dogs/${_dateParam(date)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((j) {
        final daysInDaycare = (j['daycare_days'] as List<dynamic>?)
            ?.map((day) => Weekday.values.firstWhere(
                  (w) => w.dayNumber == day,
                  orElse: () => Weekday.monday,
                ))
            .toList() ?? [];
        OwnerDetails? ownerDetails;
        if (j['owner_details'] != null) {
          ownerDetails = OwnerDetails.fromJson(j['owner_details']);
        }
        final additionalOwners = (j['additional_owners_details'] as List<dynamic>?)
            ?.map((o) => OwnerDetails.fromJson(o))
            .toList() ?? [];
        return Dog(
          id: j['id'].toString(),
          name: j['name'],
          ownerId: (j['owner'] ?? '').toString(),
          profileImageUrl: j['profile_image'],
          foodInstructions: j['food_instructions'],
          medicalNotes: j['medical_notes'],
          daysInDaycare: daysInDaycare,
          ownerDetails: ownerDetails,
          additionalOwners: additionalOwners,
          preferredDropoffTime: DropoffTimeExtension.fromApiValue(j['preferred_dropoff_time']),
          scheduleType: ScheduleTypeExtension.fromApiValue(j['schedule_type']),
          ownerBringsDefault: j['owner_brings_default'] ?? false,
          ownerCollectsDefault: j['owner_collects_default'] ?? false,
          ownerBringsDefaultTime: parseApiTime(j['owner_brings_default_time']),
          ownerCollectsDefaultTime: parseApiTime(j['owner_collects_default_time']),
        );
      }).toList();
    } else {
      throw Exception('Failed to load unassigned dogs');
    }
  }

  @override
  Future<AssignDogsResult> assignDogsToMe(List<int> dogIds, {DateTime? date}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{'dog_ids': dogIds};
    final d = _dateBody(date);
    if (d.isNotEmpty) body['date'] = d;
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/assign_to_me/'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode == 201) {
      // All dogs assigned successfully (plain list)
      final List<dynamic> data = json.decode(response.body);
      return AssignDogsResult(created: data.map((j) => DailyDogAssignment.fromJson(j)).toList());
    } else if (response.statusCode == 200) {
      // Some dogs skipped (object with created + skipped)
      final Map<String, dynamic> result = json.decode(response.body);
      final created = (result['created'] as List<dynamic>).map((j) => DailyDogAssignment.fromJson(j)).toList();
      final skipped = (result['skipped'] as List<dynamic>).map((j) => SkippedDog.fromJson(j)).toList();
      return AssignDogsResult(created: created, skipped: skipped);
    } else {
      throw Exception('Failed to assign dogs');
    }
  }

  @override
  Future<AssignDogsResult> assignDogs(List<int> dogIds, int staffMemberId, {DateTime? date}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{'dog_ids': dogIds, 'staff_member_id': staffMemberId};
    final d = _dateBody(date);
    if (d.isNotEmpty) body['date'] = d;
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/assign_dogs/'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode == 201) {
      final List<dynamic> data = json.decode(response.body);
      return AssignDogsResult(created: data.map((j) => DailyDogAssignment.fromJson(j)).toList());
    } else if (response.statusCode == 200) {
      final Map<String, dynamic> result = json.decode(response.body);
      final created = (result['created'] as List<dynamic>).map((j) => DailyDogAssignment.fromJson(j)).toList();
      final skipped = (result['skipped'] as List<dynamic>).map((j) => SkippedDog.fromJson(j)).toList();
      return AssignDogsResult(created: created, skipped: skipped);
    } else {
      String errorMessage = 'Failed to assign dogs';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {}
      throw Exception(errorMessage);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getStaffMembers() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/staff_members/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      throw Exception('Failed to load staff members');
    }
  }

  @override
  Future<DailyDogAssignment> updateAssignmentStatus(int assignmentId, AssignmentStatus status) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/$assignmentId/update_status/'),
      headers: headers,
      body: json.encode({'status': status.apiValue}),
    );
    if (response.statusCode == 200) {
      return DailyDogAssignment.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to update assignment status');
    }
  }

  @override
  Future<DailyDogAssignment> setAssignmentTransport(
    int assignmentId, {
    required bool? ownerBrings,
    required bool? ownerCollects,
    required TimeOfDay? ownerBringsTime,
    required TimeOfDay? ownerCollectsTime,
  }) async {
    final headers = await _getHeaders();
    final response = await http.patch(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/$assignmentId/transport/'),
      headers: headers,
      body: json.encode({
        'owner_brings': ownerBrings,
        'owner_collects': ownerCollects,
        'owner_brings_time': ownerBringsTime == null ? null : formatApiTime(ownerBringsTime),
        'owner_collects_time': ownerCollectsTime == null ? null : formatApiTime(ownerCollectsTime),
      }),
    );
    if (response.statusCode == 200) {
      return DailyDogAssignment.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to set transport (${response.statusCode}): ${response.body}');
  }

  @override
  Future<DailyDogAssignment> reassignDog(
    int assignmentId,
    int newStaffMemberId, {
    AssignmentScope scope = AssignmentScope.justThisDay,
  }) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/$assignmentId/reassign/'),
      headers: headers,
      body: json.encode({
        'staff_member_id': newStaffMemberId,
        'scope': scope.apiValue,
      }),
    );
    if (response.statusCode == 200) {
      return DailyDogAssignment.fromJson(json.decode(response.body));
    } else {
      String errorMessage = 'Failed to reassign dog';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {}
      throw Exception(errorMessage);
    }
  }

  @override
  Future<void> unassignDog(
    int assignmentId, {
    AssignmentScope scope = AssignmentScope.justThisDay,
  }) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/$assignmentId/unassign/'),
      headers: headers,
      body: json.encode({'scope': scope.apiValue}),
    );
    if (response.statusCode != 204) {
      String errorMessage = 'Failed to unassign dog';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {}
      throw Exception(errorMessage);
    }
  }

  @override
  Future<Map<String, dynamic>> swapStaff({
    required int fromStaffId,
    required int toStaffId,
    required SwapScope scope,
    DateTime? date,
  }) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{
      'from_staff_id': fromStaffId,
      'to_staff_id': toStaffId,
      'scope': scope.apiValue,
    };
    if (date != null) {
      body['date'] =
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    }
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/swap_staff/'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode == 200) {
      return Map<String, dynamic>.from(json.decode(response.body));
    }
    String errorMessage = 'Failed to swap staff';
    try {
      final errorData = json.decode(response.body);
      if (errorData is Map && errorData['detail'] != null) {
        errorMessage = errorData['detail'];
      }
    } catch (_) {}
    throw Exception(errorMessage);
  }

  @override
  Future<List<Map<String, dynamic>>> getWeekdayRoster({int? weekday, int? staffMemberId}) async {
    final headers = await _getHeaders();
    final params = <String, String>{};
    if (weekday != null) params['weekday'] = weekday.toString();
    if (staffMemberId != null) params['staff_member_id'] = staffMemberId.toString();
    final qs = params.isEmpty
        ? ''
        : '?${params.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/weekday_roster/$qs'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw Exception('Failed to load weekday roster');
  }

  @override
  Future<Map<String, dynamic>> getSuggestedAssignments({DateTime? date}) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/suggested_assignments/${_dateParam(date)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return Map<String, dynamic>.from(json.decode(response.body));
    } else {
      throw Exception('Failed to load suggestions');
    }
  }

  @override
  Future<Map<String, dynamic>> autoAssign({DateTime? date}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{};
    final d = _dateBody(date);
    if (d.isNotEmpty) body['date'] = d;
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/auto_assign/'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode == 201) {
      return Map<String, dynamic>.from(json.decode(response.body));
    } else {
      String errorMessage = 'Failed to auto-assign';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {}
      throw Exception(errorMessage);
    }
  }

  @override
  Future<void> sendTrafficAlert(String alertType, {DateTime? date, String? detail, List<int>? dogIds}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{'alert_type': alertType};
    final d = _dateBody(date);
    if (d.isNotEmpty) body['date'] = d;
    if (detail != null && detail.isNotEmpty) body['detail'] = detail;
    if (dogIds != null && dogIds.isNotEmpty) body['dog_ids'] = dogIds;
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/send_traffic_alert/'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      String errorMessage = 'Failed to send traffic alert';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {}
      throw Exception(errorMessage);
    }
  }

  @override
  Future<void> reorderAssignments(List<int> assignmentIds) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/reorder/'),
      headers: headers,
      body: json.encode({'assignment_ids': assignmentIds}),
    );
    if (response.statusCode != 200) {
      String errorMessage = 'Failed to save order';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {}
      throw Exception(errorMessage);
    }
  }

  // --- Support Queries ---

  @override
  Future<List<SupportQuery>> getSupportQueries() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => SupportQuery.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load queries');
    }
  }

  @override
  Future<SupportQuery> getSupportQuery(int queryId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/$queryId/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return SupportQuery.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to load query');
    }
  }

  @override
  Future<SupportQuery> createSupportQuery({required String subject, required String initialMessage}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/'),
      headers: headers,
      body: json.encode({'subject': subject, 'initial_message': initialMessage}),
    );
    if (response.statusCode != 201) {
      throw Exception('Failed to create query');
    }
    return SupportQuery.fromJson(json.decode(response.body));
  }

  @override
  Future<SupportQuery> createStaffQuery({required int ownerId, required String subject, required String initialMessage}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/'),
      headers: headers,
      body: json.encode({'subject': subject, 'owner_id': ownerId, 'initial_message': initialMessage}),
    );
    if (response.statusCode != 201) {
      throw Exception('Failed to create query');
    }
    return SupportQuery.fromJson(json.decode(response.body));
  }

  @override
  Future<SupportQuery> addQueryMessage(int queryId, String text) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/$queryId/add_message/'),
      headers: headers,
      body: json.encode({'text': text}),
    );
    if (response.statusCode == 200) {
      return SupportQuery.fromJson(json.decode(response.body));
    } else {
      String errorMessage = 'Failed to send message';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map && errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {}
      throw Exception(errorMessage);
    }
  }

  @override
  Future<SupportQuery> resolveQuery(int queryId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/$queryId/resolve/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return SupportQuery.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to resolve query');
    }
  }

  @override
  Future<SupportQuery> reopenQuery(int queryId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/$queryId/reopen/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return SupportQuery.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to reopen query');
    }
  }

  @override
  Future<void> markQueryRead(int queryId) async {
    final headers = await _getHeaders();
    await http.post(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/$queryId/mark_read/'),
      headers: headers,
    );
  }

  @override
  Future<int> getUnresolvedQueryCount() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/support-queries/unresolved_count/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['count'] ?? 0;
    } else {
      return 0;
    }
  }

  // ---- Contact Inquiries ----

  @override
  Future<List<ContactInquiry>> getContactInquiries() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/contact-inquiries/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((j) => ContactInquiry.fromJson(j)).toList();
    } else {
      throw Exception('Failed to load contact inquiries');
    }
  }

  @override
  Future<ContactInquiry> markInquiryRead(int inquiryId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/contact-inquiries/$inquiryId/mark_read/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return ContactInquiry.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to mark inquiry as read');
    }
  }

  @override
  Future<ContactInquiry> markInquiryUnread(int inquiryId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/contact-inquiries/$inquiryId/mark_unread/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return ContactInquiry.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to mark inquiry as unread');
    }
  }

  @override
  Future<ContactInquiry> markInquiryReplied(int inquiryId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/contact-inquiries/$inquiryId/mark_replied/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return ContactInquiry.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to mark inquiry as replied');
    }
  }

  @override
  Future<void> deleteInquiry(int inquiryId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/contact-inquiries/$inquiryId/'),
      headers: headers,
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to delete inquiry');
    }
  }

  @override
  Future<int> getUnreadInquiryCount() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/contact-inquiries/unread_count/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['count'] ?? 0;
    } else {
      return 0;
    }
  }

  @override
  Future<Map<String, int>> getFeedTodayStats() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/group-media/today_stats/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {
        'photos': data['photos'] ?? 0,
        'videos': data['videos'] ?? 0,
      };
    } else {
      return {'photos': 0, 'videos': 0};
    }
  }

  // ---- Closure Days ----

  @override
  Future<List<ClosureDay>> getClosureDays({DateTime? fromDate, DateTime? toDate}) async {
    final headers = await _getHeaders();
    final params = <String, String>{};
    if (fromDate != null) params['from_date'] = fromDate.toIso8601String().split('T').first;
    if (toDate != null) params['to_date'] = toDate.toIso8601String().split('T').first;
    final uri = Uri.parse('${AuthService.baseUrl}/api/closure-days/').replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => ClosureDay.fromJson(e)).toList();
    }
    throw Exception('Failed to load closure days: ${response.statusCode}');
  }

  @override
  Future<ClosureDay> createClosureDay({required DateTime date, required ClosureType closureType, String reason = ''}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/closure-days/'),
      headers: headers,
      body: json.encode({
        'date': date.toIso8601String().split('T').first,
        'closure_type': closureType.apiValue,
        'reason': reason,
      }),
    );
    if (response.statusCode == 201) {
      return ClosureDay.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to create closure day: ${response.body}');
  }

  @override
  Future<void> deleteClosureDay(int id) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/closure-days/$id/'),
      headers: headers,
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to delete closure day: ${response.statusCode}');
    }
  }

  // ---- Dog Notes ----

  @override
  Future<List<DogNote>> getDogNotes({int? dogId, String? noteType}) async {
    final headers = await _getHeaders();
    final params = <String, String>{};
    if (dogId != null) params['dog_id'] = dogId.toString();
    if (noteType != null) params['note_type'] = noteType;
    final uri = Uri.parse('${AuthService.baseUrl}/api/dog-notes/').replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => DogNote.fromJson(e)).toList();
    }
    throw Exception('Failed to load dog notes: ${response.statusCode}');
  }

  @override
  Future<DogNote> createDogNote({required int dogId, int? relatedDogId, required DogNoteType noteType, required String text, bool isPositive = true}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{
      'dog': dogId,
      'note_type': noteType.apiValue,
      'text': text,
      'is_positive': isPositive,
    };
    if (relatedDogId != null) body['related_dog'] = relatedDogId;
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/dog-notes/'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode == 201) {
      return DogNote.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to create dog note: ${response.body}');
  }

  @override
  Future<void> updateDogNote(int noteId, {String? text, bool? isPositive}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{};
    if (text != null) body['text'] = text;
    if (isPositive != null) body['is_positive'] = isPositive;
    final response = await http.patch(
      Uri.parse('${AuthService.baseUrl}/api/dog-notes/$noteId/'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to update dog note: ${response.statusCode}');
    }
  }

  @override
  Future<void> deleteDogNote(int noteId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/dog-notes/$noteId/'),
      headers: headers,
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to delete dog note: ${response.statusCode}');
    }
  }

  // ---- Staff Availability ----

  @override
  Future<List<StaffAvailability>> getMyAvailability() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/staff-availability/my_availability/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => StaffAvailability.fromJson(e)).toList();
    }
    throw Exception('Failed to load availability: ${response.statusCode}');
  }

  @override
  Future<List<StaffAvailability>> setMyAvailability(List<Map<String, dynamic>> availability) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/staff-availability/set_my_availability/'),
      headers: headers,
      body: json.encode({'availability': availability}),
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => StaffAvailability.fromJson(e)).toList();
    }
    throw Exception('Failed to set availability: ${response.body}');
  }

  @override
  Future<Map<String, dynamic>> getStaffCoverage() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/staff-availability/coverage/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load staff coverage: ${response.statusCode}');
  }

  @override
  Future<List<Map<String, dynamic>>> getAvailableStaffForDate(DateTime date) async {
    final headers = await _getHeaders();
    final dateParam = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/staff-availability/available_staff/$dateParam/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    }
    throw Exception('Failed to load available staff: ${response.statusCode}');
  }

  @override
  Future<List<DayOffRequest>> getMyDayOffRequests() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/day-off-requests/my_requests/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => DayOffRequest.fromJson(e)).toList();
    }
    throw Exception('Failed to load day off requests: ${response.statusCode}');
  }

  @override
  Future<DayOffRequest> requestDayOff({required DateTime date, String? reason}) async {
    final headers = await _getHeaders();
    final dateParam = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/day-off-requests/'),
      headers: headers,
      body: json.encode({
        'date': dateParam,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      }),
    );
    if (response.statusCode == 201 || response.statusCode == 200) {
      return DayOffRequest.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to request day off: ${response.body}');
  }

  @override
  Future<void> cancelDayOffRequest(int requestId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/day-off-requests/$requestId/'),
      headers: headers,
    );
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw Exception('Failed to cancel day off request: ${response.statusCode}');
    }
  }

  @override
  Future<List<DayOffRequest>> getAllDayOffRequests() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/day-off-requests/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => DayOffRequest.fromJson(e)).toList();
    }
    throw Exception('Failed to load all day off requests: ${response.statusCode}');
  }

  @override
  Future<DayOffRequest> approveDayOffRequest(int requestId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/day-off-requests/$requestId/approve/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return DayOffRequest.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to approve day off request: ${response.statusCode}');
  }

  @override
  Future<DayOffRequest> denyDayOffRequest(int requestId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/day-off-requests/$requestId/deny/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return DayOffRequest.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to deny day off request: ${response.statusCode}');
  }
}

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
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime}) async {
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
    );
    _dogs[index] = updatedDog;
    return updatedDog;
  }

  @override
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare, String? ownerId, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType}) async {
    return Dog(id: '99', name: name, ownerId: 'user1');
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
  Future<void> uploadMultipleGroupMedia({
    required List<(Uint8List, String)> files,
    String? caption,
    List<String?>? captionsByFile,
    List<List<String>>? taggedDogIdsByFile,
    void Function(int completed, int total)? onProgress,
  }) async {}

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
}
