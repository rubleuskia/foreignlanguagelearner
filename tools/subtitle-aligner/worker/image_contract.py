"""Offline startup smoke check; imports handlers but never loads a model or contacts AWS."""
import json
import os
from unittest.mock import patch


def check():
    import worker
    import book_worker
    with patch.dict(os.environ, {'BOOK_ALIGNMENT_QUEUE': 'offline-contract-check'}), \
            patch.object(book_worker, 'main', return_value=0) as consumer:
        if worker.main() != 0 or consumer.call_count != 1:
            raise RuntimeError('Worker entrypoint does not dispatch to the book queue consumer')
    return {'schema_version': 1, 'contracts': ['alignment-input-v1', 'book-queue-v1', 'catalog-chapters-v1']}


def main():
    print(json.dumps(check(), sort_keys=True))


if __name__ == '__main__':
    main()
