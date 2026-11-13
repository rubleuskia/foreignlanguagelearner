"""Exercise source packaging without downloading or deploying dependencies."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class CloudAssetTests(unittest.TestCase):
    def test_operator_asset_contains_queue_api_and_dispatcher_without_test_code(self):
        root = Path(__file__).resolve().parents[2]
        specification = importlib.util.spec_from_file_location('cloud_asset_builder', root / 'scripts/build-cloud.py')
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'asset'
            with patch('sys.argv', ['build-cloud.py', '--mode', 'operator', '--output', str(output)]), \
                    patch.object(module.subprocess, 'run'):
                module.main()
            for name in ['api.py', 'dispatch.py', 'repository.py', 'contract.py']:
                self.assertTrue((output / 'backend/book_alignment' / name).is_file(), name)
            self.assertFalse(list(output.rglob('test_*.py')))


if __name__ == '__main__':
    unittest.main()
