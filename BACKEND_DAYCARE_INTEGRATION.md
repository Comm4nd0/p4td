# Django Backend - Daycare Schedule Integration

## Overview
The Django backend now supports storing and managing daycare schedules for each dog.

## Model Changes

### Dog Model (`api/models.py`)
Added a new field to track which days a dog attends daycare:

```python
daycare_days = models.JSONField(
    default=list, 
    blank=True, 
    help_text='List of day numbers (1-7) for daycare attendance'
)
```

**Day Numbering:**
- 1 = Monday
- 2 = Tuesday
- 3 = Wednesday
- 4 = Thursday
- 5 = Friday
- 6 = Saturday
- 7 = Sunday

## API Integration

### DogSerializer (`api/serializers.py`)
The serializer exposes the daycare schedule alongside the rest of the Dog
fields. The real `Meta.fields` list (source of truth: `api/serializers.py`) is:

```python
fields = ['id', 'owner', 'owner_details', 'additional_owners',
          'additional_owners_details', 'name', 'profile_image',
          'food_instructions', 'medical_notes', 'registered_vet', 'address',
          'postcode', 'access_instructions', 'van_placement', 'general_notes',
          'daycare_days', 'schedule_type', 'owner_brings_default',
          'owner_collects_default', 'owner_brings_default_time',
          'owner_collects_default_time', 'sex', 'date_of_birth', 'is_spayed',
          'vaccination_summary', 'latitude', 'longitude', 'geocode_source',
          'created_at']
```

**`schedule_type`** records how often the dog attends and is one of
`weekly`, `fortnightly`, or `ad_hoc` (default `weekly`). The
`owner_brings_default` / `owner_collects_default` booleans (with optional
`owner_brings_default_time` / `owner_collects_default_time`) capture whether the
owner usually handles drop-off/collection rather than staff transport.

## API Endpoints

### Create Dog
**POST** `/api/dogs/`

Request body:
```json
{
  "name": "Buddy",
  "food_instructions": "1 cup dry food twice a day",
  "medical_notes": "None",
  "daycare_days": [1, 2, 3, 4, 5],  // Mon-Fri
  "schedule_type": "weekly"
}
```

Response (201):
```json
{
  "id": 1,
  "owner": 1,
  "name": "Buddy",
  "profile_image": "https://...",
  "food_instructions": "1 cup dry food twice a day",
  "medical_notes": "None",
  "daycare_days": [1, 2, 3, 4, 5],
  "schedule_type": "weekly",
  "created_at": "2026-01-31T10:00:00Z"
}
```

### Update Dog
**PATCH** `/api/dogs/{id}/`

Request body:
```json
{
  "name": "Buddy",
  "daycare_days": [1, 3, 5]  // Mon, Wed, Fri
}
```

### Get Dog
**GET** `/api/dogs/{id}/`

Returns the dog object with daycare_days included.

## Database Migration

A migration file has been created: `api/migrations/0003_dog_daycare_days.py`

To apply the migration:
```bash
python manage.py migrate api
```

This adds the `daycare_days` JSON field to the `api_dog` table.

## Frontend Display

The Flutter app displays daycare schedules in two places:

### 1. Dog Profile Screen (dog_home_screen.dart)
Shows a compact view of daycare days with day abbreviations (Mon, Tue, etc.) in blue chips.

Example display:
```
Daycare Schedule
Mon  Tue  Wed  Thu  Fri
```

### 2. Edit Dog Screen (edit_dog_screen.dart)
Allows full-day selection with toggleable FilterChip buttons for editing.

## Notes
- The daycare_days field defaults to an empty list (no daycare attendance)
- Days are stored as a JSON array of integers (1-7)
- The field is optional and can be updated at any time
- No validation restricts which days can be selected (allowing weekends if needed)
