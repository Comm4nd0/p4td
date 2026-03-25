import re
import time

from django import forms
from django.core.signing import BadSignature, SignatureExpired, TimestampSigner

from .models import ContactInquiry

# Minimum seconds a human would need to fill the form
MIN_SUBMIT_TIME_SECONDS = 3

# Patterns that indicate spam content
SPAM_URL_RE = re.compile(r'https?://', re.IGNORECASE)
MAX_URLS_IN_MESSAGE = 2

SPAM_KEYWORD_RE = re.compile(
    r'\b('
    r'viagra|cialis|casino|crypto|nft|bitcoin|forex|SEO services'
    r'|buy now|click here|act now|limited time|free money'
    r'|earn \$|make money|work from home'
    r')\b',
    re.IGNORECASE,
)


class ContactForm(forms.ModelForm):
    # Honeypot fields — hidden from real users, filled by bots
    website = forms.CharField(
        required=False,
        widget=forms.HiddenInput(attrs={'autocomplete': 'off', 'tabindex': '-1'}),
    )
    phone_number = forms.CharField(
        required=False,
        widget=forms.HiddenInput(attrs={'autocomplete': 'off', 'tabindex': '-1'}),
    )

    # Time-based challenge: signed timestamp set when form is rendered
    form_token = forms.CharField(
        widget=forms.HiddenInput(),
        required=False,
    )

    class Meta:
        model = ContactInquiry
        fields = ['name', 'email', 'service', 'message']
        widgets = {
            'name': forms.TextInput(attrs={
                'placeholder': 'Your Name',
                'class': 'form-input',
                'required': True,
                'maxlength': 100,
            }),
            'email': forms.EmailInput(attrs={
                'placeholder': 'your@email.com',
                'class': 'form-input',
                'required': True,
            }),
            'service': forms.Select(attrs={
                'class': 'form-input',
                'required': True,
            }),
            'message': forms.Textarea(attrs={
                'placeholder': 'How can we help?',
                'rows': 5,
                'class': 'form-input',
            }),
        }

    @staticmethod
    def generate_token():
        """Create a signed timestamp token for time-based validation."""
        signer = TimestampSigner()
        return signer.sign(str(time.time()))

    def clean(self):
        cleaned_data = super().clean()

        # --- Honeypot checks ---
        if cleaned_data.get('website') or cleaned_data.get('phone_number'):
            raise forms.ValidationError('Spam detected.')

        # --- Time-based check ---
        token = cleaned_data.get('form_token', '')
        if token:
            signer = TimestampSigner()
            try:
                # max_age=86400 rejects tokens older than 24 hours (stale forms)
                signer.unsign(token, max_age=86400)
                # Extract the embedded timestamp to check minimum time
                original_time = float(signer.unsign(token))
                elapsed = time.time() - original_time
                if elapsed < MIN_SUBMIT_TIME_SECONDS:
                    raise forms.ValidationError('Please take your time filling out the form.')
            except (BadSignature, SignatureExpired, ValueError):
                raise forms.ValidationError('Form session expired. Please refresh and try again.')
        else:
            raise forms.ValidationError('Form session expired. Please refresh and try again.')

        # --- Content-based spam detection ---
        message = cleaned_data.get('message', '')
        name = cleaned_data.get('name', '')

        # Check for excessive URLs
        url_count = len(SPAM_URL_RE.findall(message))
        if url_count > MAX_URLS_IN_MESSAGE:
            raise forms.ValidationError('Your message contains too many links. Please reduce and try again.')

        # Check for spam keywords in message and name
        if SPAM_KEYWORD_RE.search(message) or SPAM_KEYWORD_RE.search(name):
            raise forms.ValidationError('Your message was flagged as potential spam. Please revise and try again.')

        return cleaned_data
