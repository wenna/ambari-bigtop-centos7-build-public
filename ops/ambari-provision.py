#!/usr/bin/env python3
"""Create a BIGTOP cluster through the Ambari 3 API and verify its components."""
import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

STACK = '/stacks/BIGTOP/versions/3.3.0'
REPOS = STACK + '/repository_versions'
VERSION = '3.3.0'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def private(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and not info.st_mode & 0o077,
            'Use an owner-only regular file: ' + str(path))


def parse_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


class Controller:
    def __init__(self, args):
        self.args = args
        self.cluster = '/clusters/' + args.cluster
        self.blueprint = '/blueprints/' + args.name

    def api(self, route, method='GET', payload=None, missing=False):
        with tempfile.TemporaryFile() as response:
            # Kept on stdin: templates may contain the Hive database credential.
            command = ['curl', '--silent', '--show-error', '--globoff', '--connect-timeout', '10',
                       '--max-time', '150', '--netrc-file', str(self.args.netrc), '-H', 'X-Requested-By: bigtop-installer',
                       '-H', 'Content-Type: application/json', '-X', method, '-w', '\n%{http_code}']
            body = None
            if payload is not None:
                command += ['--data-binary', '@-']
                body = json.dumps(payload).encode()
            subprocess.run(command + [self.args.base.rstrip('/') + '/api/v1' + route],
                           input=body, stdout=response, check=True)
            response.seek(0)
            raw, status = response.read().rsplit(b'\n', 1)
        if status == b'404' and missing:
            return None
        if not status.startswith(b'2'):
            # API validation messages can repeat the submitted configuration.
            raise ValueError('{} {} returned HTTP {}. Inspect Ambari Server logs locally.'.format(method, route, status.decode()))
        return json.loads(raw) if raw.strip() else {}

    def repository(self):
        url = self.args.repo.rstrip('/')
        fields = '?fields=RepositoryVersions/repository_version,operating_systems/OperatingSystems/os_type,operating_systems/repositories/Repositories/base_url'
        def matching():
            return [x for x in self.api(REPOS + fields)['items'] if x['RepositoryVersions']['repository_version'] == VERSION]
        versions = matching()
        if not versions:
            self.api(REPOS, 'POST', {'RepositoryVersions': {'repository_version': VERSION, 'display_name': 'BIGTOP 3.3.0 EL7 offline'},
                'operating_systems': [{'OperatingSystems': {'os_type': 'redhat7', 'ambari_managed_repositories': True},
                    'repositories': [{'Repositories': {'base_url': url, 'repo_name': 'bigtop', 'repo_id': 'BIGTOP-3.3.0'}}]}]})
            versions = matching()
        require(len(versions) == 1, 'Expected a single BIGTOP repository version')
        systems = versions[0]['operating_systems']
        repos = [r['Repositories']['base_url'].rstrip('/') for s in systems if s['OperatingSystems']['os_type'] == 'redhat7' for r in s['repositories']]
        require(repos == [url], 'Existing BIGTOP redhat7 repository differs. Review it in Ambari before proceeding.')
        return versions[0]['RepositoryVersions']['id']

    def wait_request(self, rid):
        path = self.cluster + '/requests/' + str(int(rid))
        deadline = time.monotonic() + self.args.timeout
        old = None
        while time.monotonic() < deadline:
            req = self.api(path + '?fields=Requests/request_status,Requests/progress_percent')['Requests']
            current = (req['request_status'], req['progress_percent'])
            if current != old:
                print('Ambari request {} {} ({}%)'.format(rid, *current), flush=True)
                old = current
            if current[0] == 'COMPLETED':
                return
            if current[0] in ('FAILED', 'ABORTED', 'TIMEDOUT', 'HOLDING', 'HOLDING_FAILED', 'HOLDING_TIMEDOUT', 'SKIPPED_FAILED'):
                raise ValueError('Review failed tasks in Ambari ' + path + '/tasks before retrying')
            time.sleep(10)
        raise ValueError('Time limit reached; monitor Ambari ' + path)

    def verify(self, bp, topology):
        groups = {g['name']: g['components'] for g in bp['host_groups']}
        expected = {(h['fqdn'], c['name']): c.get('provision_action') for g in topology['host_groups']
                    for h in g['hosts'] for c in groups[g['name']]}
        components = self.api(self.cluster + '/components?fields=ServiceComponentInfo/category')['items']
        clients = {c['ServiceComponentInfo']['component_name'] for c in components
                   if c['ServiceComponentInfo']['category'] == 'CLIENT'}
        resources = self.api(self.cluster + '/host_components?fields=HostRoles/state')['items']
        actual = {(v['HostRoles']['host_name'], v['HostRoles']['component_name']): v['HostRoles'] for v in resources}
        bad = []
        for key in sorted(expected):
            r = actual.get(key, {})
            if r.get('state') != ('INSTALLED' if key[1] in clients or expected[key] == 'INSTALL_ONLY' else 'STARTED'):
                bad.append('{}:{}={}'.format(*key, r.get('state', 'MISSING')))
        require(not bad, 'Components not ready: ' + ', '.join(bad))
        print('Verified {} Ambari-managed host components'.format(len(expected)), flush=True)

    def process(self, state_dir):
        bp, topology = parse_json(self.args.bp), parse_json(self.args.template)
        require(topology['blueprint'] == self.args.name, 'Template blueprint name differs')
        if self.args.check:
            self.verify(bp, topology)
            return
        marker = state_dir / 'installation.json'
        signature = hashlib.sha256(json.dumps([self.args.base, self.args.repo, self.args.name, bp, topology], sort_keys=True).encode()).hexdigest()
        def save():
            with tempfile.NamedTemporaryFile(dir=str(state_dir), mode='w', delete=False) as f:
                json.dump(state, f)
            os.replace(f.name, str(marker))
        if marker.exists():
            private(marker)
            state = parse_json(marker)
            require(state['signature'] == signature, 'Saved installation differs from site inputs. Review existing Ambari state.')
        else:
            require(self.api(self.cluster, missing=True) is None and self.api(self.blueprint, missing=True) is None,
                    'Cluster or blueprint name already in use. Select fresh names or use --check for verification.')
            state = {'signature': signature}
            save()
        if 'request' not in state:
            topology['repository_version_id'] = self.repository()
            if not state.get('blueprint'):
                self.api(self.blueprint, 'POST', bp)
                state['blueprint'] = True
                save()
            require(self.api(self.cluster, missing=True) is None, 'Cluster already exists. Check Ambari request history before recovery.')
            result = self.api(self.cluster, 'POST', topology)
            state['request'] = int(result['Requests']['id'])
            save()
        self.wait_request(state['request'])
        self.verify(bp, topology)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('base', 'netrc', 'cluster', 'name', 'bp', 'template', 'repo'):
        parser.add_argument(arg, type=Path if arg in ('netrc', 'bp', 'template') else str)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--timeout', type=int, default=7200)
    parser.add_argument('--state-dir', type=Path, default=Path('/var/lib/bigtop-deploy/native'))
    a = parser.parse_args()
    require(all(re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_-]{0,79}', s) for s in (a.cluster, a.name)), 'Invalid Ambari name')
    base, repo = urlsplit(a.base), urlsplit(a.repo)
    require((base.scheme == 'https' or (base.scheme == 'http' and base.hostname in ('127.0.0.1', 'localhost', '::1'))) and base.hostname and not base.username and not base.password and not base.query and not base.fragment and base.path in ('', '/'), 'Use a trusted HTTPS Ambari endpoint or loopback HTTP')
    require(repo.scheme in ('https', 'http', 'file') and not repo.username and not repo.password and not repo.query and not repo.fragment and ((repo.scheme == 'file' and not repo.netloc and repo.path.startswith('/')) or (repo.scheme != 'file' and repo.hostname)), 'Use a credential-free offline YUM URL')
    private(a.netrc)
    private(a.template)
    os.umask(0o077)
    state_dir = a.state_dir / a.cluster
    state_dir.mkdir(parents=True, exist_ok=True)
    info = state_dir.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and not info.st_mode & 0o077, 'Protect the installation state directory')
    with (state_dir / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        Controller(a).process(state_dir)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as e:
        sys.exit(str(e))
