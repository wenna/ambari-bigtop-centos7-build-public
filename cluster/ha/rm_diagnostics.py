"""Capture bounded diagnostics only for the synthetic RM failover workload."""
import os
import re
import sys
from pathlib import Path

app = sys.argv[1]
if not re.fullmatch(r"application_[0-9]+_[0-9]+", app):
    raise SystemExit("Invalid application ID")
logs = Path("/var/lib/ha/nm/logs") / app
local = Path("/var/lib/ha/nm/local/usercache/root/appcache") / app
report = Path(os.environ["HADOOP_LOG_DIR"]) / (app + "-diagnostic.log")
sensitive = re.compile(r"(?i)token|secret|passw(?:or)?d|authorization|credential|"
                       r"private[ _-]?key|jdbc:|keytab|gh[pousr]_|github_pat_|"
                       r"AKIA[0-9A-Z]{16}|https?://[^/\s]*@")

with report.open("w") as out:
    for folder in sorted(logs.glob("container_*")):
        if not re.fullmatch(r"container_[a-zA-Z0-9_]+", folder.name):
            continue
        print(folder.name, file=out)
        launch = local / folder.name / "launch_container.sh"
        if launch.is_file():
            script = launch.read_text(errors="replace")
            # Actual environment exports, tokens and command arguments stay local.
            for component in ("MRAppMaster", "YarnChild", "container-log4j.properties",
                              "/etc/hadoop/conf", "hadoop-mapreduce", "hadoop-yarn"):
                print("launch script contains {}: {}".format(component, component in script), file=out)
        for name in ("prelaunch.err", "stderr", "syslog"):
            path = folder / name
            if not path.is_file() or path.is_symlink():
                continue
            print(name, file=out)
            with path.open("rb") as log:
                log.seek(max(0, path.stat().st_size - 32768))
                lines = log.read().decode("utf-8", errors="replace").splitlines()[-100:]
                for line in lines:
                    # Suppress opaque payloads, including short PEM continuation lines.
                    if (sensitive.search(line) or re.search(r"[A-Za-z0-9+/=_-]{60,}", line)
                            or re.fullmatch(r"[A-Za-z0-9+/=]+", line.strip())):
                        print("[redacted]", file=out)
                    else:
                        print(line[:1600], file=out)
