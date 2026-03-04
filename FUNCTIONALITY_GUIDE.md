# Paws4Thought Dogs - Functionality Guide

This document provides a complete overview of what **standard users (dog owners)** and **staff members** can do within the system.

---

## Standard User (Dog Owner) Functionality

### Account & Profile

| Feature | Description |
|---------|-------------|
| Register & Login | Create an account and log in using email and password |
| Password Reset | Reset password via a 3-step OTP email verification process |
| Change Password | Change password while logged in |
| Edit Profile | Update first name, address, phone number, and pickup instructions |
| Profile Photo | Upload or change profile photo |
| Notification Preferences | Toggle push notifications on/off for: activity feed, traffic alerts, booking updates, and dog status updates |

### Dog Management

| Feature | Description |
|---------|-------------|
| View Dogs | See a list and detail view of all owned dogs |
| Edit Dogs | Update dog information at any time |
| Set Daycare Schedule | Choose which days of the week each dog attends (Mon-Sun) and the schedule type (weekly, fortnightly, or ad hoc) |
| Co-ownership | Be assigned as an additional owner on another person's dog |
| Upload Dog Photos/Videos | Add photos and videos to individual dog profiles |
| Comment on Dog Photos | Add comments to photos on dog profiles |

> **Note:** Only staff can add or delete dogs. Owners can view and edit their existing dogs but cannot create new ones.

### Daycare Requests

| Feature | Description |
|---------|-------------|
| Cancel a Day | Request to cancel a scheduled daycare day |
| Change a Day | Request to move a scheduled day to a different date |
| Add an Extra Day | Request an additional daycare day outside the regular schedule |
| View Request Status | Track whether requests are pending, approved, or denied |
| Boarding Requests | Request overnight or multi-day boarding for one or more dogs, with date range and special instructions |

### Activity Feed

| Feature | Description |
|---------|-------------|
| View Feed | See photos and videos posted by staff throughout the day |
| React to Posts | Add an emoji reaction to a feed post (one per post) |
| Comment on Posts | Add text comments to feed posts |
| Delete Own Comments | Remove your own comments from posts |

### Support & Communication

| Feature | Description |
|---------|-------------|
| Contact Staff | Create a support query with a subject and message |
| Reply to Queries | Add messages to an existing support conversation |
| Reopen Queries | Reopen a previously resolved support query |

### Push Notifications

Owners receive push notifications for the following (each category can be toggled off):

| Category | Notifications |
|----------|---------------|
| Feed | New photos/videos posted by staff; new comments on posts you've engaged with |
| Traffic | Pickup or drop-off delay alerts from your dog's assigned staff member |
| Bookings | Date change and boarding requests approved or denied |
| Dog Updates | Status changes (picked up, at daycare, dropped off); care instruction updates |
| Support | Staff replies to your support queries |

---

## Staff Member Functionality

All staff features require `is_staff` status. Individual capabilities are controlled by permission flags that can be assigned per staff member.

### Staff Permission Flags

| Permission | What It Unlocks |
|------------|-----------------|
| can_manage_requests | Approve or deny date change and boarding requests |
| can_add_feed_media | Upload, edit, and delete posts in the activity feed |
| can_assign_dogs | Assign dogs to staff members for daily care |
| can_reply_queries | Reply to owner support queries |
| can_approve_timeoff | Approve or deny day-off requests from other staff |

### Dog Management (All Staff)

| Feature | Description |
|---------|-------------|
| View All Dogs | See every dog in the system, not just personally assigned ones |
| Delete Dogs | Remove a dog and all its associated photos from the system |
| Edit Care Instructions | Update food instructions and medical notes for any dog |
| Add Dog Notes | Record compatibility, behavioural, and grouping notes about dogs (can reference related dogs) |
| Assign Owners | Assign or change a dog's owner and co-owners |
| Bulk Import Dogs | Import multiple dogs by name in one operation |

### Request Management (requires `can_manage_requests`)

| Feature | Description |
|---------|-------------|
| View All Date Change Requests | See every pending, approved, and denied request |
| Approve/Deny Date Changes | Change the status of date change requests |
| View All Boarding Requests | See all boarding requests from owners |
| Approve/Deny Boarding | Change the status of boarding requests |
| Request History | View a full audit trail of who changed a request and when |

Owners are automatically notified when a request status changes.

### Daily Roster & Dog Assignments (requires `can_assign_dogs` for assigning to others)

| Feature | Description |
|---------|-------------|
| View Today's Roster | See all dog assignments for today |
| View Future Dates | View assignments up to 14 days ahead |
| Assign to Self | Pick up dogs and assign them to yourself |
| Assign to Other Staff | Assign dogs to specific staff members for a date |
| Reassign Dogs | Move a dog from one staff member to another |
| Unassign Dogs | Remove a staff assignment from a dog |
| View Unassigned Dogs | See which scheduled dogs don't have a staff member yet |
| Suggested Assignments | Get smart suggestions based on the most recent same-weekday assignment or most frequent staff member |
| Auto-Assign | Automatically assign all unassigned dogs for a date based on historical patterns |
| View Available Staff | See which staff members are available for a given date |
| Update Dog Status | Progress through the day: Assigned -> Picked Up -> At Daycare -> Dropped Off |
| Recurring Assignments | Assignments automatically repeat for the same weekday (up to 3 weeks ahead) |

The system automatically determines which dogs should appear on a given day based on their daycare schedule, approved boarding dates, approved cancellations, and closure days.

### Activity Feed (requires `can_add_feed_media`)

| Feature | Description |
|---------|-------------|
| Create Posts | Upload photos or videos with captions to the group feed |
| Edit Posts | Update captions on existing posts |
| Delete Posts | Remove posts from the feed |
| View Reaction Details | See which users reacted with which emoji |

All staff can view, react to, and comment on feed posts (same as owners).

### Support Query Management (requires `can_reply_queries`)

| Feature | Description |
|---------|-------------|
| View All Queries | See support queries from all owners |
| Reply to Queries | Send replies within any support conversation |
| Resolve Queries | Mark a support query as resolved |
| Reopen Queries | Reopen a previously resolved query |
| Unresolved Count | See the number of open support queries (for badge display) |
| Create on Behalf of Owner | Create a support query on behalf of an owner |

### Staff Availability & Time Off

| Feature | Description |
|---------|-------------|
| Set Availability | Define personal availability for each day of the week (daycare and boarding separately) |
| View Own Availability | See your current availability settings |
| View Staff Coverage | See an overview of which staff are available each day |
| Request Day Off | Submit a day-off request for a specific date |
| Cancel Day-Off Request | Cancel your own pending request |
| View Day-Off Requests | See all pending requests (requires `can_approve_timeoff`) |
| Approve/Deny Day Off | Approve or deny another staff member's request (requires `can_approve_timeoff`) |

### Owner Profile Management (All Staff)

| Feature | Description |
|---------|-------------|
| View All Owners | See a list of all registered dog owners |
| View Owner Profile | See detailed profile information for any owner |
| Edit Owner Profile | Update an owner's address, phone number, and pickup instructions |

### Closure Days (All Staff)

| Feature | Description |
|---------|-------------|
| Create Closure Day | Set a date when the facility is closed or at reduced capacity |
| Add Reason | Specify the reason for closure |
| View Closure Days | See all upcoming closure dates |

Dogs are automatically excluded from the roster on closure days.

### Traffic Alerts (All Staff)

| Feature | Description |
|---------|-------------|
| Send Pickup Alert | Notify owners of dogs assigned to you that pickup will be delayed |
| Send Drop-off Alert | Notify owners of dogs assigned to you that drop-off will be delayed |
| Custom Message | Include an optional detail message with the alert |

Only owners whose dogs are assigned to the alerting staff member (and in the relevant status) receive the notification.

### Staff Push Notifications

All staff receive notifications for:

| Event | Description |
|-------|-------------|
| New Date Change Request | An owner has submitted a date change request |
| New Boarding Request | An owner has submitted a boarding request |
| New Support Query | An owner has created a new support query |
| Support Query Reply | An owner has replied to an existing support query |
| Care Instruction Update | Food or medical notes have been changed for a dog |
| Dog Pickup/Drop-off | A dog's status has changed (picked up or dropped off) |

---

## Permission Summary Matrix

| Feature | Owner | Staff (Basic) | + manage_requests | + add_feed_media | + assign_dogs | + reply_queries | + approve_timeoff |
|---------|:-----:|:-------------:|:-----------------:|:----------------:|:-------------:|:---------------:|:-----------------:|
| View own dogs | Yes | - | - | - | - | - | - |
| View all dogs | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Add/delete dogs | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Add dog notes | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Request date changes | Yes | - | - | - | - | - | - |
| Request boarding | Yes | - | - | - | - | - | - |
| Approve/deny requests | - | - | Yes | - | - | - | - |
| Create feed posts | - | - | - | Yes | - | - | - |
| Edit/delete feed posts | - | - | - | Yes | - | - | - |
| View/react/comment feed | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Assign dogs to staff | - | - | - | - | Yes | - | - |
| Auto-assign roster | - | - | - | - | Yes | - | - |
| Self-assign dogs | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Update dog status | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Create support query | Yes | - | - | - | - | - | - |
| Reply to support queries | - | - | - | - | - | Yes | - |
| Resolve/reopen queries | - | - | - | - | - | Yes | - |
| View all owners | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Edit owner profiles | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Set own availability | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Request day off | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Approve/deny day off | - | - | - | - | - | - | Yes |
| Manage closure days | - | Yes | Yes | Yes | Yes | Yes | Yes |
| Send traffic alerts | - | Yes | Yes | Yes | Yes | Yes | Yes |
