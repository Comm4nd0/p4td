# p4td-android

This repository contains a Django backend (`p4td_backend`) and a Flutter/Android mobile app (`my_app`).

## Quick start

1. Copy `.env.example` to `.env` and fill required values (e.g., `DJANGO_SECRET_KEY`).
2. Backend: create a virtualenv and install dependencies:

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python manage.py migrate
python manage.py runserver
```

3. Mobile: follow Flutter setup in `my_app/` (ensure `local.properties` is not committed — it contains local SDK paths).

If you want, add a GitHub Actions workflow to run tests and linting.
