import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'http_client.dart' as http;
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
import '../models/dog_profile_change_request.dart';
import '../models/intake_request.dart';
import '../models/staff_permission.dart';
import '../models/postcode_address.dart';
import '../models/vaccination_record.dart';
import '../models/owner_calendar.dart';
import '../models/vehicle.dart';
import '../models/vehicle_defect.dart';
import '../models/facility_defect.dart';
import '../models/vehicle_maintenance_record.dart';
import '../models/invoice.dart';
import '../models/customer_rate.dart';
import '../models/xero_contact.dart';
import 'auth_service.dart';
import 'cache_service.dart';

part 'data_service_exceptions.dart';
part 'data_service_interface.dart';
part 'data_service_mock.dart';

/// Result of parsing a single feed page off the UI isolate.
///
/// [rawItems] is the still-JSON list of results (used to warm the offline
/// cache); [items] is the parsed model list; [hasMore] reflects pagination.
class _ParsedFeedPage {
  final List<gm.GroupMedia> items;
  final List<Map<String, dynamic>> rawItems;
  final bool hasMore;
  const _ParsedFeedPage(this.items, this.rawItems, this.hasMore);
}

/// Decodes a feed-endpoint response body and parses it into models.
///
/// Top-level so it can run on a background isolate via [compute]: it does the
/// expensive `json.decode` + `GroupMedia.fromJson` work off the UI thread.
/// Tolerates both the paginated `{count, next, previous, results}` shape and a
/// plain JSON array (unpaginated fallback).
_ParsedFeedPage _parseFeedResponseBody(String body) {
  final decoded = json.decode(body);
  List<dynamic> results;
  bool hasMore;
  if (decoded is Map<String, dynamic> && decoded.containsKey('results')) {
    results = decoded['results'] as List<dynamic>;
    hasMore = decoded['next'] != null;
  } else {
    // Unpaginated fallback: a plain array is the whole feed.
    results = decoded as List<dynamic>;
    hasMore = false;
  }
  final rawItems = results.cast<Map<String, dynamic>>();
  final items = rawItems.map((j) => gm.GroupMedia.fromJson(j)).toList();
  return _ParsedFeedPage(items, rawItems, hasMore);
}

/// Whether a picked file should be treated as a video, by extension.
/// Library pickers can hand back more than just .mp4/.mov — cover the common
/// containers so odd videos aren't uploaded (and processed) as photos.
bool _isVideoFileName(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.mp4') ||
      n.endsWith('.mov') ||
      n.endsWith('.avi') ||
      n.endsWith('.m4v') ||
      n.endsWith('.3gp') ||
      n.endsWith('.webm') ||
      n.endsWith('.mkv');
}

class ApiDataService implements DataService {
  static final ApiDataService _instance = ApiDataService._internal();

  /// Returns the shared singleton instance. Existing `ApiDataService()` call
  /// sites continue to work and now resolve to the same instance that is
  /// registered in the service locator (see `service_locator.dart`).
  factory ApiDataService() => _instance;
  ApiDataService._internal();

  final _authService = AuthService();

  Future<Map<String, String>> _getHeaders() async {
    final token = await _authService.getToken();
    // Don't send the literal "Token null" when logged out / cleared mid-flight —
    // omit the header so the server returns a clean 401 instead (F5).
    final headers = {'Content-Type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Token $token';
    }
    return headers;
  }

  /// Fetches every page of a (possibly) paginated list endpoint and returns the
  /// aggregated raw JSON list.
  ///
  /// The backend uses opt-in pagination (B6): asking for `?page=1` gets a
  /// `{count, next, previous, results}` envelope, while an old/unpaginated
  /// endpoint returns a bare JSON array. This helper handles both — it requests
  /// `page=1&page_size=200`, collects `results`, and follows the absolute `next`
  /// URLs until exhausted; if the body is a plain array it is returned as-is.
  ///
  /// Goes through [_getHeaders] and the [http] wrapper so auth, timeouts and the
  /// 401 sign-out handling apply to every page.
  Future<List<dynamic>> _fetchAllPages(Uri url) async {
    final headers = await _getHeaders();

    // Add pagination opt-in params without dropping any the caller already set.
    final firstUrl = url.replace(queryParameters: {
      ...url.queryParameters,
      'page': '1',
      'page_size': '200',
    });

    var response = await http.get(firstUrl, headers: headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to load list: ${response.statusCode}');
    }

    final decoded = json.decode(response.body);

    // Back-compat: a bare array is the whole (unpaginated) list.
    if (decoded is List) {
      return decoded;
    }

    // Paginated envelope: collect results and walk the `next` links.
    final aggregated = <dynamic>[];
    Map<String, dynamic> page = decoded as Map<String, dynamic>;
    aggregated.addAll(page['results'] as List<dynamic>);
    var next = page['next'];
    while (next != null) {
      response = await http.get(Uri.parse(next as String), headers: headers);
      if (response.statusCode != 200) {
        throw Exception('Failed to load list page: ${response.statusCode}');
      }
      page = json.decode(response.body) as Map<String, dynamic>;
      aggregated.addAll(page['results'] as List<dynamic>);
      next = page['next'];
    }
    return aggregated;
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
        registeredVet: json['registered_vet'],
        address: json['address'],
        postcode: json['postcode'],
        accessInstructions: json['access_instructions'],
        vanPlacement: json['van_placement'],
        generalNotes: json['general_notes'],
        latitude: parseApiDouble(json['latitude']),
        longitude: parseApiDouble(json['longitude']),
        daysInDaycare: daysInDaycare,
        ownerDetails: ownerDetails,
        additionalOwners: additionalOwners,
        preferredDropoffTime: DropoffTimeExtension.fromApiValue(json['preferred_dropoff_time']),
        scheduleType: ScheduleTypeExtension.fromApiValue(json['schedule_type']),
        ownerBringsDefault: json['owner_brings_default'] ?? false,
        ownerCollectsDefault: json['owner_collects_default'] ?? false,
        ownerBringsDefaultTime: parseApiTime(json['owner_brings_default_time']),
        ownerCollectsDefaultTime: parseApiTime(json['owner_collects_default_time']),
        sex: parseDogSex(json['sex']),
        dateOfBirth: parseApiDate(json['date_of_birth']),
        isSpayed: json['is_spayed'] ?? false,
        cancelledDates: parseApiDateList(json['cancelled_dates']),
      );
    }).toList();
  }

  @override
  Future<List<Dog>> getDogs() async {
    final cache = CacheService();
    try {
      final data = await _fetchAllPages(Uri.parse('${AuthService.baseUrl}/api/dogs/'));
      // Cache the raw JSON for offline use
      cache.cacheDogs(data.cast<Map<String, dynamic>>());
      return _parseDogsList(data);
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
  Future<Dog> getDogById(String dogId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/dogs/$dogId/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return _parseDogsList([json.decode(response.body)]).first;
    }
    throw Exception('Failed to load dog');
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
  Future<void> updateStaffColor(String hexColor) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/profile/'),
      headers: headers,
      body: json.encode({'staff_color': hexColor}),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to update colour');
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
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, String? registeredVet, String? address, String? postcode, String? accessInstructions, String? vanPlacement, String? generalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed, bool clearDateOfBirth = false}) async {
    final token = await _authService.getToken();
    http.Response response;

    if (imageBytes != null || deletePhoto) {
      // Use multipart request for photo changes
      var request = http.MultipartRequest('PATCH', Uri.parse('${AuthService.baseUrl}/api/dogs/${dog.id}/'));
      request.headers['Authorization'] = 'Token $token';

      if (name != null) request.fields['name'] = name;
      if (foodInstructions != null) request.fields['food_instructions'] = foodInstructions;
      if (medicalNotes != null) request.fields['medical_notes'] = medicalNotes;
      if (registeredVet != null) request.fields['registered_vet'] = registeredVet;
      if (address != null) request.fields['address'] = address;
      if (postcode != null) request.fields['postcode'] = postcode;
      if (accessInstructions != null) request.fields['access_instructions'] = accessInstructions;
      if (vanPlacement != null) request.fields['van_placement'] = vanPlacement;
      if (generalNotes != null) request.fields['general_notes'] = generalNotes;
      // Always send schedule_type and daycare_days (falling back to the dog's
      // current values) so they can never be silently dropped from the payload.
      request.fields['daycare_days'] = json.encode((daysInDaycare ?? dog.daysInDaycare).map((d) => d.dayNumber).toList());
      if (preferredDropoffTime != null) request.fields['preferred_dropoff_time'] = preferredDropoffTime.apiValue;
      request.fields['schedule_type'] = (scheduleType ?? dog.scheduleType).apiValue;
      if (ownerBringsDefault != null) request.fields['owner_brings_default'] = ownerBringsDefault.toString();
      if (ownerCollectsDefault != null) request.fields['owner_collects_default'] = ownerCollectsDefault.toString();
      if (ownerBringsDefaultTime != null) request.fields['owner_brings_default_time'] = formatApiTime(ownerBringsDefaultTime);
      if (ownerCollectsDefaultTime != null) request.fields['owner_collects_default_time'] = formatApiTime(ownerCollectsDefaultTime);
      if (sex != null) request.fields['sex'] = dogSexToApi(sex)!;
      if (dateOfBirth != null) request.fields['date_of_birth'] = formatApiDate(dateOfBirth)!;
      if (clearDateOfBirth) request.fields['date_of_birth'] = '';
      if (isSpayed != null) request.fields['is_spayed'] = isSpayed.toString();

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
          'registered_vet': registeredVet ?? dog.registeredVet,
          'address': address ?? dog.address,
          'postcode': postcode ?? dog.postcode,
          'access_instructions': accessInstructions ?? dog.accessInstructions,
          'van_placement': vanPlacement ?? dog.vanPlacement,
          'general_notes': generalNotes ?? dog.generalNotes,
          // Always send schedule_type and daycare_days (falling back to the
          // dog's current values) so they can never be silently dropped from
          // the payload when the caller passes null.
          'daycare_days': (daysInDaycare ?? dog.daysInDaycare).map((d) => d.dayNumber).toList(),
          if (preferredDropoffTime != null) 'preferred_dropoff_time': preferredDropoffTime.apiValue,
          'schedule_type': (scheduleType ?? dog.scheduleType).apiValue,
          if (ownerBringsDefault != null) 'owner_brings_default': ownerBringsDefault,
          if (ownerCollectsDefault != null) 'owner_collects_default': ownerCollectsDefault,
          if (ownerBringsDefaultTime != null) 'owner_brings_default_time': formatApiTime(ownerBringsDefaultTime),
          if (ownerCollectsDefaultTime != null) 'owner_collects_default_time': formatApiTime(ownerCollectsDefaultTime),
          if (sex != null) 'sex': dogSexToApi(sex),
          if (dateOfBirth != null) 'date_of_birth': formatApiDate(dateOfBirth),
          if (clearDateOfBirth) 'date_of_birth': null,
          if (isSpayed != null) 'is_spayed': isSpayed,
        }),
      );
    }

    // 202 means the changes were submitted for staff approval
    if (response.statusCode == 202) {
      final body = json.decode(response.body);
      throw DogUpdatePendingApprovalException(
        body['detail'] ?? 'Your changes have been submitted for approval.',
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
      registeredVet: data['registered_vet'],
      address: data['address'],
      postcode: data['postcode'],
      accessInstructions: data['access_instructions'],
      vanPlacement: data['van_placement'],
      generalNotes: data['general_notes'],
      daysInDaycare: updatedDaysInDaycare,
      ownerDetails: ownerDetails,
      additionalOwners: additionalOwners,
      preferredDropoffTime: DropoffTimeExtension.fromApiValue(data['preferred_dropoff_time']),
      scheduleType: ScheduleTypeExtension.fromApiValue(data['schedule_type']),
      ownerBringsDefault: data['owner_brings_default'] ?? false,
      ownerCollectsDefault: data['owner_collects_default'] ?? false,
      ownerBringsDefaultTime: parseApiTime(data['owner_brings_default_time']),
      ownerCollectsDefaultTime: parseApiTime(data['owner_collects_default_time']),
      sex: parseDogSex(data['sex']),
      dateOfBirth: parseApiDate(data['date_of_birth']),
      isSpayed: data['is_spayed'] ?? false,
    );
  }

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
    final isVideo = _isVideoFileName(imageName);

    final response = await http.sendMultipart(
      method: 'POST',
      url: Uri.parse('${AuthService.baseUrl}/api/photos/'),
      fill: (request) {
        request.headers['Authorization'] = 'Token $token';
        request.fields['dog'] = dogId;
        request.fields['taken_at'] = takenAt.toIso8601String();
        request.fields['media_type'] = isVideo ? 'VIDEO' : 'PHOTO';
        request.files.add(http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: imageName,
        ));
      },
    );

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
  Future<PhotoBatchResult> uploadMultiplePhotos(
    String dogId,
    List<(Uint8List, String, DateTime)> images, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final uploaded = <Photo>[];
    final failures = <UploadFailure>[];

    for (var i = 0; i < images.length; i++) {
      final (imageBytes, imageName, takenAt) = images[i];
      try {
        // uploadPhoto retries transient failures internally; keep going on a
        // permanent failure so one bad photo doesn't abort the whole batch.
        uploaded.add(await uploadPhoto(dogId, imageBytes, imageName, takenAt));
      } catch (e) {
        failures.add((index: i, fileName: imageName, error: e));
      }
      onProgress?.call(i + 1, images.length);
    }

    return (uploaded: uploaded, failures: failures);
  }

  @override
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, String? registeredVet, String? address, String? postcode, String? accessInstructions, String? vanPlacement, String? generalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare, String? ownerId, DropoffTime? preferredDropoffTime, ScheduleType? scheduleType, bool? ownerBringsDefault, bool? ownerCollectsDefault, TimeOfDay? ownerBringsDefaultTime, TimeOfDay? ownerCollectsDefaultTime, DogSex? sex, DateTime? dateOfBirth, bool? isSpayed}) async {
    final token = await _authService.getToken();

    if (imageBytes != null) {
      // Use multipart request for file upload
      var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/dogs/'));
      request.headers['Authorization'] = 'Token $token';

      request.fields['name'] = name;
      if (foodInstructions != null) request.fields['food_instructions'] = foodInstructions;
      if (medicalNotes != null) request.fields['medical_notes'] = medicalNotes;
      if (registeredVet != null) request.fields['registered_vet'] = registeredVet;
      if (address != null) request.fields['address'] = address;
      if (postcode != null) request.fields['postcode'] = postcode;
      if (accessInstructions != null) request.fields['access_instructions'] = accessInstructions;
      if (vanPlacement != null) request.fields['van_placement'] = vanPlacement;
      if (generalNotes != null) request.fields['general_notes'] = generalNotes;
      if (daysInDaycare != null && daysInDaycare.isNotEmpty) request.fields['daycare_days'] = json.encode(daysInDaycare.map((d) => d.dayNumber).toList());
      if (ownerId != null) request.fields['owner'] = ownerId;
      if (preferredDropoffTime != null) request.fields['preferred_dropoff_time'] = preferredDropoffTime.apiValue;
      if (scheduleType != null) request.fields['schedule_type'] = scheduleType.apiValue;
      if (ownerBringsDefault != null) request.fields['owner_brings_default'] = ownerBringsDefault.toString();
      if (ownerCollectsDefault != null) request.fields['owner_collects_default'] = ownerCollectsDefault.toString();
      if (ownerBringsDefaultTime != null) request.fields['owner_brings_default_time'] = formatApiTime(ownerBringsDefaultTime);
      if (ownerCollectsDefaultTime != null) request.fields['owner_collects_default_time'] = formatApiTime(ownerCollectsDefaultTime);
      if (sex != null) request.fields['sex'] = dogSexToApi(sex)!;
      if (dateOfBirth != null) request.fields['date_of_birth'] = formatApiDate(dateOfBirth)!;
      if (isSpayed != null) request.fields['is_spayed'] = isSpayed.toString();

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
          registeredVet: data['registered_vet'],
          address: data['address'],
          postcode: data['postcode'],
          accessInstructions: data['access_instructions'],
          vanPlacement: data['van_placement'],
          generalNotes: data['general_notes'],
          daysInDaycare: daysInDaycareResult,
          ownerDetails: ownerDetails,
          additionalOwners: additionalOwners,
          preferredDropoffTime: DropoffTimeExtension.fromApiValue(data['preferred_dropoff_time']),
          scheduleType: ScheduleTypeExtension.fromApiValue(data['schedule_type']),
          ownerBringsDefault: data['owner_brings_default'] ?? false,
          ownerCollectsDefault: data['owner_collects_default'] ?? false,
          ownerBringsDefaultTime: parseApiTime(data['owner_brings_default_time']),
          ownerCollectsDefaultTime: parseApiTime(data['owner_collects_default_time']),
          sex: parseDogSex(data['sex']),
          dateOfBirth: parseApiDate(data['date_of_birth']),
          isSpayed: data['is_spayed'] ?? false,
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
          'registered_vet': registeredVet,
          'address': address,
          'postcode': postcode,
          'access_instructions': accessInstructions,
          'van_placement': vanPlacement,
          'general_notes': generalNotes,
          if (daysInDaycare != null && daysInDaycare.isNotEmpty) 'daycare_days': daysInDaycare.map((d) => d.dayNumber).toList(),
          if (ownerId != null) 'owner': int.parse(ownerId),
          if (preferredDropoffTime != null) 'preferred_dropoff_time': preferredDropoffTime.apiValue,
          if (scheduleType != null) 'schedule_type': scheduleType.apiValue,
          if (ownerBringsDefault != null) 'owner_brings_default': ownerBringsDefault,
          if (ownerCollectsDefault != null) 'owner_collects_default': ownerCollectsDefault,
          if (ownerBringsDefaultTime != null) 'owner_brings_default_time': formatApiTime(ownerBringsDefaultTime),
          if (ownerCollectsDefaultTime != null) 'owner_collects_default_time': formatApiTime(ownerCollectsDefaultTime),
          if (sex != null) 'sex': dogSexToApi(sex),
          if (dateOfBirth != null) 'date_of_birth': formatApiDate(dateOfBirth),
          if (isSpayed != null) 'is_spayed': isSpayed,
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
          registeredVet: data['registered_vet'],
          address: data['address'],
          postcode: data['postcode'],
          accessInstructions: data['access_instructions'],
          vanPlacement: data['van_placement'],
          generalNotes: data['general_notes'],
          daysInDaycare: daysInDaycareResult,
          ownerDetails: ownerDetails,
          additionalOwners: additionalOwners,
          preferredDropoffTime: DropoffTimeExtension.fromApiValue(data['preferred_dropoff_time']),
          scheduleType: ScheduleTypeExtension.fromApiValue(data['schedule_type']),
          ownerBringsDefault: data['owner_brings_default'] ?? false,
          ownerCollectsDefault: data['owner_collects_default'] ?? false,
          ownerBringsDefaultTime: parseApiTime(data['owner_brings_default_time']),
          ownerCollectsDefaultTime: parseApiTime(data['owner_collects_default_time']),
          sex: parseDogSex(data['sex']),
          dateOfBirth: parseApiDate(data['date_of_birth']),
          isSpayed: data['is_spayed'] ?? false,
        );
      } else {
        throw Exception('Failed to create dog: ${response.body}');
      }
    }
  }

  @override
  Future<List<PostcodeAddress>> lookupPostcode(String postcode) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/postcode/lookup/?postcode=${Uri.encodeQueryComponent(postcode)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final list = (data['addresses'] as List<dynamic>? ?? const []);
      return list
          .map((a) => PostcodeAddress.fromJson(a as Map<String, dynamic>))
          .toList();
    }
    // Surface the backend's friendly message where available.
    String message = 'Address lookup failed (${response.statusCode}).';
    try {
      final err = json.decode(response.body);
      if (err is Map && err['detail'] != null) message = err['detail'].toString();
    } catch (_) {}
    throw Exception(message);
  }

  @override
  Future<UnspayedMalesResult> getUnspayedMales() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/dogs/unspayed_males/'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load unspayed males: ${response.body}');
    }
    final data = json.decode(response.body) as Map<String, dynamic>;
    final dogs = (data['dogs'] as List<dynamic>? ?? [])
        .map((d) => UnspayedMaleSummary(
              id: d['id'].toString(),
              name: d['name']?.toString() ?? '',
              imageUrl: d['profile_image']?.toString(),
            ))
        .toList();
    return UnspayedMalesResult(count: data['count'] ?? dogs.length, dogs: dogs);
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
  Future<Dog> assignDogToUser(String dogId, {int? owner, List<int>? additionalOwners, bool removeOwner = false}) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{};
    // Send an explicit null to clear the primary owner; otherwise only include
    // the owner key when a new owner is given, so we never clear it by accident.
    if (removeOwner) {
      body['owner'] = null;
    } else if (owner != null) {
      body['owner'] = owner;
    }
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
      registeredVet: data['registered_vet'],
      address: data['address'],
      postcode: data['postcode'],
      accessInstructions: data['access_instructions'],
      vanPlacement: data['van_placement'],
      generalNotes: data['general_notes'],
      daysInDaycare: daysInDaycare,
      ownerDetails: ownerDetails,
      additionalOwners: additionalOwnersList,
      cancelledDates: parseApiDateList(data['cancelled_dates']),
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
  Future<List<DateTime>> getDogPastAttendance(String dogId, {DateTime? from}) async {
    final headers = await _getHeaders();
    var uri = Uri.parse('${AuthService.baseUrl}/api/dogs/$dogId/past-attendance/');
    if (from != null) {
      uri = uri.replace(queryParameters: {'from': from.toIso8601String().split('T').first});
    }
    final response = await http.get(uri, headers: headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to load past attendance: ${response.statusCode}');
    }
    final data = json.decode(response.body);
    return (data['dates'] as List).map((d) => DateTime.parse(d as String)).toList();
  }

  @override
  Future<List<DateChangeRequest>> getDateChangeRequests({String? dogId}) async {
    final data = await _fetchAllPages(
      Uri.parse('${AuthService.baseUrl}/api/date-change-requests/'),
    );
    var requests = data.map((json) => DateChangeRequest.fromJson(json)).toList();

    // Filter by dogId if specified
    if (dogId != null) {
      requests = requests.where((r) => r.dogId == dogId).toList();
    }

    return requests;
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
  /// Backwards-compatible: returns the first page of the feed as a flat list.
  /// New code should prefer [getFeedPage] for infinite scrolling.
  Future<List<gm.GroupMedia>> getFeed({String? dogId}) async {
    final page = await getFeedPage(dogId: dogId, page: 1);
    return page.items;
  }

  /// Fetch a single page of the feed.
  ///
  /// The backend paginates the feed endpoint (`{count, next, previous,
  /// results}`), but this also tolerates a plain JSON array in case the API is
  /// unpaginated. Only the first page is cached, for offline warm-start.
  Future<FeedPage> getFeedPage({String? dogId, int page = 1}) async {
    final cache = CacheService();
    try {
      final headers = await _getHeaders();
      final params = <String, String>{'page': '$page'};
      if (dogId != null) params['dog_id'] = dogId;
      final url = Uri.parse('${AuthService.baseUrl}/api/feed/')
          .replace(queryParameters: params);
      final response = await http.get(url, headers: headers);

      if (response.statusCode == 200) {
        // Decode + parse off the UI isolate to keep feed loads/refreshes smooth.
        final parsed = await compute(_parseFeedResponseBody, response.body);
        if (page == 1) cache.cacheFeed(parsed.rawItems);
        return FeedPage(items: parsed.items, hasMore: parsed.hasMore);
      } else {
        throw Exception('Failed to load feed');
      }
    } catch (e) {
      // Offline: fall back to the cached first page only.
      if (page == 1) {
        final cached = cache.getCachedFeed();
        if (cached != null && cached.isNotEmpty) {
          return FeedPage(
            items: cached.map((j) => gm.GroupMedia.fromJson(j)).toList(),
            hasMore: false,
          );
        }
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
    void Function(int sentBytes, int totalBytes)? onSendProgress,
  }) async {
    final token = await _authService.getToken();

    final response = await http.sendMultipart(
      method: 'POST',
      url: Uri.parse('${AuthService.baseUrl}/api/feed/'),
      onProgress: onSendProgress,
      fill: (request) {
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
      },
    );

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

  /// Upload multiple media files to the group feed.
  ///
  /// Transient failures (dead connections, stalls, 5xx) are retried per file
  /// inside [uploadGroupMedia]; if a file still fails the batch continues with
  /// the remaining files. Returns the list of files that ultimately failed
  /// (empty list means everything succeeded).
  ///
  /// [onProgress] fires after each file is processed (success or final
  /// failure) with (completed, total). [onFileProgress] fires as bytes of
  /// file [index] are sent, for byte-level progress UI.
  Future<List<UploadFailure>> uploadMultipleGroupMedia({
    required List<(Uint8List, String)> files,
    String? caption,
    List<String?>? captionsByFile,
    List<List<String>>? taggedDogIdsByFile,
    void Function(int completed, int total)? onProgress,
    void Function(int index, int sentBytes, int totalBytes)? onFileProgress,
  }) async {
    final failures = <UploadFailure>[];

    for (int i = 0; i < files.length; i++) {
      final (bytes, fileName) = files[i];
      final fileCaption = (captionsByFile != null && i < captionsByFile.length)
          ? captionsByFile[i]
          : caption;
      final dogIds = taggedDogIdsByFile != null && i < taggedDogIdsByFile.length
          ? taggedDogIdsByFile[i]
          : null;

      try {
        await uploadGroupMedia(
          fileBytes: bytes,
          fileName: fileName,
          isVideo: _isVideoFileName(fileName),
          caption: fileCaption,
          taggedDogIds: dogIds,
          onSendProgress: onFileProgress == null
              ? null
              : (sent, total) => onFileProgress(i, sent, total),
        );
      } catch (e) {
        failures.add((index: i, fileName: fileName, error: e));
      }
      onProgress?.call(i + 1, files.length);
    }

    return failures;
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
    final data = await _fetchAllPages(
      Uri.parse('${AuthService.baseUrl}/api/boarding-requests/'),
    );
    return data.map((json) => BoardingRequest.fromJson(json)).toList();
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
          // Validation errors (e.g. duplicate booking) arrive as lists.
          final first = errorData.values.first;
          if (first is List && first.isNotEmpty) {
            errorMessage = first.first.toString();
          } else {
            errorMessage = first?.toString() ?? errorMessage;
          }
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  Future<void> updateBoardingRequestStatus(int requestId, String status, {int? assignedStaffId}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/boarding-requests/$requestId/change_status/'),
      headers: headers,
      body: json.encode({
        'status': status,
        if (assignedStaffId != null) 'assigned_staff_id': assignedStaffId,
      }),
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
  Future<void> deleteBoardingRequest(int requestId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/boarding-requests/$requestId/'),
      headers: headers,
    );
    if (response.statusCode != 204) {
      String errorMessage = 'Failed to delete boarding request';
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

  /// Amend an existing boarding booking (dates and/or instructions). Owners
  /// can only edit while the request is still pending; staff can edit any.
  @override
  Future<void> updateBoardingRequest(
    int requestId, {
    DateTime? startDate,
    DateTime? endDate,
    String? specialInstructions,
  }) async {
    final headers = await _getHeaders();
    final response = await http.patch(
      Uri.parse('${AuthService.baseUrl}/api/boarding-requests/$requestId/'),
      headers: headers,
      body: json.encode({
        if (startDate != null) 'start_date': startDate.toIso8601String().split('T').first,
        if (endDate != null) 'end_date': endDate.toIso8601String().split('T').first,
        if (specialInstructions != null) 'special_instructions': specialInstructions,
      }),
    );

    if (response.statusCode != 200) {
      String errorMessage = 'Failed to update boarding request';
      try {
        final errorData = json.decode(response.body);
        if (errorData is Map) {
          // Validation errors (e.g. duplicate booking) arrive as lists.
          final first = errorData.values.first;
          if (first is List && first.isNotEmpty) {
            errorMessage = first.first.toString();
          } else {
            errorMessage = first?.toString() ?? errorMessage;
          }
        }
      } catch (_) {
        errorMessage = 'Server error (${response.statusCode})';
      }
      throw Exception(errorMessage);
    }
  }

  /// Set or change which staff member a boarding dog stays with. Pass null to
  /// clear the assignment.
  Future<void> assignBoardingStaff(int requestId, int? staffId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/boarding-requests/$requestId/assign_staff/'),
      headers: headers,
      body: json.encode({'assigned_staff_id': staffId}),
    );

    if (response.statusCode != 200) {
      String errorMessage = 'Failed to assign boarding staff';
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
        debugPrint('Failed to register device token: ${response.body}');
      }
    }
  }

  @override
  Future<void> deregisterDeviceToken(String token) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/device-tokens/deregister/'),
      headers: headers,
      body: json.encode({'token': token}),
    );

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint('Failed to deregister device token: ${response.body}');
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
  Future<List<CompatibilityConflict>> getCompatibilityConflicts({DateTime? date}) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/compatibility_conflicts/${_dateParam(date)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final list = data['conflicts'] as List<dynamic>? ?? [];
      return list
          .map((c) => CompatibilityConflict.fromJson(c as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Failed to load compatibility conflicts: ${response.statusCode}');
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
      return _parseDogsList(data);
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
  Future<void> removeDogFromDay(int dogId, DateTime date) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/daily-assignments/mark_removed/'),
      headers: headers,
      body: json.encode({
        'dog_id': dogId,
        'date': _dateBody(date),
      }),
    );
    if (response.statusCode != 204) {
      String errorMessage = 'Failed to remove dog from day';
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
  Future<ClosureDay> createClosureDay({required DateTime date, required ClosureType closureType, String reason = '', int? capacityOverride}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/closure-days/'),
      headers: headers,
      body: json.encode({
        'date': date.toIso8601String().split('T').first,
        'closure_type': closureType.apiValue,
        'reason': reason,
        'capacity_override': capacityOverride,
      }),
    );
    if (response.statusCode == 201) {
      return ClosureDay.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to create closure day: ${response.body}');
  }

  // ── Vaccinations ───────────────────────────────────────────────────

  @override
  Future<List<VaccinationRecord>> getVaccinations(String dogId) async {
    final data = await _fetchAllPages(
      Uri.parse('${AuthService.baseUrl}/api/vaccinations/?dog=$dogId'),
    );
    return data.map((e) => VaccinationRecord.fromJson(e)).toList();
  }

  @override
  Future<VaccinationRecord> createVaccination({
    required String dogId,
    required String name,
    required DateTime dateAdministered,
    required DateTime expiryDate,
    String? notes,
  }) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/vaccinations/'),
      headers: headers,
      body: json.encode({
        'dog': dogId,
        'name': name,
        'date_administered': dateAdministered.toIso8601String().split('T').first,
        'expiry_date': expiryDate.toIso8601String().split('T').first,
        'notes': notes,
      }),
    );
    if (response.statusCode == 201) {
      return VaccinationRecord.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to add vaccination: ${response.body}');
  }

  @override
  Future<VaccinationRecord> updateVaccination(
    int id, {
    String? name,
    DateTime? dateAdministered,
    DateTime? expiryDate,
    String? notes,
  }) async {
    final headers = await _getHeaders();
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (dateAdministered != null) {
      body['date_administered'] = dateAdministered.toIso8601String().split('T').first;
    }
    if (expiryDate != null) {
      body['expiry_date'] = expiryDate.toIso8601String().split('T').first;
    }
    if (notes != null) body['notes'] = notes;
    final response = await http.patch(
      Uri.parse('${AuthService.baseUrl}/api/vaccinations/$id/'),
      headers: headers,
      body: json.encode(body),
    );
    if (response.statusCode == 200) {
      return VaccinationRecord.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to update vaccination: ${response.body}');
  }

  @override
  Future<void> deleteVaccination(int id) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/vaccinations/$id/'),
      headers: headers,
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to delete vaccination: ${response.statusCode}');
    }
  }

  // ── Owner calendar & waitlist ──────────────────────────────────────

  @override
  Future<OwnerCalendar> getOwnerCalendar({DateTime? start, DateTime? end}) async {
    final headers = await _getHeaders();
    final params = <String, String>{};
    if (start != null) params['start'] = start.toIso8601String().split('T').first;
    if (end != null) params['end'] = end.toIso8601String().split('T').first;
    final uri = Uri.parse('${AuthService.baseUrl}/api/dogs/calendar/')
        .replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      return OwnerCalendar.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to load calendar: ${response.statusCode}');
  }

  @override
  Future<WaitlistEntry> joinWaitlist({required String dogId, required DateTime date}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/waitlist/'),
      headers: headers,
      body: json.encode({
        'dog': dogId,
        'date': date.toIso8601String().split('T').first,
      }),
    );
    if (response.statusCode == 201 || response.statusCode == 200) {
      return WaitlistEntry.fromJson(json.decode(response.body));
    }
    String message = 'Failed to join waitlist';
    try {
      final data = json.decode(response.body);
      if (data is Map && data['detail'] != null) message = data['detail'];
    } catch (_) {}
    throw Exception(message);
  }

  @override
  Future<void> leaveWaitlist(int entryId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/waitlist/$entryId/'),
      headers: headers,
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to leave waitlist: ${response.statusCode}');
    }
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
  Future<List<StaffAvailability>> getStaffAvailability(int staffId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/staff-availability/?staff_member=$staffId'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => StaffAvailability.fromJson(e)).toList();
    }
    throw Exception('Failed to load staff availability: ${response.statusCode}');
  }

  @override
  Future<List<StaffAvailability>> setStaffAvailability(int staffId, List<Map<String, dynamic>> availability) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/staff-availability/set_staff_availability/'),
      headers: headers,
      body: json.encode({'staff_member': staffId, 'availability': availability}),
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => StaffAvailability.fromJson(e)).toList();
    }
    throw Exception('Failed to set staff availability: ${response.body}');
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
  Future<Map<DateTime, List<String>>> getTeamTimeOff({required DateTime start, required DateTime end}) async {
    final headers = await _getHeaders();
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final uri = Uri.parse('${AuthService.baseUrl}/api/staff-availability/team_off/')
        .replace(queryParameters: {'start': fmt(start), 'end': fmt(end)});
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final Map<String, dynamic> data = json.decode(response.body);
      final result = <DateTime, List<String>>{};
      data.forEach((key, value) {
        final parts = key.split('-');
        final date = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        result[date] = (value as List).map((e) => e.toString()).toList();
      });
      return result;
    }
    throw Exception('Failed to load team time off: ${response.statusCode}');
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

  // --- Booking Forms (intake requests) ---

  @override
  Future<List<IntakeRequest>> getIntakeRequests() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/intake-requests/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((j) => IntakeRequest.fromJson(j)).toList();
    }
    throw Exception('Failed to fetch booking forms: ${response.statusCode}');
  }

  @override
  Future<IntakeRequest> submitIntakeRequest({
    String? phoneNumber,
    String? address,
    String? postcode,
    String? pickupInstructions,
    String? additionalInfo,
    required List<IntakeDog> dogs,
  }) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/intake-requests/'),
      headers: headers,
      body: json.encode({
        'phone_number': phoneNumber ?? '',
        'address': address ?? '',
        'postcode': postcode ?? '',
        'pickup_instructions': pickupInstructions ?? '',
        'additional_info': additionalInfo ?? '',
        'dogs': dogs.map((d) => d.toJson()).toList(),
      }),
    );
    if (response.statusCode == 201) {
      return IntakeRequest.fromJson(json.decode(response.body));
    }
    String errorMessage = 'Failed to submit booking form';
    try {
      final errorData = json.decode(response.body);
      if (errorData is Map && errorData.isNotEmpty) {
        final first = errorData.values.first;
        if (first is List && first.isNotEmpty) {
          errorMessage = first.first.toString();
        } else {
          errorMessage = first?.toString() ?? errorMessage;
        }
      }
    } catch (_) {
      errorMessage = 'Server error (${response.statusCode})';
    }
    throw Exception(errorMessage);
  }

  @override
  Future<IntakeRequest> approveIntakeRequest(int requestId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/intake-requests/$requestId/approve/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return IntakeRequest.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to approve booking form: ${response.statusCode}');
  }

  @override
  Future<IntakeRequest> denyIntakeRequest(int requestId, {String? reason}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/intake-requests/$requestId/deny/'),
      headers: headers,
      body: json.encode({'reason': reason ?? ''}),
    );
    if (response.statusCode == 200) {
      return IntakeRequest.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to deny booking form: ${response.statusCode}');
  }

  @override
  Future<void> deleteIntakeRequest(int requestId) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/intake-requests/$requestId/'),
      headers: headers,
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to withdraw booking form: ${response.statusCode}');
    }
  }

  // --- Dog Profile Change Requests ---

  @override
  Future<List<DogProfileChangeRequest>> getDogProfileChangeRequests({String? status}) async {
    final headers = await _getHeaders();
    var url = '${AuthService.baseUrl}/api/dog-profile-changes/';
    if (status != null) url += '?status=$status';
    final response = await http.get(Uri.parse(url), headers: headers);
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((j) => DogProfileChangeRequest.fromJson(j)).toList();
    }
    throw Exception('Failed to fetch dog profile change requests: ${response.statusCode}');
  }

  @override
  Future<DogProfileChangeRequest> approveDogProfileChange(int requestId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/dog-profile-changes/$requestId/approve/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return DogProfileChangeRequest.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to approve dog profile change: ${response.statusCode}');
  }

  @override
  Future<DogProfileChangeRequest> rejectDogProfileChange(int requestId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/dog-profile-changes/$requestId/reject/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return DogProfileChangeRequest.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to reject dog profile change: ${response.statusCode}');
  }

  @override
  Future<int> getPendingDogProfileChangeCount() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/dog-profile-changes/pending_count/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body)['count'] ?? 0;
    }
    return 0;
  }

  @override
  Future<List<StaffPermission>> listStaffPermissions() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/profile/list_staff_permissions/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => StaffPermission.fromJson(e as Map<String, dynamic>)).toList();
    }
    throw Exception('Failed to load staff permissions (${response.statusCode})');
  }

  @override
  Future<StaffPermission> updateStaffPermissions(int userId, Map<String, bool> permissions) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/profile/update_staff_permissions/?user_id=$userId'),
      headers: headers,
      body: json.encode(permissions),
    );
    if (response.statusCode == 200) {
      return StaffPermission.fromJson(json.decode(response.body));
    }
    String errorMessage = 'Failed to update permissions';
    try {
      final errorData = json.decode(response.body);
      if (errorData is Map && errorData['detail'] != null) {
        errorMessage = errorData['detail'].toString();
      }
    } catch (_) {}
    throw Exception(errorMessage);
  }

  // ── Fleet ──────────────────────────────────────────────────────────

  void _addVehicleFields(
    Map<String, String> fields, {
    String? name,
    String? registration,
    String? make,
    String? model,
    String? notes,
    String? status,
    DateTime? motDueDate,
    DateTime? serviceDueDate,
    String? maintenanceNotes,
  }) {
    if (name != null) fields['name'] = name;
    if (registration != null) fields['registration'] = registration;
    if (make != null) fields['make'] = make;
    if (model != null) fields['model'] = model;
    if (notes != null) fields['notes'] = notes;
    if (status != null) fields['status'] = status;
    if (motDueDate != null) {
      fields['mot_due_date'] = motDueDate.toIso8601String().split('T').first;
    }
    if (serviceDueDate != null) {
      fields['service_due_date'] = serviceDueDate.toIso8601String().split('T').first;
    }
    if (maintenanceNotes != null) fields['maintenance_notes'] = maintenanceNotes;
  }

  Future<Vehicle> _sendVehicleRequest(
    String method,
    Uri uri,
    Map<String, String> fields,
    Uint8List? imageBytes,
    String? imageName,
  ) async {
    final token = await _authService.getToken();
    final request = http.MultipartRequest(method, uri);
    request.headers['Authorization'] = 'Token $token';
    request.fields.addAll(fields);
    if (imageBytes != null) {
      final filename = imageName ?? 'vehicle.jpg';
      request.files.add(http.MultipartFile.fromBytes(
        'image',
        imageBytes,
        filename: filename,
        contentType: http_parser.MediaType('image', filename.endsWith('.png') ? 'png' : 'jpeg'),
      ));
    }
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode == 200 || response.statusCode == 201) {
      return Vehicle.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to save vehicle: ${response.body}');
  }

  @override
  Future<List<Vehicle>> getVehicles() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/vehicles/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => Vehicle.fromJson(e as Map<String, dynamic>)).toList();
    }
    throw Exception('Failed to load vehicles: ${response.statusCode}');
  }

  @override
  Future<Vehicle> getVehicle(int id) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/vehicles/$id/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return Vehicle.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to load vehicle: ${response.statusCode}');
  }

  @override
  Future<Vehicle> createVehicle({
    required String name,
    required String registration,
    String? make,
    String? model,
    String? notes,
    String? status,
    DateTime? motDueDate,
    DateTime? serviceDueDate,
    Uint8List? imageBytes,
    String? imageName,
  }) async {
    final fields = <String, String>{};
    _addVehicleFields(
      fields,
      name: name,
      registration: registration,
      make: make,
      model: model,
      notes: notes,
      status: status,
      motDueDate: motDueDate,
      serviceDueDate: serviceDueDate,
    );
    return _sendVehicleRequest(
      'POST',
      Uri.parse('${AuthService.baseUrl}/api/vehicles/'),
      fields,
      imageBytes,
      imageName,
    );
  }

  @override
  Future<Vehicle> updateVehicle(
    int id, {
    String? name,
    String? registration,
    String? make,
    String? model,
    String? notes,
    String? status,
    DateTime? motDueDate,
    DateTime? serviceDueDate,
    String? maintenanceNotes,
    Uint8List? imageBytes,
    String? imageName,
  }) async {
    final fields = <String, String>{};
    _addVehicleFields(
      fields,
      name: name,
      registration: registration,
      make: make,
      model: model,
      notes: notes,
      status: status,
      motDueDate: motDueDate,
      serviceDueDate: serviceDueDate,
      maintenanceNotes: maintenanceNotes,
    );
    return _sendVehicleRequest(
      'PATCH',
      Uri.parse('${AuthService.baseUrl}/api/vehicles/$id/'),
      fields,
      imageBytes,
      imageName,
    );
  }

  @override
  Future<void> deleteVehicle(int id) async {
    final headers = await _getHeaders();
    final response = await http.delete(
      Uri.parse('${AuthService.baseUrl}/api/vehicles/$id/'),
      headers: headers,
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to delete vehicle: ${response.statusCode}');
    }
  }

  @override
  Future<List<VehicleMaintenanceRecord>> getVehicleHistory(int vehicleId) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/vehicles/$vehicleId/history/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data
          .map((e) => VehicleMaintenanceRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Failed to load vehicle history: ${response.statusCode}');
  }

  @override
  Future<List<VehicleDefect>> getVehicleDefects({int? vehicleId, String? status}) async {
    final headers = await _getHeaders();
    final params = <String, String>{};
    if (vehicleId != null) params['vehicle'] = vehicleId.toString();
    if (status != null) params['status'] = status;
    final uri = Uri.parse('${AuthService.baseUrl}/api/vehicle-defects/')
        .replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => VehicleDefect.fromJson(e as Map<String, dynamic>)).toList();
    }
    throw Exception('Failed to load defects: ${response.statusCode}');
  }

  @override
  Future<VehicleDefect> getVehicleDefect(int id) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/vehicle-defects/$id/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return VehicleDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to load defect: ${response.statusCode}');
  }

  void _addDefectImages(http.MultipartRequest request, List<(Uint8List, String)> images) {
    for (final (bytes, name) in images) {
      request.files.add(http.MultipartFile.fromBytes(
        'images',
        bytes,
        filename: name,
        contentType: http_parser.MediaType('image', name.endsWith('.png') ? 'png' : 'jpeg'),
      ));
    }
  }

  @override
  Future<VehicleDefect> createVehicleDefect({
    required int vehicleId,
    required String title,
    String? description,
    String? severity,
    List<(Uint8List, String)> images = const [],
  }) async {
    final token = await _authService.getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${AuthService.baseUrl}/api/vehicle-defects/'),
    );
    request.headers['Authorization'] = 'Token $token';
    request.fields['vehicle'] = vehicleId.toString();
    request.fields['title'] = title;
    if (description != null) request.fields['description'] = description;
    if (severity != null) request.fields['severity'] = severity;
    _addDefectImages(request, images);
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode == 201) {
      return VehicleDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to report defect: ${response.body}');
  }

  @override
  Future<VehicleDefect> addDefectImages(int defectId, List<(Uint8List, String)> images) async {
    final token = await _authService.getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${AuthService.baseUrl}/api/vehicle-defects/$defectId/add_images/'),
    );
    request.headers['Authorization'] = 'Token $token';
    _addDefectImages(request, images);
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode == 200) {
      return VehicleDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to add photos: ${response.body}');
  }

  @override
  Future<VehicleDefect> changeDefectStatus(int defectId, String status) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/vehicle-defects/$defectId/change_status/'),
      headers: headers,
      body: json.encode({'status': status}),
    );
    if (response.statusCode == 200) {
      return VehicleDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to update defect status: ${response.body}');
  }

  @override
  Future<VehicleDefect> addVehicleDefectComment(int defectId, String text) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/vehicle-defects/$defectId/comment/'),
      headers: headers,
      body: json.encode({'text': text}),
    );
    if (response.statusCode == 200) {
      return VehicleDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to add comment: ${response.body}');
  }

  @override
  Future<int> getUnresolvedVehicleDefectCount() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/vehicle-defects/unresolved_count/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['count'] ?? 0;
    } else {
      return 0;
    }
  }

  // ---- Facility Defects ----

  @override
  Future<List<FacilityDefect>> getFacilityDefects({String? status}) async {
    final headers = await _getHeaders();
    final params = <String, String>{};
    if (status != null) params['status'] = status;
    final uri = Uri.parse('${AuthService.baseUrl}/api/facility-defects/')
        .replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => FacilityDefect.fromJson(e as Map<String, dynamic>)).toList();
    }
    throw Exception('Failed to load defects: ${response.statusCode}');
  }

  @override
  Future<FacilityDefect> getFacilityDefect(int id) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/facility-defects/$id/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return FacilityDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to load defect: ${response.statusCode}');
  }

  @override
  Future<FacilityDefect> createFacilityDefect({
    required String title,
    String? location,
    String? description,
    String? severity,
    List<(Uint8List, String)> images = const [],
  }) async {
    final token = await _authService.getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${AuthService.baseUrl}/api/facility-defects/'),
    );
    request.headers['Authorization'] = 'Token $token';
    request.fields['title'] = title;
    if (location != null) request.fields['location'] = location;
    if (description != null) request.fields['description'] = description;
    if (severity != null) request.fields['severity'] = severity;
    _addDefectImages(request, images);
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode == 201) {
      return FacilityDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to report defect: ${response.body}');
  }

  @override
  Future<FacilityDefect> addFacilityDefectImages(int defectId, List<(Uint8List, String)> images) async {
    final token = await _authService.getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${AuthService.baseUrl}/api/facility-defects/$defectId/add_images/'),
    );
    request.headers['Authorization'] = 'Token $token';
    _addDefectImages(request, images);
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode == 200) {
      return FacilityDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to add photos: ${response.body}');
  }

  @override
  Future<FacilityDefect> changeFacilityDefectStatus(int defectId, String status) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/facility-defects/$defectId/change_status/'),
      headers: headers,
      body: json.encode({'status': status}),
    );
    if (response.statusCode == 200) {
      return FacilityDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to update defect status: ${response.body}');
  }

  @override
  Future<FacilityDefect> addFacilityDefectComment(int defectId, String text) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/facility-defects/$defectId/comment/'),
      headers: headers,
      body: json.encode({'text': text}),
    );
    if (response.statusCode == 200) {
      return FacilityDefect.fromJson(json.decode(response.body));
    }
    throw Exception('Failed to add comment: ${response.body}');
  }

  @override
  Future<int> getUnresolvedFacilityDefectCount() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/facility-defects/unresolved_count/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['count'] ?? 0;
    } else {
      return 0;
    }
  }
  // ---------------------------------------------------------------------
  // Customer payments
  // ---------------------------------------------------------------------

  String _invoiceError(http.Response response, String fallback) {
    try {
      final errorData = json.decode(response.body);
      if (errorData is Map<String, dynamic>) {
        final detail = errorData['detail'] ?? errorData.values.first;
        if (detail != null) return detail.toString();
      }
    } catch (_) {}
    return '$fallback (${response.statusCode})';
  }

  @override
  Future<List<Invoice>> getInvoices({int? year, int? month, String? status, int? customerId}) async {
    final headers = await _getHeaders();
    final params = <String, String>{
      if (year != null) 'year': '$year',
      if (month != null) 'month': '$month',
      if (status != null) 'status': status,
      if (customerId != null) 'customer': '$customerId',
    };
    final uri = Uri.parse('${AuthService.baseUrl}/api/invoices/')
        .replace(queryParameters: params.isEmpty ? null : params);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => Invoice.fromJson(e as Map<String, dynamic>)).toList();
    }
    throw Exception(_invoiceError(response, 'Failed to load invoices'));
  }

  @override
  Future<Invoice> getInvoice(int id) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/invoices/$id/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return Invoice.fromJson(json.decode(response.body));
    }
    throw Exception(_invoiceError(response, 'Failed to load invoice'));
  }

  Future<Invoice> _invoiceAction(int id, String actionPath, [Map<String, dynamic>? body]) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/invoices/$id/$actionPath/'),
      headers: headers,
      body: json.encode(body ?? {}),
    );
    if (response.statusCode == 200) {
      return Invoice.fromJson(json.decode(response.body));
    }
    throw Exception(_invoiceError(response, 'Invoice update failed'));
  }

  @override
  Future<({int created, int skipped, int manual})> generateInvoices(int year, int month, {int? customerId}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/invoices/generate/'),
      headers: headers,
      body: json.encode({
        'year': year,
        'month': month,
        if (customerId != null) 'customer': customerId,
      }),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (
        created: data['created'] as int,
        skipped: data['skipped'] as int,
        manual: (data['manual'] ?? 0) as int,
      );
    }
    throw Exception(_invoiceError(response, 'Failed to generate invoices'));
  }

  @override
  Future<Invoice> sendInvoice(int id) => _invoiceAction(id, 'send');

  @override
  Future<int> sendAllInvoices(int year, int month) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/invoices/send_all/'),
      headers: headers,
      body: json.encode({'year': year, 'month': month}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body)['sent'] as int;
    }
    throw Exception(_invoiceError(response, 'Failed to send invoices'));
  }

  @override
  Future<Invoice> regenerateInvoice(int id) => _invoiceAction(id, 'regenerate');

  @override
  Future<Invoice> recordInvoicePayment(int id, {required double amount, required String method, DateTime? paymentDate, String? notes}) {
    return _invoiceAction(id, 'record_payment', {
      'amount': amount.toStringAsFixed(2),
      'method': method,
      if (paymentDate != null) 'payment_date': paymentDate.toIso8601String().split('T').first,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
  }

  @override
  Future<Invoice> voidInvoice(int id) => _invoiceAction(id, 'void');

  @override
  Future<Invoice> addInvoiceLine(int id, {required String description, required double amount}) {
    return _invoiceAction(id, 'add_line', {
      'description': description,
      'amount': amount.toStringAsFixed(2),
    });
  }

  @override
  Future<Invoice> removeInvoiceLine(int id, int lineId) =>
      _invoiceAction(id, 'remove_line', {'line_id': lineId});

  @override
  Future<Invoice> pushInvoiceToXero(int id) => _invoiceAction(id, 'push_to_xero');

  @override
  Future<Map<String, dynamic>> syncXeroInvoices() async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/invoices/sync_xero/'),
      headers: headers,
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(_invoiceError(response, 'Xero sync failed'));
  }

  @override
  Future<String> getInvoicePayUrl(int id) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/invoices/$id/pay_url/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body)['url'] as String;
    }
    throw Exception(_invoiceError(response, 'Online payment is not available'));
  }

  @override
  Future<BillingSettings> getBillingSettings() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/billing-settings/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return BillingSettings.fromJson(json.decode(response.body));
    }
    throw Exception(_invoiceError(response, 'Failed to load pricing'));
  }

  @override
  Future<BillingSettings> updateBillingSettings({double? dayCarePrice, double? boardingPricePerNight, double? ownerTransportDiscount}) async {
    final headers = await _getHeaders();
    final response = await http.patch(
      Uri.parse('${AuthService.baseUrl}/api/billing-settings/'),
      headers: headers,
      body: json.encode({
        if (dayCarePrice != null) 'day_care_price': dayCarePrice.toStringAsFixed(2),
        if (boardingPricePerNight != null) 'boarding_price_per_night': boardingPricePerNight.toStringAsFixed(2),
        if (ownerTransportDiscount != null) 'owner_transport_discount': ownerTransportDiscount.toStringAsFixed(2),
      }),
    );
    if (response.statusCode == 200) {
      return BillingSettings.fromJson(json.decode(response.body));
    }
    throw Exception(_invoiceError(response, 'Failed to update pricing'));
  }

  @override
  Future<List<CustomerRate>> getCustomerRates() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/customer-rates/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((e) => CustomerRate.fromJson(e as Map<String, dynamic>)).toList();
    }
    throw Exception(_invoiceError(response, 'Failed to load customer rates'));
  }

  @override
  Future<CustomerRate> updateCustomerRates(int userId, {required double? daycareRate, required double? boardingRate, String? billingMode}) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/customer-rates/?user_id=$userId'),
      headers: headers,
      body: json.encode({
        'daycare_rate': daycareRate?.toStringAsFixed(2),
        'boarding_rate': boardingRate?.toStringAsFixed(2),
        if (billingMode != null) 'billing_mode': billingMode,
      }),
    );
    if (response.statusCode == 200) {
      return CustomerRate.fromJson(json.decode(response.body));
    }
    throw Exception(_invoiceError(response, 'Failed to update customer rates'));
  }

  @override
  Future<XeroContactMatches> getXeroContactMatches() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/xero/contact-matches/'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return XeroContactMatches.fromJson(json.decode(response.body));
    }
    throw Exception(_invoiceError(response, 'Failed to load Xero contact matches'));
  }

  @override
  Future<CustomerRate> pinXeroContact(int userId, String contactId) async {
    final headers = await _getHeaders();
    final response = await http.post(
      Uri.parse('${AuthService.baseUrl}/api/xero/pin-contact/'),
      headers: headers,
      body: json.encode({'user_id': userId, 'contact_id': contactId}),
    );
    if (response.statusCode == 200) {
      return CustomerRate.fromJson(json.decode(response.body));
    }
    throw Exception(_invoiceError(response, 'Failed to pin Xero contact'));
  }

  @override
  Future<List<XeroContact>> searchXeroContacts(String query) async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/xero/contacts/?q=${Uri.encodeQueryComponent(query)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['contacts'] as List<dynamic>)
          .map((e) => XeroContact.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception(_invoiceError(response, 'Xero contact search failed'));
  }

  @override
  Future<InvoiceSummary> getInvoiceSummary({int? year, int? month}) async {
    final headers = await _getHeaders();
    final params = <String, String>{
      if (year != null) 'year': '$year',
      if (month != null) 'month': '$month',
    };
    final uri = Uri.parse('${AuthService.baseUrl}/api/invoices/summary/')
        .replace(queryParameters: params.isEmpty ? null : params);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      return InvoiceSummary.fromJson(json.decode(response.body));
    }
    throw Exception(_invoiceError(response, 'Failed to load payment summary'));
  }
}
