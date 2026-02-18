from django.core.management.base import BaseCommand
from django.contrib.auth.models import User
from api.models import Dog


class Command(BaseCommand):
    help = 'Bulk import dogs from a text file (one name per line) or CSV (owner_username,dog_name)'

    def add_arguments(self, parser):
        parser.add_argument('file', type=str, help='Path to the file with dog names')
        parser.add_argument(
            '--owner',
            type=str,
            default=None,
            help='Username to assign as owner for all dogs (optional)',
        )
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='Preview what would be imported without saving',
        )

    def handle(self, *args, **options):
        file_path = options['file']
        dry_run = options['dry_run']
        owner_username = options['owner']

        owner = None
        if owner_username:
            try:
                owner = User.objects.get(username=owner_username)
            except User.DoesNotExist:
                self.stderr.write(self.style.ERROR(f'User "{owner_username}" not found'))
                return

        try:
            with open(file_path, 'r') as f:
                lines = f.readlines()
        except FileNotFoundError:
            self.stderr.write(self.style.ERROR(f'File not found: {file_path}'))
            return

        created = 0
        skipped = 0

        for line in lines:
            name = line.strip()
            if not name:
                continue

            # Skip header-like lines
            if name.lower() in ('name', 'dog_name', 'dog name', 'dogs'):
                continue

            # Check if dog already exists (by name, and owner if provided)
            existing = Dog.objects.filter(name=name)
            if owner:
                existing = existing.filter(owner=owner)
            else:
                existing = existing.filter(owner__isnull=True)

            if existing.exists():
                self.stdout.write(f'  Skipped (already exists): {name}')
                skipped += 1
                continue

            if dry_run:
                self.stdout.write(f'  Would create: {name}')
            else:
                Dog.objects.create(name=name, owner=owner)
                self.stdout.write(f'  Created: {name}')
            created += 1

        prefix = 'Would create' if dry_run else 'Created'
        self.stdout.write(self.style.SUCCESS(
            f'\n{prefix}: {created} | Skipped: {skipped}'
        ))
