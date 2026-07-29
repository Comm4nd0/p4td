# App Store listing — automated

The App Store Connect version form (description, promotional text, keywords,
what's new, URLs, review contact) is **kept in git** under
`my_app/fastlane/metadata/` and pushed to Apple with `deliver`. Per release you
edit one file — `release_notes.txt` — and run a workflow, instead of retyping
the form.

```
metadata/en-GB/*.txt  ──►  fastlane upload_metadata  ──►  App Store Connect
   (in git)                 (App Store Listing workflow)     version form
```

## One-time: seed the files from the live listing

Don't hand-write these — pull down what's already on the store so the first
upload is a no-op:

Actions tab → **App Store Listing** → Run workflow → mode `download`. Download
the `app-store-metadata` artifact, unzip it into `my_app/fastlane/metadata/`,
and commit.

Locally (needs Ruby + `gem install fastlane`):

```bash
cd my_app/fastlane
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
fastlane ios download_metadata
```

You get roughly:

```
metadata/
├── copyright.txt
├── primary_category.txt
├── review_information/       # contact details + demo account for App Review
│   ├── demo_user.txt
│   ├── demo_password.txt
│   └── notes.txt
└── en-GB/
    ├── name.txt
    ├── subtitle.txt
    ├── description.txt
    ├── keywords.txt
    ├── promotional_text.txt
    ├── release_notes.txt     # "What's New in This Version" — the per-release one
    ├── support_url.txt
    ├── marketing_url.txt
    └── privacy_url.txt
```

The App Review demo account is the same seeded owner the screenshots use
(`python manage.py seed_demo_data` — see [SCREENSHOTS.md](SCREENSHOTS.md)).

## Every release

1. Bump `version:` in `my_app/pubspec.yaml` (already required for every
   `my_app/` change — see the root `CLAUDE.md`).
2. Edit `metadata/en-GB/release_notes.txt` — this is the only field that
   genuinely changes per release.
3. Commit, then Actions → **App Store Listing** → mode `upload`.

The lane reads the marketing version from `pubspec.yaml` (`1.9.25+400` →
`1.9.25`), creates that version in App Store Connect if it isn't there yet, and
writes every field. It does **not** submit for review, and it doesn't touch the
binary.

Tick **include_screenshots** to also re-upload `fastlane/screenshots/`; leave it
off if the screenshots on the listing are still current (the `Store Screenshots`
workflow handles those independently).

## Shipping to the App Store

To actually ship — listing, build and review submission in one go — use the
`Release iOS to App Store` workflow instead of the listing-only one above. It is
driven by a tag:

```bash
git tag v1.9.26 && git push origin v1.9.26
```

The tag must name the version in `pubspec.yaml` on a commit that is already on
`main`; the workflow refuses to run otherwise. It then pushes the listing, waits
for the build Xcode Cloud produced for that commit, attaches it, and submits it
for review.

### Where the binary comes from

Xcode Cloud archives and uploads on push to `main`, bootstrapped by
`my_app/ios/ci_scripts/ci_post_clone.sh`. The build number comes from
`pubspec.yaml` — `flutter pub get` writes it into `ios/Flutter/Generated.xcconfig`
as `FLUTTER_BUILD_NUMBER`, which reaches `CFBundleVersion` through
`CURRENT_PROJECT_VERSION`.

That matters: **App Store Connect rejects a build number it has already seen**,
so the number has to be globally unique. pubspec's is, because `CLAUDE.md`
requires a bump on every `my_app/` commit and `flutter-ci.yml` enforces it on
PRs. Two things would break it, and neither should be added:

- starting an Xcode Cloud build from the tag *as well as* from `main` — the same
  commit gets archived twice with one build number, and the second upload fails;
- numbering builds from `CI_BUILD_NUMBER`, which Xcode Cloud counts **per
  workflow**, so a second workflow restarts at 1 and collides.

### Dry run

Actions → **Release iOS to App Store** → Run workflow (pick the tag) with
**submit** left off. That pushes the listing and attaches the build but sends
nothing to Apple, so you can check the version in App Store Connect first.

## What still needs the web UI

- **App Privacy** ("nutrition label") answers and the **age-rating
  questionnaire** — including Apple's new social-media questions. One-time-ish
  settings, not part of the per-release loop.
- **Releasing the version** once Apple approves it. Submission is automated;
  `automatic_release` is deliberately off, so an approval never puts a build in
  front of customers on its own.
- Pricing/availability, and anything under App Information rather than the
  version.

## Local run

```bash
cd my_app/fastlane
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=/path/to/AuthKey.p8
fastlane ios upload_metadata                        # listing only
INCLUDE_SCREENSHOTS=1 fastlane ios upload_metadata  # listing + screenshots
SUBMIT=0 fastlane ios submit_for_review             # attach the build, submit nothing
fastlane ios submit_for_review                      # attach the build and submit
APP_BUILD=401 fastlane ios submit_for_review        # target a specific build
APP_VERSION=1.9.14 fastlane ios upload_metadata     # target a specific version
```

`fastlane/keys/` (the API key material) is gitignored — never commit it.

## Android

The Play listing has the same mechanism (`supply` reads
`fastlane/metadata/android/<locale>/`), but that tree is currently generated
per-run for screenshots only and the alpha uploads skip metadata entirely. If
per-release Play changelogs become a chore too, commit
`metadata/android/en-GB/changelogs/<versionCode>.txt` and drop
`skip_upload_changelogs` from the `upload_android` lane.
