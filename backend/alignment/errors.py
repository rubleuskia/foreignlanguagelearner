"""Stable API and worker errors."""


class AlignmentError(Exception):
    def __init__(self, code: str, message: str, status: int = 400, retry_after: int | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status
        self.retry_after = retry_after


class Conflict(AlignmentError):
    def __init__(self, code: str, message: str):
        super().__init__(code, message, 409)


class NotFound(AlignmentError):
    def __init__(self):
        super().__init__("NOT_FOUND", "Alignment job was not found.", 404)


class Unauthorized(AlignmentError):
    def __init__(self):
        super().__init__("UNAUTHORIZED", "A valid job capability is required.", 401)


class Gone(AlignmentError):
    def __init__(self, message: str):
        super().__init__("RESOURCE_EXPIRED", message, 410)


class RateLimited(AlignmentError):
    def __init__(self, code: str, message: str, retry_after: int):
        super().__init__(code, message, 429, retry_after)
