"""Serialize the validated renderer inputs for the data-service controller (no secrets)."""
import json
import shlex
import sys
from pathlib import Path

site, plan = [json.loads(Path(p).read_text()) for p in sys.argv[1:3]]
out = Path(sys.argv[3])
slots = sorted(plan)
data_roles = sorted({role for s in slots for role in plan[s]["services"]})
placement = {role: [s for s in slots if role in plan[s]["services"]] for role in data_roles}


def array(items):
    return "(" + " ".join(map(shlex.quote, items)) + ")"


topology = ["ALL_SLOTS=" + array(slots), "declare -A HOST"]
topology.extend("HOST[{}]={}".format(shlex.quote(s), shlex.quote(plan[s]["fqdn"])) for s in slots)
topology.extend("NODES_" + role + "=" + array(placement[role]) for role in data_roles)
(out / "topology.sh").write_bytes(("\n".join(topology) + "\n").encode("utf-8"))
for slot, node in sorted(plan.items()):
    values = {key.upper(): value for key, value in site.items() if isinstance(value, str)}
    values.update({name.upper() + "_USER": user for name, user in site["accounts"].items()})
    values.update(SLOT=slot, FQDN=node["fqdn"], PG_CA=site["pg_url"].split("sslrootcert=")[1])
    overrides = node.get("node_overrides", {})
    values.update({key.upper(): overrides.get(key, site[key])
                   for key in ("datanode_dirs", "nm_local_dirs")})
    if slot in placement["namenode"]:
        peer, = [p for p in placement["namenode"] if p != slot]
        values["FENCE_PORT"] = str(site.get("fence_port", 22))
        values["FENCE_PEER"] = plan[peer]["fqdn"]
    values["ROLES"] = sorted(node["services"])
    values.update({"OWNER_" + role: user for role, user in node["services"].items()})
    lines = []
    for key, val in sorted(values.items()):
        val = array(val) if isinstance(val, list) else shlex.quote(val)
        lines.append(key + "=" + val)
    (out / (slot + ".env")).write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
