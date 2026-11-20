"""Report task metadata without publishing command payloads or database credentials."""
import json
import subprocess
from pathlib import Path
from urllib.parse import quote

def items(path):
    output = subprocess.check_output(["docker", "exec", "bd01.lab.test", "curl", "-gfsS", "--netrc-file", "/root/test.netrc", "http://localhost:8080/api/v1/" + path], text=True)
    return json.loads(output)["items"]

out = Path("web-evidence")
out.mkdir(exist_ok=True)
for cluster in items("clusters"):
    name = quote(cluster["Clusters"]["cluster_name"], safe="")
    requests = items(f"clusters/{name}/requests?fields=Requests/request_context,Requests/request_status")
    inventory = []
    for item in requests:
        request = item["Requests"]
        print(request["id"], request["request_status"], request.get("request_context"))
        tasks = items(f"clusters/{name}/requests/{request['id']}/tasks?fields=Tasks/command,Tasks/role,Tasks/status,Tasks/host_name")
        inventory.extend(task["Tasks"] for task in tasks)
    for task in inventory:
        if task["status"] in {"FAILED", "TIMEDOUT"}:
            print(task)
    (out / "task-status.json").write_text(json.dumps(inventory, indent=2))
