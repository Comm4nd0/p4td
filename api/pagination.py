from rest_framework.pagination import PageNumberPagination


class FeedPagination(PageNumberPagination):
    """Pagination for the activity feed.

    Returns a small page by default so the feed paints quickly on mobile, and
    lets the client request more via ``?page=N`` (or override the size with
    ``?page_size=N`` up to a sane cap). This is applied only to the feed
    endpoint, so other list endpoints keep returning plain JSON arrays.
    """

    page_size = 5
    page_size_query_param = 'page_size'
    max_page_size = 30
