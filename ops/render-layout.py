#!/usr/bin/env python3
"""Render an Ambari operator worksheet. Python 3.6+, standard library."""
import argparse
import csv
import re


ROLES = [
    "NameNode nn1, ZKFC, JournalNode, ZooKeeper 1",
    "NameNode nn2, ZKFC, JournalNode, ZooKeeper 2, ResourceManager rm1",
    "JournalNode, ZooKeeper 3, ResourceManager rm2, JobHistory",
    *["DataNode, NodeManager"] * 5,
    "Ambari Server, Hive Metastore, HiveServer2, DB primary candidate",
    "Gateway, Hive Metastore, HiveServer2, Spark History, DB standby candidate",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory")
    parser.add_argument("--nameservice", default="prod")
    args = parser.parse_args()
    ns = args.nameservice
    if not re.fullmatch(r"[a-z][a-z0-9-]*", ns):
        parser.error("invalid nameservice")
    with open(args.inventory, newline="", encoding="utf-8-sig") as stream:
        rows = sorted(csv.DictReader(stream), key=lambda row: row["slot"])
    if [r["slot"] for r in rows] != ["bd%02d" % i for i in range(1, 11)]:
        parser.error("expected exactly bd01 through bd10")
    hosts = [r["fqdn"].lower() for r in rows]
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if (len(set(hosts)) != 10 or any(len(h) > 253 or not re.fullmatch(
            label + r"(?:\." + label + r")+", h) for h in hosts)):
        parser.error("each site needs a unique DNS FQDN")
    if any(not r["rack"].strip() for r in rows):
        parser.error("every host needs a rack")
    print("slot\thost\track\troles (all hosts also run Ambari Agent)")
    for row, host, roles in zip(rows, hosts, ROLES):
        print("\t".join((row["slot"], host, row["rack"], roles)))
    if len(set(row["rack"] for row in rows[:3])) < 3:
        print("# WARNING: quorum hosts share a failure domain")
    zk = ",".join(h + ":2181" for h in hosts[:3])
    qjournal = ";".join(h + ":8485" for h in hosts[:3])
    print("\n# Ambari configuration worksheet: site<TAB>key<TAB>value")
    props = [
        ("core-site", "fs.defaultFS", "hdfs://" + ns),
        ("core-site", "ha.zookeeper.quorum", zk),
        ("hdfs-site", "dfs.nameservices", ns),
        ("hdfs-site", "dfs.ha.namenodes." + ns, "nn1,nn2"),
        ("hdfs-site", "dfs.namenode.rpc-address." + ns + ".nn1", hosts[0] + ":8020"),
        ("hdfs-site", "dfs.namenode.rpc-address." + ns + ".nn2", hosts[1] + ":8020"),
        ("hdfs-site", "dfs.namenode.shared.edits.dir", "qjournal://" + qjournal + "/" + ns),
        ("hdfs-site", "dfs.client.failover.proxy.provider." + ns,
         "org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider"),
        ("hdfs-site", "dfs.ha.automatic-failover.enabled", "true"),
        ("hdfs-site", "dfs.replication", "3"),
        ("yarn-site", "yarn.resourcemanager.ha.enabled", "true"),
        ("yarn-site", "yarn.resourcemanager.cluster-id", ns + "-yarn"),
        ("yarn-site", "yarn.resourcemanager.ha.rm-ids", "rm1,rm2"),
        ("yarn-site", "yarn.resourcemanager.hostname.rm1", hosts[1]),
        ("yarn-site", "yarn.resourcemanager.hostname.rm2", hosts[2]),
        ("yarn-site", "yarn.resourcemanager.webapp.address.rm1", hosts[1] + ":8088"),
        ("yarn-site", "yarn.resourcemanager.webapp.address.rm2", hosts[2] + ":8088"),
        ("yarn-site", "yarn.resourcemanager.webapp.https.address.rm1", hosts[1] + ":8090"),
        ("yarn-site", "yarn.resourcemanager.webapp.https.address.rm2", hosts[2] + ":8090"),
        ("core-site", "hadoop.zk.address", zk),
        ("yarn-site", "yarn.resourcemanager.recovery.enabled", "true"),
        ("yarn-site", "yarn.resourcemanager.store.class",
         "org.apache.hadoop.yarn.server.resourcemanager.recovery.ZKRMStateStore"),
        ("mapred-site", "mapreduce.framework.name", "yarn"),
        ("hive-site", "hive.metastore.uris",
         ",".join("thrift://" + h + ":9083" for h in hosts[8:])),
        ("hive-site", "hive.execution.engine", "tez"),
        ("hive-site", "hive.server2.support.dynamic.service.discovery", "true"),
        ("hive-site", "hive.zookeeper.quorum", zk),
        ("hive-site", "hive.server2.zookeeper.namespace", "hiveserver2"),
    ]
    for prop in props:
        print("\t".join(prop))


if __name__ == "__main__":
    main()
