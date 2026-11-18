"""Write the isolated five-node integration cluster's site files."""
import os
import socket
import xml.etree.ElementTree as ET

conf = os.environ["HADOOP_CONF_DIR"]
os.makedirs(conf, exist_ok=True)
host = socket.gethostname().split(".")[0]
masters = ["master1", "master2"]
workers = ["worker1", "worker2", "worker3"]
zk = ",".join(name + ":2181" for name in workers)
journals = ";".join(name + ":8485" for name in workers)


def configuration(filename, properties):
    root = ET.Element("configuration")
    for key, value in sorted(properties.items()):
        prop = ET.SubElement(root, "property")
        ET.SubElement(prop, "name").text = key
        ET.SubElement(prop, "value").text = value
    ET.ElementTree(root).write(os.path.join(conf, filename), encoding="utf-8")


configuration("core-site.xml", {
    "fs.defaultFS": "hdfs://cluster",
    "ha.zookeeper.quorum": zk,
    "ha.zookeeper.session-timeout.ms": "6000",
    "ha.health-monitor.rpc-timeout.ms": "6000",
    "ha.failover-controller.graceful-fence.rpc-timeout.ms": "6000",
    "hadoop.tmp.dir": "/var/lib/ha/hadoop",
    "hadoop.zk.address": zk,
})
hdfs = {
    "dfs.nameservices": "cluster",
    "dfs.ha.namenodes.cluster": "nn1,nn2",
    "dfs.namenode.shared.edits.dir": "qjournal://" + journals + "/cluster",
    "dfs.client.failover.proxy.provider.cluster":
        "org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider",
    "dfs.ha.automatic-failover.enabled": "true",
    "dfs.ha.fencing.methods": "sshfence(root:22)",
    "dfs.ha.fencing.ssh.private-key-files": "/run/ha/fence-key",
    "dfs.ha.fencing.ssh.connect-timeout": "10000",
    "dfs.journalnode.edits.dir": "/var/lib/ha/journal",
    "dfs.namenode.name.dir": "file:///var/lib/ha/name",
    "dfs.datanode.data.dir": "file:///var/lib/ha/data",
    "dfs.replication": "3",
    "dfs.namenode.safemode.min.datanodes": "3",
    "dfs.namenode.safemode.extension": "1000",
}
for index, name in enumerate(masters, 1):
    hdfs["dfs.namenode.rpc-address.cluster.nn%d" % index] = name + ":8020"
    hdfs["dfs.namenode.http-address.cluster.nn%d" % index] = name + ":9870"
if host in workers:
    hdfs["dfs.datanode.hostname"] = host
configuration("hdfs-site.xml", hdfs)
libdirs = [os.environ[name] for name in (
    "HADOOP_COMMON_HOME", "HADOOP_HDFS_HOME", "HADOOP_YARN_HOME", "HADOOP_MAPRED_HOME")]
# The RPMs install loose webapps and configuration resources alongside the jars.
# Java's directory/* entries include jars only.
classpath = [conf] + [directory + suffix for directory in libdirs
                      for suffix in ("", "/lib/*", "/*")]
with open(os.path.join(conf, "container-log4j.properties"), "w") as stream:
    stream.write("""log4j.rootLogger=INFO,syslog,stderr
log4j.appender.syslog=org.apache.log4j.FileAppender
log4j.appender.syslog.File=${yarn.app.container.log.dir}/syslog
log4j.appender.syslog.layout=org.apache.log4j.PatternLayout
log4j.appender.syslog.layout.ConversionPattern=%d %-5p %c - %m%n
log4j.appender.stderr=org.apache.log4j.ConsoleAppender
log4j.appender.stderr.Target=System.err
log4j.appender.stderr.Threshold=WARN
log4j.appender.stderr.layout=org.apache.log4j.PatternLayout
log4j.appender.stderr.layout.ConversionPattern=%d %-5p %c - %m%n
""")
yarn = {
    "yarn.resourcemanager.ha.enabled": "true",
    "yarn.resourcemanager.cluster-id": "cluster",
    "yarn.resourcemanager.ha.rm-ids": "rm1,rm2",
    "yarn.resourcemanager.ha.automatic-failover.enabled": "true",
    "yarn.resourcemanager.recovery.enabled": "true",
    "yarn.resourcemanager.store.class": "org.apache.hadoop.yarn.server.resourcemanager.recovery.ZKRMStateStore",
    "yarn.resourcemanager.zk-address": zk,
    "yarn.application.classpath": ",".join(classpath),
    "yarn.nodemanager.aux-services": "mapreduce_shuffle",
    "yarn.nodemanager.local-dirs": "/var/lib/ha/nm/local",
    "yarn.nodemanager.log-dirs": "/var/lib/ha/nm/logs",
    "yarn.nodemanager.delete.debug-delay-sec": "600",
    "yarn.nodemanager.resource.memory-mb": "3072",
    "yarn.nodemanager.resource.cpu-vcores": "3",
    "yarn.scheduler.minimum-allocation-mb": "128",
    "yarn.scheduler.maximum-allocation-mb": "3072",
    "yarn.nodemanager.vmem-check-enabled": "false",
    "yarn.nodemanager.pmem-check-enabled": "false",
    "yarn.nodemanager.env-whitelist": "PATH,LANG,LC_ALL,JAVA_HOME,HADOOP_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_YARN_HOME,HADOOP_MAPRED_HOME,HADOOP_CONF_DIR",
}
for index, name in enumerate(masters, 1):
    yarn["yarn.resourcemanager.hostname.rm%d" % index] = name
    yarn["yarn.resourcemanager.webapp.address.rm%d" % index] = name + ":8088"
    yarn["yarn.resourcemanager.webapp.https.address.rm%d" % index] = name + ":8090"
if host in masters:
    yarn["yarn.resourcemanager.ha.id"] = "rm%d" % (masters.index(host) + 1)
if host in workers:
    yarn["yarn.nodemanager.hostname"] = host
configuration("yarn-site.xml", yarn)
configuration("capacity-scheduler.xml", {
    "yarn.scheduler.capacity.root.queues": "default",
    "yarn.scheduler.capacity.root.default.capacity": "100",
    "yarn.scheduler.capacity.maximum-am-resource-percent": "1.0",
})
configuration("mapred-site.xml", {
    "mapreduce.framework.name": "yarn",
    "mapreduce.application.classpath": ",".join(classpath),
    "yarn.app.mapreduce.am.resource.mb": "512",
    "yarn.app.mapreduce.am.command-opts": "-Xmx320m",
    "mapreduce.map.memory.mb": "384",
    "mapreduce.map.java.opts": "-Xmx240m",
    "mapreduce.reduce.memory.mb": "384",
    "mapreduce.reduce.java.opts": "-Xmx240m",
})
if host in workers:
    directory = "/var/lib/ha/zk"
    os.makedirs(directory, exist_ok=True)
    with open(directory + "/myid", "w") as stream:
        stream.write(str(workers.index(host) + 1) + "\n")
    with open("/run/ha/zoo.cfg", "w") as stream:
        stream.write("tickTime=2000\ninitLimit=10\nsyncLimit=5\ndataDir=" + directory +
                     "\nclientPort=2181\n4lw.commands.whitelist=srvr\n")
        for index, worker in enumerate(workers, 1):
            stream.write("server.%d=%s:2888:3888\n" % (index, worker))
