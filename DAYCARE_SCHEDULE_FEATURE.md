# Daycare Schedule Selection Feature

## Overview
Added the ability for dog owners to select which days of the week their dog attends daycare (e.g., Monday & Tuesday, or all 5 weekdays).

## Changes Made

### 1. **Dog Model** (`lib/models/dog.dart`)
- Added `Weekday` enum with values: `monday`, `tuesday`, `wednesday`, `thursday`, `friday`, `saturday`, `sunday`
- Added `WeekdayExtension` with:
  - `displayName`: Returns formatted day name (e.g., "Monday")
  - `dayNumber`: Returns ISO day number (1-7)
- Added `daysInDaycare` field to `Dog` class to store selected days
- Added `copyWith()` method for immutable updates

### 2. **Data Service** (`lib/services/data_service.dart`)
- Updated `DataService` abstract class:
  - `createDog()`: Added `List<Weekday>? daysInDaycare` parameter
  - `updateDog()`: Added `List<Weekday>? daysInDaycare` parameter
  
- Updated `ApiDataService` implementation:
  - Serialize daycare days as day numbers (1-7) when sending to API
  - Deserialize API responses back to `Weekday` enums
  - Handles optional daycare days field

### 3. **Add Dog Screen** (`lib/screens/add_dog_screen.dart`)
- Added state variable: `Set<Weekday> _selectedDays`
- Added UI section with:
  - "Daycare Schedule (Optional)" heading
  - Wrap of FilterChip buttons for each day of the week
  - Selected days show checkmark avatar
  - Blue highlight for selected days
- Pass selected days to `createDog()` method

### 4. **Edit Dog Screen** (`lib/screens/edit_dog_screen.dart`)
- Added state variable: `Set<Weekday> _selectedDays`
- Initialize with existing dog's daycare days in `initState()`
- Added identical UI section for day selection (same as Add Dog)
- Pass updated days to `updateDog()` method

## UI/UX Details

### Day Selection Widget
- **Type**: FilterChip in a Wrap layout
- **Visual Feedback**:
  - Unselected: Gray background (`Colors.grey[200]`)
  - Selected: Light blue background (`Colors.blue[100]`)
  - Checkmark icon shown when selected
- **Interaction**: Tap to toggle day selection
- **Spacing**: 8px horizontal, 8px vertical

### API Integration
- Daycare days sent/received as: `[1, 2, 3, 4, 5]` (day numbers)
- Converted to/from `Weekday` enums at service layer
- Optional field: If not provided, defaults to empty list

## Example Usage

### Creating a dog with Mon-Fri schedule:
```dart
await dataService.createDog(
  name: 'Buddy',
  breed: 'Golden Retriever',
  daysInDaycare: [Weekday.monday, Weekday.tuesday, Weekday.wednesday, Weekday.thursday, Weekday.friday],
);
```

### Updating schedule:
```dart
await dataService.updateDog(
  dog,
  daysInDaycare: [Weekday.monday, Weekday.wednesday, Weekday.friday],
);
```

## Backend Requirements
The Django API should accept/return a `daycare_days` field that is a list of day numbers (1-7, where 1=Monday, 7=Sunday):

```python
# Example API response
{
  "id": 1,
  "name": "Buddy",
  "breed": "Golden Retriever",
  "daycare_days": [1, 2, 3, 4, 5],  # Mon-Fri
  ...
}
```

## Testing
1. Navigate to Add Dog screen
2. Select multiple days (e.g., Mon, Wed, Fri)
3. Create dog - verify daycare schedule is saved
4. Edit dog - verify selected days are shown
5. Toggle days on/off and save - verify updates work

## Files Modified
- `lib/models/dog.dart` - Added Weekday enum and daysInDaycare field
- `lib/screens/add_dog_screen.dart` - Added day selection UI
- `lib/screens/edit_dog_screen.dart` - Added day selection UI
- `lib/services/data_service.dart` - Added daycare days parameter support
