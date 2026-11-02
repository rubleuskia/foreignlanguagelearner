from contextlib import nullcontext
import json
import plistlib
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from scripts.ci_ios import (DiscoveryBootstrapError, discover_target, make_plan,
                            plan_tests, prepared_simulator, target_enumeration, validate_compiled_targets,
                            validate_shard, xctestrun, UI_TARGET)


def enumeration(unit=5, ui=59):
    identifiers = ([f'ForeignLanguageLearnerTests/UnitTests/testCase{i}()' for i in range(unit)] +
                   [f'ForeignLanguageLearnerUITests/ReaderTests/testCase{i}()' for i in range(ui)])
    return {'errors': [], 'values': [{'disabledTests': [], 'enabledTests': [{'identifier':i} for i in identifiers]}]}


class TestPlanning(unittest.TestCase):
    def test_unit_only_plan_preserves_every_unit_method_and_has_no_ui_shards(self):
        plan=make_plan(enumeration(ui=0),'commit','Xcode',include_ui=False)
        self.assertEqual(set(plan['shards']),{'unit'})
        self.assertEqual(len(plan['shards']['unit']),5)
        for source in [enumeration(),enumeration(unit=0,ui=0)]:
            with self.assertRaises(ValueError):make_plan(source,'commit','Xcode',include_ui=False)

    def test_all_discovered_methods_run_once_and_ui_work_is_balanced(self):
        source=enumeration();plan=make_plan(source,'commit','Xcode')
        assigned=[t for values in plan['shards'].values() for t in values]
        expected={t['identifier'].removesuffix('()') for t in source['values'][0]['enabledTests']}
        self.assertEqual(set(assigned),expected);self.assertEqual(len(assigned),len(expected))
        self.assertEqual(len(plan['shards']['unit']),5)
        lengths=[len(v) for k,v in plan['shards'].items() if k.startswith('ui-')]
        self.assertEqual(sorted(lengths),[7,7,7,7,7,8,8,8])
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
        self.assertEqual(len(validate_shard(plan,'ui-1','commit','Xcode')),8)
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

    def test_target_filter_cannot_hide_a_new_compiled_test_bundle(self):
        targets=[{'BlueprintName':name,'TestBundlePath':'fixture.xctest'} for name in
                 ['ForeignLanguageLearnerTests','ForeignLanguageLearnerUITests']]
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'fixture.xctestrun'
            for version in [1,2]:
                def write(items):
                    value={t['BlueprintName']:t for t in items} if version==1 else {'TestConfigurations':[{'TestTargets':items}]}
                    path.write_bytes(plistlib.dumps(value))
                write(targets);validate_compiled_targets(path)
                write(targets+[{'BlueprintName':'NewTests','TestBundlePath':'new.xctest'}])
                with self.assertRaises(ValueError):validate_compiled_targets(path)


class DiscoveryTests(unittest.TestCase):
    def test_unit_only_discovery_never_launches_the_ui_target(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'build').mkdir()
            with patch('scripts.ci_ios.ROOT',root),patch('scripts.ci_ios.xctestrun',return_value=Path('fixture')), \
                 patch('scripts.ci_ios.validate_compiled_targets'), \
                 patch('scripts.ci_ios.discover_target',return_value=enumeration(ui=0)) as discover, \
                 patch('scripts.ci_ios.command',return_value='fixture'),patch.dict('os.environ',{},clear=True):
                plan_tests(root,include_ui=False)
            discover.assert_called_once_with(Path('fixture'),'ForeignLanguageLearnerTests',root/'build')
            self.assertEqual(set(json.loads((root/'build/test-shards.json').read_text())['shards']),{'unit'})

    bootstrap = 'Runner encountered an error. Early unexpected exit. Underlying Error: Lost connection to testmanagerd'

    def ui(self):
        source=enumeration(unit=0)
        source['values'][0]['disabledTests']=[{'identifier':'ForeignLanguageLearnerTests/UnitTests/testCase0()'}]
        return source

    def partial(self):
        return {'errors':[self.bootstrap], 'values':[{'disabledTests':[], 'enabledTests':[
            {'identifier':'ForeignLanguageLearnerTests/UnitTests/testCase0()'}, {'identifier':UI_TARGET}]}]}

    def discover(self, responses):
        calls=[]
        def invoke(argv,**kwargs):
            self.assertIn('-enumerate-tests',argv)
            self.assertIn('-only-testing:'+UI_TARGET,argv)
            path=Path(argv[argv.index('-test-enumeration-output-path')+1])
            payload=responses[min(len(calls),len(responses)-1)]
            calls.append(list(argv));path.write_text(json.dumps(payload))
        with tempfile.TemporaryDirectory() as folder, \
             patch('scripts.ci_ios.prepared_simulator', side_effect=[nullcontext('fresh-1'),nullcontext('fresh-2')]) as simulators, \
             patch('scripts.ci_ios.command',side_effect=invoke):
            try: result=discover_target(Path('fixture.xctestrun'),UI_TARGET,Path(folder))
            except Exception as error:return None,error,calls,simulators.call_count
        return result,None,calls,simulators.call_count

    def test_partial_success_exit_manifest_cannot_become_a_release_plan(self):
        with self.assertRaises(ValueError):make_plan(self.partial(),'commit','Xcode')
        with self.assertRaises(DiscoveryBootstrapError):target_enumeration(self.partial(),UI_TARGET)

    def test_failed_discovery_cannot_leave_a_previous_plan_available_for_packaging(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'build').mkdir()
            plan=root/'build/test-shards.json';plan.write_text('{"stale":true}')
            with patch('scripts.ci_ios.ROOT',root),patch('scripts.ci_ios.xctestrun',return_value=Path('fixture')), \
                 patch('scripts.ci_ios.validate_compiled_targets'), \
                 patch('scripts.ci_ios.discover_target',side_effect=ValueError('discovery failed')):
                with self.assertRaises(ValueError):plan_tests(root)
            self.assertFalse(plan.exists())

    def test_discovery_bootstrap_only_is_retried_once_on_a_fresh_device(self):
        result,error,calls,count=self.discover([self.partial(),self.ui()])
        self.assertIsNone(error);self.assertEqual(len(result['values'][0]['enabledTests']),59)
        self.assertEqual(count,2);self.assertEqual(len(calls),2)
        self.assertIn('platform=iOS Simulator,id=fresh-1',calls[0])
        self.assertIn('platform=iOS Simulator,id=fresh-2',calls[1])

    def test_simulator_preparation_timeout_is_not_restarted_from_scratch(self):
        with tempfile.TemporaryDirectory() as folder, \
             patch('scripts.ci_ios.prepared_simulator',side_effect=subprocess.TimeoutExpired('bootstatus',600)) as prepare:
            with self.assertRaises(subprocess.TimeoutExpired):
                discover_target(Path('fixture.xctestrun'),UI_TARGET,Path(folder))
            self.assertEqual(prepare.call_count,1)

    def test_repeat_bootstrap_failure_still_blocks_all_test_shards(self):
        result,error,calls,count=self.discover([self.partial()])
        self.assertIsNone(result);self.assertIsInstance(error,DiscoveryBootstrapError)
        self.assertEqual(count,2);self.assertEqual(len(calls),2)

    def test_non_bootstrap_errors_and_disabled_selected_methods_are_not_retried(self):
        disabled=self.ui();disabled['values'][0]['disabledTests'].append({'identifier':UI_TARGET+'/ReaderTests/testCase0()'})
        for response in [{'errors':['Invalid test configuration'],'values':[]},disabled,
                         {'errors':[],'values':[{'enabledTests':[{'identifier':UI_TARGET}]}]}]:
            result,error,calls,count=self.discover([response])
            self.assertIsNone(result);self.assertIsInstance(error,ValueError)
            self.assertEqual(len(calls),1);self.assertEqual(count,1)

    def test_target_filter_only_excludes_other_bundle_discovered_separately(self):
        ui=target_enumeration(self.ui(),UI_TARGET)
        unit=enumeration(ui=0)
        combined={'errors':[],'values':unit['values']+ui['values']}
        plan=make_plan(combined,'commit','Xcode')
        self.assertEqual(sum(len(t) for t in plan['shards'].values()),64)

    def test_requested_device_is_prewarmed_and_never_deleted(self):
        template={'udid':'requested','state':'Booted','name':'iPhone','deviceTypeIdentifier':'type'}
        with patch.dict('os.environ',{'SIMULATOR_ID':'requested'}), \
             patch('scripts.ci_ios.simulator_template',return_value=('runtime',template)), \
             patch('scripts.ci_ios.command') as invoke, patch('scripts.ci_ios.subprocess.run') as cleanup:
            with prepared_simulator('test') as sid:self.assertEqual(sid,'requested')
            invoke.assert_called_once_with(['xcrun','simctl','bootstatus','requested','-b'],timeout=600)
            cleanup.assert_not_called()

    def test_owned_device_is_created_booted_ready_then_cleaned_up(self):
        template={'udid':'template','state':'Booted','name':'iPhone','deviceTypeIdentifier':'type'}
        with patch.dict('os.environ',{},clear=True), \
             patch('scripts.ci_ios.simulator_template',return_value=('runtime',template)), \
             patch('scripts.ci_ios.command',return_value='owned') as invoke, \
             patch('scripts.ci_ios.subprocess.run') as cleanup:
            with prepared_simulator('test') as sid:
                self.assertEqual(sid,'owned')
                self.assertEqual([c.args[0][2] for c in invoke.call_args_list],['create','boot','bootstatus'])
            self.assertEqual([c.args[0][2] for c in cleanup.call_args_list],['shutdown','delete'])


if __name__=='__main__':unittest.main()
