# CLAUDE.md — Paws 4 Thought Dogs (p4td)

## Project Overview

Dog daycare management and booking app for pet owners and staff. Monorepo containing a **Django backend** and a **Flutter mobile app**.

- **Package:** `uk.co.paws4thoughtdogs.app`
- **Production API:** `https://paws4thoughtdogs.com`

## Repository Structure

```
├── api/                  # Django REST API (models, views, serializers, urls)
├── p4td_backend/         # Django project settings
├── website/              # Django website models
├── templates/            # Django templates
├── my_app/               # Flutter mobile app
│   ├── lib/
│   │   ├── main.dart     # App entry point & routing
│   │   ├── screens/      # UI screens
│   │   ├── services/     # Auth, data, cache, notifications, theme
│   │   ├── models/       # Domain models (Dog, Owner, BoardingRequest, etc.)
│   │   ├── widgets/      # Reusable UI components
│   │   └── constants/    # Colors & config
│   ├── android/          # Android native layer
│   ├── ios/              # iOS native layer (Xcode Cloud builds)
│   └── test/             # Widget tests
├── .github/workflows/    # CI/CD (GitHub Actions → Google Play alpha)
├── docker-compose*.yml   # Backend deployment
└── deploy.sh             # Production deploy script
```

## Build & Run

### Flutter App (from `my_app/`)

```bash
flutter pub get
flutter run                          # Debug
flutter build appbundle --release    # Play Store bundle
flutter build apk --release          # APK
flutter analyze                      # Lint check
```

- **Flutter SDK:** stable channel, Dart >=3.2.6 <4.0.0
- **Android:** compileSdk 36, Java 17, Kotlin 2.0.0
- **API URL override:** `--dart-define=API_URL=...`

### Django Backend

```bash
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python manage.py migrate
python manage.py runserver
```

- Set `DJANGO_DEBUG=true` for local development
- Config in `.env` (not committed)

## Key Conventions

- **Flutter state management:** StatefulWidget + ListenableBuilder (no external state lib)
- **Services pattern:** Abstract `DataService` → `ApiDataService` implementation
- **Auth:** Token-based, stored in `FlutterSecureStorage`
- **Local caching:** Hive
- **Linting:** `flutter_lints` with recommended rules

## CI/CD

- **Android:** GitHub Actions deploys to Google Play alpha on push to `main` (when `my_app/**` changes)
- **iOS:** Xcode Cloud builds for App Store Connect
- **Signing:** `key.properties` + keystore (from GitHub secrets)

## Git Workflow

- **Main branch:** `main`
- **Development branch:** `development`
- PRs go from feature branches or `development` → `main`

## Versioning

Version managed in `my_app/pubspec.yaml` as `version: X.Y.Z+buildNumber`.

**Every code change requires a version bump.** Increment the build number (and semver as appropriate) in `my_app/pubspec.yaml` before committing.
