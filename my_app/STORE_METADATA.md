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

Xcode Cloud archives and uploads, bootstrapped by
`my_app/ios/ci_scripts/ci_post_clone.sh`. Two workflows exist on the
`Paws 4 Thought Dogs` product:

| Workflow | Starts on |
|---|---|
| `Development` | branch `development` |
| `Production Workflow` | branch `main` **and** tags `v*` |

**The build number is not pubspec's.** Xcode Cloud stamps its own counter into
`CFBundleVersion` when it distributes — run #525 arrived in TestFlight as build
525 while `pubspec.yaml` said `+401`. That counter is shared across both
workflows above (their run numbers interleave), so it stays unique on its own.
pubspec's `+<buildNumber>` governs the Play Store only.

So the release lane resolves the build by **version train** — the group of builds
sharing a `CFBundleShortVersionString` — and takes the newest in it. The train is
keyed on the marketing version, which is why the version bump `CLAUDE.md` already
requires matters here: skip it and the release shares a train with the previous
one, and the wrong binary can be attached.

Don't try to force `CFBundleVersion` to match pubspec, and in particular don't
pass `--build-number="$CI_BUILD_NUMBER"` in `ci_post_clone.sh` — Xcode Cloud
counts that **per workflow** in some configurations, and a second workflow
restarting at 1 would collide with builds App Store Connect has already accepted.

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
APP_BUILD=525 fastlane ios submit_for_review        # attach this exact build
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
