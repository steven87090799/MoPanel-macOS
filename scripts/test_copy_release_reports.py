import pathlib
import tempfile
import unittest
from copy_release_reports import REQUIRED, copy_reports

class ReleaseReportPrivacyTests(unittest.TestCase):
    def test_only_named_regular_reports_are_copied(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp); source = root / 'reports'; source.mkdir()
            for name in REQUIRED: (source / name).write_text('{}')
            (source / 'work-continuation.json').write_text('private development checkpoint')
            (source / 'monitoring-details').mkdir()
            (source / 'monitoring-details/private-probe.txt').write_text('personal local paths')
            (source / 'build-app.log').symlink_to(source / 'work-continuation.json')
            copy_reports(source, root / 'package')
            self.assertEqual({p.name for p in (root / 'package').iterdir()}, REQUIRED)
    def test_required_symlink_or_missing_report_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp); source = root / 'reports'; source.mkdir()
            with self.assertRaises(RuntimeError): copy_reports(source, root / 'package')
            self.assertFalse((root / 'package').exists())

if __name__ == '__main__': unittest.main()
