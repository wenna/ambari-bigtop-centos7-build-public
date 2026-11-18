"""Run a temporary three-node ZooKeeper quorum, then stop its leader."""
import json
from pathlib import Path
import re
import subprocess
import time
import uuid


def mode(reply):
    match = re.search(r'^Mode:\s*(leader|follower)\s*$', reply, re.MULTILINE)
    return match.group(1) if match else None


def is_quorum(replies):
    modes = [mode(reply) for reply in replies]
    return len(modes) in (2, 3) and modes.count('leader') == 1 and modes.count('follower') == len(modes) - 1


def command(args, timeout=60):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[:3]}: {result.stderr[-3000:]}')
    return result.stdout


def wait_quorum(nodes):
    deadline = time.monotonic() + 240
    replies = {}
    probe = ("import socket; s=socket.create_connection(('127.0.0.1',2181),2); "
             "s.settimeout(2); s.sendall(b'srvr'); "
             "print(s.makefile('rb').read(16384).decode()); s.close()")
    while time.monotonic() < deadline:
        for node in nodes:
            try:
                replies[node] = command(['docker', 'exec', node, 'python3', '-c', probe], timeout=15)
            except Exception as error:
                replies[node] = str(error)
        if is_quorum(list(replies.values())):
            return replies
        time.sleep(3)
    raise RuntimeError('Quorum did not become healthy: ' + json.dumps(replies))


def main():
    root = Path.cwd().resolve()
    logs = root / 'artifacts' / 'zk-quorum'
    logs.mkdir(parents=True, exist_ok=True)
    network = 'zk-probe-' + uuid.uuid4().hex[:12]
    nodes = []
    network_created = False
    report = {'status': 'failed', 'cleanup_errors': []}
    try:
        command(['docker', 'network', 'create', '--label', f'ambari.probe={network}', network])
        network_created = True
        for index in range(1, 4):
            node = f'{network}-{index}'
            nodes.append(node)
            command(['docker', 'run', '-d', '--name', node, '--hostname', f'zk{index}',
                     '--network', network, '--network-alias', f'zk{index}',
                     '--memory', '768m', '--cpus', '0.5', '--label', f'ambari.probe={network}',
                     '-e', 'VERIFY_EXTRA=zookeeper',
                     '-v', f'{root}/upstream/bigtop/output:/rpms:ro',
                     '-v', f'{root}/scripts:/scripts:ro',
                     'centos@sha256:be65f488b7764ad3638f236b7b515b3678369a5124c47b8d32916d6487418ea4',
                     'bash', '/scripts/launch-zk-node.sh', str(index)])
        print('Stage: waiting for three-node quorum', flush=True)
        report['initial'] = wait_quorum(nodes)
        leader = next(node for node, reply in report['initial'].items() if mode(reply) == 'leader')
        print('Stage: stopping leader and verifying re-election', flush=True)
        command(['docker', 'stop', '--time', '5', leader])
        report['stopped_leader'] = leader
        report['after_failover'] = wait_quorum([node for node in nodes if node != leader])
        report['status'] = 'passed'
    except Exception as error:
        report['error'] = str(error)
    finally:
        for index, node in enumerate(nodes, 1):
            try:
                result = subprocess.run(['docker', 'logs', '--tail', '300', node], capture_output=True, text=True, timeout=20)
                (logs / f'node{index}.log').write_text(result.stdout + result.stderr)
            except Exception as error:
                report['cleanup_errors'].append('log collection: ' + str(error))
            try:
                command(['docker', 'rm', '-f', node], timeout=30)
            except Exception as error:
                report['cleanup_errors'].append(str(error))
        if network_created:
            try:
                command(['docker', 'network', 'rm', network])
            except Exception as error:
                report['cleanup_errors'].append(str(error))
        if report['cleanup_errors']:
            report['status'] = 'failed-cleanup'
        (logs / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2), flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
