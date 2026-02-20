import re
from django.core.exceptions import ValidationError


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
