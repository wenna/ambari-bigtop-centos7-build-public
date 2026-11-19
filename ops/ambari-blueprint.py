#!/usr/bin/env python3
"""Render the pinned BIGTOP 3.3.0 Ambari blueprint and host creation template."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from urllib.parse import urlsplit
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'production'))
from render import checked_site, inventory, render, require

COMPONENT = dict(namenode='NAMENODE', zkfc='ZKFC', journalnode='JOURNALNODE',
                 datanode='DATANODE', zookeeper='ZOOKEEPER_SERVER', resourcemanager='RESOURCEMANAGER',
                 nodemanager='NODEMANAGER', jobhistory='HISTORYSERVER', metastore='HIVE_METASTORE',
                 hiveserver2='HIVE_SERVER', sparkhistory='SPARK_JOBHISTORYSERVER')
PASSWORD = 'javax.jdo.option.ConnectionPassword'


def configurations(values):
    return [{name: {'properties': properties}} for name, properties in sorted(values.items()) if properties]


def read_properties(path):
    return {prop.findtext('name'): prop.findtext('value') for prop in ElementTree.parse(str(path)).findall('property')}


def generate(rows, site, name, password=None):
    checked_site(site, rows)
    require(re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,79}', name), 'Invalid blueprint name')
    def members(role):
        return [row['fqdn'] for row in rows if role in row['roles']]

    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp)
        render(dest, rows, site)
        sample = dest / rows[0]['slot'] / 'etc'
        common = {kind: read_properties(sample / 'hadoop/conf' / (kind + '.xml'))
                  for kind in ('core-site', 'hdfs-site', 'yarn-site', 'mapred-site')}
        common['tez-site'] = read_properties(sample / 'tez/conf/tez-site.xml')
        common['hive-site'] = read_properties(sample / 'hive/conf/hive-site.xml')

    # Bound the sort buffers to the task heap on smaller workers.
    sort_mb = str(min(256, site['task_memory_mb'] // 8))
    common['mapred-site']['mapreduce.task.io.sort.mb'] = sort_mb
    common['tez-site']['tez.runtime.io.sort.mb'] = sort_mb
    # Tez's explicit classpath replaces its default archive entries. YARN expands $PWD on each worker.
    common['tez-site']['tez.lib.uris.classpath'] = '$PWD/tezlib/*,$PWD/tezlib/lib/*'
    common['core-site']['net.topology.script.file.name'] = '/etc/hadoop/conf/topology_script.py'
    hdfs, yarn, hive = (common[key] for key in ('hdfs-site', 'yarn-site', 'hive-site'))
    for values, keys in ((hdfs, ('dfs.ha.namenode.id', 'dfs.datanode.hostname')),
                         (yarn, ('yarn.resourcemanager.ha.id', 'yarn.nodemanager.hostname')),
                         (hive, ('hive.server2.thrift.bind.host',))):
        for key in keys:
            values.pop(key, None)
    hdfs['dfs.datanode.data.dir'] = ','.join(site['datanode_dirs'])
    yarn.update({'yarn.nodemanager.local-dirs': ','.join(site['nm_local_dirs']),
                 'yarn.nodemanager.resource.memory-mb': str(site['nm_memory_mb']),
                 'yarn.nodemanager.resource.cpu-vcores': str(site['nm_vcores']),
                 'yarn.timeline-service.enabled': 'false',
                 'yarn.resourcemanager.system-metrics-publisher.enabled': 'false'})
    for index, host in enumerate(members('namenode'), 1):
        hdfs['dfs.namenode.https-address.%s.nn%d' % (site['nameservice'], index)] = host + ':9871'
    for index, host in enumerate(members('resourcemanager'), 1):
        for prop, port in [('address', 8032), ('admin.address', 8033), ('resource-tracker.address', 8031), ('scheduler.address', 8030)]:
            yarn['yarn.resourcemanager.%s.rm%d' % (prop, index)] = '%s:%d' % (host, port)

    pg = urlsplit(site['pg_url'][5:])
    db = pg.path.lstrip('/')
    log_dir, run_dir, accounts = site['log_dir'], site['run_dir'], site['accounts']
    events = 'hdfs://%s/spark-history' % site['nameservice']
    hive.update({'javax.jdo.option.ConnectionURL': site['pg_url'],
                 'javax.jdo.option.ConnectionUserName': site['pg_user'],
                 'javax.jdo.option.ConnectionDriverName': 'org.postgresql.Driver',
                 'ambari.hive.db.schema.name': db, 'hive.metastore.schema.verification': 'true',
                 'hive.server2.support.dynamic.service.discovery': 'true',
                 'hive.zookeeper.quorum': common['core-site']['ha.zookeeper.quorum'],
                 'hive.server2.zookeeper.namespace': 'hiveserver2'})
    common.update({'cluster-env': dict(dfs_ha_initial_namenode_active=members('namenode')[0],
                                       dfs_ha_initial_namenode_standby=members('namenode')[1]),
                   'hadoop-env': dict(hdfs_user=accounts['hdfs'], hdfs_log_dir_prefix=log_dir, hadoop_pid_dir_prefix=run_dir),
                   'yarn-env': dict(yarn_user=accounts['yarn'], yarn_log_dir_prefix=log_dir, yarn_pid_dir_prefix=run_dir),
                   'mapred-env': dict(mapred_user=accounts['mapred'], mapred_log_dir_prefix=log_dir, mapred_pid_dir_prefix=run_dir),
                   'hive-env': dict(hive_user=accounts['hive'], hive_database='Existing PostgreSQL Database',
                                    hive_database_type='postgres', hive_database_name=db,
                                    hive_log_dir=log_dir + '/hive', hive_pid_dir=run_dir + '/hive'),
                   'zookeeper-env': dict(zk_user=accounts['zookeeper'], zk_log_dir=log_dir + '/zookeeper', zk_pid_dir=run_dir + '/zookeeper'),
                   'zoo.cfg': dict(dataDir=site['state_dir'] + '/zookeeper'),
                   'spark-env': dict(spark_user=accounts['spark'], spark_log_dir=log_dir + '/spark', spark_pid_dir=run_dir + '/spark'),
                   'spark-defaults': {'spark.master': 'yarn', 'spark.eventLog.enabled': 'true',
                                      'spark.eventLog.dir': events, 'spark.history.fs.logDirectory': events}})

    groups, mapping = [], []
    for row in rows:
        host, slot, roles = row['fqdn'], row['slot'], row['roles']
        components = {COMPONENT[role] for role in roles if role in COMPONENT}
        components.update(('HDFS_CLIENT', 'YARN_CLIENT', 'MAPREDUCE2_CLIENT', 'ZOOKEEPER_CLIENT'))
        if set(roles) & {'jobhistory', 'hiveserver2', 'metastore', 'sparkhistory'}:
            components.update(('HIVE_CLIENT', 'HCAT', 'TEZ_CLIENT'))
        if 'sparkhistory' in roles:
            components.add('SPARK_CLIENT')
        install_only = set()
        if host == members('resourcemanager')[0]:
            install_only.add('TIMELINE_READER')
        if 'jobhistory' in roles:
            install_only.add('APP_TIMELINE_SERVER')
        if host == members('hiveserver2')[0]:
            components.add('WEBHCAT_SERVER')
        entries = [dict(name=component, **({'provision_action': 'INSTALL_ONLY'} if component in install_only else {}))
                   for component in sorted(components | install_only)]
        local = {}
        if 'hiveserver2' in roles:
            local['hive-site'] = {'hive.server2.thrift.bind.host': host}
        for field, kind, prop in [('nm_memory_mb', 'yarn-site', 'yarn.nodemanager.resource.memory-mb'),
                                  ('nm_vcores', 'yarn-site', 'yarn.nodemanager.resource.cpu-vcores'),
                                  ('nm_local_dirs', 'yarn-site', 'yarn.nodemanager.local-dirs'),
                                  ('datanode_dirs', 'hdfs-site', 'dfs.datanode.data.dir')]:
            settings = site.get('node_overrides', {}).get(slot, {})
            if field in settings:
                value = settings[field]
                local.setdefault(kind, {})[prop] = ','.join(value) if isinstance(value, list) else str(value)
        group = dict(name=slot, cardinality='1', components=entries)
        if local:
            group['configurations'] = configurations(local)
        groups.append(group)
        mapping.append(dict(name=slot, hosts=[dict(fqdn=host, rack_info='/' + row['rack'])]))
    blueprint = {'Blueprints': dict(stack_name='BIGTOP', stack_version='3.3.0'),
                 'host_groups': groups, 'configurations': configurations(common),
                 'settings': [{'service_settings': [{'name': 'HIVE', 'credential_store_enabled': 'true'}]}]}
    template = dict(blueprint=name, host_groups=mapping)
    if password is not None:
        template['configurations'] = configurations({'hive-site': {PASSWORD: password}})
    return blueprint, template


def read_secret(path):
    with os.fdopen(os.open(str(path), os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)), 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and (os.name != 'posix' or
                (info.st_uid == os.geteuid() and not info.st_mode & 0o077)), 'Use an owner-only regular Hive password file')
        data = stream.read(16385)
    require(len(data) <= 16384, 'Hive password file is too large')
    value = data.decode('utf-8').rstrip('\r\n')
    require(value and not any(char in value for char in '\0\r\n'), 'Use one nonempty Hive password line')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('inventory', 'site', 'out'):
        parser.add_argument('--' + arg, type=Path, required=True)
    parser.add_argument('--blueprint', '--name', required=True)
    parser.add_argument('--hive-password-file', type=Path, help='Only for private cluster submission; omit for a secret-free plan')
    args = parser.parse_args()
    rows = inventory(args.inventory)
    site = json.loads(args.site.read_text(encoding='utf-8'))
    outputs = generate(rows, site, args.blueprint, read_secret(args.hive_password_file) if args.hive_password_file else None)
    os.umask(0o077)
    args.out.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = args.out.lstat()
    require(stat.S_ISDIR(info.st_mode) and (os.name != 'posix' or (info.st_uid == os.geteuid() and not info.st_mode & 0o077)),
            'Use an owner-only output directory')
    for filename, data in zip(('blueprint.json', 'cluster.json'), outputs):
        with tempfile.NamedTemporaryFile(dir=str(args.out), mode='w', encoding='utf-8', delete=False) as stream:
            try:
                json.dump(data, stream, sort_keys=True, indent=2)
                stream.write('\n')
                stream.close()
                os.replace(stream.name, str(args.out / filename))
            finally:
                if os.path.exists(stream.name):
                    os.unlink(stream.name)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, TypeError, KeyError) as error:
        sys.exit(str(error))
