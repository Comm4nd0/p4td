import 'package:flutter/material.dart' show Color;

import '../constants/app_colors.dart';
import 'comment.dart';

/// Media attached to an incident — a photo of a wound, a clip of a gate.
class IncidentMedia {
  final int id;

  /// 'PHOTO' | 'VIDEO'
  final String mediaType;
  final String? fileUrl;
  final String? thumbnailUrl;
  final String caption;

  IncidentMedia({
    required this.id,
    this.mediaType = 'PHOTO',
    this.fileUrl,
    this.thumbnailUrl,
    this.caption = '',
  });

  bool get isVideo => mediaType == 'VIDEO';

  factory IncidentMedia.fromJson(Map<String, dynamic> json) {
    return IncidentMedia(
      id: json['id'],
      mediaType: json['media_type'] ?? 'PHOTO',
      fileUrl: json['file'],
      thumbnailUrl: json['thumbnail'],
      caption: json['caption'] ?? '',
    );
  }
}

/// One dog's involvement in an incident. Two dogs in the same scuffle rarely
/// come out of it the same way, so role and injuries are per dog.
class IncidentDog {
  final int id;
  final String dogId;
  final String dogName;
  final String? ownerName;

  /// 'INVOLVED' | 'INSTIGATOR' | 'INJURED' | 'PRESENT'
  final String role;
  final String roleDisplay;
  final String injuries;
  final bool ownerNotified;

  IncidentDog({
    required this.id,
    required this.dogId,
    required this.dogName,
    this.ownerName,
    this.role = 'INVOLVED',
    this.roleDisplay = 'Involved',
    this.injuries = '',
    this.ownerNotified = false,
  });

  factory IncidentDog.fromJson(Map<String, dynamic> json) {
    return IncidentDog(
      id: json['id'],
      dogId: json['dog'].toString(),
      dogName: json['dog_name'] ?? '',
      ownerName: json['owner_name'],
      role: json['role'] ?? 'INVOLVED',
      roleDisplay: json['role_display'] ?? 'Involved',
      injuries: json['injuries'] ?? '',
      ownerNotified: json['owner_notified'] ?? false,
    );
  }
}

/// A dog named on an incident being written up, before it is submitted.
class IncidentDogEntry {
  final String dogId;
  final String dogName;
  String role;
  String injuries;

  IncidentDogEntry({
    required this.dogId,
    required this.dogName,
    this.role = 'INVOLVED',
    this.injuries = '',
  });

  Map<String, dynamic> toJson() => {
        'dog': int.tryParse(dogId) ?? dogId,
        'role': role,
        'injuries': injuries,
      };
}

/// A staff-only record of something that went wrong. Never shown to owners —
/// the API refuses them outright — so nothing here needs an owner-safe view.
class Incident {
  final int id;
  final String title;

  /// 'SCUFFLE' | 'BITE' | 'INJURY' | 'ILLNESS' | 'ESCAPE' | 'PROPERTY' |
  /// 'TRANSPORT' | 'OTHER'
  final String incidentType;
  final String typeDisplay;

  /// 'LOW' | 'MEDIUM' | 'HIGH' | 'CRITICAL'
  final String severity;
  final String severityDisplay;

  /// 'OPEN' | 'MONITORING' | 'RESOLVED'
  final String status;
  final String statusDisplay;

  final DateTime occurredAt;
  final String location;
  final String description;
  final String injuries;
  final String actionTaken;
  final bool vetRequired;
  final String vetDetails;
  final String resolutionNotes;
  final List<String> staffPresentNames;
  final String? reportedByName;
  final String? resolvedByName;
  final DateTime? resolvedAt;
  final List<IncidentDog> dogsInvolved;
  final List<IncidentMedia> media;
  final List<Comment> comments;

  /// Only sent by the summary shape used on a dog's profile.
  final List<String> dogNames;

  Incident({
    required this.id,
    required this.title,
    this.incidentType = 'OTHER',
    this.typeDisplay = 'Other',
    this.severity = 'LOW',
    this.severityDisplay = 'Minor',
    this.status = 'OPEN',
    this.statusDisplay = 'Open',
    required this.occurredAt,
    this.location = '',
    this.description = '',
    this.injuries = '',
    this.actionTaken = '',
    this.vetRequired = false,
    this.vetDetails = '',
    this.resolutionNotes = '',
    this.staffPresentNames = const [],
    this.reportedByName,
    this.resolvedByName,
    this.resolvedAt,
    this.dogsInvolved = const [],
    this.media = const [],
    this.comments = const [],
    this.dogNames = const [],
  });

  bool get isResolved => status == 'RESOLVED';

  /// Names to show in a list row, whichever shape the server sent.
  List<String> get involvedNames =>
      dogsInvolved.isNotEmpty ? dogsInvolved.map((d) => d.dogName).toList() : dogNames;

  factory Incident.fromJson(Map<String, dynamic> json) {
    return Incident(
      id: json['id'],
      title: json['title'] ?? '',
      incidentType: json['incident_type'] ?? 'OTHER',
      typeDisplay: json['type_display'] ?? 'Other',
      severity: json['severity'] ?? 'LOW',
      severityDisplay: json['severity_display'] ?? 'Minor',
      status: json['status'] ?? 'OPEN',
      statusDisplay: json['status_display'] ?? 'Open',
      occurredAt: DateTime.parse(json['occurred_at']),
      location: json['location'] ?? '',
      description: json['description'] ?? '',
      injuries: json['injuries'] ?? '',
      actionTaken: json['action_taken'] ?? '',
      vetRequired: json['vet_required'] ?? false,
      vetDetails: json['vet_details'] ?? '',
      resolutionNotes: json['resolution_notes'] ?? '',
      staffPresentNames:
          (json['staff_present_names'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      reportedByName: json['reported_by_name'],
      resolvedByName: json['resolved_by_name'],
      resolvedAt: json['resolved_at'] != null ? DateTime.parse(json['resolved_at']) : null,
      dogsInvolved: (json['dogs_involved'] as List<dynamic>? ?? [])
          .map((e) => IncidentDog.fromJson(e as Map<String, dynamic>))
          .toList(),
      media: (json['media'] as List<dynamic>? ?? [])
          .map((e) => IncidentMedia.fromJson(e as Map<String, dynamic>))
          .toList(),
      comments: (json['comments'] as List<dynamic>? ?? [])
          .map((e) => Comment.fromJson(e as Map<String, dynamic>))
          .toList(),
      dogNames: (json['dog_names'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
    );
  }
}

/// The incident types staff pick from, in the order the form shows them.
const List<(String, String)> kIncidentTypes = [
  ('SCUFFLE', 'Scuffle / fight'),
  ('BITE', 'Bite'),
  ('INJURY', 'Injury'),
  ('ILLNESS', 'Illness'),
  ('ESCAPE', 'Escape / loose dog'),
  ('PROPERTY', 'Property damage'),
  ('TRANSPORT', 'Transport / vehicle'),
  ('OTHER', 'Other'),
];

const List<(String, String)> kIncidentSeverities = [
  ('LOW', 'Minor'),
  ('MEDIUM', 'Moderate'),
  ('HIGH', 'Serious'),
  ('CRITICAL', 'Critical'),
];

const List<(String, String)> kIncidentRoles = [
  ('INVOLVED', 'Involved'),
  ('INSTIGATOR', 'Instigator'),
  ('INJURED', 'Injured'),
  ('PRESENT', 'Present'),
];


/// Badge colour for an incident's severity, shared by every incident screen.
Color incidentSeverityColor(String severity) {
  switch (severity) {
    case 'CRITICAL':
      return AppColors.error;
    case 'HIGH':
      return const Color(0xFFFD7E14);
    case 'MEDIUM':
      return AppColors.warning;
    default:
      return AppColors.success;
  }
}

/// Badge colour for an incident's status. Monitoring counts as still open.
Color incidentStatusColor(String status) {
  switch (status) {
    case 'RESOLVED':
      return AppColors.success;
    case 'MONITORING':
      return AppColors.warning;
    default:
      return AppColors.error;
  }
}
