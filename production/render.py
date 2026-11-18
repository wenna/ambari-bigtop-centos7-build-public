#!/usr/bin/env python3
"""Render an immutable ten-host configuration snapshot (Python 3.6+)."""
import argparse
import csv
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree as ET

HERE = Path(__file__).resolve().parent
BASE = "/usr/bigtop/3.3.0/usr"
CONF = "/etc/hadoop/conf"
LIB = BASE + "/lib/"
HOMES = {"HADOOP_COMMON_HOME": "hadoop", "HADOOP_HDFS_HOME": "hadoop-hdfs",
         "HADOOP_YARN_HOME": "hadoop-yarn", "HADOOP_MAPRED_HOME": "hadoop-mapreduce"}
ROLES = [
    ["namenode", "zkfc", "journalnode", "zookeeper"],
    ["namenode", "zkfc", "journalnode", "zookeeper", "resourcemanager"],
    ["journalnode", "zookeeper", "resourcemanager", "jobhistory"],
] + [["datanode", "nodemanager"] for _ in range(5)] + [
    ["metastore", "hiveserver2"], ["metastore", "hiveserver2", "sparkhistory"]]
OWNER = dict(namenode="hdfs", zkfc="hdfs", journalnode="hdfs", datanode="hdfs",
             zookeeper="zookeeper", resourcemanager="yarn", nodemanager="yarn",
             jobhistory="mapred", metastore="hive", hiveserver2="hive", sparkhistory="spark")
USER = r"[a-z_][a-z0-9_-]{0,30}"
LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
FQDN = LABEL + r"(?:\." + LABEL + r")+"
PATH = r"(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+"


def require(ok, message):
    if not ok:
        raise ValueError(message)


def checked_site(site):
    example = json.loads((HERE / "site.example.json").read_text())
    require(isinstance(site, dict) and set(site) == set(example),
            "Unexpected or missing site fields; supply only the documented public settings")
    match = lambda pattern, value: isinstance(value, str) and re.fullmatch(pattern, value)
    require(match(r"[a-z][a-z0-9-]{0,40}", site["nameservice"]), "Invalid nameservice")
    for k in ("state_dir", "log_dir", "run_dir", "fence_key", "hms_keystore", "tez_archive"):
        require(match(PATH, site[k]), "Invalid absolute path for " + k)
    storage = []
    for k in ("datanode_dirs", "nm_local_dirs"):
        paths = site[k]
        require(isinstance(paths, list) and paths and all(match(PATH, p) for p in paths), k)
        storage.extend(paths)
    require(len(set(storage)) == len(storage), "DataNode and NM storage paths must be distinct")
    require(isinstance(site["accounts"], dict) and set(site["accounts"]) == set(example["accounts"]),
            "Invalid service accounts")
    for u in list(site["accounts"].values()) + [site["pg_user"], site["fence_user"]]:
        require(match(USER, u) and u != "root", "Use a named non-root account")
    groups = site["proxy_groups"]
    require(isinstance(groups, list) and groups and all(match(USER, g) for g in groups),
            "Invalid Hive proxy groups")
    pg = re.fullmatch(r"jdbc:postgresql://(" + FQDN + r"):(\d{1,5})/[a-zA-Z0-9_]+"
                      r"\?sslmode=verify-full&sslrootcert=" + PATH, str(site["pg_url"]))
    require(pg and 0 < int(pg.group(2)) <= 65535,
            "Use the documented PostgreSQL TLS URL without credentials")
    for k in ("nm_memory_mb", "task_memory_mb", "nm_vcores"):
        require(type(site[k]) is int and site[k] > 0, "Invalid " + k)
    require(512 <= site["task_memory_mb"] <= site["nm_memory_mb"] and
            site["task_memory_mb"] % 256 == site["nm_memory_mb"] % 256 == 0,
            "Memory sizes must fit node capacity in multiples of 256 MiB")


def inventory(path):
    with path.open(encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        require(reader.fieldnames == ["slot", "fqdn", "rack"], "Invalid inventory header")
        rows = sorted(reader, key=lambda row: row["slot"])
    require([r["slot"] for r in rows] == ["bd%02d" % i for i in range(1, 11)], "Expected bd01-bd10")
    for row in rows:
        require(None not in row and re.fullmatch(FQDN, row["fqdn"]) and len(row["fqdn"]) <= 253
                and re.fullmatch(LABEL, row["rack"]), "Invalid host or rack")
    require(len(set(r["fqdn"] for r in rows)) == 10, "Duplicate host")
    return rows


def put(root, path, text, executable=False):
    dest = root / path.lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes((text.rstrip() + "\n").encode("utf-8"))
    dest.chmod(0o755 if executable else 0o644)


def xml(root, path, props):
    doc = ET.Element("configuration")
    for k, v in sorted(props.items()):
        p = ET.SubElement(doc, "property")
        ET.SubElement(p, "name").text = k
        ET.SubElement(p, "value").text = str(v)
    put(root, path, ET.tostring(doc, encoding="unicode").replace("><property>", ">\n  <property>")
        .replace("</configuration>", "\n</configuration>"))


def render(dest, rows, s):
    hosts = [r["fqdn"] for r in rows]
    ns, state = s["nameservice"], s["state_dir"]
    fs = "hdfs://" + ns
    zk = ",".join(h + ":2181" for h in hosts[:3])
    cp = [CONF] + [LIB + directory + suffix for directory in HOMES.values()
                   for suffix in ("", "/lib/*", "/*")]
    hive_hosts = ",".join(hosts[8:])
    core = {"fs.defaultFS": fs, "ha.zookeeper.quorum": zk, "hadoop.zk.address": zk,
            "net.topology.script.file.name": CONF + "/rack-map",
            "hadoop.proxyuser." + s["accounts"]["hive"] + ".hosts": hive_hosts,
            "hadoop.proxyuser." + s["accounts"]["hive"] + ".groups": ",".join(s["proxy_groups"])}
    hdfs = {"dfs.nameservices": ns, "dfs.ha.namenodes." + ns: "nn1,nn2",
            "dfs.namenode.shared.edits.dir": "qjournal://" + ";".join(h + ":8485" for h in hosts[:3]) + "/" + ns,
            "dfs.client.failover.proxy.provider." + ns: "org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider",
            "dfs.ha.automatic-failover.enabled": "true", "dfs.ha.fencing.methods": "sshfence(" + s["fence_user"] + ":22)",
            "dfs.ha.fencing.ssh.private-key-files": s["fence_key"], "dfs.replication": 3,
            "dfs.namenode.name.dir": state + "/namenode", "dfs.journalnode.edits.dir": state + "/journalnode",
            "dfs.datanode.data.dir": ",".join(s["datanode_dirs"])}
    yarn = {"yarn.resourcemanager.ha.enabled": "true", "yarn.resourcemanager.cluster-id": ns + "-yarn",
            "yarn.resourcemanager.ha.rm-ids": "rm1,rm2", "yarn.resourcemanager.zk-address": zk,
            "yarn.resourcemanager.ha.automatic-failover.enabled": "true", "yarn.resourcemanager.recovery.enabled": "true",
            "yarn.resourcemanager.store.class": "org.apache.hadoop.yarn.server.resourcemanager.recovery.ZKRMStateStore",
            "yarn.application.classpath": ",".join(cp), "yarn.nodemanager.aux-services": "mapreduce_shuffle",
            "yarn.nodemanager.local-dirs": ",".join(s["nm_local_dirs"]), "yarn.nodemanager.log-dirs": s["log_dir"] + "/yarn/containers",
            "yarn.log-aggregation-enable": "true", "yarn.nodemanager.resource.memory-mb": s["nm_memory_mb"],
            "yarn.scheduler.minimum-allocation-mb": 256, "yarn.scheduler.maximum-allocation-mb": s["nm_memory_mb"],
            "yarn.nodemanager.resource.cpu-vcores": s["nm_vcores"], "yarn.scheduler.maximum-allocation-vcores": s["nm_vcores"],
            "yarn.nodemanager.env-whitelist": "PATH,LANG,LC_ALL,JAVA_HOME,HADOOP_HOME,HADOOP_CONF_DIR," + ",".join(HOMES)}
    for i in (1, 2):
        key = ns + ".nn" + str(i)
        hdfs["dfs.namenode.rpc-address." + key] = hosts[i-1] + ":8020"
        hdfs["dfs.namenode.http-address." + key] = hosts[i-1] + ":9870"
        for prop, port in (("hostname", ""), ("webapp.address", ":8088"), ("webapp.https.address", ":8090")):
            yarn["yarn.resourcemanager.%s.rm%d" % (prop, i)] = hosts[i] + port
    task = s["task_memory_mb"]
    heap = "-Xmx%dm" % (task * 2 // 3)
    common_env = {"JAVA_HOME": "/usr/lib/jvm/java-1.8.0-openjdk", "HADOOP_HOME": LIB + "hadoop",
                  "HADOOP_LIBEXEC_DIR": LIB + "hadoop/libexec", "HADOOP_CONF_DIR": CONF,
                  "YARN_CONF_DIR": CONF, "HIVE_HOME": LIB + "hive", "TEZ_HOME": LIB + "tez",
                  "TEZ_CONF_DIR": "/etc/tez/conf", "SPARK_HOME": LIB + "spark", "SPARK_CONF_DIR": "/etc/spark/conf"}
    common_env.update({k: LIB + v for k, v in HOMES.items()})
    env = "\n".join("export %s=%s" % kv for kv in sorted(common_env.items())) + "\n"
    env += 'export PATH="$HADOOP_HOME/bin:$HADOOP_HDFS_HOME/bin:$HADOOP_YARN_HOME/bin:$HADOOP_MAPRED_HOME/bin:$JAVA_HOME/bin:$PATH"\n'
    rackmap = {r["fqdn"]: "/" + r["rack"] for r in rows}
    rack_script = (HERE / "rack-map.py").read_text().replace("RACKS = {}", "RACKS = " + repr(rackmap))
    plan = {}
    for i, row in enumerate(rows):
        slot, host = row["slot"], row["fqdn"]
        root, roles = dest / slot, ROLES[i]
        plan[slot] = dict(row, services={r: s["accounts"][OWNER[r]] for r in roles})
        xml(root, CONF + "/core-site.xml", core)
        local_hdfs, local_yarn = dict(hdfs), dict(yarn)
        if "namenode" in roles:
            local_hdfs["dfs.ha.namenode.id"] = "nn%d" % (i+1)
        if "resourcemanager" in roles:
            local_yarn["yarn.resourcemanager.ha.id"] = "rm%d" % i
        if "datanode" in roles:
            local_hdfs["dfs.datanode.hostname"] = host
            local_yarn["yarn.nodemanager.hostname"] = host
        xml(root, CONF + "/hdfs-site.xml", local_hdfs)
        xml(root, CONF + "/yarn-site.xml", local_yarn)
        xml(root, CONF + "/mapred-site.xml", {"mapreduce.framework.name": "yarn",
            "mapreduce.application.classpath": ",".join(cp), "mapreduce.jobhistory.address": hosts[2] + ":10020",
            "mapreduce.jobhistory.webapp.address": hosts[2] + ":19888", "yarn.app.mapreduce.am.resource.mb": task,
            "yarn.app.mapreduce.am.command-opts": heap, "mapreduce.map.memory.mb": task, "mapreduce.map.java.opts": heap,
            "mapreduce.reduce.memory.mb": task, "mapreduce.reduce.java.opts": heap})
        xml(root, CONF + "/capacity-scheduler.xml", {"yarn.scheduler.capacity.root.queues": "default",
            "yarn.scheduler.capacity.root.default.capacity": 100})
        put(root, CONF + "/container-log4j.properties", "log4j.rootLogger=INFO,syslog\nlog4j.appender.syslog=org.apache.log4j.FileAppender\nlog4j.appender.syslog.File=${yarn.app.container.log.dir}/syslog\nlog4j.appender.syslog.layout=org.apache.log4j.PatternLayout\nlog4j.appender.syslog.layout.ConversionPattern=%d %-5p %c - %m%n")
        put(root, CONF + "/rack-map", rack_script, True)
        put(root, CONF + "/bigtop-env.sh", env)
        for component in ("hadoop", "yarn", "mapred"):
            put(root, CONF + "/" + component + "-env.sh", ". " + CONF + "/bigtop-env.sh\n" +
                'export HADOOP_LOG_DIR="%s/$(id -un)"\nexport HADOOP_PID_DIR="%s/$(id -un)"' % (s["log_dir"], s["run_dir"]))
        if "zookeeper" in roles:
            put(root, "/etc/zookeeper/conf/zoo.cfg", "tickTime=2000\ninitLimit=10\nsyncLimit=5\nclientPort=2181\n"
                "admin.enableServer=false\nautopurge.purgeInterval=24\ndataDir=" + state + "/zookeeper\n" +
                "\n".join("server.%d=%s:2888:3888" % (j, h) for j, h in enumerate(hosts[:3], 1)))
            put(root, state + "/zookeeper/myid", str(i + 1))
        xml(root, "/etc/tez/conf/tez-site.xml", {"tez.lib.uris": fs + s["tez_archive"],
            "tez.use.cluster.hadoop-libs": "false", "tez.local.mode": "false",
            "tez.am.resource.memory.mb": task, "tez.am.launch.cmd-opts": heap})
        hclient = {"hive.metastore.uris": ",".join("thrift://" + h + ":9083" for h in hosts[8:]),
                   "hive.metastore.warehouse.dir": "/user/hive/warehouse", "hive.execution.engine": "tez",
                   "hive.tez.container.size": task, "hive.tez.java.opts": heap}
        hive_env = (". " + CONF + "/bigtop-env.sh\n" +
                    'export HADOOP_CLASSPATH="$TEZ_CONF_DIR:$HIVE_CONF_DIR:$TEZ_HOME/*:$TEZ_HOME/lib/*:${HADOOP_CLASSPATH:-}"')
        if "hiveserver2" in roles:
            hclient.update({"hive.server2.thrift.bind.host": host, "hive.server2.support.dynamic.service.discovery": "true",
                            "hive.zookeeper.quorum": zk, "hive.server2.zookeeper.namespace": "hiveserver2"})
            xml(root, "/etc/hive/metastore/hive-site.xml", {"hive.metastore.warehouse.dir": "/user/hive/warehouse",
                "hive.metastore.schema.verification": "true", "javax.jdo.option.ConnectionDriverName": "org.postgresql.Driver",
                "javax.jdo.option.ConnectionURL": s["pg_url"], "javax.jdo.option.ConnectionUserName": s["pg_user"],
                "hadoop.security.credential.provider.path": "localjceks://file" + s["hms_keystore"],
                "hadoop.security.credential.clear-text-fallback": "false"})
            put(root, "/etc/hive/metastore/hive-env.sh", hive_env +
                '\nexport HIVE_AUX_JARS_PATH=/opt/cluster/postgresql.jar' +
                '\nexport HADOOP_CLASSPATH="/opt/cluster/postgresql.jar:$HADOOP_CLASSPATH"')
        xml(root, "/etc/hive/conf/hive-site.xml", hclient)
        put(root, "/etc/hive/conf/hive-env.sh", hive_env)
        put(root, "/etc/spark/conf/spark-env.sh", ". " + CONF + '/bigtop-env.sh\nexport SPARK_DIST_CLASSPATH="$(hadoop classpath --glob)"')
        events = fs + "/spark-history"
        put(root, "/etc/spark/conf/spark-defaults.conf", "spark.master yarn\nspark.yarn.populateHadoopClasspath true\n"
            "spark.dynamicAllocation.enabled false\nspark.eventLog.enabled true\nspark.eventLog.dir " + events +
            "\nspark.history.fs.logDirectory " + events)
    put(dest, "plan.json", json.dumps(plan, sort_keys=True, indent=2))


def files(tree):
    result = {}
    for p in tree.rglob("*"):
        require(not p.is_symlink(), "Existing snapshot contains a symlink")
        if p.is_file():
            result[p.relative_to(tree)] = (p.read_bytes(), os.name == "posix" and p.stat().st_mode & 0o777)
        else:
            require(p.is_dir(), "Unexpected non-regular file")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for k in ("inventory", "site", "out"):
        parser.add_argument("--" + k, type=Path, required=True)
    args = parser.parse_args()
    rows = inventory(args.inventory)
    site = json.loads(args.site.read_text(encoding="utf-8"))
    checked_site(site)
    out = args.out.absolute()
    require(not out.is_symlink(), "Output cannot be a symlink")
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=str(out.parent)) as tmp:
        stage = Path(tmp) / "snapshot"
        render(stage, rows, site)
        if out.exists():
            expected = {"bd%02d" % i for i in range(1, 11)} | {"plan.json"}
            require(out.is_dir() and {p.name for p in out.iterdir()} == expected
                    and files(out) == files(stage),
                    "Existing output differs; select a fresh snapshot directory")
        else:
            stage.rename(out)
    print("Validated 10 host configurations in " + str(out))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, TypeError, KeyError) as error:
        sys.exit(str(error))
