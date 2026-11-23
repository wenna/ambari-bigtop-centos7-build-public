# Ambari 新建环境核对表

按行填写，凭据只记录密钥系统中的引用。先完成主机准备与基础服务，再回到《现场配置与安装操作单》执行账号引导和管理面安装。

| 责任人 / 项目 | 现场值或参数 | 提交安装前怎样确认 |
|---|---|---|
| 系统管理员 / 操作系统 | 每台 CentOS Linux 7.9.2009、x86_64；systemd 为 PID 1 | 逐台运行 `cat /etc/centos-release`、`uname -m`、`ps -p 1 -o comm=`、`systemctl show -p Version`。普通 sleep 容器不满足生产操作系统预检。镜像须提供 sshd、sudo、yum、系统 Python 和 util-linux。控制机提供 Bash、Python 3.6+、SSH。 |
| 架构和存储 / 数量与故障域 | 服务器数、实际机架、每个角色的机型、内存/vCPU、磁盘和冗余目标 | 每台一行 hosts.csv；对照资产表查 FQDN、IP、rack。3 个仲裁成员分别放在 3 个独立故障域；两台 NN、两台 RM 各自跨域。记录整机失效后剩余 YARN 资源和磁盘空间。清单的 rack 是规划记录，现场需核实 Hadoop 拓扑映射（`hdfs dfsadmin -printTopology`）。 |
| 系统管理员 / 文件系统 | REQUIRED_MOUNTS、WORKER_MOUNTS、MIN_FREE_MIB，HDFS、YARN 本地和日志路径 | `lsblk -f`、`findmnt --verify`、`df -hPT`、`df -i`，核对挂载持久化。阈值以每个挂载点为单位。共节点主机须给 OS、Ambari、各 JVM 和页缓存留足内存，再确定 NM 内存和 vCore。 |
| 网络 / 名称与路由 | 管理和业务子网、网关、DNS、短名/FQDN、证书 SAN、SSH_PORT、已验证的 host keys | 控制机及节点对所有对端执行 `getent ahosts 实际FQDN`；每节点的 `hostname -f` 要与清单完全一致。多网卡选定实际互联地址。登记 DNS 和时间源，DNS 常用 UDP/TCP 53、NTP 用 UDP 123。|
| 网络 / 管理与数据流量 | 浏览器→Server 的管理地址；Agent→Server；各节点→两个 yum 根地址；Server/Hive→数据库；NN 间 fencing | 运维入口默认 TCP 8080（启用 TLS 后使用站点实际端口）；Agent 常用 TCP 8440、8441；数据库默认 TCP 5432。逐条核对[各服务流向与端口表](README.md#2-安装前准备)，按真实配置、双向路由、防火墙及 SELinux 策略验收。所有节点执行 `curl -fsS 仓库根地址/repodata/repomd.xml -o /dev/null`，两个仓库各测一次。 |
| 系统管理员 / SSH 与时钟 | access.env、site.env、bootstrap.csv、NTP_SOURCES | 先确认初始普通管理员和公钥信任，再运行操作单的 plan/apply。事先由现场维护时间时，运行 `chronyc -n sources` 和 `chronyc tracking`；须有选中的授时时钟源。需脚本配置 chrony、名称和 hosts 时使用 PREPARE_OS=1。 |
| DBA / 两个独立数据库 | Ambari 的 PG_*；Hive 的 pg_url、pg_user、hive_database；备份目标和数据库主备端点 | DBA 按[建库示例](README.md#2-安装前准备)创建库与所有者，确认 pg_hba、TLS、CA、口令文件和数据库可写。数据库切换后应保持证书域名及写端点有效。Hive 在向导中执行 Test Connection。 |
| 运维 / 交付版本 | 发布标签、套件摘要、KIT_ROOT、应用/依赖仓库 URL | 分卷及包内校验均成功；所有节点的交付目录一致并受保护。对照 WEB-INSTALL 在 redhat7 行填应用仓库；各主机另启用系统依赖仓库。 |
| 运维 / 身份和上线入口 | 初始管理员、安装账号、管理网 URL、服务身份、API netrc | 脚本回报全部 Agent HEALTHY 后，用浏览器打开 `http://实际Ambari主机:8080` 或已配置的 HTTPS 管理入口。全新默认初始化下为 Ambari 应用账号 `admin`、初始口令 `admin`；首次在隔离管理网登录后立即轮换并更新 netrc。它与 Linux 安装账号分别维护。 |

**SELinux 现场决策应在安装前完成。** 在管理节点记录 `getenforce` 的实际输出。Ambari 3.0 的上游 setup 检查到 Enforcing 时会尝试将运行模式临时切到 Permissive。要求全程 Enforcing 的站点应先在相同策略镜像中完成适配验证，再执行管理面安装。已按现场策略完成安装时，复核运行模式、持久配置和 AVC，再签收。[Apache Ambari 3.0 安装实现](https://github.com/apache/ambari/blob/release-3.0.0/ambari-server/src/main/python/ambari_server/serverSetup.py)

## 安装结束后启用和验收 HA

1. 浏览器向导完成后，先核对所有目标主机上的安装和服务检查。在维护窗口记录当前配置版本，备份 Ambari、Hive 数据库及 HDFS namespace 元数据。记录备份位置和恢复负责人。
2. 在 HDFS 服务操作中进入 NameNode HA 向导。按页面填写单准备 nameservice、第二台 NN、3 台 JournalNode、ZooKeeper quorum、两个 NN 本机的 ZKFC 和双向 fencing 身份。核对共享 edits 目录和各自本地存储。按该版本向导标出的主机、服务身份和顺序完成检查点、备用节点初始化及服务重启。已有数据的 NameNode 禁止重新格式化。若页面要求运行管理员命令，交由现场授权的维护脚本执行；部署账号的安装权限只覆盖已审阅的安装动作。
3. 在 YARN 服务操作中进入 ResourceManager HA 向导，选择另一故障域的第二台 RM，审阅 RM ID、两端地址、ZooKeeper 连接和恢复配置，应用后重启页面标记的服务。同步客户端配置。核对 `hdfs haadmin -getAllServiceState` 和 `yarn rmadmin -getAllServiceState` 输出，各有一个 active 和一个 standby。留存实际 ID。
4. 建专用验收目录，保存一份带校验值的 HDFS 文件，提交 YARN 作业、Hive on Tez 查询和 Spark on YARN 作业。维护窗口内通过 Ambari 每次只停一个活动 NN 或 RM。记录原状态、对端接管时间、客户端读写或新作业结果；启动原服务，验证它回到 standby 后再测下一项。遇到双 active、仲裁失联或文件校验不一致，停止演练并保留请求号。
5. 现场另测整机故障、机架断联和管理数据库主备切换。先确认剩余多数派和磁盘副本、执行窗口及回退负责人。容器共享宿主机，单进程切换仅覆盖其中一部分。

## 容灾签收

上线前逐台验证重启后的数据盘和交付目录挂载、主机名、时钟、Agent 心跳和服务状态；先做一台备用或 Worker，恢复正常后再继续下一台。记录 Ambari Server、Agent 的开机启动策略和实际重启结果。保留独立访问数据库和备份的管理入口。

本次免费环境的浏览器复装在独立的 3 台和 4 台容器上分别核对了 44 和 54 个组件实例；两套环境都从 HDFS 文件副本和 Hive 库备份恢复到新目标。另一次三节点演练以 Ambari Blueprint 创建 HA 拓扑，分别验证 NameNode、ResourceManager 切换和业务作业。页面安装后在现场启用 HA、整机重启、异地恢复仍需按本表单独签收。[两种规模的页面复装与恢复](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/45108523093) · [HA 切换和作业](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/45108522442)

填写 **备份位置、保留期、最近恢复点、目标/实测 RPO 和 RTO、恢复负责人**。将 HDFS 数据及权限、NameNode 元数据、Hive 和 Ambari PostgreSQL、配置版本、证书和所需密钥分别备份到独立故障域。数据库与仓库数据需对应同一业务恢复点。

在隔离环境恢复两个数据库、配置和数据；按恢复点检查 HDFS 路径与权限、文件校验值、Hive 表和分区、真实查询及作业输出。记录丢失事务窗口和恢复耗时。文件回读和单库恢复可作为日常抽查；异地重建须使用场外副本，在原站点不可用的条件下完成业务验证。
