"""Read host identities for Ambari bootstrap without imposing a data topology."""
import csv
import ipaddress
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "production"))
from inventory import FQDN, LABEL, LEGACY, OWNER


def bootstrap(inventory, output, addresses=None):
    plan = {}
    hosts = set()
    with inventory.open(encoding="utf-8-sig", newline="") as stream:
        rows = csv.DictReader(stream)
        fields = ["slot", "fqdn", "rack"]
        if rows.fieldnames not in (fields, fields + ["roles"]):
            raise ValueError("Expected slot,fqdn,rack,roles or the original ten-slot inventory")
        legacy = rows.fieldnames == fields
        for row in rows:
            if None in row or None in row.values():
                raise ValueError("Malformed host row")
            slot, host, rack = (row[name] for name in fields)
            roles = (LEGACY.get(slot, "") if legacy else row['roles']).split()
            if (not re.fullmatch(LABEL, slot) or not re.fullmatch(LABEL, rack)
                    or not re.fullmatch(FQDN, host) or len(host) > 253
                    or host in hosts or slot in plan or len(set(roles)) != len(roles)
                    or set(roles) - set(OWNER) - {"ambari-server", "ambari-agent"}):
                raise ValueError("Invalid or duplicate host, slot, rack or role: " + str(row))
            plan[slot] = dict(fqdn=host, roles=roles, rack=rack)
            hosts.add(host)
    if legacy and set(plan) != set(LEGACY):
        raise ValueError("Use explicit roles for inventories other than bd01 through bd10")
    if sum("ambari-server" in row['roles'] for row in plan.values()) != 1:
        raise ValueError("Provide exactly one ambari-server role")
    if addresses:
        peers = {}
        with addresses.open(encoding="utf-8-sig", newline="") as stream:
            rows = csv.DictReader(stream)
            if rows.fieldnames != ["slot", "address"]:
                raise ValueError("Expected slot,address bootstrap inventory")
            for row in rows:
                slot = row["slot"]
                ip = ipaddress.ip_address(row["address"])
                if (None in row or slot not in plan or slot in peers or ip in peers.values()
                        or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified or '%' in str(ip)):
                    raise ValueError("Invalid or duplicate bootstrap address: " + str(row))
                peers[slot] = ip
        if set(peers) != set(plan):
            raise ValueError("Missing bootstrap address for an inventory host")
        (output / "guard-addresses").write_bytes(''.join(str(peers[k]) + '\n' for k in sorted(peers)).encode("ascii"))
    (output / "plan.json").write_text(json.dumps(plan))


if __name__ == "__main__":
    bootstrap(*(Path(arg) for arg in sys.argv[1:]))
