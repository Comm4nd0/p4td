from django import forms
from .models import ContactInquiry


class ContactForm(forms.ModelForm):
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
