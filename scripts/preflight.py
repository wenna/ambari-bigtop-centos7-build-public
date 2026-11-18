"""Small, bounded cloud probe. This does not build or certify the Hadoop stack."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import urllib.request
import uuid


def assess_resources(system, arch, cpus, memory_gib, free_disk_gib):
    reasons = []
    for passed, reason in [
        (system == 'Linux', 'Linux is required'),
        (arch in ('x86_64', 'amd64'), 'x86_64 is required'),
        (cpus >= 2, 'at least 2 CPUs are required for the probe'),
        (memory_gib >= 6, 'at least 6 GiB RAM are required for the probe'),
        (free_disk_gib >= 8, 'at least 8 GiB free disk are required for the probe'),
    ]:
        if not passed:
            reasons.append(reason)
    return {
        'probe_ready': not reasons,
        'blocked_reasons': reasons,
        'full_stack_recommended': not reasons and cpus >= 16
        and memory_gib >= 60 and free_disk_gib >= 300,
        'note': 'Probe thresholds are not full-stack build requirements or validation.',
    }


def run_command(args, timeout=60):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr[-4000:]}')
    return result.stdout.strip()


def host_resources():
    mem_gib = 0
    if Path('/proc/meminfo').is_file():
        for line in Path('/proc/meminfo').read_text().splitlines():
            if line.startswith('MemTotal:'):
                mem_gib = int(line.split()[1]) / 1024 / 1024
                break
    return dict(system=platform.system(), arch=platform.machine(), cpus=os.cpu_count() or 0,
                memory_gib=round(mem_gib, 2),
                free_disk_gib=round(shutil.disk_usage(Path.cwd()).free / 1024**3, 2))


def network_probe():
    # Read only small responses: no dependency downloads or credentials.
    urls = [
        'https://archive.apache.org/dist/bigtop/bigtop-3.3.0/',
        'https://archive.apache.org/dist/ambari/ambari-3.0.0/',
        'https://vault.centos.org/7.9.2009/os/x86_64/repodata/repomd.xml',
        'https://repo.maven.apache.org/maven2/org/apache/maven/maven-core/maven-metadata.xml',
        'https://registry.npmjs.org/npm/latest',
    ]
    results = []
    for url in urls:
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'ambari-bigtop-preflight'})
            with urllib.request.urlopen(request, timeout=30) as response:
                response.read(1024)
                results.append(dict(url=url, ok=True, status=response.status))
        except Exception as error:
            results.append(dict(url=url, ok=False, error=str(error)))
    return results


def container_probe(report):
    image = 'centos:7.9.2009'
    prefix = 'ambari-probe-' + uuid.uuid4().hex[:12]
    nodes = []
    network_created = False
    report['containers'] = {'image_tag': image, 'checks': [], 'cleanup_errors': []}
    try:
        run_command(['docker', 'pull', '--platform', 'linux/amd64', image], timeout=240)
        report['containers']['image'] = json.loads(run_command(['docker', 'image', 'inspect', image]))[0]
        # Save only provenance fields, not the full image configuration.
        info = report['containers']['image']
        report['containers']['image'] = {k: info.get(k) for k in ('Id', 'RepoDigests', 'Architecture', 'Os', 'Size')}
        run_command(['docker', 'network', 'create', '--label', f'ambari.probe={prefix}', prefix])
        network_created = True
        for index in range(1, 4):
            name = f'{prefix}-{index}'
            # Track before create: even a partially failed launch is cleaned up.
            nodes.append(name)
            run_command(['docker', 'run', '-d', '--name', name, '--hostname', f'node{index}',
                         '--network', prefix, '--memory', '128m', '--cpus', '0.25',
                         '--label', f'ambari.probe={prefix}', image, 'sleep', '300'])
        for index, name in enumerate(nodes):
            peer = nodes[(index + 1) % len(nodes)]
            output = run_command(['docker', 'exec', name, 'bash', '-c',
                                  'cat /etc/centos-release; uname -m; getent hosts "$1"', '--', peer])
            if 'CentOS Linux release 7.9.2009' not in output or 'x86_64' not in output:
                raise RuntimeError('unexpected CentOS version or architecture')
            report['containers']['checks'].append({'node': name, 'peer': peer, 'output': output})
        report['containers']['ok'] = True
        report['containers']['scope'] = 'Three user-space containers and DNS only; no systemd, services, or HA validation.'
    finally:
        for name in reversed(nodes):
            try:
                run_command(['docker', 'rm', '-f', name])
            except Exception as error:
                report['containers']['cleanup_errors'].append(str(error))
        if network_created:
            try:
                run_command(['docker', 'network', 'rm', prefix])
            except Exception as error:
                report['containers']['cleanup_errors'].append(str(error))
        if report['containers']['cleanup_errors']:
            report['containers']['ok'] = False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--containers', action='store_true')
    parser.add_argument('--report', default='reports/preflight.json')
    options = parser.parse_args()
    report = {'time_utc': datetime.now(timezone.utc).isoformat(), 'status': 'failed',
              'billing': 'Caller must first confirm free quota and overage blocking.'}
    try:
        report['host'] = host_resources()
        report['resources'] = assess_resources(**report['host'])
        if not report['resources']['probe_ready']:
            raise RuntimeError('; '.join(report['resources']['blocked_reasons']))
        report['docker'] = json.loads(run_command(['docker', 'info', '--format', '{{json .}}']))
        report['docker'] = {k: report['docker'].get(k) for k in ('ServerVersion', 'Driver', 'CgroupVersion', 'NCPU', 'MemTotal')}
        report['network'] = network_probe()
        if options.containers:
            container_probe(report)
        report['status'] = 'passed' if all(item['ok'] for item in report['network']) else 'blocked-network'
        if options.containers and not report['containers'].get('ok'):
            report['status'] = 'failed-containers'
    except Exception as error:
        report['error'] = str(error)
    finally:
        path = Path(options.report)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
