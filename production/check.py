#!/usr/bin/env python3
"""Exercise site rendering, role separation, immutable reruns and input validation."""
import csv
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree as ET

HERE = Path(__file__).resolve().parent
INVENTORY = HERE.parent / "ops/hosts.example.csv"


def xml(path):
    props = ET.parse(str(path)).getroot().findall("property")
    result = {p.findtext("name"): p.findtext("value") for p in props}
    assert len(props) == len(result) and all(result.values())
    return result


def main():
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        cfg = json.loads((HERE / "site.example.json").read_text())
        cfg["nameservice"] = "checkns"
        cfg["accounts"]["yarn"] = "yarnprod"
        cfg["nm_memory_mb"] = 8192
        site = directory / "site.json"
        site.write_text(json.dumps(cfg))
        dest = directory / "output"
        argv = [sys.executable, str(HERE / "render.py"), "--site", str(site),
                "--inventory", str(INVENTORY), "--out", str(dest)]
        subprocess.check_call(argv)
        subprocess.check_call(argv)
        with INVENTORY.open() as f:
            rows = list(csv.DictReader(f))
        plan = json.loads((dest / "plan.json").read_text())
        assert len(plan) == 10
        for i, row in enumerate(rows):
            host = dest / row["slot"]
            hadoop = host / "etc/hadoop/conf"
            for path in host.rglob("*.xml"):
                xml(path)
            assert xml(hadoop / "core-site.xml")["fs.defaultFS"] == "hdfs://checkns"
            hdfs = xml(hadoop / "hdfs-site.xml")
            assert hdfs.get("dfs.ha.namenode.id") == ("nn%d" % (i+1) if i < 2 else None)
            assert hdfs["dfs.namenode.shared.edits.dir"] == "qjournal://" + ";".join(
                r["fqdn"] + ":8485" for r in rows[:3]) + "/checkns"
            yarn = xml(hadoop / "yarn-site.xml")
            assert yarn["yarn.resourcemanager.webapp.address.rm1"] == rows[1]["fqdn"] + ":8088"
            assert yarn["yarn.resourcemanager.webapp.https.address.rm2"] == rows[2]["fqdn"] + ":8090"
            assert yarn.get("yarn.resourcemanager.ha.id") == ("rm%d" % i if 1 <= i <= 2 else None)
            assert yarn["yarn.nodemanager.resource.memory-mb"] == "8192"
            if i in range(3, 8):
                assert plan[row["slot"]]["services"]["nodemanager"] == "yarnprod"
            rack = subprocess.check_output([sys.executable, str(hadoop / "rack-map"), row["fqdn"]])
            assert rack.decode().strip() == "/" + row["rack"]
            myid = host / cfg["state_dir"].lstrip("/") / "zookeeper/myid"
            assert myid.exists() == (i < 3)
            if i < 3:
                assert myid.read_text().strip() == str(i+1)
            hms = host / "etc/hive/metastore/hive-site.xml"
            assert hms.exists() == (i >= 8)
            if i >= 8:
                props = xml(hms)
                assert props["javax.jdo.option.ConnectionURL"] == cfg["pg_url"]
                assert "javax.jdo.option.ConnectionPassword" not in props
            client = xml(host / "etc/hive/conf/hive-site.xml")
            assert "javax.jdo.option.ConnectionURL" not in client
            assert client["hive.metastore.uris"].count("thrift://") == 2
            assert xml(host / "etc/tez/conf/tez-site.xml")["tez.lib.uris"] == "hdfs://checkns" + cfg["tez_archive"]
            assert "TEZ_CONF_DIR=/etc/tez/conf" in (hadoop / "bigtop-env.sh").read_text()
            assert "spark.master yarn" in (host / "etc/spark/conf/spark-defaults.conf").read_text()
        edited = dest / "bd01/etc/hadoop/conf/core-site.xml"
        edited.write_text("preserve")
        assert subprocess.call(argv, stderr=subprocess.DEVNULL) != 0 and edited.read_text() == "preserve"
        cfg["pg_url"] += "&password=reject-this-test-value"
        site.write_text(json.dumps(cfg))
        bad = directory / "invalid"
        failed = subprocess.run(argv[:-1] + [str(bad)], stderr=subprocess.PIPE)
        assert failed.returncode != 0 and b"reject-this-test-value" not in failed.stderr and not bad.exists()
    print("PRODUCTION_CONFIG_PLAN_CHECK_PASSED 10 hosts; HA roles, racks, SQL, Spark, secrets and reruns")


if __name__ == "__main__":
    main()
