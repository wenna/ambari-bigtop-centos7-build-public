"""Embed the tested frontend inputs in Bigtop's Hadoop source RPM build script."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
script = root / 'upstream/bigtop/bigtop-packages/src/common/hadoop/do-component-build'
original = script.read_text()
marker = '# Build artifacts\nmvn $BUNDLE_SNAPPY'
if original.count(marker) != 1:
    raise SystemExit('unexpected Hadoop build script')
block = '''# C7 catalog lock: preserve Node 12 engine checks
catalog=hadoop-yarn-project/hadoop-yarn/hadoop-yarn-applications/hadoop-yarn-applications-catalog/hadoop-yarn-applications-catalog-webapp
# Bigtop already applied its YARN-11528 patch here.
echo "bd06d8244a7a7b2c700c0644e6a0d59d2e6589d2d31086a3a92d77b242663abe  $catalog/package.json" | sha256sum -c -
'''
if '# C7 catalog lock:' not in original:
    for filename in ('package.json', 'yarn.lock'):
        data = (root / 'manifests/hadoop-catalog' / filename).read_text(encoding='utf-8')
        block += f'cat > "$catalog/{filename}" <<\'C7_LOCK_INPUT\'\n{data.rstrip()}\nC7_LOCK_INPUT\n'
    script.write_bytes(original.replace(marker, block + '\n' + marker).encode())
