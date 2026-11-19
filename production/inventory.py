"""Read explicit role inventories and the original ten-slot deployment CSV."""
import csv
import re

LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
FQDN = LABEL + r"(?:\." + LABEL + r")+"
OWNER = dict(namenode="hdfs", zkfc="hdfs", journalnode="hdfs", datanode="hdfs",
             zookeeper="zookeeper", resourcemanager="yarn", nodemanager="yarn",
             jobhistory="mapred", metastore="hive", hiveserver2="hive", sparkhistory="spark")
LEGACY = {
    "bd01": "namenode zkfc journalnode zookeeper",
    "bd02": "namenode zkfc journalnode zookeeper resourcemanager",
    "bd03": "journalnode zookeeper resourcemanager jobhistory",
    "bd09": "metastore hiveserver2 ambari-server",
    "bd10": "metastore hiveserver2 sparkhistory",
}
LEGACY.update({"bd%02d" % i: "datanode nodemanager" for i in range(4, 9)})


def inventory(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        fields = ["slot", "fqdn", "rack"]
        if reader.fieldnames not in (fields, fields + ["roles"]):
            raise ValueError("Expected slot,fqdn,rack,roles (or original three-column inventory)")
        legacy = reader.fieldnames == fields
        rows = list(reader)
    slots = set()
    names = set()
    members = {role: set() for role in list(OWNER) + ["ambari-server"]}
    for row in rows:
        if None in row or None in row.values():
            raise ValueError("Malformed inventory row")
        slot, host = row["slot"], row["fqdn"]
        if (not re.fullmatch(LABEL, slot) or not re.fullmatch(FQDN, host) or len(host) > 253
                or not re.fullmatch(LABEL, row["rack"])):
            raise ValueError("Invalid slot, FQDN or rack")
        if slot in slots or host in names:
            raise ValueError("Duplicate slot or FQDN")
        slots.add(slot)
        names.add(host)
        roles = (LEGACY.get(slot, "") if legacy else row["roles"]).split()
        if len(set(roles)) != len(roles) or set(roles) - set(members):
            raise ValueError("Unknown or repeated role on " + slot)
        row["roles"] = sorted(roles)
        for role in roles:
            members[role].add(slot)
    if legacy and slots != set(LEGACY):
        raise ValueError("Three-column inventories must contain bd01 through bd10; use explicit roles otherwise")
    for role, count in (("namenode", 2), ("resourcemanager", 2), ("jobhistory", 1),
                        ("sparkhistory", 1), ("ambari-server", 1)):
        if len(members[role]) != count:
            raise ValueError("Expected %d distinct %s hosts" % (count, role))
    if members["namenode"] != members["zkfc"]:
        raise ValueError("Each NameNode requires a colocated ZKFC")
    for role in ("zookeeper", "journalnode"):
        if len(members[role]) < 3 or len(members[role]) % 2 == 0:
            raise ValueError("Expected an odd quorum of at least three " + role + " hosts")
    for role, least in (("datanode", 3), ("nodemanager", 1), ("metastore", 1), ("hiveserver2", 1)):
        if len(members[role]) < least:
            raise ValueError("Expected at least %d %s hosts" % (least, role))
    return sorted(rows, key=lambda r: r["slot"])
