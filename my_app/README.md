# Paws 4 Thought Dogs — Mobile App

The Flutter mobile client for **Paws 4 Thought Dogs (p4td)**, a dog daycare
management platform. It is the cross-platform app used by dog owners and staff
(scheduling, daycare requests, activity feed, boarding, pickup routes, and more).
It talks to the Django REST API in the repository root.

## Getting started

```bash
cd my_app
flutter pub get
flutter run
```

- **Dart SDK**: `>=3.3.0 <4.0.0`
- **Flutter channel**: stable
- Lint config: `analysis_options.yaml` (`flutter_lints`). Run `flutter analyze`.
- Tests: `flutter test`.

## Version bumps (required)

**Every commit that changes anything under `my_app/` must bump the version in
`my_app/pubspec.yaml`.** The Play Store build (GitHub Actions) fails if the build
number (after the `+`) is not greater than the previously uploaded one.

- Format: `version: <major>.<minor>.<patch>+<buildNumber>`
- Default: bump the patch and build number by 1 (e.g. `1.8.18+343` → `1.8.19+344`).
- Make the bump part of the same commit as the change (or an immediate follow-up
  before pushing).

## Firebase configuration

Firebase config files are **gitignored** (see `.gitignore`) and must be supplied
locally / in CI:

- Android: `android/app/google-services.json`
- iOS: `ios/Runner/GoogleService-Info.plist`

## See also

- [`SCREENSHOTS.md`](SCREENSHOTS.md) — store-screenshot capture harness and the
  demo account used for it.
- [`../CLAUDE.md`](../CLAUDE.md) — full project guide (backend, app, website,
  deployment, conventions).
