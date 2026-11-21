#!/usr/bin/env python3
"""Render the operator's values for the interactive BIGTOP installation."""
import argparse
import csv
import json
from pathlib import Path
from urllib.parse import urlsplit
from urllib.parse import parse_qsl
import re


def render(inventory, site, web):
    with inventory.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
    hosts = {row["slot"]: row["fqdn"] for row in rows}
    if not hosts or len(hosts) != len(rows) or len(set(hosts.values())) != len(rows):
        raise ValueError("Empty or duplicate inventory")
    def role(name):
        result = [r["fqdn"] for r in rows if name in r["roles"].split()]
        if not result:
            raise ValueError("Assign role in hosts.csv: " + name)
        return ", ".join(result)
    for field in ("application_repo", "runtime_repo"):
        url = urlsplit(web[field])
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password:
            raise ValueError("Use an internal HTTP(S) repository URL: " + field)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", web["cluster_name"]):
        raise ValueError("Invalid cluster_name")
    jdbc = site["pg_url"]
    db = urlsplit(jdbc[5:] if jdbc.startswith("jdbc:") else "")
    if (db.scheme != "postgresql" or not db.hostname or db.username or db.password or db.fragment
            or db.path != "/" + web["hive_database"]
            or any(k.lower() in {"user", "password", "sslpassword"} for k, _ in parse_qsl(db.query))):
        raise ValueError("Use the matching PostgreSQL JDBC database without embedded credentials")
    lines = ["Get Started — " + web["cluster_name"], "Select Version — BIGTOP-3.3.0 / Use Local Repository / redhat7",
             "Base URL — " + web["application_repo"], "系统依赖仓库（各节点 yum） — " + web["runtime_repo"],
             "Target Hosts — Perform manual registration", *hosts.values(),
             "Choose Services — HDFS, YARN + MapReduce2, ZooKeeper, Tez, Hive, Spark"]
    for label, key in (("NameNode", "namenode"), ("Secondary NameNode", "secondary_namenode"),
                       ("ResourceManager", "resourcemanager"), ("Timeline Reader", "timeline_reader"),
                       ("Timeline Server", "timeline_server"), ("YARN Registry DNS", "registry_dns")):
        lines.append(label + " — " + hosts[web[key]])
    for label, key in (("ZooKeeper Server", "zookeeper"), ("History Server", "jobhistory"),
                       ("Hive Metastore", "metastore"), ("HiveServer2", "hiveserver2"),
                       ("Spark History Server", "sparkhistory"), ("DataNode", "datanode"),
                       ("NodeManager", "nodemanager")):
        lines.append(label + " — " + role(key))
    lines.extend(["Clients — " + ", ".join(hosts[k] for k in web["client_slots"]),
                  "Router — none", "Hive Database — Existing PostgreSQL", "Database Name — " + web["hive_database"],
                  "Database Username — " + site["pg_user"], "JDBC URL — " + site["pg_url"],
                  "Driver — org.postgresql.Driver", "Password — 从现场密钥系统取得，在页面输入后执行 Test Connection",
                  "dfs.namenode.name.dir — " + ",".join(web["namenode_metadata_dirs"]),
                  "dfs.datanode.data.dir — " + ",".join(site["datanode_dirs"]),
                  "yarn.nodemanager.local-dirs — " + ",".join(site["nm_local_dirs"]),
                  "yarn.nodemanager.log-dirs — " + ",".join(web["nm_log_dirs"]),
                  "yarn.nodemanager.resource.memory-mb — " + str(site["nm_memory_mb"]),
                  "yarn.nodemanager.resource.cpu-vcores — " + str(site["nm_vcores"]),
                  "YARN queue — " + web["queue"], "Tez HDFS archive — /bigtop/apps/3.3.0/tez/tez.tar.gz",
                  "服务账号 — " + json.dumps(site["accounts"], ensure_ascii=False)])
    for slot, values in site.get("node_overrides", {}).items():
        lines.append("主机配置组 " + hosts[slot] + " — " + json.dumps(values, ensure_ascii=False))
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("inventory", "site", "web"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        print(render(args.inventory, json.loads(args.site.read_text(encoding="utf-8-sig")),
                     json.loads(args.web.read_text(encoding="utf-8-sig"))))
    except (KeyError, ValueError, OSError, TypeError) as exc:
        parser.exit(2, "Invalid site settings: {}\n".format(exc))
