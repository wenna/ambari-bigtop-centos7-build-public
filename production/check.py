#!/usr/bin/env python3
"""Exercise site rendering, role separation, immutable reruns and input validation."""
import csv
import json
import random
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


def write_csv(path, rows, fields):
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def explicit_hosts(size):
    # Slot order, DNS order, CSV order and placement deliberately differ.
    rng = random.Random(1207 + size)
    slots = ["fleet-%03d" % n for n in range(size)]
    dns = ["machine-%03d.site.example" % n for n in range(size)]
    rng.shuffle(slots)
    rng.shuffle(dns)
    roles = [[] for _ in slots]
    placement = {"namenode": [3, 9], "zkfc": [3, 9], "resourcemanager": [7, 8],
                 "zookeeper": [1, 5, 7, 11, 13], "journalnode": [2, 4, 6],
                 "metastore": [0, 4, 7], "hiveserver2": [8, 14], "ambari-server": [16],
                 "jobhistory": [9], "sparkhistory": [15],
                 "datanode": list(range(3, size, 2)), "nodemanager": list(range(4, size, 2))}
    for role, indexes in placement.items():
        for i in indexes:
            roles[i].append(role)
    rows = [dict(slot=slot, fqdn=dns[i], rack="rack-%d" % (i % 5), roles=" ".join(roles[i]))
            for i, slot in enumerate(slots)]
    rng.shuffle(rows)
    return rows


def check_explicit(directory, site, cfg, size):
    directory.mkdir()
    rows = explicit_hosts(size)
    overrides = {}
    if size == 20:
        dn = next(r["slot"] for r in rows if "datanode" in r["roles"].split())
        nms = [r["slot"] for r in rows if "nodemanager" in r["roles"].split()]
        overrides = {dn: {"datanode_dirs": ["/ssd/hdfs-a", "/ssd/hdfs-b"]},
                     nms[0]: {"nm_local_dirs": ["/ssd/yarn"], "nm_memory_mb": 16384, "nm_vcores": 18},
                     nms[1]: {"nm_memory_mb": 4096, "nm_vcores": 2}}
        site = directory / "heterogeneous-site.json"
        site.write_text(json.dumps(dict(cfg, node_overrides=overrides, fence_port=2222)))
    path = directory / "hosts.csv"
    fields = ["slot", "fqdn", "rack", "roles"]
    write_csv(path, rows, fields)
    out = directory / "output"
    cmd = [sys.executable, str(HERE / "render.py"), "--site", str(site),
           "--inventory", str(path), "--out", str(out)]
    subprocess.check_call(cmd)
    plan = json.loads((out / "plan.json").read_text())
    assert set(plan) == {r["slot"] for r in rows}
    ordered = sorted(rows, key=lambda r: r["slot"])
    def members(role):
        return [r["fqdn"] for r in ordered if role in r["roles"].split()]
    nns, rms, zks = members("namenode"), members("resourcemanager"), members("zookeeper")
    jns, hs2, hms = members("journalnode"), members("hiveserver2"), members("metastore")
    for row in ordered:
        slot, host, roles = row["slot"], row["fqdn"], set(row["roles"].split())
        root = out / slot
        assert xml(root / "etc/hadoop/conf/hdfs-site.xml")["dfs.ha.fencing.methods"] == (
            "sshfence({}:{})".format(cfg["fence_user"], 2222 if size == 20 else cfg.get("fence_port", 22)))
        hc = root / "etc/hadoop/conf"
        core, dfs, yarn = [xml(hc / (service + "-site.xml")) for service in ("core", "hdfs", "yarn")]
        assert set(plan[slot]["roles"]) == roles
        assert set(plan[slot]["services"]) == roles - {"ambari-server"}
        assert plan[slot]["node_overrides"] == overrides.get(slot, {})
        effective = dict(cfg, **overrides.get(slot, {}))
        assert dfs["dfs.datanode.data.dir"] == ",".join(effective["datanode_dirs"])
        assert yarn["yarn.nodemanager.local-dirs"] == ",".join(effective["nm_local_dirs"])
        assert int(yarn["yarn.nodemanager.resource.memory-mb"]) == effective["nm_memory_mb"]
        assert int(yarn["yarn.nodemanager.resource.cpu-vcores"]) == effective["nm_vcores"]
        assert int(yarn["yarn.scheduler.maximum-allocation-mb"]) == (16384 if overrides else cfg["nm_memory_mb"])
        assert int(yarn["yarn.scheduler.maximum-allocation-vcores"]) == (18 if overrides else cfg["nm_vcores"])
        assert core["ha.zookeeper.quorum"] == ",".join(h + ":2181" for h in zks)
        assert core["hadoop.proxyuser.hive.hosts"] == ",".join(hs2)
        assert dfs["dfs.namenode.shared.edits.dir"] == "qjournal://" + ";".join(h + ":8485" for h in jns) + "/checkns"
        for i, nn in enumerate(nns, 1):
            assert dfs["dfs.namenode.rpc-address.checkns.nn%d" % i] == nn + ":8020"
        for i, rm in enumerate(rms, 1):
            assert yarn["yarn.resourcemanager.webapp.address.rm%d" % i] == rm + ":8088"
        assert dfs.get("dfs.ha.namenode.id") == ("nn%d" % (1 + nns.index(host)) if host in nns else None)
        assert yarn.get("yarn.resourcemanager.ha.id") == ("rm%d" % (1 + rms.index(host)) if host in rms else None)
        assert dfs.get("dfs.datanode.hostname") == (host if "datanode" in roles else None)
        assert yarn.get("yarn.nodemanager.hostname") == (host if "nodemanager" in roles else None)
        assert xml(hc / "mapred-site.xml")["mapreduce.jobhistory.address"] == members("jobhistory")[0] + ":10020"
        myid = root / cfg["state_dir"].lstrip("/") / "zookeeper/myid"
        assert myid.exists() == (host in zks)
        if host in zks:
            assert int(myid.read_text()) == 1 + zks.index(host)
            zoo = (root / "etc/zookeeper/conf/zoo.cfg").read_text().splitlines()
            for i, zk in enumerate(zks, 1):
                assert "server.%d=%s:2888:3888" % (i, zk) in zoo
        hive = xml(root / "etc/hive/conf/hive-site.xml")
        assert (root / "etc/hive/metastore/hive-site.xml").exists() == (host in hms)
        assert hive.get("hive.server2.thrift.bind.host") == (host if host in hs2 else None)
        assert hive["hive.metastore.uris"] == ",".join("thrift://" + h + ":9083" for h in hms)
    if size == 20:
        # An unchanged snapshot must be accepted with a different row/role order.
        reordered = [dict(r, roles=" ".join(reversed(r["roles"].split()))) for r in reversed(rows)]
        write_csv(path, reordered, fields)
        subprocess.check_call(cmd)
        for role in ("namenode", "zkfc", "resourcemanager", "zookeeper", "journalnode",
                     "datanode", "nodemanager", "metastore", "hiveserver2"):
            broken = [dict(r, roles=" ".join(v for v in r["roles"].split() if v != role)) for r in rows]
            if role in ("zookeeper", "journalnode"):
                # Also check that a nonzero even quorum is rejected.
                broken = [dict(r) for r in rows]
                first = next(r for r in broken if role in r["roles"].split())
                first["roles"] = " ".join(v for v in first["roles"].split() if v != role)
            write_csv(path, broken, fields)
            invalid = directory / "invalid"
            fail = subprocess.run(cmd[:-1] + [str(invalid)], stderr=subprocess.PIPE)
            assert fail.returncode != 0 and not invalid.exists(), role
        write_csv(path, rows, fields)
        for bad_config in (
                [], {"unknown-slot": {}}, {dn: []}, {dn: {"accounts": {}}},
                {dn: {"datanode_dirs": []}}, {dn: {"datanode_dirs": ["../unsafe"]}},
                {dn: {"datanode_dirs": cfg["nm_local_dirs"]}}, {nms[0]: {"nm_vcores": True}},
                {nms[0]: {"nm_memory_mb": 1537}}, {nms[1]: {"nm_memory_mb": 256}}):
            site.write_text(json.dumps(dict(cfg, node_overrides=bad_config)))
            fail = subprocess.run(cmd[:-1] + [str(invalid)], stderr=subprocess.PIPE)
            assert fail.returncode != 0 and not invalid.exists(), bad_config


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
        with INVENTORY.open() as f:
            rows = sorted(csv.DictReader(f), key=lambda r: r["slot"])
        legacy = directory / "legacy.csv"
        write_csv(legacy, list(reversed(rows)), ["slot", "fqdn", "rack"])
        argv = [sys.executable, str(HERE / "render.py"), "--site", str(site),
                "--inventory", str(legacy), "--out", str(dest)]
        subprocess.check_call(argv)
        subprocess.check_call(argv)
        plan = json.loads((dest / "plan.json").read_text())
        assert len(plan) == 10
        assert "ambari-server" in plan["bd09"]["roles"] and "ambari-server" not in plan["bd09"]["services"]
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
        for size in (20, 100, 107):
            check_explicit(directory / ("fleet-%d" % size), site, cfg, size)
        cfg["pg_url"] += "&password=reject-this-test-value"
        site.write_text(json.dumps(cfg))
        bad = directory / "invalid"
        failed = subprocess.run(argv[:-1] + [str(bad)], stderr=subprocess.PIPE)
        assert failed.returncode != 0 and b"reject-this-test-value" not in failed.stderr and not bad.exists()
    print("PRODUCTION_CONFIG_PLAN_CHECK_PASSED legacy 10 and explicit 20, 100, 107 hosts; "
          "role placement, stable HA IDs, node overrides, SQL, Spark, secrets and reruns")


if __name__ == "__main__":
    main()
