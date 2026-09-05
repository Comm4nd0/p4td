"""Sign-in by email address.

Clients sign up through the app with their email as the username, so plain
``ModelBackend`` already lets them log in with it. This backend covers the
accounts that did not come through the app — created in Django admin or by a
script with some other username — so the login screen's "Email" field works
for everyone. It only steps in when the username lookup found nobody, and only
when exactly one account has that email (sign-up rejects duplicates, but older
rows may predate that check).
"""
from django.contrib.auth import get_user_model
from django.contrib.auth.backends import ModelBackend


class EmailOrUsernameBackend(ModelBackend):
    def authenticate(self, request, username=None, password=None, **kwargs):
        User = get_user_model()
        if username is None:
            username = kwargs.get(User.USERNAME_FIELD)
        if username is None or password is None:
            return None
        if User.objects.filter(username=username).exists():
            return None  # ModelBackend handles exact usernames
        matches = list(User.objects.filter(email__iexact=username)[:2])
        if len(matches) != 1:
            return None
        user = matches[0]
        if user.check_password(password) and self.user_can_authenticate(user):
            return user
        return None
