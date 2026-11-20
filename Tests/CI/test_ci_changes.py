from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts.ci_changes import affects_ios, changed_paths, select_ui, select_ios_tests


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

    def test_simulator_tests_follow_ios_inputs_for_prs_and_main_pushes(self):
        events = [('pull_request', {'pull_request': {'base': {'sha': 'a'*40}, 'head': {'sha': 'b'*40}}}),
                  ('push', {'before': 'a'*40, 'after': 'b'*40})]
        for name, event in events:
            for path in ['App/View.swift','Tests/Unit/ExampleTests.swift','Tests/UI/Flow.swift',
                         'project.yml','Shared/Example.swift','scripts/ci_ios.py']:
                with self.subTest(name=name,path=path), patch('scripts.ci_changes.changed_paths',return_value=[path]):
                    self.assertTrue(select_ios_tests(name,event))
            with patch('scripts.ci_changes.changed_paths',return_value=['backend/example.py','tools/subtitle-aligner/align.py','docs/guide.md','.github/workflows/ci.yml']):
                self.assertFalse(select_ios_tests(name,event))

    def test_explicit_runs_and_initial_push_keep_unit_tests(self):
        self.assertTrue(select_ios_tests('workflow_dispatch',{}))
        self.assertTrue(select_ios_tests('workflow_call',{}))
        self.assertTrue(select_ios_tests('push',{'before':'0'*40,'after':'a'*40}))
        with self.assertRaises(KeyError):select_ios_tests('push',{})
        with self.assertRaises(ValueError):select_ios_tests('push',{'before':'bad','after':'b'*40})


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
