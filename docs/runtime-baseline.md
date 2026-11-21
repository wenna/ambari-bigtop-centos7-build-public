# CentOS 7.9 x86_64 离线运行基线

新安装以本次签名仓库快照为基线。下表给出可复现的最低交付配置，即运维选择本包时应采用的版本。更老的版本未逐一降级测试。每个应用 RPM 的硬性 Requires 和版本关系保存在交付包 manifests/application-rpm-requires.txt；没有上游声明版本下限的条目保留 RPM 原文。

| 用途 | 交付或验证版本 |
| --- | --- |
| 操作系统 ABI | CentOS Linux 7.9.2009 x86_64，glibc 2.17-326.el7_9.3 |
| 数据服务 Java | OpenJDK 1.8.0.412.b08-1.el7_9，含 JDK 工具 |
| Ambari Server Java | Eclipse Temurin 17.0.21+9，runtimes/jdk17.tar.gz |
| EL7 Python | 系统 Python 2 留给 yum，另装 Python 3.6.8-21.el7_9 |
| RPM / yum | 4.11.3-48.el7_9 / 3.4.3-168.el7.centos |
| SSH fencing | openssh-server 7.4p1-23.el7_9，psmisc/fuser，nmap-ncat/nc |
| 持久化数据库 / Java 驱动 | PostgreSQL 15.20 x86_64 容器镜像或站点提供的数据库服务，pgJDBC 42.7.7 |
| 应用 RPM | 基础交付含 60 个。包含内嵌 HBase 的 Ambari 原生包增加 3 个，共 63 个。主要版本为 Ambari 3.0.0.0-2.compat2、Bigtop 3.3.0、ZooKeeper 3.7.2、Hadoop 3.3.6、Hive 3.1.3、Tez 0.10.2、Spark 3.3.4、HBase 2.4.17-1.el7 |
| 系统依赖 RPM | 基础快照含 283 个。原生安装另含 4 个 Stack 脚本依赖，共 287 个。完整 NEVRA 表见 manifests/runtime-versions.tsv |

已从无已安装 RPM 的 installroot 解析运维角色依赖，在干净 CentOS 7 容器中使用两个 file:// 源且关闭网络，执行同一组服务端和客户端 yum 安装。依赖检查覆盖 cluster/packages.txt 列出的部署角色。可选的调试、示例和扩展服务不属于默认安装角色。数据库使用归档 OCI 镜像时，数据库主机需提供支持 docker load 的容器引擎；选择企业数据库时集群节点无需安装容器引擎。现有服务器的第三方 RPM、操作系统基线、磁盘和安全域须按部署手册检查。

[离线依赖解析、签名核对、断网安装与归档](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44273252473)
