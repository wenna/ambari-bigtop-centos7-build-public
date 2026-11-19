#!/usr/bin/env python3
"""Render an immutable role-based configuration snapshot (Python 3.6+)."""
import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree as ET

from inventory import FQDN, OWNER, inventory

HERE = Path(__file__).resolve().parent
BASE = "/usr/bigtop/3.3.0/usr"
CONF = "/etc/hadoop/conf"
LIB = BASE + "/lib/"
HOMES = {"HADOOP_COMMON_HOME": "hadoop", "HADOOP_HDFS_HOME": "hadoop-hdfs",
         "HADOOP_YARN_HOME": "hadoop-yarn", "HADOOP_MAPRED_HOME": "hadoop-mapreduce"}
USER = r"[a-z_][a-z0-9_-]{0,30}"
PATH = r"(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+"


def require(ok, message):
    if not ok:
        raise ValueError(message)


def checked_resources(site):
    storage = []
    for key in ("datanode_dirs", "nm_local_dirs"):
        paths = site[key]
        require(isinstance(paths, list) and paths and
                all(isinstance(p, str) and re.fullmatch(PATH, p) for p in paths),
                "Invalid absolute storage paths for " + key)
        storage.extend(paths)
    require(len(set(storage)) == len(storage), "DataNode and NM storage paths must be distinct")
    for key in ("nm_memory_mb", "task_memory_mb", "nm_vcores"):
        require(type(site[key]) is int and site[key] > 0, "Invalid " + key)
    require(512 <= site["task_memory_mb"] <= site["nm_memory_mb"] and
            site["task_memory_mb"] % 256 == site["nm_memory_mb"] % 256 == 0,
            "Memory sizes must fit node capacity in multiples of 256 MiB")


def checked_site(site, rows):
    example = json.loads((HERE / "site.example.json").read_text())
    require(isinstance(site, dict) and set(site) - {"node_overrides", "fence_port"} == set(example) - {"node_overrides", "fence_port"},
            "Unexpected or missing site fields; supply only the documented public settings")
    match = lambda pattern, value: isinstance(value, str) and re.fullmatch(pattern, value)
    require(match(r"[a-z][a-z0-9-]{0,40}", site["nameservice"]), "Invalid nameservice")
    for k in ("state_dir", "log_dir", "run_dir", "fence_key", "hms_keystore", "tez_archive"):
        require(match(PATH, site[k]), "Invalid absolute path for " + k)
    port = site.get("fence_port", 22)
    require(type(port) is int and 1 <= port <= 65535, "Invalid fence_port")
    checked_resources(site)
    overrides = site.get("node_overrides", {})
    require(isinstance(overrides, dict) and set(overrides) <= {row["slot"] for row in rows},
            "node_overrides must map inventory slots to local settings")
    allowed = {"datanode_dirs", "nm_local_dirs", "nm_memory_mb", "nm_vcores"}
    for slot, settings in overrides.items():
        require(isinstance(settings, dict) and set(settings) <= allowed, "Invalid node_overrides for " + slot)
        checked_resources(dict(site, **settings))
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
    hosts = {role: [r["fqdn"] for r in rows if role in r["roles"]] for role in OWNER}
    overrides = s.get("node_overrides", {})
    workers = [dict(s, **overrides.get(r["slot"], {})) for r in rows if "nodemanager" in r["roles"]]
    ns, state = s["nameservice"], s["state_dir"]
    fs = "hdfs://" + ns
    zk = ",".join(h + ":2181" for h in hosts["zookeeper"])
    cp = [CONF] + [LIB + directory + suffix for directory in HOMES.values()
                   for suffix in ("", "/lib/*", "/*")]
    hive_hosts = ",".join(hosts["hiveserver2"])
    core = {"fs.defaultFS": fs, "ha.zookeeper.quorum": zk, "hadoop.zk.address": zk,
            "net.topology.script.file.name": CONF + "/rack-map",
            "hadoop.proxyuser." + s["accounts"]["hive"] + ".hosts": hive_hosts,
            "hadoop.proxyuser." + s["accounts"]["hive"] + ".groups": ",".join(s["proxy_groups"])}
    hdfs = {"dfs.nameservices": ns, "dfs.ha.namenodes." + ns: "nn1,nn2",
            "dfs.namenode.shared.edits.dir": "qjournal://" + ";".join(h + ":8485" for h in hosts["journalnode"]) + "/" + ns,
            "dfs.client.failover.proxy.provider." + ns: "org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider",
            "dfs.ha.automatic-failover.enabled": "true", "dfs.ha.fencing.methods": "sshfence({}:{})".format(s["fence_user"], s.get("fence_port", 22)),
            "dfs.ha.fencing.ssh.private-key-files": s["fence_key"], "dfs.replication": 3,
            "dfs.namenode.name.dir": state + "/namenode", "dfs.journalnode.edits.dir": state + "/journalnode"}
    yarn = {"yarn.resourcemanager.ha.enabled": "true", "yarn.resourcemanager.cluster-id": ns + "-yarn",
            "yarn.resourcemanager.ha.rm-ids": "rm1,rm2", "yarn.resourcemanager.zk-address": zk,
            "yarn.resourcemanager.ha.automatic-failover.enabled": "true", "yarn.resourcemanager.recovery.enabled": "true",
            "yarn.resourcemanager.store.class": "org.apache.hadoop.yarn.server.resourcemanager.recovery.ZKRMStateStore",
            "yarn.application.classpath": ",".join(cp), "yarn.nodemanager.aux-services": "mapreduce_shuffle",
            "yarn.nodemanager.log-dirs": s["log_dir"] + "/yarn/containers", "yarn.log-aggregation-enable": "true",
            "yarn.scheduler.minimum-allocation-mb": 256, "yarn.scheduler.maximum-allocation-mb": max(w["nm_memory_mb"] for w in workers),
            "yarn.scheduler.maximum-allocation-vcores": max(w["nm_vcores"] for w in workers),
            "yarn.nodemanager.env-whitelist": "PATH,LANG,LC_ALL,JAVA_HOME,HADOOP_HOME,HADOOP_CONF_DIR," + ",".join(HOMES)}
    for i in (1, 2):
        key = ns + ".nn" + str(i)
        hdfs["dfs.namenode.rpc-address." + key] = hosts["namenode"][i-1] + ":8020"
        hdfs["dfs.namenode.http-address." + key] = hosts["namenode"][i-1] + ":9870"
        for prop, port in (("hostname", ""), ("webapp.address", ":8088"), ("webapp.https.address", ":8090")):
            yarn["yarn.resourcemanager.%s.rm%d" % (prop, i)] = hosts["resourcemanager"][i-1] + port
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
    for row in rows:
        slot, host = row["slot"], row["fqdn"]
        root, roles = dest / slot, row["roles"]
        settings = overrides.get(slot, {})
        local = dict(s, **settings)
        plan[slot] = dict(row, services={r: s["accounts"][OWNER[r]] for r in roles if r in OWNER},
                          node_overrides=settings)
        xml(root, CONF + "/core-site.xml", core)
        local_hdfs, local_yarn = dict(hdfs), dict(yarn)
        local_hdfs["dfs.datanode.data.dir"] = ",".join(local["datanode_dirs"])
        local_yarn["yarn.nodemanager.local-dirs"] = ",".join(local["nm_local_dirs"])
        local_yarn["yarn.nodemanager.resource.memory-mb"] = local["nm_memory_mb"]
        local_yarn["yarn.nodemanager.resource.cpu-vcores"] = local["nm_vcores"]
        if "namenode" in roles:
            local_hdfs["dfs.ha.namenode.id"] = "nn%d" % (hosts["namenode"].index(host) + 1)
        if "resourcemanager" in roles:
            local_yarn["yarn.resourcemanager.ha.id"] = "rm%d" % (hosts["resourcemanager"].index(host) + 1)
        if "datanode" in roles:
            local_hdfs["dfs.datanode.hostname"] = host
        if "nodemanager" in roles:
            local_yarn["yarn.nodemanager.hostname"] = host
        xml(root, CONF + "/hdfs-site.xml", local_hdfs)
        xml(root, CONF + "/yarn-site.xml", local_yarn)
        xml(root, CONF + "/mapred-site.xml", {"mapreduce.framework.name": "yarn",
            "mapreduce.application.classpath": ",".join(cp), "mapreduce.jobhistory.address": hosts["jobhistory"][0] + ":10020",
            "mapreduce.jobhistory.webapp.address": hosts["jobhistory"][0] + ":19888", "yarn.app.mapreduce.am.resource.mb": task,
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
                "\n".join("server.%d=%s:2888:3888" % (j, h) for j, h in enumerate(hosts["zookeeper"], 1)))
            put(root, state + "/zookeeper/myid", str(hosts["zookeeper"].index(host) + 1))
        xml(root, "/etc/tez/conf/tez-site.xml", {"tez.lib.uris": fs + s["tez_archive"],
            "tez.use.cluster.hadoop-libs": "false", "tez.local.mode": "false",
            "tez.am.resource.memory.mb": task, "tez.am.launch.cmd-opts": heap})
        hclient = {"hive.metastore.uris": ",".join("thrift://" + h + ":9083" for h in hosts["metastore"]),
                   "hive.metastore.warehouse.dir": "/user/hive/warehouse", "hive.execution.engine": "tez",
                   "hive.tez.container.size": task, "hive.tez.java.opts": heap}
        hive_env = (". " + CONF + "/bigtop-env.sh\n" +
                    'export HADOOP_CLASSPATH="$TEZ_CONF_DIR:$HIVE_CONF_DIR:$TEZ_HOME/*:$TEZ_HOME/lib/*:${HADOOP_CLASSPATH:-}"')
        if "hiveserver2" in roles:
            hclient.update({"hive.server2.thrift.bind.host": host, "hive.server2.support.dynamic.service.discovery": "true",
                            "hive.zookeeper.quorum": zk, "hive.server2.zookeeper.namespace": "hiveserver2"})
        if "metastore" in roles:
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
    checked_site(site, rows)
    out = args.out.absolute()
    require(not out.is_symlink(), "Output cannot be a symlink")
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=str(out.parent)) as tmp:
        stage = Path(tmp) / "snapshot"
        render(stage, rows, site)
        if out.exists():
            expected = {r["slot"] for r in rows} | {"plan.json"}
            require(out.is_dir() and {p.name for p in out.iterdir()} == expected
                    and files(out) == files(stage),
                    "Existing output differs; select a fresh snapshot directory")
        else:
            stage.rename(out)
    print("Validated %d host configurations in %s" % (len(rows), out))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, TypeError, KeyError) as error:
        sys.exit(str(error))
