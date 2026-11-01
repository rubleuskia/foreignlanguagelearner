import copy
import json
from pathlib import Path
import tempfile
import unittest
from scripts.ci_ios import make_plan, validate_shard, xctestrun


def enumeration(unit=5, ui=59):
    identifiers = ([f'ForeignLanguageLearnerTests/UnitTests/testCase{i}()' for i in range(unit)] +
                   [f'ForeignLanguageLearnerUITests/ReaderTests/testCase{i}()' for i in range(ui)])
    return {'errors': [], 'values': [{'disabledTests': [], 'enabledTests': [{'identifier':i} for i in identifiers]}]}


class TestPlanning(unittest.TestCase):
    def test_all_discovered_methods_run_once_and_ui_work_is_balanced(self):
        source=enumeration();plan=make_plan(source,'commit','Xcode')
        assigned=[t for values in plan['shards'].values() for t in values]
        expected={t['identifier'].removesuffix('()') for t in source['values'][0]['enabledTests']}
        self.assertEqual(set(assigned),expected);self.assertEqual(len(assigned),len(expected))
        self.assertEqual(len(plan['shards']['unit']),5)
        lengths=[len(v) for k,v in plan['shards'].items() if k.startswith('ui-')]
        self.assertEqual(sorted(lengths),[14,15,15,15])
        self.assertTrue(all(t.startswith('ForeignLanguageLearnerUITests/') for k,v in plan['shards'].items() if k!='unit' for t in v))

    def test_discovery_order_does_not_change_the_frozen_assignment(self):
        source=enumeration();first=make_plan(source,'commit','Xcode')
        source['values'][0]['enabledTests'].reverse()
        self.assertEqual(make_plan(source,'commit','Xcode'),first)

    def test_fail_closed_on_enumeration_error_disabled_missing_or_unknown_targets(self):
        for change in ['error','disabled','no-ui','unknown-target','duplicate','invalid-id']:
            source=enumeration()
            if change=='error':source['errors']=['Unable to load bundle']
            if change=='disabled':source['values'][0]['disabledTests']=[{'identifier':'disabled'}]
            if change=='no-ui':source=enumeration(ui=0)
            if change=='unknown-target':source['values'][0]['enabledTests'].append({'identifier':'NewTests/SomeTests/testExample()'})
            if change=='duplicate':source['values'][0]['enabledTests'].append(source['values'][0]['enabledTests'][0])
            if change=='invalid-id':source['values'][0]['enabledTests'][0]['identifier']='--skip-testing:all'
            with self.subTest(change=change),self.assertRaises(ValueError):make_plan(source,'commit','Xcode')

    def test_foreign_commit_xcode_architecture_empty_and_duplicate_shards_are_rejected(self):
        plan=make_plan(enumeration(),'commit','Xcode')
        self.assertEqual(len(validate_shard(plan,'ui-1','commit','Xcode')),15)
        for modified in [{**plan,'revision':'other'},{**plan,'xcode_version':'Other Xcode'},
                         {**plan,'architecture':'different'},{**plan,'shards':{'ui-1':[]}},
                         {**plan,'shards':{'ui-1':['same','same']}}]:
            with self.assertRaises(ValueError):validate_shard(modified,'ui-1','commit','Xcode')
        with self.assertRaises(ValueError):validate_shard(plan,'missing','commit','Xcode')

    def test_xctestrun_requires_one_unambiguous_build_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            with self.assertRaises(ValueError):xctestrun(root)
            (root/'one.xctestrun').touch();self.assertEqual(xctestrun(root).name,'one.xctestrun')
            (root/'two.xctestrun').touch()
            with self.assertRaises(ValueError):xctestrun(root)


if __name__=='__main__':unittest.main()
