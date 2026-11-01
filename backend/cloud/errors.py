"""Public errors never include provider payloads or credentials."""

class CloudError(Exception):
    def __init__(self, code, status=400):
        self.code, self.status = code, status
        super().__init__(code)
