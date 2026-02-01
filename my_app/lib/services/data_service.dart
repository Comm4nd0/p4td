import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/dog.dart';
import '../models/booking.dart';
import '../models/photo.dart';
import '../models/user_profile.dart';
import 'auth_service.dart';

abstract class DataService {
  Future<List<Dog>> getDogs();
  Future<List<Booking>> getBookings(String dogId);
  Future<List<Photo>> getPhotos(String dogId);
  Future<UserProfile> getProfile();
  Future<void> updateProfile(UserProfile profile);
  Future<Dog> updateDog(Dog dog, {String? name, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, bool deletePhoto = false, List<Weekday>? daysInDaycare});
  Future<List<String>> getBreeds();
  Future<Dog> createDog({required String name, required String breed, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare});
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
        
        return Dog(
          id: json['id'].toString(),
          name: json['name'],
          breed: json['breed'],
          ownerId: (json['owner'] ?? '').toString(),
          profileImageUrl: json['profile_image'],
          foodInstructions: json['food_instructions'],
          medicalNotes: json['medical_notes'],
          daysInDaycare: daysInDaycare,
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
      breed: data['breed'],
      ownerId: (data['owner'] ?? '').toString(),
      profileImageUrl: data['profile_image'],
      foodInstructions: data['food_instructions'],
      medicalNotes: data['medical_notes'],
      daysInDaycare: updatedDaysInDaycare,
    );
  }

  @override
  Future<List<Booking>> getBookings(String dogId) async {
    final headers = await _getHeaders();
    // Note: The API should ideally allow filtering by dog_id via query param or sub-route
    // For now, fetching all bookings (which are already filtered by user permission)
    // and filtering client-side for the specific dog.
    final response = await http.get(Uri.parse('${AuthService.baseUrl}/api/bookings/'), headers: headers);

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      
      return data
          .where((json) => json['dog'].toString() == dogId)
          .map((json) => Booking(
            id: json['id'].toString(),
            dogId: json['dog'].toString(),
            date: DateTime.parse(json['date']),
            status: _parseStatus(json['status']),
            notes: json['notes'],
          )).toList();
    } else {
      throw Exception('Failed to load bookings');
    }
  }

  @override
  Future<List<Photo>> getPhotos(String dogId) async {
    final headers = await _getHeaders();
    final response = await http.get(Uri.parse('${AuthService.baseUrl}/api/photos/'), headers: headers);

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      
      return data
          .where((json) => json['dog'].toString() == dogId)
          .map((json) => Photo(
            id: json['id'].toString(),
            dogId: json['dog'].toString(),
            url: json['image'], 
            takenAt: DateTime.parse(json['taken_at']),
          )).toList();
    } else {
      throw Exception('Failed to load photos');
    }
  }

  BookingStatus _parseStatus(String status) {
    switch (status) {
      case 'CONFIRMED': return BookingStatus.confirmed;
      case 'PENDING': return BookingStatus.pending;
      case 'CANCELLED': return BookingStatus.cancelled;
      default: return BookingStatus.pending;
    }
  }

  @override
  Future<List<String>> getBreeds() async {
    final headers = await _getHeaders();
    final response = await http.get(Uri.parse('${AuthService.baseUrl}/api/breeds/'), headers: headers);

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => json['name'].toString()).toList();
    } else {
      throw Exception('Failed to load breeds');
    }
  }

  @override
  Future<Dog> createDog({required String name, required String breed, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare}) async {
    final token = await _authService.getToken();
    
    if (imageBytes != null) {
      // Use multipart request for file upload
      var request = http.MultipartRequest('POST', Uri.parse('${AuthService.baseUrl}/api/dogs/'));
      request.headers['Authorization'] = 'Token $token';
      
      request.fields['name'] = name;
      request.fields['breed'] = breed;
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
          breed: data['breed'],
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
          'breed': breed,
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
          breed: data['breed'],
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
}

class MockDataService implements DataService {
  final _dogs = [
    Dog(
      id: '1',
      name: 'Buddy',
      breed: 'Golden Retriever',
      ownerId: 'user1',
      profileImageUrl: 'https://images.unsplash.com/photo-1552053831-71594a27632d?auto=format&fit=crop&w=500&q=60',
    ),
    Dog(
      id: '2',
      name: 'Bella',
      breed: 'French Bulldog',
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
  Future<List<String>> getBreeds() async {
    return ['Golden Retriever', 'French Bulldog', 'Labrador', 'Poodle'];
  }

  @override
  Future<Dog> createDog({required String name, required String breed, String? foodInstructions, String? medicalNotes, Uint8List? imageBytes, String? imageName, List<Weekday>? daysInDaycare}) async {
    return Dog(id: '99', name: name, breed: breed, ownerId: 'user1');
  }

  @override
  Future<List<Booking>> getBookings(String dogId) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return [
      Booking(
        id: 'b1',
        dogId: dogId,
        date: DateTime.now().add(const Duration(days: 2)),
        status: BookingStatus.confirmed,
        notes: 'Drop off at 8am',
      ),
      Booking(
        id: 'b2',
        dogId: dogId,
        date: DateTime.now().add(const Duration(days: 5)),
        status: BookingStatus.confirmed,
      ),
      Booking(
        id: 'b3',
        dogId: dogId,
        date: DateTime.now().add(const Duration(days: 10)),
        status: BookingStatus.pending,
      ),
    ];
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
}
