"""Vaccination certificates: private storage, byte-level validation, re-encoding.

Everything under ``MEDIA_ROOT`` is public. Caddy serves ``/media/*`` straight
off disk with no authentication, and ``p4td_backend/urls.py`` does the same
through Django's static serve as a fallback. That is fine for a photo of a
dog in the park; it is not fine for a vaccination certificate, which is vet
paperwork naming the owner and their address alongside the dog. So a
certificate never touches ``MEDIA_ROOT``. This module is the whole of the
difference between the two:

* Files go under ``PRIVATE_MEDIA_ROOT`` — a *sibling* of ``media/``, never a
  child, so no future edit to Caddy's ``handle_path`` can expose them — under
  a random filename inside a per-dog folder. Nothing serves that directory.
  The only way to a file is ``VaccinationCertificateViewSet.download``, which
  goes through the same owner/staff-scoped queryset as every other read.

* The bytes are checked against what the client *claims* they are. A
  browser's ``Content-Type`` is whatever the uploader's OS guessed and an
  attacker sets it to anything; the extension is just a string. The magic
  bytes, and for images a full Pillow decode, are what say what a file is.

* Images are re-encoded through Pillow before they are stored, so nothing the
  uploader put in the file survives to disk: no EXIF (a phone photo of the
  card carries the GPS position of the owner's kitchen table), no ICC or XMP
  blobs, and no polyglot payload — a file that is both a valid JPEG and a
  valid HTML/ZIP/PHP document stops being anything but a JPEG.

* PDFs cannot be re-encoded without a rendering stack the server does not
  have, so they are kept as uploaded but refused if they carry active
  content (JavaScript, launch actions, embedded files, rich media). That
  scan reads the raw bytes and so cannot see inside compressed object
  streams; it is a cheap extra layer, not the defence. The defence is that
  the download view never renders anything inline: ``Content-Disposition:
  attachment`` plus ``nosniff`` means a browser hands the bytes to a viewer
  rather than executing them on the API's origin, and the app opens them
  with the OS document viewer.
"""

import io
import os
import re
import secrets
import uuid
from dataclasses import dataclass
from pathlib import Path

from django.conf import settings
from django.core.files.base import ContentFile
from django.core.files.storage import FileSystemStorage
from django.utils.functional import cached_property

#: What an uploader may send. HEIC is deliberately absent: Pillow cannot
#: decode it without a plugin this deployment does not carry, and the app's
#: image picker hands over JPEG for iPhone photos anyway.
ALLOWED_EXTENSIONS = frozenset({'pdf', 'jpg', 'jpeg', 'png', 'webp'})

#: Pillow format names an image upload may decode as. MPO is a JPEG with an
#: extra frame (some phone cameras); it re-encodes as a plain JPEG.
ALLOWED_IMAGE_FORMATS = frozenset({'JPEG', 'PNG', 'WEBP', 'MPO'})

#: Refuse an image before decoding it if it would need more pixels than this.
#: Pillow's own decompression-bomb guard sits far higher (~178 MP); a
#: certificate is a sheet of paper, and 40 MP is beyond any phone camera.
MAX_IMAGE_PIXELS = 40_000_000

#: Longest side of a stored certificate image. Big enough that the small print
#: on a vet's card stays legible when zoomed; small enough that one certificate
#: is a few hundred kilobytes, not ten megabytes.
IMAGE_MAX_SIDE = 2400
IMAGE_JPEG_QUALITY = 88

#: How many certificates a single dog may hold. Renewals are yearly, so this
#: is decades of history — it exists only so that one account cannot turn the
#: upload endpoint into unlimited storage.
MAX_CERTIFICATES_PER_DOG = 25

#: PDF name tokens that mean active content. Word-bounded so ``/JS`` does not
#: match ``/JSName``. ``/OpenAction`` and ``/AA`` are not here: a benign PDF
#: uses them to open on page one at a given zoom.
_PDF_ACTIVE_CONTENT = re.compile(
    rb'/(?:JavaScript|JS|Launch|EmbeddedFile|EmbeddedFiles|RichMedia|XFA)(?![A-Za-z0-9_])'
)

#: Characters allowed to survive from an uploader's filename into the name we
#: hand back on download. Anything else — path separators, quotes, control
#: characters, the lot — is dropped.
_SAFE_NAME_CHARS = re.compile(r'[^A-Za-z0-9 ._-]+')


class PrivateMediaStorage(FileSystemStorage):
    """``FileSystemStorage`` rooted at ``PRIVATE_MEDIA_ROOT`` with no URL.

    A subclass rather than ``FileSystemStorage(location=...)`` for two
    reasons. The location is resolved lazily from settings, so the test suite
    can point it at a temporary directory with ``override_settings`` and no
    absolute path is baked into a migration. And ``url()`` raises: the base
    class would fall back to ``MEDIA_URL`` and quietly produce a
    ``/media/...`` link that 404s — which still tells whoever sees it exactly
    where on disk the file lives. There is no URL for these files, and any
    code that asks for one is a bug we want to hear about.
    """

    @cached_property
    def base_location(self):
        return str(settings.PRIVATE_MEDIA_ROOT)

    @cached_property
    def location(self):
        return os.path.abspath(self.base_location)

    def _clear_cached_properties(self, setting, **kwargs):
        if setting == 'PRIVATE_MEDIA_ROOT':
            self.__dict__.pop('base_location', None)
            self.__dict__.pop('location', None)
        else:
            super()._clear_cached_properties(setting, **kwargs)

    def url(self, name):
        raise ValueError(
            'Private media has no URL. It is reached only through the gated '
            'download view — see api/certificates.py.'
        )


_storage = None


def private_storage():
    """The storage callable ``VaccinationCertificate.file`` is declared with.

    A callable rather than an instance so the migration records a reference to
    this function, not a storage object carrying a laptop's absolute path.
    """
    global _storage
    if _storage is None:
        _storage = PrivateMediaStorage()
    return _storage


def certificate_upload_path(instance, filename):
    """``vaccination_certificates/<dog id>/<random>.<ext>``.

    Never the uploader's own filename: that defends against path traversal,
    and against the name itself (``fluffy-smith-vaccination-card.jpg``)
    leaking into a path that ends up in a log line. By the time this runs the
    file has already been renamed by :func:`prepare_certificate`, so the
    extension here is one we chose.
    """
    extension = Path(filename).suffix.lower().lstrip('.') or 'bin'
    return f'vaccination_certificates/{instance.dog_id}/{secrets.token_hex(16)}.{extension}'


class CertificateRejected(Exception):
    """An upload that is not a certificate we are prepared to store.

    The message is written for the person holding the phone — it is what the
    app shows them.
    """


@dataclass
class PreparedCertificate:
    file: ContentFile
    content_type: str


def _extension_of(name):
    return (Path(name or '').suffix.lower().lstrip('.'))


def _read_head(upload, size=1024):
    upload.seek(0)
    head = upload.read(size)
    upload.seek(0)
    return head


def _looks_like_markup(head):
    """The dangerous shapes: anything a browser would run as a document.

    SVG in particular is an XML document with script in it. Refused here by
    its bytes as well as by its extension, because ``svg`` will never be in
    the allow-list and a ``.png`` that opens with ``<svg`` is exactly the
    disguise this check exists for.
    """
    lead = head.lstrip(b'\xef\xbb\xbf \t\r\n').lower()
    return lead.startswith((b'<?xml', b'<svg', b'<!doctype', b'<html', b'<script'))


def _prepare_pdf(upload):
    head = _read_head(upload)
    if b'%PDF-' not in head:
        raise CertificateRejected(
            "That file is called a PDF but it isn't one inside. Try exporting it again, "
            'or take a photo of the certificate instead.'
        )
    upload.seek(0)
    data = upload.read()
    upload.seek(0)
    if _PDF_ACTIVE_CONTENT.search(data):
        raise CertificateRejected(
            'That PDF contains scripts or embedded files, which we cannot accept. '
            'A flattened copy or a photo of the certificate will be fine.'
        )
    return PreparedCertificate(
        file=ContentFile(data, name=f'{uuid.uuid4().hex}.pdf'),
        content_type='application/pdf',
    )


def _prepare_image(upload):
    from PIL import Image, ImageOps, UnidentifiedImageError

    upload.seek(0)
    try:
        img = Image.open(upload)
        image_format = (img.format or '').upper()
        if image_format not in ALLOWED_IMAGE_FORMATS:
            raise CertificateRejected(
                f'{image_format or "That kind of"} image is not supported. '
                'Send a JPG or PNG photo, or a PDF.'
            )
        width, height = img.size
        if width * height > MAX_IMAGE_PIXELS:
            raise CertificateRejected(
                'That image is far larger than a certificate needs to be. '
                'Please send a smaller photo.'
            )
        # Decode for real. verify() only reads the header; a truncated or
        # forged file fails here, not at save time.
        img = ImageOps.exif_transpose(img)
        img.load()
    except CertificateRejected:
        raise
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError) as exc:
        raise CertificateRejected(
            "That file doesn't look like a valid image. Send a JPG or PNG photo, or a PDF."
        ) from exc
    finally:
        upload.seek(0)

    # JPEG only holds RGB/L/CMYK; flatten transparency onto white so a PNG
    # scan with an alpha channel doesn't come out black.
    if img.mode in ('RGBA', 'LA', 'P'):
        img = img.convert('RGBA')
        flat = Image.new('RGB', img.size, (255, 255, 255))
        flat.paste(img, mask=img.getchannel('A'))
        img = flat
    elif img.mode not in ('RGB', 'L'):
        img = img.convert('RGB')

    if max(img.size) > IMAGE_MAX_SIDE:
        img.thumbnail((IMAGE_MAX_SIDE, IMAGE_MAX_SIDE), Image.Resampling.LANCZOS)

    out = io.BytesIO()
    # No exif=, no icc_profile=: the re-encode is the metadata strip.
    img.save(out, format='JPEG', quality=IMAGE_JPEG_QUALITY, optimize=True)
    return PreparedCertificate(
        file=ContentFile(out.getvalue(), name=f'{uuid.uuid4().hex}.jpg'),
        content_type='image/jpeg',
    )


def prepare_certificate(upload):
    """Validate an upload and return the bytes we will actually store.

    Raises :class:`CertificateRejected` with a message for the uploader.
    Everything that comes back has been produced by us: a Pillow-encoded JPEG
    for any image, or the original bytes for a PDF that passed inspection.
    """
    size = getattr(upload, 'size', None)
    limit = settings.MAX_VACCINATION_CERTIFICATE_BYTES
    if size is not None and size > limit:
        raise CertificateRejected(
            f'That file is {size // (1024 * 1024)} MB; the limit is {limit // (1024 * 1024)} MB. '
            'A photo of the certificate is usually much smaller.'
        )
    if not size:
        raise CertificateRejected('That file is empty.')

    extension = _extension_of(getattr(upload, 'name', ''))
    if extension not in ALLOWED_EXTENSIONS:
        raise CertificateRejected(
            'Attach a PDF or a photo of the certificate (PDF, JPG or PNG).'
        )

    if _looks_like_markup(_read_head(upload)):
        raise CertificateRejected('That file is a web page, not a certificate.')

    if extension == 'pdf':
        return _prepare_pdf(upload)
    return _prepare_image(upload)


def safe_original_filename(name):
    """The uploader's filename, reduced to something we are happy to store and echo.

    Base name only, printable ASCII subset only, capped in length. Used for
    display in the app and as the stem of the download filename.
    """
    base = os.path.basename((name or '').replace('\\', '/'))
    cleaned = _SAFE_NAME_CHARS.sub('', base).strip(' .')
    return cleaned[:120]


def download_filename(certificate):
    """What the browser or OS saves the file as.

    The stem comes from the sanitised original name; the extension comes
    from what is actually on disk, because an uploaded ``card.png`` is a JPEG
    by the time it is stored.
    """
    stored_extension = _extension_of(certificate.file.name) or 'bin'
    stem = Path(certificate.original_filename or '').stem.strip(' .')
    if not stem:
        stem = f'{certificate.dog.name}-vaccination-certificate'
        stem = _SAFE_NAME_CHARS.sub('', stem).strip(' .') or 'vaccination-certificate'
    return f'{stem}.{stored_extension}'
