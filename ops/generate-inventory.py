#!/usr/bin/env python3
"""Generate a starter role inventory for a new installation."""
import argparse
import csv
import json
from pathlib import Path
import re
import sys

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nodes", type=int, required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--prefix", default="bd")
    parser.add_argument("--web-out", type=Path, help="Create a matching new wizard template")
    args = parser.parse_args()
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if args.nodes < 3:
        parser.error("This HA layout needs at least three distinct hosts")
    if not all(re.fullmatch(label, part) for part in args.domain.split(".")):
        parser.error("Invalid DNS domain")
    width = max(3, len(str(args.nodes)))
    if not re.fullmatch(label, args.prefix + "9" * width) or len(args.prefix) + width + 1 + len(args.domain) > 253:
        parser.error("Invalid generated FQDN")
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(("slot", "fqdn", "rack", "roles"))
    special = {
        1: "namenode zkfc journalnode zookeeper",
        2: "namenode zkfc journalnode zookeeper resourcemanager",
        3: "journalnode zookeeper resourcemanager jobhistory",
        4: "ambari-server metastore hiveserver2",
        5: "metastore hiveserver2 sparkhistory",
    }
    if args.nodes < 8:
        special = {
            1: "ambari-server namenode zkfc journalnode zookeeper datanode nodemanager",
            2: "namenode zkfc journalnode zookeeper resourcemanager datanode nodemanager",
            3: "journalnode zookeeper resourcemanager jobhistory metastore hiveserver2 sparkhistory datanode nodemanager",
        }
    if args.web_out:
        web = json.loads(Path(__file__).with_name("web-install.example.json").read_text())
        slot = lambda n: args.prefix + str(n).zfill(width)
        for key in ("namenode", "secondary_namenode", "resourcemanager", "timeline_reader", "timeline_server", "registry_dns"):
            web[key] = slot(int(web[key][2:]))
        web["client_slots"] = [slot(3)] if args.nodes < 8 else [slot(4), slot(5)]
        with args.web_out.open("x", encoding="utf-8") as stream:
            json.dump(web, stream, indent=2)
            stream.write("\n")
    for n in range(1, args.nodes + 1):
        slot = args.prefix + str(n).zfill(width)
        writer.writerow((slot, slot + "." + args.domain, "rack-" + str((n - 1) % 3 + 1),
                         special.get(n, "datanode nodemanager")))

if __name__ == "__main__":
    main()
