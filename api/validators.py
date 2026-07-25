import os
import re
from django.core.exceptions import ValidationError

# Media served from /media/ is public and unauthenticated (see I3), and Caddy
# serves it straight off disk with content-type inferred from the extension. An
# uploaded .html or .svg would therefore execute as script on the primary
# domain — the same origin as /admin/. Photo.file and GroupMedia.file are
# FileFields (they have to accept video), so unlike the ImageField uploads
# nothing validates them by default. These allow-lists are that validation.
ALLOWED_IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.heif'}
ALLOWED_VIDEO_EXTENSIONS = {'.mp4', '.mov', '.m4v', '.3gp', '.avi', '.webm'}

# Pillow format names corresponding to ALLOWED_IMAGE_EXTENSIONS. SVG is
# deliberately absent: Pillow cannot open it, but more importantly it is an
# XML document that browsers execute.
ALLOWED_IMAGE_FORMATS = {'JPEG', 'PNG', 'GIF', 'WEBP', 'MPO', 'HEIF', 'HEIC'}

MAX_IMAGE_UPLOAD_BYTES = 25 * 1024 * 1024   # 25 MB
MAX_VIDEO_UPLOAD_BYTES = 200 * 1024 * 1024  # 200 MB


def validate_media_upload(uploaded, media_type):
    """Validate an uploaded dog photo / feed item before it is stored.

    Raises django.core.exceptions.ValidationError, which DRF surfaces as a 400.
    ``media_type`` is 'PHOTO' or 'VIDEO'.
    """
    if not uploaded:
        return

    is_video = media_type == 'VIDEO'
    allowed_ext = ALLOWED_VIDEO_EXTENSIONS if is_video else ALLOWED_IMAGE_EXTENSIONS
    max_bytes = MAX_VIDEO_UPLOAD_BYTES if is_video else MAX_IMAGE_UPLOAD_BYTES

    ext = os.path.splitext(getattr(uploaded, 'name', '') or '')[1].lower()
    if ext not in allowed_ext:
        raise ValidationError(
            f"'{ext or 'this file type'}' isn't allowed here. "
            f"Accepted types: {', '.join(sorted(allowed_ext))}."
        )

    size = getattr(uploaded, 'size', None)
    if size is not None and size > max_bytes:
        raise ValidationError(
            f'That file is {size // (1024 * 1024)} MB. '
            f'The limit is {max_bytes // (1024 * 1024)} MB.'
        )

    if is_video:
        # Videos are re-encoded by nothing and only probed by ffmpeg for a
        # thumbnail, so the extension + size check above is the guard. The
        # extension allow-list is what stops .html/.svg being stored.
        return

    # For images, don't trust the extension — confirm the bytes really are a
    # supported image. verify() detects truncated/forged files cheaply.
    from PIL import Image
    try:
        uploaded.seek(0)
        with Image.open(uploaded) as probe:
            probe.verify()
            image_format = probe.format
    except ValidationError:
        raise
    except Exception:
        raise ValidationError("That file doesn't look like a valid image.")
    finally:
        try:
            uploaded.seek(0)
        except Exception:
            pass

    if image_format and image_format.upper() not in ALLOWED_IMAGE_FORMATS:
        raise ValidationError(f'{image_format} images are not supported here.')


class PasswordComplexityValidator:
    """
    Validates that a password meets complexity requirements:
    - At least one uppercase letter
    - At least one lowercase letter
    - At least one digit
    - At least one special character
    """

    def validate(self, password, user=None):
        errors = []
        if not re.search(r'[A-Z]', password):
            errors.append('Password must contain at least one uppercase letter.')
        if not re.search(r'[a-z]', password):
            errors.append('Password must contain at least one lowercase letter.')
        if not re.search(r'\d', password):
            errors.append('Password must contain at least one number.')
        if not re.search(r'[^A-Za-z0-9]', password):
            errors.append('Password must contain at least one special character (e.g. !@#$%&*).')
        if errors:
            raise ValidationError(errors)

    def get_help_text(self):
        return (
            'Your password must contain at least one uppercase letter, '
            'one lowercase letter, one number, and one special character.'
        )
