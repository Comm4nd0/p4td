import time

from django.core.management.base import BaseCommand

from api.models import Dog
from api.geocoding import geocode_dog


def _needs_geocode(dog, force):
    """Whether this dog's cached coordinates are missing, stale, or forced."""
    address = (dog.address or '').strip()
    if not address:
        # No address: only "needs" work if there are stale coords to clear.
        return any([
            dog.latitude is not None, dog.longitude is not None,
            dog.geocode_source, dog.geocoded_address,
        ])
    if force:
        return True
    return dog.geocoded_address != address


class Command(BaseCommand):
    help = (
        'Geocode dog pickup addresses (via getAddress.io) and cache the '
        'coordinates on each Dog for the staff pickup map. Idempotent: only '
        'touches dogs whose address is new, changed, or not yet geocoded.'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='List the dogs that would be geocoded without calling the provider.',
        )
        parser.add_argument(
            '--force',
            action='store_true',
            help='Re-geocode every dog with an address, even if already cached.',
        )
        parser.add_argument(
            '--limit',
            type=int,
            default=None,
            help='Process at most this many dogs (useful for testing).',
        )
        parser.add_argument(
            '--sleep',
            type=float,
            default=0.2,
            help='Seconds to pause between provider calls (default: 0.2).',
        )

    def handle(self, *args, **options):
        dry_run = options['dry_run']
        force = options['force']
        limit = options['limit']
        sleep = options['sleep']
        prefix = '[DRY RUN] ' if dry_run else ''

        candidates = [d for d in Dog.objects.all().order_by('name') if _needs_geocode(d, force)]
        if limit is not None:
            candidates = candidates[:limit]

        self.stdout.write(f'{prefix}{len(candidates)} dog(s) need geocoding.')

        if dry_run:
            for d in candidates:
                addr = (d.address or '').strip() or '(no address)'
                self.stdout.write(f'  - {d.name}: {addr}')
            return

        counts = {'house': 0, 'postcode': 0, 'failed': 0, 'cleared': 0}
        for i, dog in enumerate(candidates):
            had_address = bool((dog.address or '').strip())
            geocode_dog(dog, force=force)
            if not had_address:
                counts['cleared'] += 1
            else:
                counts[dog.geocode_source if dog.geocode_source in counts else 'failed'] += 1
                coord = (
                    f'{dog.latitude:.5f},{dog.longitude:.5f}'
                    if dog.latitude is not None else 'no match'
                )
                self.stdout.write(f'  {dog.name}: {dog.geocode_source or "—"} ({coord})')
                # Be polite to the provider between network calls.
                if sleep and i < len(candidates) - 1:
                    time.sleep(sleep)

        self.stdout.write(self.style.SUCCESS(
            'Done. '
            f"house={counts['house']} postcode={counts['postcode']} "
            f"failed={counts['failed']} cleared={counts['cleared']}"
        ))
