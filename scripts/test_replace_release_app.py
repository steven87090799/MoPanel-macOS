import pathlib
import tempfile
import unittest
from replace_release_app import replace_bundle

class ReplaceAppTests(unittest.TestCase):
    def test_old_resource_layout_is_removed_instead_of_merged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); source = root / 'new.app'; destination = root / 'MoPanel.app'
            source.mkdir(); destination.mkdir()
            (source / 'new-resource').write_text('new')
            (destination / 'old-resource').write_text('stale')
            checked = []
            replace_bundle(source, destination, verify=lambda path: checked.append((path / 'new-resource').read_text()))
            self.assertEqual(checked, ['new'])
            self.assertEqual([p.name for p in destination.iterdir()], ['new-resource'])
    def test_failed_signature_verification_preserves_previous_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); source = root / 'new.app'; destination = root / 'MoPanel.app'
            source.mkdir(); destination.mkdir(); (destination / 'previous').write_text('keep')
            def reject(_): raise RuntimeError('invalid signature')
            with self.assertRaises(RuntimeError): replace_bundle(source, destination, verify=reject)
            self.assertEqual((destination / 'previous').read_text(), 'keep')
    def test_missing_source_never_removes_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary); destination = root / 'MoPanel.app'; destination.mkdir()
            with self.assertRaises(ValueError): replace_bundle(root / 'missing', destination, verify=lambda _: None)
            self.assertTrue(destination.is_dir())

if __name__ == '__main__': unittest.main()
