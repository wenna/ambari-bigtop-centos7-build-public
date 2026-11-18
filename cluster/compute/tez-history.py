"""Correlate the named Hive aggregation with its Tez DAG and YARN application."""
import json
import re
import sys
import time
from pathlib import Path


def completed_query(history_dir, name):
    submitted = set()
    finished = {}
    for path in sorted(history_dir.glob("history.txt.appattempt_*")):
        with path.open("rb") as stream:
            for raw in stream:
                # Tez 0.10.2 writes a JSON event followed by literal "^A" and LF.
                # A still-running AM may have flushed only part of the last event.
                if not raw.endswith(b"^A\n"):
                    continue
                event = json.loads(raw[:-3].decode("utf-8", errors="replace"))
                if event["entitytype"] != "TEZ_DAG_ID":
                    continue
                dag = event["entity"]
                types = {entry["eventtype"] for entry in event.get("events", [])}
                if "DAG_SUBMITTED" in types and event["primaryfilters"]["dagName"] == name:
                    submitted.add(dag)
                if "DAG_FINISHED" in types:
                    finished[dag] = event["otherinfo"]
    matches = []
    for dag in submitted.intersection(finished):
        record = finished[dag]
        if record["status"] == "SUCCEEDED":
            groups = record["counters"]["counterGroups"]
            reduce_groups = [c["counterValue"] for group in groups
                             for c in group.get("counters", [])
                             if c["counterName"] == "REDUCE_INPUT_GROUPS"]
            if reduce_groups != [2]:
                raise ValueError("Unexpected REDUCE_INPUT_GROUPS for {}: {}".format(dag, reduce_groups))
            matches.append(dag)
    if len(matches) > 1:
        raise ValueError("Multiple successful DAGs for {}: {}".format(name, matches))
    if matches:
        dag = matches[0]
        match = re.fullmatch(r"dag_(\d+_\d+)_\d+", dag)
        if not match:
            raise ValueError("Invalid Tez DAG ID: " + dag)
        return "{} application_{} {} SUCCEEDED REDUCE_INPUT_GROUPS=2".format(dag, match[1], name)


if __name__ == "__main__":
    history, query = Path(sys.argv[1]), sys.argv[2]
    deadline = time.monotonic() + 120
    while True:
        result = completed_query(history, query)
        if result:
            print(result)
            break
        if time.monotonic() >= deadline:
            sys.exit("No successful DAG history for {} in {}".format(query, history))
        time.sleep(2)
