"""Read back final state independently of the browser."""
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import quote

out = Path("web-evidence")

def get(path):
    raw = subprocess.check_output(["docker", "exec", "bd01.lab.test", "curl", "-gfsS", "--netrc-file", "/root/test.netrc", "http://localhost:8080/api/v1/" + path])
    return json.loads(raw)["items"]

clusters = get("clusters")
assert len(clusters) == 1, clusters
prefix = "clusters/" + quote(clusters[0]["Clusters"]["cluster_name"], safe="") + "/"
services = {s["ServiceInfo"]["service_name"] for s in get(prefix + "services")}
assert {"HDFS","YARN","MAPREDUCE2","ZOOKEEPER","TEZ","HIVE","SPARK"} <= services, services
rows = [r["HostRoles"] for r in get(prefix + "host_components?fields=HostRoles/component_name,HostRoles/host_name,HostRoles/state,HostRoles/desired_state")]
(out / "host-components.json").write_text(json.dumps(rows, indent=2))
hosts = {f"bd{n:02d}.lab.test" for n in range(1, int(os.environ["AGENT_COUNT"]) + 1)}
for component in ("DATANODE", "NODEMANAGER"):
    assert {r["host_name"] for r in rows if r["component_name"] == component and r["state"] == "STARTED"} == hosts
for r in rows:
    assert r["state"] in {"STARTED", "INSTALLED"} and r["state"] == r["desired_state"], r
critical = {"NAMENODE","DATANODE","RESOURCEMANAGER","NODEMANAGER","HISTORYSERVER","ZOOKEEPER_SERVER","HIVE_SERVER","HIVE_METASTORE"}
assert critical <= {r["component_name"] for r in rows if r["state"] == "STARTED"}
reqs = [r["Requests"] for r in get(prefix + "requests?fields=Requests/id,Requests/request_context,Requests/request_status")]
(out / "final-requests.json").write_text(json.dumps(reqs, indent=2))
print("Verified", sorted(services), "components:", len(rows))
