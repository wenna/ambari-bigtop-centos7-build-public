"""Extract the named query and successful DAG from the actual NodeManager AM log."""
import re
import sys
from pathlib import Path

query = sys.argv[1]
for app in Path("/var/lib/ha/nm/logs").glob("application_*"):
    names = set()
    completed = set()
    for path in app.glob("container_*/*"):
        if not path.name.startswith("syslog") or not path.is_file():
            continue
        with path.open(errors="replace") as stream:
            for line in stream:
                if "Starting DAG submitted via RPC: " in line:
                    names.add(line.split("Starting DAG submitted via RPC: ", 1)[1].strip())
                match = re.search(r"\[DAG:(dag_\d+_\d+_\d+)\]\[Event:DAG_FINISHED\]", line)
                if match and "status=SUCCEEDED" in line and re.search(r"\bREDUCE_INPUT_GROUPS=2\b", line):
                    completed.add(match.group(1))
    if names == {query} and len(completed) == 1:
        dag = completed.pop()
        if app.name != "application_" + dag[4:].rsplit("_", 1)[0]:
            raise ValueError("DAG/application mismatch")
        print(dag, app.name, query, "SUCCEEDED REDUCE_INPUT_GROUPS=2")
