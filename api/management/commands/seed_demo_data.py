"""
Seed (or refresh) the demo owner account used for App Store / Play Store
screenshots.

Creates an *owner* user (no staff permissions), assigns a demo dog with a full
profile, and adds a little gallery + feed content so the owner-facing screens
look populated. Idempotent — safe to re-run.

    python manage.py seed_demo_data \
        --email demo-owner@paws4thoughtdogs.com \
        --password 'SomeStrongPassword!' \
        --dog-name Luna

Then point the screenshot harness at the same credentials (see
my_app/SCREENSHOTS.md). Run with --no-media to skip generated images.

NOTE: this writes to whatever database/media store DJANGO_SETTINGS_MODULE
points at — run it against the same backend the screenshot build talks to.
"""

import io
from datetime import date, datetime, timedelta

from django.contrib.auth.models import User
from django.core.files.base import ContentFile
from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone

from api.models import Dog, Photo, GroupMedia

# Brand-ish palette for the generated placeholder images.
_BG_COLORS = ["#6C5CE7", "#00B894", "#0984E3", "#E17055", "#FD79A8"]


def _make_image(text, color, size=(1080, 1080)):
    """Generate a simple branded placeholder PNG (so screens aren't empty).
    Replace these with real photos any time by uploading via the app."""
    from PIL import Image, ImageDraw

    img = Image.new("RGB", size, color)
    draw = ImageDraw.Draw(img)
    # Centre the text without depending on a bundled font.
    try:
        from PIL import ImageFont
        font = ImageFont.load_default()
    except Exception:
        font = None
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(((size[0] - tw) / 2, (size[1] - th) / 2), text, fill="white", font=font)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


class Command(BaseCommand):
    help = "Create/refresh the demo owner + dog + media used for store screenshots."

    def add_arguments(self, parser):
        parser.add_argument("--email", default="demo-owner@paws4thoughtdogs.com")
        parser.add_argument("--password", default="Paws4Demo!2026")
        parser.add_argument("--first-name", default="Sam")
        parser.add_argument("--last-name", default="Taylor")
        parser.add_argument("--dog-name", default="Luna")
        parser.add_argument("--no-media", action="store_true", help="Skip generated gallery/feed images.")

    @transaction.atomic
    def handle(self, *args, **opts):
        email = opts["email"]

        user, created = User.objects.get_or_create(
            username=email,
            defaults={"email": email, "first_name": opts["first_name"], "last_name": opts["last_name"]},
        )
        user.email = email
        user.first_name = opts["first_name"]
        user.last_name = opts["last_name"]
        user.set_password(opts["password"])
        user.is_staff = False
        user.is_superuser = False
        user.save()

        # Ensure this is a plain owner (no staff permissions on the profile).
        profile = user.profile
        for flag in (
            "can_manage_requests", "can_add_feed_media", "can_assign_dogs",
            "can_reply_queries", "can_approve_timeoff", "can_view_inquiries",
        ):
            if hasattr(profile, flag):
                setattr(profile, flag, False)
        profile.phone_number = profile.phone_number or "07700 900123"
        profile.address = profile.address or "12 Meadow Lane, Berkshire"
        profile.save()
        self.stdout.write(self.style.SUCCESS(f"{'Created' if created else 'Updated'} owner {email}"))

        # One demo dog, assigned to the owner.
        dog, dog_created = Dog.objects.get_or_create(
            owner=user, name=opts["dog_name"],
            defaults={
                "food_instructions": "One scoop of kibble at noon. No treats with chicken.",
                "medical_notes": "Slightly nervous around large dogs. Up to date on all vaccinations.",
                "daycare_days": [1, 3, 5],  # Mon/Wed/Fri
                "schedule_type": "weekly",
                "sex": "F",
                "date_of_birth": date.today() - timedelta(days=365 * 3),
                "is_spayed": True,
                "owner_brings_default": False,
                "owner_collects_default": False,
            },
        )
        self.stdout.write(self.style.SUCCESS(f"{'Created' if dog_created else 'Found'} dog {dog.name} (id={dog.id})"))

        if opts["no_media"]:
            self.stdout.write("Skipped media (--no-media).")
            self._print_summary(email, opts["password"])
            return

        # Dog profile image.
        if not dog.profile_image:
            dog.profile_image.save(
                f"demo_{dog.id}_profile.png",
                ContentFile(_make_image(dog.name, _BG_COLORS[0])),
                save=True,
            )

        # A small gallery (Photo) so the dog profile / gallery screen is populated.
        if dog.photos.count() == 0:
            now = timezone.now()
            for i in range(3):
                data = _make_image(f"{dog.name} #{i + 1}", _BG_COLORS[i % len(_BG_COLORS)])
                p = Photo(dog=dog, media_type="PHOTO", taken_at=now - timedelta(days=i))
                p.file.save(f"demo_{dog.id}_photo_{i}.png", ContentFile(data), save=False)
                p.thumbnail.save(f"demo_{dog.id}_thumb_{i}.png", ContentFile(data), save=False)
                p.save()
            self.stdout.write(self.style.SUCCESS("Added 3 gallery photos."))

        # A couple of feed posts (GroupMedia) tagged with the dog.
        captions = [
            f"{dog.name} had a brilliant day in the paddock! 🐾",
            f"Nap time after a big play session for {dog.name} 😴",
        ]
        if GroupMedia.objects.filter(tagged_dogs=dog).count() == 0:
            for i, cap in enumerate(captions):
                data = _make_image(f"{dog.name}", _BG_COLORS[(i + 1) % len(_BG_COLORS)])
                gm = GroupMedia(uploaded_by=user, media_type="PHOTO", caption=cap)
                gm.file.save(f"demo_feed_{dog.id}_{i}.png", ContentFile(data), save=False)
                gm.thumbnail.save(f"demo_feed_thumb_{dog.id}_{i}.png", ContentFile(data), save=False)
                gm.save()
                gm.tagged_dogs.add(dog)
            self.stdout.write(self.style.SUCCESS("Added 2 feed posts."))

        self._print_summary(email, opts["password"])

    def _print_summary(self, email, password):
        self.stdout.write("")
        self.stdout.write(self.style.MIGRATE_HEADING("Demo account ready for screenshots:"))
        self.stdout.write(f"  DEMO_EMAIL={email}")
        self.stdout.write(f"  DEMO_PASSWORD={password}")
        self.stdout.write("  (pass these to tool/screenshots.sh)")
