"""Serialize the validated renderer inputs for the data-service controller (no secrets)."""
import json
import shlex
import sys
from pathlib import Path

site, plan = [json.loads(Path(p).read_text()) for p in sys.argv[1:3]]
for slot, node in sorted(plan.items()):
    values = {key.upper(): value for key, value in site.items() if isinstance(value, str)}
    values.update({name.upper() + "_USER": user for name, user in site["accounts"].items()})
    values.update(SLOT=slot, FQDN=node["fqdn"], PG_CA=site["pg_url"].split("sslrootcert=")[1])
    values.update({key.upper(): site[key] for key in ("datanode_dirs", "nm_local_dirs")})
    values["HOSTS"] = [plan[s]["fqdn"] for s in sorted(plan)]
    values["ROLES"] = sorted(node["services"])
    values.update({"OWNER_" + role: user for role, user in node["services"].items()})
    lines = []
    for key, val in sorted(values.items()):
        val = "(" + " ".join(map(shlex.quote, val)) + ")" if isinstance(val, list) else shlex.quote(val)
        lines.append(key + "=" + val)
    (Path(sys.argv[3]) / (slot + ".env")).write_text("\n".join(lines) + "\n")
