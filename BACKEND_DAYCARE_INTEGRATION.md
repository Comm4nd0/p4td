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
Updated to include `daycare_days` field in serialization:

```python
fields = ['id', 'owner', 'name', 'breed', 'profile_image', 
          'food_instructions', 'medical_notes', 'daycare_days', 'created_at']
```

## API Endpoints

### Create Dog
**POST** `/api/dogs/`

Request body:
```json
{
  "name": "Buddy",
  "breed": "Golden Retriever",
  "food_instructions": "1 cup dry food twice a day",
  "medical_notes": "None",
  "daycare_days": [1, 2, 3, 4, 5]  // Mon-Fri
}
```

Response (201):
```json
{
  "id": 1,
  "owner": 1,
  "name": "Buddy",
  "breed": "Golden Retriever",
  "profile_image": "https://...",
  "food_instructions": "1 cup dry food twice a day",
  "medical_notes": "None",
  "daycare_days": [1, 2, 3, 4, 5],
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
