import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/dog.dart';
import '../models/photo.dart';
import '../models/user_profile.dart';
import '../models/date_change_request.dart';
import '../models/group_media.dart';
import 'auth_service.dart';

abstract class DataService {
  Future<List<Dog>> getDogs();
  Future<List<Photo>> getPhotos(String dogId);
  Future<Photo> uploadPhoto(String dogId, Uint8List imageBytes, String imageName, DateTime takenAt);
  Future<UserProfile> getProfile();
  Future<void> updateProfile(UserProfile profile);
  Future<OwnerProfile> getOwnerProfile(int userId);
  Future<OwnerProfile> updateOwnerProfile(int userId, {String? address, String? phoneNumber, String? pickupInstructions});
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare});
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare});
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

  @override
  Future<List<Dog>> getDogs() async {
    final headers = await _getHeaders();
    final response = await http.get(Uri.parse('${AuthService.baseUrl}/api/dogs/'), headers: headers);

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
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
        
        return Dog(
          id: json['id'].toString(),
          name: json['name'],
          ownerId: (json['owner'] ?? '').toString(),
          profileImageUrl: json['profile_image'],
          foodInstructions: json['food_instructions'],
          medicalNotes: json['medical_notes'],
          daysInDaycare: daysInDaycare,
          ownerDetails: ownerDetails,
        );
      }).toList();
    } else {
      throw Exception('Failed to load dogs');
    }
  }

  @override
  Future<UserProfile> getProfile() async {
    final headers = await _getHeaders();
    final response = await http.get(Uri.parse('${AuthService.baseUrl}/api/profile/'), headers: headers);

    if (response.statusCode == 200) {
      return UserProfile.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to load profile');
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
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare}) async {
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

      if (deletePhoto) {
        request.fields['profile_image'] = '';  // Empty string to clear the image
      } else if (imageBytes != null) {
        request.files.add(http.MultipartFile.fromBytes(
          'profile_image',
          imageBytes,
          filename: imageName ?? 'dog_photo.jpg',
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

    return Dog(
      id: data['id'].toString(),
      name: data['name'],
      ownerId: (data['owner'] ?? '').toString(),
      profileImageUrl: data['profile_image'],
      foodInstructions: data['food_instructions'],
      medicalNotes: data['medical_notes'],
      daysInDaycare: updatedDaysInDaycare,
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
      return data.map((json) => Photo(
        id: json['id'].toString(),
        dogId: json['dog'].toString(),
        url: json['image'], 
        takenAt: DateTime.parse(json['taken_at']),
      )).toList();
    } else {
      throw Exception('Failed to load photos');
    }
  }

  Future<Photo> uploadPhoto(String dogId, Uint8List imageBytes, String imageName, DateTime takenAt) async {
    final token = await _authService.getToken();
    var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/photos/'));
    request.headers['Authorization'] = 'Token $token';

    request.fields['dog'] = dogId;
    request.fields['taken_at'] = takenAt.toIso8601String();
    request.files.add(http.MultipartFile.fromBytes(
      'image',
      imageBytes,
      filename: imageName,
    ));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 201) {
      final data = json.decode(response.body);
      return Photo(
        id: data['id'].toString(),
        dogId: data['dog'].toString(),
        url: data['image'],
        takenAt: DateTime.parse(data['taken_at']),
      );
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
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare}) async {
    final token = await _authService.getToken();
    
    if (imageBytes != null) {
      // Use multipart request for file upload
      var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/dogs/'));
      request.headers['Authorization'] = 'Token $token';
      
      request.fields['name'] = name;
      if (foodInstructions != null) request.fields['food_instructions'] = foodInstructions;
      if (medicalNotes != null) request.fields['medical_notes'] = medicalNotes;
      if (daysInDaycare != null && daysInDaycare.isNotEmpty) request.fields['daycare_days'] = json.encode(daysInDaycare.map((d) => d.dayNumber).toList());
      
      // Use bytes instead of file path for cross-platform compatibility
      request.files.add(http.MultipartFile.fromBytes(
        'profile_image',
        imageBytes,
        filename: imageName ?? 'dog_photo.jpg',
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
        
        return Dog(
          id: data['id'].toString(),
          name: data['name'],
          ownerId: data['owner'].toString(),
          profileImageUrl: data['profile_image'],
          foodInstructions: data['food_instructions'],
          medicalNotes: data['medical_notes'],
          daysInDaycare: daysInDaycareResult,
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
        
        return Dog(
          id: data['id'].toString(),
          name: data['name'],
          ownerId: data['owner'].toString(),
          foodInstructions: data['food_instructions'],
          medicalNotes: data['medical_notes'],
          daysInDaycare: daysInDaycareResult,
        );
      } else {
        throw Exception('Failed to create dog: ${response.body}');
      }
    }
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

  Future<List<GroupMedia>> getFeed() async {
    final headers = await _getHeaders();
    final response = await http.get(
      Uri.parse('${AuthService.baseUrl}/api/feed/'),
      headers: headers,
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => GroupMedia.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load feed');
    }
  }

  Future<void> uploadGroupMedia({
    required Uint8List fileBytes,
    required String fileName,
    required bool isVideo,
    String? caption,
    Uint8List? thumbnailBytes,
  }) async {
    final token = await _authService.getToken();
    var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/feed/'));
    request.headers['Authorization'] = 'Token $token';

    request.fields['media_type'] = isVideo ? 'VIDEO' : 'PHOTO';
    if (caption != null && caption.isNotEmpty) {
      request.fields['caption'] = caption;
    }

    request.files.add(http.MultipartFile.fromBytes(
      'file',
      fileBytes,
      filename: fileName,
    ));

    if (thumbnailBytes != null) {
      request.files.add(http.MultipartFile.fromBytes(
        'thumbnail',
        thumbnailBytes,
        filename: 'thumbnail.jpg',
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
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare}) async {
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
  Future<Dog> createDog({required String name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare}) async {
    return Dog(id: '99', name: name, ownerId: 'user1');
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
      ),
      Photo(
        id: 'p2',
        dogId: dogId,
        url: 'https://images.unsplash.com/photo-1591769225440-811ad7d6eca6?auto=format&fit=crop&w=500&q=60',
        takenAt: DateTime.now().subtract(const Duration(days: 3)),
      ),
      Photo(
        id: 'p3',
        dogId: dogId,
        url: 'https://images.unsplash.com/photo-1587300003388-59208cc962cb?auto=format&fit=crop&w=500&q=60',
        takenAt: DateTime.now().subtract(const Duration(days: 5)),
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
    );
  }
}
