import 'dog.dart';
import 'intake_request.dart';

/// An existing dog the server thinks a link request may be about, with the
/// reasons it was suggested. Staff-only: owners never receive candidates.
class LinkCandidate {
  final int id;
  final String name;
  final String? profileImageUrl;
  final String? postcode;

  /// Who the dog is on the books under, or null when it has no owner yet.
  final String? ownerName;
  final bool nameMatches;
  final bool postcodeMatches;
  final bool phoneMatches;

  LinkCandidate({
    required this.id,
    required this.name,
    this.profileImageUrl,
    this.postcode,
    this.ownerName,
    this.nameMatches = false,
    this.postcodeMatches = false,
    this.phoneMatches = false,
  });

  factory LinkCandidate.fromJson(Map<String, dynamic> json) {
    final matches = json['matches'] as Map<String, dynamic>? ?? const {};
    return LinkCandidate(
      id: json['id'],
      name: json['name'] ?? '',
      profileImageUrl: json['profile_image'],
      postcode: json['postcode'],
      ownerName: json['owner_name'],
      nameMatches: matches['name'] == true,
      postcodeMatches: matches['postcode'] == true,
      phoneMatches: matches['phone'] == true,
    );
  }

  /// "Name · Postcode · Phone" — what agreed with the request.
  List<String> get matchLabels => [
        if (nameMatches) 'Name',
        if (postcodeMatches) 'Postcode',
        if (phoneMatches) 'Phone',
      ];
}

/// A client asking for a dog that already comes to daycare to be attached
/// to their account. Staff match it to the dog and approve, or deny.
class DogLinkRequest {
  final int id;
  final int? ownerId;
  final String ownerName;
  final String ownerEmail;
  final String dogName;
  final String? postcode;
  final String? phoneNumber;
  final String? notes;
  final IntakeRequestStatus status;
  final String? denialReason;

  /// The dog the account was linked to, once approved.
  final int? linkedDogId;
  final String? linkedDogName;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final DateTime? createdAt;

  /// Staff-only suggestions while the request is pending; null otherwise.
  final List<LinkCandidate>? candidates;

  DogLinkRequest({
    required this.id,
    this.ownerId,
    this.ownerName = '',
    this.ownerEmail = '',
    required this.dogName,
    this.postcode,
    this.phoneNumber,
    this.notes,
    this.status = IntakeRequestStatus.pending,
    this.denialReason,
    this.linkedDogId,
    this.linkedDogName,
    this.reviewedByName,
    this.reviewedAt,
    this.createdAt,
    this.candidates,
  });

  factory DogLinkRequest.fromJson(Map<String, dynamic> json) {
    return DogLinkRequest(
      id: json['id'],
      ownerId: json['owner'],
      ownerName: json['owner_name'] ?? '',
      ownerEmail: json['owner_email'] ?? '',
      dogName: json['dog_name'] ?? '',
      postcode: json['postcode'],
      phoneNumber: json['phone_number'],
      notes: json['notes'],
      status: parseIntakeRequestStatus(json['status']),
      denialReason: json['denial_reason'],
      linkedDogId: json['dog'],
      linkedDogName: json['linked_dog_name'],
      reviewedByName: json['reviewed_by_name'],
      reviewedAt: parseApiDate(json['reviewed_at']),
      createdAt: parseApiDate(json['created_at']),
      candidates: json['candidates'] is List
          ? (json['candidates'] as List)
              .map((c) => LinkCandidate.fromJson(c as Map<String, dynamic>))
              .toList()
          : null,
    );
  }
}
