"""Embed the tested frontend inputs in Bigtop's Hadoop source RPM build script."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
script = root / 'upstream/bigtop/bigtop-packages/src/common/hadoop/do-component-build'
original = script.read_text()
marker = '# Build artifacts\nmvn $BUNDLE_SNAPPY'
if original.count(marker) != 1:
    raise SystemExit('unexpected Hadoop build script')
block = '''# C7 catalog lock: preserve Node 12 engine checks
patch -p1 <<'C7_EL_VERSION'
--- a/hadoop-project/pom.xml
+++ b/hadoop-project/pom.xml
@@ -222,5 +222,10 @@
   <dependencyManagement>
     <dependencies>
       <dependency>
+        <groupId>org.glassfish</groupId>
+        <artifactId>javax.el</artifactId>
+        <version>3.0.1-b12</version>
+      </dependency>
+      <dependency>
         <groupId>com.squareup.okhttp3</groupId>
         <artifactId>okhttp</artifactId>
C7_EL_VERSION
catalog=hadoop-yarn-project/hadoop-yarn/hadoop-yarn-applications/hadoop-yarn-applications-catalog/hadoop-yarn-applications-catalog-webapp
# Bigtop already applied its YARN-11528 patch here.
echo "bd06d8244a7a7b2c700c0644e6a0d59d2e6589d2d31086a3a92d77b242663abe  $catalog/package.json" | sha256sum -c -
'''
if '# C7 catalog lock:' not in original:
    for filename in ('package.json', 'yarn.lock'):
        data = (root / 'manifests/hadoop-catalog' / filename).read_text(encoding='utf-8')
        block += f'cat > "$catalog/{filename}" <<\'C7_LOCK_INPUT\'\n{data.rstrip()}\nC7_LOCK_INPUT\n'
    script.write_bytes(original.replace(marker, block + '\n' + marker).encode())
