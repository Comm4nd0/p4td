from django import forms
from django.conf import settings
from django.core.validators import MaxLengthValidator
from django_recaptcha.fields import ReCaptchaField
from django_recaptcha.widgets import ReCaptchaV3

from .models import ContactInquiry

# Cap on the contact message length, enforced via the form field (no model
# migration). Generous enough for a genuine enquiry, small enough to blunt
# abuse / huge payloads.
MESSAGE_MAX_LENGTH = 2000


class ContactForm(forms.ModelForm):
    captcha = ReCaptchaField(widget=ReCaptchaV3(action='contact'))

    # Honeypot: a hidden field real users never see/fill. Bots that fill every
    # input will populate it, letting us silently drop the submission as spam.
    website = forms.CharField(
        required=False,
        widget=forms.TextInput(attrs={
            'autocomplete': 'off',
            'tabindex': '-1',
            'style': 'position:absolute;left:-9999px;top:-9999px;',
            'aria-hidden': 'true',
        }),
        label='',
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
                'maxlength': MESSAGE_MAX_LENGTH,
            }),
        }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Cap the message length without a model migration. ModelForm fields
        # don't pick up a max_length automatically (the model field is a
        # TextField), so register the validator explicitly.
        message = self.fields['message']
        message.max_length = MESSAGE_MAX_LENGTH
        message.validators.append(MaxLengthValidator(MESSAGE_MAX_LENGTH))
        # Only enforce reCAPTCHA when a private key is configured. With a blank
        # key Google rejects every token, so a misconfigured prod would silently
        # reject all genuine inquiries. Drop the field in that case.
        if not getattr(settings, 'RECAPTCHA_PRIVATE_KEY', ''):
            self.fields.pop('captcha', None)

    def is_spam(self):
        """True if the honeypot was filled (i.e. likely a bot)."""
        return bool(self.cleaned_data.get('website', '').strip())
