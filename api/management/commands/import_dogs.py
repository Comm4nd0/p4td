import csv
from django.core.management.base import BaseCommand
from django.contrib.auth.models import User
from api.models import Dog


class Command(BaseCommand):
    help = 'Bulk import dogs from a CSV file. CSV format: owner_username,dog_name'

    def add_arguments(self, parser):
        parser.add_argument('csv_file', type=str, help='Path to the CSV file')
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='Preview what would be imported without saving',
        )

    def handle(self, *args, **options):
        csv_file = options['csv_file']
        dry_run = options['dry_run']

        try:
            with open(csv_file, 'r') as f:
                reader = csv.reader(f)
                rows = list(reader)
        except FileNotFoundError:
            self.stderr.write(self.style.ERROR(f'File not found: {csv_file}'))
            return

        # Skip header row if it looks like one
        if rows and rows[0][0].lower().strip() in ('owner', 'owner_username', 'username'):
            rows = rows[1:]

        created = 0
        skipped = 0
        errors = []

        for i, row in enumerate(rows, start=1):
            # Skip empty rows
            if not row or not any(cell.strip() for cell in row):
                continue

            if len(row) < 2:
                errors.append(f'Row {i}: Expected at least 2 columns, got {len(row)}: {row}')
                continue

            owner_username = row[0].strip()
            dog_name = row[1].strip()

            if not owner_username or not dog_name:
                errors.append(f'Row {i}: Missing owner_username or dog_name')
                continue

            try:
                owner = User.objects.get(username=owner_username)
            except User.DoesNotExist:
                errors.append(f'Row {i}: User "{owner_username}" not found')
                skipped += 1
                continue

            # Check if this dog already exists for this owner
            if Dog.objects.filter(owner=owner, name=dog_name).exists():
                self.stdout.write(f'  Skipped (already exists): {dog_name} -> {owner_username}')
                skipped += 1
                continue

            if dry_run:
                self.stdout.write(f'  Would create: {dog_name} -> {owner_username}')
            else:
                Dog.objects.create(owner=owner, name=dog_name)
                self.stdout.write(f'  Created: {dog_name} -> {owner_username}')
            created += 1

        if errors:
            self.stderr.write(self.style.WARNING(f'\nErrors ({len(errors)}):'))
            for error in errors:
                self.stderr.write(f'  {error}')

        prefix = 'Would create' if dry_run else 'Created'
        self.stdout.write(self.style.SUCCESS(
            f'\n{prefix}: {created} | Skipped: {skipped} | Errors: {len(errors)}'
        ))
