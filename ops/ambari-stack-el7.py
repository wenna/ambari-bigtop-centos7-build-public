#!/usr/bin/env python3
"""Install the pinned BIGTOP EL7 service package lists before first Ambari startup."""
import copy
import os
from pathlib import Path
import sys
from xml.etree import ElementTree as ET

# Ambari inherits the entire osSpecifics element only if the child supplies none.
# Keep inherited lists for other operating systems; split out EL7 for this kit.
PACKAGES = {
    'HDFS': ['hadoop_@', 'hadoop_@-client', 'hadoop_@-libhdfs', 'hadoop_@-hdfs-namenode',
             'hadoop_@-hdfs-zkfc', 'hadoop_@-hdfs-journalnode', 'hadoop_@-hdfs-datanode'],
    'YARN': ['hadoop_@-yarn', 'hadoop_@-mapreduce', 'hadoop_@-hdfs',
             'hadoop_@-yarn-resourcemanager', 'hadoop_@-yarn-nodemanager'],
    'MAPREDUCE2': ['hadoop_@-mapreduce-historyserver', 'hadoop_@-mapreduce'],
    'HIVE': ['hive_@', 'hive_@-hcatalog', 'hive_@-webhcat', 'hive_@-webhcat-server',
             'hive_@-jdbc', 'hive_@-metastore', 'hive_@-server2'],
    'ZOOKEEPER': ['zookeeper_@', 'zookeeper_@-server'],
}


def changes(root):
    for service in ('HDFS', 'YARN', 'HIVE', 'ZOOKEEPER'):
        name = Path('services') / service / 'metainfo.xml'
        src = root / '3.2.0' / name
        dest = root / '3.3.0' / name
        backup = dest.with_name('metainfo.xml.original-el7')
        original = backup.read_bytes() if backup.exists() else dest.read_bytes()
        parent = ET.parse(str(src)).getroot()
        # Preserve source comments and original XML verbatim outside each injected section.
        rendered = original.decode('utf-8')
        for child in ET.fromstring(original).findall('./services/service'):
            svc = child.findtext('name')
            if svc not in PACKAGES or child.find('osSpecifics') is not None:
                raise ValueError('Unexpected source service metadata: ' + svc)
            inherited = parent.find("./services/service[name='{}']/osSpecifics".format(svc))
            specs = copy.deepcopy(inherited)
            for entry in list(specs):
                families = entry.findtext('osFamily').split(',')
                if 'redhat7' not in families:
                    continue
                families.remove('redhat7')
                if families:
                    entry.find('osFamily').text = ','.join(families)
                else:
                    specs.remove(entry)
                break
            else:
                raise ValueError('Missing inherited redhat7 metadata for ' + svc)
            entry = ET.SubElement(specs, 'osSpecific')
            ET.SubElement(entry, 'osFamily').text = 'redhat7'
            packages = ET.SubElement(entry, 'packages')
            for rpm in PACKAGES[svc]:
                ET.SubElement(ET.SubElement(packages, 'package'), 'name').text = rpm.replace('@', '${stack_version}')
            start = rendered.index('<name>' + svc + '</name>')
            end = rendered.index('</service>', start)
            rendered = rendered[:end] + ET.tostring(specs, encoding='unicode') + '\n    ' + rendered[end:]
        result = rendered.encode('utf-8')
        if dest.read_bytes() not in (original, result):
            raise ValueError('Existing site changes in ' + str(dest))
        yield dest, original, result, backup


def apply(root):
    updates = list(changes(root))
    for path, old, new, backup in updates:
        if path.read_bytes() == new:
            continue
        if not backup.exists():
            with backup.open('xb') as f:
                f.write(old)
        # Keep the existing file's owner, access mode and SELinux context.
        with path.open('r+b') as f:
            f.write(new)
            f.truncate()
            f.flush()
            os.fsync(f.fileno())
        print('BIGTOP 3.3.0 EL7:', path)


if __name__ == '__main__':
    apply(Path(sys.argv[1]) if len(sys.argv) == 2 else Path('/var/lib/ambari-server/resources/stacks/BIGTOP'))
