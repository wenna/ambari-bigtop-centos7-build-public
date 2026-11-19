#!/usr/bin/env python3
"""Generate a starter role inventory for a new installation."""
import argparse
import csv
import re
import sys

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nodes", type=int, required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--prefix", default="bd")
    args = parser.parse_args()
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if args.nodes < 8:
        parser.error("This example separates 3 controllers, 2 SQL hosts and at least 3 workers. Supply a custom inventory for other placements.")
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
    for n in range(1, args.nodes + 1):
        slot = args.prefix + str(n).zfill(width)
        writer.writerow((slot, slot + "." + args.domain, "rack-" + str((n - 1) % 3 + 1),
                         special.get(n, "datanode nodemanager")))

if __name__ == "__main__":
    main()
