import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'ops/ambari-blueprint.py'
spec = importlib.util.spec_from_file_location('native_blueprint', str(SCRIPT))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def properties(document):
    return {kind: values['properties'] for entry in document.get('configurations', []) for kind, values in entry.items()}


class NativeBlueprintTests(unittest.TestCase):
    def setUp(self):
        self.rows = native.inventory(ROOT / 'ops/hosts.example.csv')
        self.site = json.loads((ROOT / 'production/site.example.json').read_text())

    def test_stack_roles_and_ha_addresses_follow_custom_hosts(self):
        for index, row in enumerate(self.rows):
            row['fqdn'] = 'el7-%d.site.example' % index
        bp, template = native.generate(self.rows, self.site, 'example')
        self.assertEqual({'stack_name': 'BIGTOP', 'stack_version': '3.3.0'}, bp['Blueprints'])
        self.assertEqual({row['fqdn']: '/' + row['rack'] for row in self.rows},
                         {host['fqdn']: host['rack_info'] for group in template['host_groups'] for host in group['hosts']})
        groups = {group['name']: {component['name']: component.get('provision_action') for component in group['components']}
                  for group in bp['host_groups']}
        for required, slots in {'NAMENODE': ['bd01', 'bd02'], 'ZKFC': ['bd01', 'bd02'], 'JOURNALNODE': ['bd01', 'bd02', 'bd03'],
                                'RESOURCEMANAGER': ['bd02', 'bd03'], 'HIVE_METASTORE': ['bd09', 'bd10'],
                                'HIVE_SERVER': ['bd09', 'bd10'], 'SPARK_JOBHISTORYSERVER': ['bd10']}.items():
            self.assertEqual(slots, sorted(slot for slot in groups if required in groups[slot]))
        all_components = {name for group in groups.values() for name in group}
        self.assertFalse(all_components & {'SECONDARY_NAMENODE', 'MYSQL_SERVER', 'HBASE_CLIENT'})
        self.assertIn('WEBHCAT_SERVER', groups['bd09'])
        self.assertEqual({'TIMELINE_READER', 'APP_TIMELINE_SERVER'},
                         {name for group in groups.values() for name, action in group.items() if action == 'INSTALL_ONLY'})
        config = properties(bp)
        self.assertEqual('el7-0.site.example', config['cluster-env']['dfs_ha_initial_namenode_active'])
        self.assertEqual('el7-1.site.example:8020', config['hdfs-site']['dfs.namenode.rpc-address.prod.nn2'])
        self.assertEqual('qjournal://el7-0.site.example:8485;el7-1.site.example:8485;el7-2.site.example:8485/prod',
                         config['hdfs-site']['dfs.namenode.shared.edits.dir'])
        self.assertEqual('el7-2.site.example:8032', config['yarn-site']['yarn.resourcemanager.address.rm2'])
        self.assertEqual('thrift://el7-8.site.example:9083,thrift://el7-9.site.example:9083', config['hive-site']['hive.metastore.uris'])

    def test_first_worker_override_does_not_leak_to_cluster(self):
        for row in self.rows:
            if row['slot'] == 'bd05':
                row['slot'] = 'aa-worker'
        self.rows.sort(key=lambda row: row['slot'])
        self.site['node_overrides'] = {'aa-worker': {'nm_memory_mb': 65536, 'nm_vcores': 32, 'datanode_dirs': ['/big/dfs']}}
        bp, _ = native.generate(self.rows, self.site, 'prod')
        self.assertEqual(str(self.site['nm_memory_mb']), properties(bp)['yarn-site']['yarn.nodemanager.resource.memory-mb'])
        self.assertEqual('65536', properties(bp)['yarn-site']['yarn.scheduler.maximum-allocation-mb'])
        groups = {group['name']: properties(group) for group in bp['host_groups']}
        self.assertEqual('/big/dfs', groups['aa-worker']['hdfs-site']['dfs.datanode.data.dir'])
        self.assertEqual('32', groups['aa-worker']['yarn-site']['yarn.nodemanager.resource.cpu-vcores'])
        self.assertEqual({}, groups['bd04'])

    def test_external_pg_secret_is_only_in_private_cluster_body(self):
        secret = 'dummy-\"sensitive credential$!'
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'private'
            source = Path(directory) / 'password'
            source.write_text(secret + '\n')
            source.chmod(0o600)
            command = [sys.executable, str(SCRIPT), '--inventory', str(ROOT / 'ops/hosts.example.csv'), '--site',
                       str(ROOT / 'production/site.example.json'), '--name', 'demo', '--out', str(out)]
            for private in (True, False):
                result = subprocess.run(command + (['--hive-password-file', str(source)] if private else []),
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
                self.assertNotIn(b'sensitive credential', result.stdout + result.stderr)
                bp = json.loads((out / 'blueprint.json').read_text())
                self.assertNotIn(native.PASSWORD, properties(bp)['hive-site'])
                self.assertEqual(self.site['pg_url'], properties(bp)['hive-site']['javax.jdo.option.ConnectionURL'])
                self.assertEqual('Existing PostgreSQL Database', properties(bp)['hive-env']['hive_database'])
                template = json.loads((out / 'cluster.json').read_text())
                self.assertEqual(secret if private else None, properties(template).get('hive-site', {}).get(native.PASSWORD))
                self.assertNotIn('default_password', template)
            if os.name == 'posix':
                self.assertEqual(0, (out / 'cluster.json').stat().st_mode & 0o077)
                source.chmod(0o644)
                with self.assertRaises(ValueError):
                    native.read_secret(source)


if __name__ == '__main__':
    unittest.main()
