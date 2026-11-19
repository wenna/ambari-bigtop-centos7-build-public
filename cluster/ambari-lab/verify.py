"""Check independently collected RPM inventories and Ambari task/host evidence."""
import csv
import json
from pathlib import Path
import re
import sys


ROLES = {
    'namenode': ('NAMENODE', 'hadoop_3_3_0-hdfs-namenode'),
    'zkfc': ('ZKFC', 'hadoop_3_3_0-hdfs-zkfc'),
    'journalnode': ('JOURNALNODE', 'hadoop_3_3_0-hdfs-journalnode'),
    'datanode': ('DATANODE', 'hadoop_3_3_0-hdfs-datanode'),
    'resourcemanager': ('RESOURCEMANAGER', 'hadoop_3_3_0-yarn-resourcemanager'),
    'nodemanager': ('NODEMANAGER', 'hadoop_3_3_0-yarn-nodemanager'),
    'jobhistory': ('HISTORYSERVER', 'hadoop_3_3_0-mapreduce-historyserver'),
    'zookeeper': ('ZOOKEEPER_SERVER', 'zookeeper_3_3_0-server'),
    'metastore': ('HIVE_METASTORE', 'hive_3_3_0-metastore'),
    'hiveserver2': ('HIVE_SERVER', 'hive_3_3_0-server2'),
    'sparkhistory': ('SPARK_JOBHISTORYSERVER', 'spark_3_3_0-history-server'),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def rpms(path):
    return dict(line.split('\t', 1) for line in path.read_text().splitlines())


def verify(inventory, evidence):
    release = rpms(evidence / 'release-rpms.tsv')
    ecosystem = {name for name in release if re.match(r'^(?:bigtop|hadoop|zookeeper|hive|tez|spark)(?:_|-|$)', name)}
    with inventory.open() as stream:
        nodes = list(csv.DictReader(stream))
    tasks = [task for path in evidence.glob('request-*-tasks.json') for task in json.loads(path.read_text())]
    states = {(row['HostRoles']['host_name'], row['HostRoles']['component_name']): row['HostRoles']['state']
              for row in json.loads((evidence / 'host-components.json').read_text())['items']}
    for node in nodes:
        host = node['fqdn']
        before, after = (rpms(evidence / (host + '-' + phase + '.tsv')) for phase in ('before', 'after'))
        require(not ecosystem.intersection(before), 'Preinstalled application package on ' + host)
        for pkg in ecosystem.intersection(after):
            require(after[pkg] == release[pkg], 'Unexpected build of ' + pkg + ' on ' + host)
        for role in set(node['roles'].split()) - {'ambari-server'}:
            component, pkg = ROLES[role]
            require(pkg in release and after.get(pkg) == release[pkg], 'Missing release package %s on %s' % (pkg, host))
            require(states.get((host, component)) == 'STARTED', 'Role not running: %s on %s' % (component, host))
            require(any(task['host_name'] == host and task['role'] == component and task['command'] == 'INSTALL'
                        and task['status'] == 'COMPLETED' for task in tasks), 'No successful Ambari INSTALL for %s/%s' % (host, component))
    require(any(component == 'TEZ_CLIENT' and state == 'INSTALLED' for (_, component), state in states.items()),
            'No installed Tez client')
    for host, component in states:
        if component == 'TEZ_CLIENT':
            require(rpms(evidence / (host + '-after.tsv')).get('tez_3_3_0') == release['tez_3_3_0'], 'Wrong Tez RPM on ' + host)
    checks = {task['role'] for task in tasks if task['command'] == 'SERVICE_CHECK' and task['status'] == 'COMPLETED'}
    for service in ('ZOOKEEPER', 'HDFS', 'YARN', 'MAPREDUCE2', 'TEZ', 'HIVE', 'SPARK'):
        require(service + '_SERVICE_CHECK' in checks, 'No successful service check: ' + service)
    print('Verified Ambari INSTALL tasks, started daemons, offline release RPMs and service checks on', len(nodes), 'hosts')


if __name__ == '__main__':
    verify(Path(sys.argv[1]), Path(sys.argv[2]))
