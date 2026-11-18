"""Keep database credentials in the metastore service configuration on master1."""
import os
import xml.etree.ElementTree as ET


def write_site(path, settings):
    root = ET.Element("configuration")
    for key, value in sorted(settings.items()):
        prop = ET.SubElement(root, "property")
        ET.SubElement(prop, "name").text = key
        ET.SubElement(prop, "value").text = value
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


base = "/run/compute"
common = {
    "hive.metastore.warehouse.dir": "/user/hive/warehouse",
    "hive.metastore.schema.verification": "true",
}
server = dict(common)
server.update({
    "javax.jdo.option.ConnectionDriverName": "org.postgresql.Driver",
    "javax.jdo.option.ConnectionURL": "jdbc:postgresql://db:5432/hive",
    "javax.jdo.option.ConnectionUserName": "hive",
    "javax.jdo.option.ConnectionPassword": os.environ["HIVE_DB_PASSWORD"],
})
write_site(base + "/server/hive-site.xml", server)
client = dict(common)
client.update({
    "hive.metastore.uris": "thrift://master1:9083",
    "hive.execution.engine": "tez",
    "hive.fetch.task.conversion": "none",
    "hive.compute.query.using.stats": "false",
    "hive.exec.mode.local.auto": "false",
    "hive.tez.container.size": "768",
    "hive.tez.java.opts": "-Xmx512m",
})
write_site(base + "/client/hive-site.xml", client)
write_site(os.path.join(os.environ["TEZ_CONF_DIR"], "tez-site.xml"), {
    "tez.lib.uris": os.environ["TEZ_ARCHIVE_URI"],
    "tez.use.cluster.hadoop-libs": "false",
    "tez.local.mode": "false",
    "tez.am.resource.memory.mb": "768",
    "tez.am.launch.cmd-opts": "-Xmx512m",
    "tez.runtime.io.sort.mb": "96",
})
