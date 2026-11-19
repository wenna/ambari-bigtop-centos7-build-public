#!/usr/bin/env python3
"""Print assignments and effective cluster-wide settings using the deployment renderer."""
import argparse
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "production"))
from render import checked_site, inventory, render

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("--site", type=Path, default=ROOT / "production/site.example.json")
    parser.add_argument("--nameservice")
    args = parser.parse_args()
    rows = inventory(args.inventory)
    site = json.loads(args.site.read_text(encoding="utf-8"))
    if args.nameservice:
        site["nameservice"] = args.nameservice
    checked_site(site, rows)
    print("slot\tfqdn\track\troles")
    for row in rows:
        print("\t".join((row["slot"], row["fqdn"], row["rack"], " ".join(row["roles"]))))
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        render(root, rows, site)
        sample = root / rows[0]["slot"]
        for path in [sample / "etc/hadoop/conf" / (s + "-site.xml") for s in ("core","hdfs","yarn","mapred")] + [sample / "etc/hive/conf/hive-site.xml"]:
            for prop in ElementTree.parse(str(path)).getroot().findall("property"):
                print("\t".join((path.stem, prop.findtext("name"), prop.findtext("value"))))

if __name__ == "__main__":
    main()
