/// Models for the manager-only Staff Management (HR) section: employment
/// records, pay history, meetings, appraisals, sickness and training.
library;

DateTime? _date(dynamic v) => v != null ? DateTime.tryParse(v.toString()) : null;

int _int(dynamic v) => v is int ? v : int.parse(v.toString());

class HolidaySummary {
  final int year;
  final double? allowanceDays;
  final int usedDays;
  final double? remainingDays;

  HolidaySummary({
    required this.year,
    this.allowanceDays,
    this.usedDays = 0,
    this.remainingDays,
  });

  factory HolidaySummary.fromJson(Map<String, dynamic> json) => HolidaySummary(
        year: _int(json['year']),
        allowanceDays: (json['allowance_days'] as num?)?.toDouble(),
        usedDays: (json['used_days'] as num?)?.toInt() ?? 0,
        remainingDays: (json['remaining_days'] as num?)?.toDouble(),
      );
}

class StaffPayRate {
  final int id;
  final int staffMemberId;
  final String payType; // HOURLY | SALARY
  final String rate;
  final DateTime effectiveFrom;
  final String note;
  final String? createdByName;

  StaffPayRate({
    required this.id,
    required this.staffMemberId,
    required this.payType,
    required this.rate,
    required this.effectiveFrom,
    this.note = '',
    this.createdByName,
  });

  String get payTypeLabel => payType == 'SALARY' ? 'per year' : 'per hour';

  factory StaffPayRate.fromJson(Map<String, dynamic> json) => StaffPayRate(
        id: json['id'],
        staffMemberId: _int(json['staff_member']),
        payType: json['pay_type'] ?? 'HOURLY',
        rate: json['rate']?.toString() ?? '0',
        effectiveFrom: DateTime.parse(json['effective_from']),
        note: json['note'] ?? '',
        createdByName: json['created_by_name'],
      );
}

class StaffHrRecord {
  final int id;
  final int userId;
  final String name;
  final String jobTitle;
  final DateTime? employmentStartDate;
  final DateTime? employmentEndDate;
  final String holidayAllowanceDays;
  final String emergencyContactName;
  final String emergencyContactPhone;
  final String emergencyContactRelationship;
  final String managerNotes;
  final StaffPayRate? currentPay;
  final HolidaySummary? holiday;

  StaffHrRecord({
    required this.id,
    required this.userId,
    required this.name,
    this.jobTitle = '',
    this.employmentStartDate,
    this.employmentEndDate,
    this.holidayAllowanceDays = '28',
    this.emergencyContactName = '',
    this.emergencyContactPhone = '',
    this.emergencyContactRelationship = '',
    this.managerNotes = '',
    this.currentPay,
    this.holiday,
  });

  factory StaffHrRecord.fromJson(Map<String, dynamic> json) => StaffHrRecord(
        id: json['id'],
        userId: _int(json['user']),
        name: json['staff_member_name'] ?? json['username'] ?? '',
        jobTitle: json['job_title'] ?? '',
        employmentStartDate: _date(json['employment_start_date']),
        employmentEndDate: _date(json['employment_end_date']),
        holidayAllowanceDays: json['holiday_allowance_days']?.toString() ?? '28',
        emergencyContactName: json['emergency_contact_name'] ?? '',
        emergencyContactPhone: json['emergency_contact_phone'] ?? '',
        emergencyContactRelationship: json['emergency_contact_relationship'] ?? '',
        managerNotes: json['manager_notes'] ?? '',
        currentPay: json['current_pay'] != null
            ? StaffPayRate.fromJson(json['current_pay'])
            : null,
        holiday: json['holiday'] != null
            ? HolidaySummary.fromJson(json['holiday'])
            : null,
      );
}

class StaffMeeting {
  final int id;
  final String title;
  final String meetingType; // ONE_TO_ONE | TEAM | RETURN_TO_WORK | OTHER
  final DateTime scheduledFor;
  final String location;
  final String agenda;
  final String minutes;
  final String status; // SCHEDULED | COMPLETED | CANCELLED
  final List<int> attendeeIds;
  final List<String> attendeeNames;
  final String? createdByName;

  StaffMeeting({
    required this.id,
    required this.title,
    this.meetingType = 'ONE_TO_ONE',
    required this.scheduledFor,
    this.location = '',
    this.agenda = '',
    this.minutes = '',
    this.status = 'SCHEDULED',
    this.attendeeIds = const [],
    this.attendeeNames = const [],
    this.createdByName,
  });

  String get meetingTypeLabel {
    switch (meetingType) {
      case 'TEAM':
        return 'Team meeting';
      case 'RETURN_TO_WORK':
        return 'Return to work';
      case 'OTHER':
        return 'Other';
      default:
        return 'One-to-one';
    }
  }

  factory StaffMeeting.fromJson(Map<String, dynamic> json) => StaffMeeting(
        id: json['id'],
        title: json['title'] ?? '',
        meetingType: json['meeting_type'] ?? 'ONE_TO_ONE',
        scheduledFor: DateTime.parse(json['scheduled_for']),
        location: json['location'] ?? '',
        agenda: json['agenda'] ?? '',
        minutes: json['minutes'] ?? '',
        status: json['status'] ?? 'SCHEDULED',
        attendeeIds: (json['attendees'] as List<dynamic>? ?? [])
            .map((e) => _int(e))
            .toList(),
        attendeeNames: (json['attendee_names'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        createdByName: json['created_by_name'],
      );
}

class StaffAppraisal {
  final int id;
  final int staffMemberId;
  final String staffMemberName;
  final String? appraiserName;
  final DateTime appraisalDate;
  final int? overallRating;
  final String summary;
  final String strengths;
  final String areasForImprovement;
  final String goals;
  final String staffComments;
  final DateTime? nextReviewDate;
  final String status; // DRAFT | SHARED | ACKNOWLEDGED
  final DateTime? sharedAt;
  final DateTime? acknowledgedAt;

  StaffAppraisal({
    required this.id,
    required this.staffMemberId,
    this.staffMemberName = '',
    this.appraiserName,
    required this.appraisalDate,
    this.overallRating,
    this.summary = '',
    this.strengths = '',
    this.areasForImprovement = '',
    this.goals = '',
    this.staffComments = '',
    this.nextReviewDate,
    this.status = 'DRAFT',
    this.sharedAt,
    this.acknowledgedAt,
  });

  String get statusLabel {
    switch (status) {
      case 'SHARED':
        return 'Shared';
      case 'ACKNOWLEDGED':
        return 'Acknowledged';
      default:
        return 'Draft';
    }
  }

  factory StaffAppraisal.fromJson(Map<String, dynamic> json) => StaffAppraisal(
        id: json['id'],
        staffMemberId: _int(json['staff_member']),
        staffMemberName: json['staff_member_name'] ?? '',
        appraiserName: json['appraiser_name'],
        appraisalDate: DateTime.parse(json['appraisal_date']),
        overallRating: (json['overall_rating'] as num?)?.toInt(),
        summary: json['summary'] ?? '',
        strengths: json['strengths'] ?? '',
        areasForImprovement: json['areas_for_improvement'] ?? '',
        goals: json['goals'] ?? '',
        staffComments: json['staff_comments'] ?? '',
        nextReviewDate: _date(json['next_review_date']),
        status: json['status'] ?? 'DRAFT',
        sharedAt: _date(json['shared_at']),
        acknowledgedAt: _date(json['acknowledged_at']),
      );
}

class SicknessAbsence {
  final int id;
  final int staffMemberId;
  final String staffMemberName;
  final DateTime startDate;
  final DateTime? endDate;
  final String reason;
  final String notes;
  final String? recordedByName;

  SicknessAbsence({
    required this.id,
    required this.staffMemberId,
    this.staffMemberName = '',
    required this.startDate,
    this.endDate,
    this.reason = '',
    this.notes = '',
    this.recordedByName,
  });

  bool get ongoing => endDate == null;

  factory SicknessAbsence.fromJson(Map<String, dynamic> json) => SicknessAbsence(
        id: json['id'],
        staffMemberId: _int(json['staff_member']),
        staffMemberName: json['staff_member_name'] ?? '',
        startDate: DateTime.parse(json['start_date']),
        endDate: _date(json['end_date']),
        reason: json['reason'] ?? '',
        notes: json['notes'] ?? '',
        recordedByName: json['recorded_by_name'],
      );
}

class StaffTrainingRecord {
  final int id;
  final int staffMemberId;
  final String name;
  final String provider;
  final DateTime? completedDate;
  final DateTime? expiryDate;
  final String expiryStatus; // VALID | EXPIRING | EXPIRED | NONE
  final String notes;

  StaffTrainingRecord({
    required this.id,
    required this.staffMemberId,
    required this.name,
    this.provider = '',
    this.completedDate,
    this.expiryDate,
    this.expiryStatus = 'NONE',
    this.notes = '',
  });

  factory StaffTrainingRecord.fromJson(Map<String, dynamic> json) =>
      StaffTrainingRecord(
        id: json['id'],
        staffMemberId: _int(json['staff_member']),
        name: json['name'] ?? '',
        provider: json['provider'] ?? '',
        completedDate: _date(json['completed_date']),
        expiryDate: _date(json['expiry_date']),
        expiryStatus: json['expiry_status'] ?? 'NONE',
        notes: json['notes'] ?? '',
      );
}

/// One row of `GET /api/staff-hr/team_overview/` — everything the staff
/// management list screen shows per person.
class TeamMemberOverview {
  final int staffMemberId;
  final String name;
  final String username;
  final String? profilePhoto;
  final String jobTitle;
  final DateTime? employmentStartDate;
  final DateTime? employmentEndDate;
  final String? payType;
  final String? payRate;
  final HolidaySummary? holiday;
  final int pendingDayOffRequests;
  final bool offSickToday;
  final int trainingExpiring;
  final DateTime? lastAppraisalDate;
  final DateTime? nextReviewDate;
  final String? nextMeetingTitle;
  final DateTime? nextMeetingAt;

  TeamMemberOverview({
    required this.staffMemberId,
    required this.name,
    required this.username,
    this.profilePhoto,
    this.jobTitle = '',
    this.employmentStartDate,
    this.employmentEndDate,
    this.payType,
    this.payRate,
    this.holiday,
    this.pendingDayOffRequests = 0,
    this.offSickToday = false,
    this.trainingExpiring = 0,
    this.lastAppraisalDate,
    this.nextReviewDate,
    this.nextMeetingTitle,
    this.nextMeetingAt,
  });

  factory TeamMemberOverview.fromJson(Map<String, dynamic> json) {
    final meeting = json['next_meeting'];
    return TeamMemberOverview(
      staffMemberId: _int(json['staff_member']),
      name: json['name'] ?? '',
      username: json['username'] ?? '',
      profilePhoto: json['profile_photo'],
      jobTitle: json['job_title'] ?? '',
      employmentStartDate: _date(json['employment_start_date']),
      employmentEndDate: _date(json['employment_end_date']),
      payType: json['pay_type'],
      payRate: json['pay_rate']?.toString(),
      holiday: json['holiday'] != null
          ? HolidaySummary.fromJson(json['holiday'])
          : null,
      pendingDayOffRequests: (json['pending_day_off_requests'] as num?)?.toInt() ?? 0,
      offSickToday: json['off_sick_today'] ?? false,
      trainingExpiring: (json['training_expiring'] as num?)?.toInt() ?? 0,
      lastAppraisalDate: _date(json['last_appraisal_date']),
      nextReviewDate: _date(json['next_review_date']),
      nextMeetingTitle: meeting != null ? meeting['title'] : null,
      nextMeetingAt: meeting != null ? _date(meeting['scheduled_for']) : null,
    );
  }
}
