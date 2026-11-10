from django.apps import AppConfig

#: The most pixels any upload may decode to. Pillow's own guard only raises at
#: about 178 MP, and a solid-colour PNG that size is under a megabyte on the
#: wire but half a gigabyte once decoded — a few of those at once take the
#: whole box (and Postgres with it) out of memory. 40 MP is beyond any phone
#: camera; api/certificates.py has used the same figure from the start.
MAX_UPLOAD_IMAGE_PIXELS = 40_000_000


class ApiConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'api'

    def ready(self):
        # Set once, process-wide, so every Image.open in the project is
        # covered, including Django's own ImageField validation. Pillow warns
        # above this and refuses outright at twice it; the upload helpers
        # (views._decode_upload, validators.validate_media_upload) refuse at
        # the figure itself.
        from PIL import Image
        Image.MAX_IMAGE_PIXELS = MAX_UPLOAD_IMAGE_PIXELS
