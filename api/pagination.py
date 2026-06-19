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


class OptInPagination(PageNumberPagination):
    """Paginate only when the client asks (sends ?page=...). With no page param
    the viewset returns the full bare list, exactly as before — so existing
    tests and any old client are unaffected, while a client that opts in gets
    bounded pages. (B6)"""
    page_size = 100
    max_page_size = 1000
    page_size_query_param = 'page_size'
    page_query_param = 'page'

    def paginate_queryset(self, queryset, request, view=None):
        if self.page_query_param not in request.query_params:
            return None  # back-compat: DRF then returns the full unpaginated list
        return super().paginate_queryset(queryset, request, view)
