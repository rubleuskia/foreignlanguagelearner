from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts.ci_changes import affects_ios, changed_paths, select_ui


class UIScopeTests(unittest.TestCase):
    def test_docs_backend_and_agent_setup_do_not_require_ui(self):
        paths = ['README.md', 'docs/IOS_CI.md', 'knowledgebase/CHANGELOG.md',
                 'backend/cloud/handler.py', 'infra/alignment/lib/cloud.ts',
                 'tools/cloud_control/server.py', 'AGENTS.md', 'CLAUDE.md', 'GEMINI.md',
                 '.cursor/rules/aws-agent-toolkit.mdc', '.gitignore',
                 '.github/workflows/ci.yml', 'scripts/ci_changes.py',
                 'Tests/CI/test_ci_changes.py', 'Tests/Unit/BookFeatureTests.swift']
        for path in paths:
            with self.subTest(path=path):
                self.assertFalse(affects_ios(path))

    def test_ios_sources_resources_project_and_ui_scenarios_require_ui(self):
        paths = ['App/Views/ReaderView.swift', 'App/ru.lproj/Localizable.strings',
                 'Shared/YouTubeCapture.js', 'YouTubeShare/ShareViewController.swift',
                 'App/Assets.xcassets/cover.imageset/image.png', 'App/Info.plist',
                 'App/ForeignLanguageLearner.entitlements', 'Tests/UI/LibraryFlowTests.swift',
                 'project.yml', 'Package.swift', 'Package.resolved', 'scripts/bootstrap.sh',
                 '.swiftpm/configuration/mirrors.json',
                 'ForeignLanguageLearner.xcodeproj/project.pbxproj']
        for path in paths:
            with self.subTest(path=path):
                self.assertTrue(affects_ios(path))

    def test_only_main_targeting_prs_consult_the_diff(self):
        event = {'pull_request': {'base': {'ref': 'main', 'sha': 'a' * 40}, 'head': {'sha': 'b' * 40}}}
        with patch('scripts.ci_changes.changed_paths', return_value=['App/View.swift']) as diff:
            for name in ['push', 'workflow_dispatch', 'workflow_call']:
                self.assertFalse(select_ui(name, event))
            self.assertFalse(select_ui('pull_request', {'pull_request': {'base': {'ref': 'release'}}}))
            diff.assert_not_called()
            self.assertTrue(select_ui('pull_request', event))
        with patch('scripts.ci_changes.changed_paths', return_value=['backend/handler.py', 'docs/guide.md']):
            self.assertFalse(select_ui('pull_request', event))

    def test_invalid_event_or_refs_fail_instead_of_silently_disabling_ui(self):
        with self.assertRaises(KeyError):
            select_ui('pull_request', {})
        for base in ['', '--bad-option', 'HEAD', None]:
            with self.subTest(base=base), self.assertRaises(ValueError):
                changed_paths(base, 'b' * 40)


class GitDiffScopeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git('init', '-q', '-b', 'main')
        (self.root / 'App').mkdir()
        (self.root / 'docs').mkdir()
        (self.root / 'App/View.swift').write_text('initial app')
        (self.root / 'docs/note with spaces.md').write_text('initial docs')
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def commit(self):
        self.git('add', '--all')
        self.git('-c', 'user.name=CI', '-c', 'user.email=ci@example.test', 'commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def test_unrelated_ios_changes_on_main_do_not_turn_a_docs_pr_into_ios(self):
        self.git('switch', '-qc', 'docs-pr')
        (self.root / 'docs/note with spaces.md').write_text('changed docs')
        head = self.commit()
        self.git('switch', '-q', 'main')
        (self.root / 'App/View.swift').write_text('unrelated main update')
        base = self.commit()
        paths = changed_paths(base, head, repo=self.root)
        self.assertEqual(paths, ['docs/note with spaces.md'])
        self.assertFalse(any(map(affects_ios, paths)))

    def test_rename_out_of_app_includes_the_deleted_ios_path(self):
        self.git('mv', 'App/View.swift', 'docs/moved view.md')
        head = self.commit()
        paths = changed_paths(self.base, head, repo=self.root)
        self.assertEqual(set(paths), {'App/View.swift', 'docs/moved view.md'})
        self.assertTrue(any(map(affects_ios, paths)))


if __name__ == '__main__':
    unittest.main()
