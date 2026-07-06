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
import os
from datetime import date, datetime, timedelta

from django.contrib.auth.models import User
from django.core.files.base import ContentFile
from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone

from api.models import Dog, Photo, GroupMedia

# Brand-ish palette for the generated placeholder images.
_BG_COLORS = ["#6C5CE7", "#00B894", "#0984E3", "#E17055", "#FD79A8"]

# Candidate fonts for the placeholder caption — the app uses Nunito, so prefer
# it if the screenshot tooling has fetched it; otherwise fall back gracefully.
_FONT_CANDIDATES = [
    "my_app/fastlane/fonts/Nunito-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/Library/Fonts/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]


def _hex_to_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def _shade(rgb, factor):
    """Lighten (factor>1) or darken (factor<1) an RGB tuple, clamped to 0-255."""
    return tuple(max(0, min(255, int(c * factor))) for c in rgb)


def _load_font(size):
    from PIL import ImageFont

    for path in _FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    # Pillow >= 10 can scale the bundled font; older versions return a tiny one.
    try:
        return ImageFont.load_default(size=size)
    except Exception:
        return ImageFont.load_default()


def _draw_paw(draw, cx, cy, scale, fill):
    """Draw a simple paw print (one pad + four toes) centred on (cx, cy)."""
    pad_w, pad_h = scale * 1.15, scale * 0.95
    draw.ellipse(
        [cx - pad_w / 2, cy - pad_h / 2 + scale * 0.25,
         cx + pad_w / 2, cy + pad_h / 2 + scale * 0.25],
        fill=fill,
    )
    toe = scale * 0.42
    offsets = [(-0.62, -0.78), (-0.2, -1.02), (0.2, -1.02), (0.62, -0.78)]
    for dx, dy in offsets:
        tx, ty = cx + dx * scale, cy + dy * scale
        draw.ellipse([tx - toe / 2, ty - toe / 2, tx + toe / 2, ty + toe / 2], fill=fill)


def _make_image(text, color, size=(1080, 1080)):
    """Generate an on-brand placeholder PNG (vertical gradient + paw + caption)
    so demo screens look intentional rather than empty. Replace these with real
    photos any time by uploading via the app — far nicer for store listings."""
    from PIL import Image, ImageDraw

    w, h = size
    base = _hex_to_rgb(color)
    top, bottom = _shade(base, 1.18), _shade(base, 0.72)

    # Vertical gradient background.
    img = Image.new("RGB", size, top)
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (w, y)], fill=row)

    # Soft translucent paw motif in the upper third.
    overlay = Image.new("RGBA", size, (0, 0, 0, 0))
    odraw = ImageDraw.Draw(overlay)
    _draw_paw(odraw, w / 2, h * 0.36, scale=w * 0.22, fill=(255, 255, 255, 60))
    img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
    draw = ImageDraw.Draw(img)

    # Large, centred caption near the lower third — shrink to fit the width.
    font_size = int(h * 0.085)
    font = _load_font(font_size)
    bbox = draw.textbbox((0, 0), text, font=font)
    while (bbox[2] - bbox[0]) > w * 0.9 and font_size > 18:
        font_size = int(font_size * 0.9)
        font = _load_font(font_size)
        bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    tx, ty = (w - tw) / 2 - bbox[0], h * 0.62
    # Subtle shadow for legibility on any backdrop.
    draw.text((tx + 3, ty + 3), text, fill=(0, 0, 0, 90), font=font)
    draw.text((tx, ty), text, fill="white", font=font)

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
            "can_reply_queries", "can_manage_staff", "can_view_inquiries",
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
