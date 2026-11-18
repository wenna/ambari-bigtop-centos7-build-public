# 十节点离线安装与接管手册

适用 CentOS Linux 7.9.2009 x86_64，服务器 bd01–bd10。第一轮在隔离区按正式拓扑走完整个流程，保存配置版本、输出和故障演练记录后再将相同快照推广到业务环境。运行命令的起点为归档解包后的根目录。示例 DNS 域名、磁盘、数据库入口和机架均须按现场清单替换。

## 直接部署入口

在可访问十个 FQDN 的 Linux 管理机解包本交付。所有服务器将**同一份**解包目录挂载在配置的 KIT_ROOT（默认 /srv/bigtop-kit）；使用只读挂载，或由 root 拥有且普通用户无写权限。先将归档摘要与受信任的发布记录核对，再从该副本取 `sha256sum SHA256SUMS` 的首列填入 site.env。自动化会在十台分别核对这份摘要及清单里的每个文件。应用包仅通过该已核验的本地 file:// 源安装，系统包同时检查发行者 RPM 签名。第二节的企业签名 HTTPS 镜像可用于自行管理软件源的部署。

1. 管理机从 ops/hosts.example.csv、ops/site.env.example、production/site.example.json 复制出 hosts.csv、site.env、site.json。填写真实域名、机架、挂载点、专用服务身份、数据库写入口和资源限制。site.env 为本地受信的运维脚本配置，避免其他账户写入。为 SSH_USER 设置密钥登录、可信 known_hosts 和非交互 sudo 权限。十台基础主机需要可用 sshd、sudo、bash、coreutils 和 DNS；控制机需要 Python 3.6+ 及 OpenSSH 客户端。
2. DBA 建立两个独立空库与 owner，配置生产 TLS 和允许的来源。bd09 放置管理库 root 专有密码文件（0400/0600，单行，至少含一个非十六进制字符，如以 Db! 开头加随机串）及 PG_CA。纯十六进制密码会被此版 EclipseLink 当作密文。bd09 使用交付的 JDK 17 和 pgJDBC 42.7.7，在 TLS 会话的单个事务中检查空库、导入 DDL 并校验 schema 版本与 Quartz 表。自动化在空 schema 中导入 DDL 并配置 Server，**走自动化时跳过第 4 节的手工导表、setup 和 reset**。按 site.env 的 API_NETRC 在 bd09 设置 root 专有的 curl netrc，machine 与 API_BASE 一致，首次启动在受限网络使用 Ambari 初始账号，轮换后同步更新该文件。
3. 为数据面在两个 NameNode 安装并验证生产 fencing 密钥及对端授权，实际检查隔离手段。两个 Hive 节点配可信 CA、HMS 服务身份可读的 JCEKS，别名 javax.jdo.option.ConnectionPassword，按 production/site.example.json 填写路径；密码文件由现场密钥管理提供。磁盘按 UUID 挂载并在每台执行 check-node.sh。按 production/ 下的说明核对初始化的空盘、数据库和系统服务状态。
4. 从交付根目录依次运行下列命令。`preflight` 会生成可重复比对的十节点快照，验证 SSH、DNS、EL7 版本和两层摘要。换参数时选新的 SNAPSHOT 路径。`packages` 复用逐角色的离线安装程序。`management` 在 bd09 接入 PostgreSQL、配置 JDK、启动 Server、注册十个 Agent，并通过 API 等待全部 HEALTHY。`data` 分发快照，由 systemd 管理各角色的运行状态。也可将四阶段替换为 `all`。运行用户需要能创建 SNAPSHOT 目录。

```bash
bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env preflight
bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env packages
bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env management
bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env data
```

各阶段支持对同一快照重跑。管理面脚本只对空 public schema 导入一次；标记保存在 bd09 的 /var/lib/bigtop-deploy/ambari。若在数据库提交与写标记之间中断，脚本会因已有表而停止。请先核实数据库实例、schema 与原任务日志，在隔离库恢复或由 DBA 完成接管；保留备份及已有数据。已有 Server、不同归属的 Agent 或不同数据库入口需走接管流程。首次 setup 期间 Ambari CLI 会把数据库凭据放入本机命令参数，使用受限维护窗口，控制本机进程可见性。再次运行核验状态并保留密码和数据。

自动部署完成后 Ambari 管理面提供 API 及 Agent 心跳。数据面由交付的 systemd 单元启停。如果需要通过 Ambari 下发和管理数据服务，请为独立部署按第 5 节建集群，在同一服务上只能有一个配置和启停管理方。

## 1. 版本与验收边界

| 层 | 采用的版本或验证点 | 现场工作 |
|---|---|---|
| 操作系统与库 | EL7.9 x86_64，系统 Python 2 继续供 yum 使用。Python 3、distro、rpm 绑定及系统库以 runtime-repo 的逐包 NEVRA 为准 | 在相同基础镜像上离线求解依赖，保存已安装 RPM 差异 |
| 管理面 | Ambari 3.0.0.0-2.compat2.el7，Server 与 Agent 同版。已有三个容器完成 PostgreSQL 建表、启动、单 Agent HEALTHY 及 BIGTOP 3.3.0 API 检查 | 正式 DNS/TLS、十台 Agent、服务生命周期和重启 |
| Java | 管理面实测 Temurin JDK 17.0.21+9；Stack 采用 EL7 OpenJDK 8 devel。固定 JAVA_HOME，核对 java -version 及 RPM release | 分别检查 Ambari Server 和数据进程实际使用的 java 可执行文件 |
| PostgreSQL / JDBC | 管理面注册测试用 PostgreSQL 镜像摘要 e924003122c1459b25ebe2af0f5b8becc8b50ccee1354b304e5ba7ec1e0bb42c；Hive 连接、流复制和恢复另行验证 | 记录 `SHOW server_version;`、驱动版本及 SHA-256。先以相同组合验证 TLS、密码算法及故障切换 |
| 数据面 | Hadoop 3.3.6 在本地模式执行过 WordCount，ZooKeeper 3.7.2 有三节点选举验证，Hive 3.1.3、Spark 3.3.4 有 CLI 检查，Tez 0.10.2 有 JAR 检查 | 实际跑 HDFS/YARN HA、Hive on Tez 与 Spark on YARN |

这些版本是已有证据对应的基线。通用“最低支持版本”须以组件声明与降版实测分别证明，当前未做降版矩阵。包管理器声明的最低依赖可通过 `rpm -qpR 包文件` 查看。CI 的 Python/Maven/Gradle/编译器属于构建机，部署节点只安装运行包。CentOS Linux 7 已结束社区安全维护，需落实补丁来源、负责人和迁移期限。[CentOS 生命周期](https://www.centos.org/centos-linux/) · [管理面验证](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44247038617) · [数据客户端验证](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44248922277)

交付快照含 283 个 EL7 基础/运行 RPM。选定版本包括 glibc 2.17-326.el7_9.3、OpenJDK 8 1.8.0.412.b08-1.el7_9、OpenSSH 7.4p1-23.el7_9、Python 3.6.8-21.el7_9、rpm 4.11.3-48.el7_9 和 yum 3.4.3-168.el7.centos。三个额外运行件随归档交付：`runtimes/jdk17.tar.gz`（Temurin 17.0.21+9）、`runtimes/postgresql.jar`（pgJDBC 42.7.7）、`runtimes/postgres15-image.tar.gz`（载入后为 offline/postgres:15）。脚本将前两项装到 /opt/jdk17 和 /opt/cluster/postgresql.jar，PostgreSQL 服务可由企业已有主备库提供。

## 2. 发布两个内部 yum 源

1. 从可信的交付渠道核对归档和 SHA-256 清单，再解包。单独保留原始归档、原始哈希、NEVRA 清单和来源记录。应用包在 `yum-staging/`，系统运行 RPM 在 `runtime-repo/`，两个目录都应含 `repodata/repomd.xml`。
2. 在发布机复制两个目录至新的快照目录。用组织 RPM 签名键给应用 RPM 签名；运行包保留已核对的 CentOS / EPEL 等发行者签名，逐包用 `rpmkeys --checksig --verbose` 确认签名及摘要。其他签名来源要单独核验全指纹并加入受控信任库。仅有摘要或 NOKEY 不满足发布条件。
3. 签名改变应用 RPM 哈希。用 `createrepo_c --update yum-staging` 重建该副本元数据。如改动 runtime-repo 也重建其元数据。分别对两个 `repodata/repomd.xml` 执行 `gpg --armor --detach-sign --local-user "$REPO_KEY" --output repodata/repomd.xml.asc repodata/repomd.xml`（在各仓库根目录执行）。重新生成并签名企业发布清单，记录原包到签名包的映射。通过 HTTPS 只读发布快照。
4. 所有节点预置企业 CA、公钥文件（使用独立渠道验证指纹）。复制 `ops/cluster.repo.example` 至 `/etc/yum.repos.d/cluster.repo`，替换服务器及快照名。断开公网，停用发行版镜像列表及旧 yum 源，确保 Agent 子进程与交互式 yum 的仓库视图相同。需要完整操作系统重装时另外保留安装 ISO 或已签名的 OS 快照，运行依赖仓库用于这个服务集合。
5. 在干净系统以普通运维流程执行以下命令。首次导入公钥要核对全指纹。每种角色按实际安装成功、服务启动成功验收；只做 makecache 无法证明闭包。若报缺依赖，记录完整包及 soname，回发布机补齐签名 RPM 后生成新快照。

```bash
yum --disablerepo='*' --enablerepo=cluster-app,cluster-runtime makecache
yum --disablerepo='*' --enablerepo=cluster-app,cluster-runtime list available ambari-server 'hadoop_3_3_0*'
yum --disablerepo='*' --enablerepo=cluster-app,cluster-runtime install ambari-agent java-1.8.0-openjdk-devel
# 仅 bd09，冷备时使用相同包及运行环境
yum --disablerepo='*' --enablerepo=cluster-app,cluster-runtime install ambari-server
python3 -c 'import distro,rpm; print(distro.id(), distro.version(), rpm.__file__)'
/usr/lib/jvm/java-1.8.0-openjdk/bin/java -version
```

## 3. 节点准备与角色配置表

```bash
cp ops/hosts.example.csv hosts.csv
# 编辑 hosts.csv 的 fqdn、rack，保留 bd01–bd10 唯一槽位
python3 ops/render-layout.py hosts.csv --nameservice prod > cluster-layout.txt
# 每台运行，参数为该节点必须已挂载的实际文件系统，如 Worker 有两个独立数据盘
bash ops/check-node.sh hosts.csv /data01 /data02
```

配置表包括主机、机架、角色、HDFS/RM/Hive 逻辑配置。管理控制台录入配置时使用真实 FQDN。三台 ZooKeeper 和 JournalNode 分散至三个故障域。两个 NameNode 分开，两个数据库实例分开。五台 Worker 用独立挂载的数据盘，YARN 本地目录另留空间；按实际拓扑配置 Hadoop 机架映射。服务器重启后重新确认 `findmnt`、`chronyc tracking`、正反向 DNS、一致的服务账户 UID/GID、磁盘权限和防止服务在数据盘脱挂时启动的挂载依赖。

初始容量参考：主控 16 核 / 64 GiB，Worker 32 核 / 128 GiB。若每个 Worker 有 6×8 TB 数据盘，五台共 240 TB；按三副本并预留 30%，业务粗算约 56 TB，另扣快照、临时文件和小文件开销。用一台 Worker 离线的工况实测队列容量。以上规格为规划起点，未通过最小硬件压测。

## 4. PostgreSQL、Ambari Server 与十台 Agent

由 DBA 提供 PostgreSQL 稳定写入域名（示例 pg-write.prod.example.internal）、主备、可信 CA 与受限账户。数据库端只允许管理和 Hive 节点入站，分别建立空的 ambari 和 hive 数据库及同名 owner。按现场密码管理流程签发凭据，通过 pg_hba.conf 限制角色、库和来源。DBA 可在 psql 中执行以下建库动作，每个库只执行一次，已有实例先确认角色与库归属。

```sql
CREATE ROLE ambari LOGIN;
\password ambari
CREATE DATABASE ambari OWNER ambari ENCODING 'UTF8' TEMPLATE template0;
CREATE ROLE hive LOGIN;
\password hive
CREATE DATABASE hive OWNER hive ENCODING 'UTF8' TEMPLATE template0;
```

在能读取 Server RPM 所附 DDL 的运维端，用 DBA 批准版本的 psql，设置 `PGHOST` 为写入口、`PGPORT`、`PGSSLMODE=verify-full`、`PGSSLROOTCERT` 和权限 0600 的 pgpass。以 ambari 身份对**全新空业务 schema**执行一次；导入失败先审阅错误，确认是否回滚，再处理。已有生产库须按升级/恢复流程操作。

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction -U ambari -d ambari \
  -f /var/lib/ambari-server/resources/Ambari-DDL-Postgres-CREATE.sql
```

JDK 17 使用发布清单所列的 Linux x64 归档。已注册验证的文件为 `OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz`，SHA-256 为 `8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711`。对经核验的离线归档在新的空目录解包，Server 与冷备节点保持一致。Stack 统一 `/usr/lib/jvm/java-1.8.0-openjdk`；若向导会向 Agent 分发 JDK 或执行检查，在相关主机预置相同路径，避免公网获取。

```bash
# 在交付根目录执行，/opt/jdk17 应尚不存在
echo '8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711  runtimes/jdk17.tar.gz' | sha256sum -c -
mkdir -m 0755 /opt/jdk17
tar -xzf runtimes/jdk17.tar.gz -C /opt/jdk17 --strip-components=1
/opt/jdk17/bin/java -version
ambari-server setup --help
ambari-server setup --java-home=/opt/jdk17 --ambari-java-home=/opt/jdk17 \
  --stack-java-home=/usr/lib/jvm/java-1.8.0-openjdk
```

在交互设置中选择 advanced database / PostgreSQL，输入写入口、端口 5432、库 ambari、schema public 和登录凭据。配置 JDBC 的 TLS 主机校验及受信任 CA，DBA 在连接会话确认 TLS；核对 /etc/ambari-server/conf 和密码文件权限。Hive 所需 PostgreSQL JDBC JAR 按交付锁定值核验，确认 Java 8 可加载；用 `ambari-server setup --jdbc-db=postgres --jdbc-driver=/opt/cluster/postgresql.jar` 登记供 Stack 分发。用 `rpm -ql ambari-server` 对照随包管理面驱动位置，避免同一路径并存多个版本。关于 Server / Stack 的 JDK 参数与 UI 操作见[官方安装指南](https://ambari.apache.org/docs/3.0.0/quick-start/installation-guide/)。

在 bd09 执行 `ambari-server start`、`ambari-server status`。首次登录在受限管理网络完成，立即更换初始管理员口令并配置 HTTPS。所有十台逐台执行 `ambari-agent reset 管理服务正式FQDN`、`ambari-agent start`、`ambari-agent status`。reset 用于未注册的新 Agent，重新绑定已有主机前先核对归属。用浏览器或管理凭据执行 `curl --fail --user admin "$AMBARI_HTTPS/api/v1/hosts?fields=Hosts/host_state"`，核对十个 FQDN 均为 HEALTHY。查看 /var/log/ambari-server/ 和 /var/log/ambari-agent/ 定位错误。

## 5. 通过 Ambari 安装与启用 HA

新建集群选 BIGTOP 3.3.0，在 redhat7 的软件仓库项填写内部 yum-staging 快照，保留已配置的 cluster-runtime。使用手动注册的十台 Agent。选 ZooKeeper、HDFS、YARN、MapReduce2、Tez、Hive、Spark 的实际 Stack 项，导出向导显示的依赖项目并核对仓库。先完成 ZooKeeper → HDFS → YARN/MapReduce，再添加 SQL / Spark。若 Stack 要求清单外依赖，先补仓并重做隔离验收。所有最终配置存入 Ambari，并从操作台下发客户端配置。

1. **ZooKeeper**。bd01–03 各放一个服务端，使用唯一的 myid 1、2、3 和持久化目录。三台的 server 列表一致，仲裁和选举端口通常为 2888/3888。使用每台 zkServer.sh status 核对一个 leader、两个 follower；客户端可在受限测试 znode 写入并读回。
2. **HDFS**。初始 NN 在 bd01，五台 Worker 放 DN。若向导要求临时 SecondaryNameNode，按 HA 转换流程移除。先验证单 NN 的读写，导出配置并备份 fsimage、edits。进入 HDFS 的 Enable NameNode HA；配置逻辑 nameservice、bd02 的备用 NN、三台 JournalNode 和两台 ZKFC。将生成的键值与 cluster-layout.txt 对照，并按站点选择有效的 fencing 方法、受限凭据和超时，实际验证能隔离旧主。指定 NN 元数据、JN edits、DN 多盘路径；两台 NN 使用独立持久化存储。
3. **HA 初始化**。使用向导给出的分阶段命令及其执行主机。由初始 NN 提供已存在的 namespace，先启动多数 JN，按向导在原 NN 初始化共享 edits，在新 NN 执行 bootstrapStandby；在一个 NN 上仅首次初始化该集群 ZKFC 的 ZooKeeper 路径，最后启动两台 NN 和 ZKFC。已有 namespace 禁止重复 format。保存 ClusterID、nameservice、NN ID、命令回显及启动时间。网关的 fs.defaultFS 应为逻辑 URI。[HDFS 3.3.6 QJM](https://hadoop.apache.org/docs/r3.3.6/hadoop-project-dist/hadoop-hdfs/HDFSHighAvailabilityWithQJM.html)
4. **YARN / MapReduce**。bd02 主 RM、bd03 第二 RM 与 JobHistory、bd04–08 为 NM。由 Enable ResourceManager HA 添加第二实例，落地 cluster-layout.txt 的 rm1/rm2 和 ZK 状态存储配置。对每个 rm-id 显式设置 yarn.resourcemanager.webapp.address.rm1/rm2（各节点 :8088）及 yarn.resourcemanager.webapp.https.address.rm1/rm2（各节点 :8090），核对两个实例各自的实际 RPC/Web 地址；启用 NM 的 mapreduce_shuffle、日志聚合和队列容量。运行 yarn node -list 并确认五台 RUNNING。[ResourceManager 3.3.6 HA](https://hadoop.apache.org/docs/r3.3.6/hadoop-yarn/hadoop-yarn-site/ResourceManagerHA.html)
5. **Tez / Hive**。在两个 Hive 节点及提交网关部署客户端。用 Stack 分发 Tez 库到 HDFS，核对 tez.lib.uris 对应文件可由服务与提交用户读取，检查 warehouse、scratch、staging 的拥有者和权限。创建独立 hive 数据库连接，配置 javax.jdo.option.ConnectionURL 指向写入口并启用 verify-full、ConnectionDriverName=org.postgresql.Driver。先让一台 Metastore 初始化 schema；若 Stack 已执行初始化，用 schematool -dbType postgres -info 核验即可，手动初始化仅对空库执行一次。启动两个 HMS 和两个 HS2，客户端对照双 HMS 地址与 ZooKeeper 的 hiveserver2 服务发现命名空间，Hive 执行引擎选 tez。Hive 进程必须能读取 TEZ_CONF_DIR=/etc/tez/conf 中的 tez-site.xml，并包含该目录的 classpath。
6. **Spark on YARN**。使用 bd10 网关提交，配置源自 Ambari 的 HADOOP_CONF_DIR 与 YARN_CONF_DIR，创建 Spark 专用事件日志目录并设置服务读取和作业写入权限。spark.eventLog.enabled=true，spark.eventLog.dir 与 spark.history.fs.logDirectory 指向同一逻辑 HDFS 路径；启动 History Server。启用动态资源分配时另行验证 shuffle 服务或相应保留机制。

## 6. 上线验收与恢复

在专用测试用户及独占的测试目录运行，Kerberos 环境先以该用户 kinit。由管理员逐台核查，故障演练每次仅隔离一个角色，恢复正常、补齐副本后再测下一项。

网关可直接执行 `HDFS_TEST_PARENT=/user/acceptance bash ops/smoke-yarn.sh`，先由管理员创建对应用户的私有目录并授予写权限。脚本检查 HDFS 文件读回摘要，在 YARN 提交 WordCount 并逐行核对结果，在唯一的 HDFS 目录保留输入输出。收集终端中的 application ID、服务日志及留存路径后，由测试用户按保留期清理。

| 操作 | 核对并留存 |
|---|---|
| hdfs haadmin -getServiceState nn1 / nn2；hdfs dfsadmin -report；网关向逻辑 HDFS put/get 并校验 SHA-256 | 恰好一主一备，五个 Live DN；测试文件三副本，fsck 块位置正常；受控停止活动 NN 后客户端由同一逻辑地址读写，旧主无法写入 |
| yarn rmadmin -getServiceState rm1 / rm2；用 hadoop-mapreduce-examples JAR 从 HDFS 输入跑 wordcount 至新 HDFS 目录 | 五台 NM，YARN 产生 application ID，检查结果和聚合日志；启动持续作业后演练 RM 切换，核对作业状态及新作业提交 |
| Beeline 用真实认证连接 jdbc:hive2://三台ZK列表/default;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2 | 在授权测试库建表、插入两组记录并运行带 GROUP BY 的查询，确认 YARN 中生成 Tez DAG；停一台 HS2、HMS 后重连，查询持久表。原 JDBC 会话可能需重建 |
| spark-submit --master yarn --deploy-mode cluster --class org.apache.spark.examples.SparkPi 实际spark-examples.jar 20 | YARN 最终状态 SUCCEEDED、Driver 输出 Pi 值，History Server 可回放；记录应用 ID |
| 禁止身份读写及运维恢复演练 | 检查 Kerberos、HDFS/Hive ACL、审计成功/拒绝事件、TLS 证书过期监控；业务数据导入前完成备份恢复、节点重启及代表性负载压测 |

验证命令在本地执行时应使用 /usr/bigtop/3.3.0/usr/lib 下对应的程序和 JAR；select 链接、/etc/hadoop/conf、Java 8 与实际服务配置须匹配。保存包 NEVRA、配置版本、作业 ID、切换时间、复制延迟及 RTO/RPO 实测。生产防火墙按方向放通：Agent 到 Server（8440/8441）、受限管理入口、ZK 客户端 2181 及 peer 2888/3888、两 NN 到 JN 8485、HDFS/YARN 内部 RPC、NM Shuffle、客户端到 HS2、HS2 到 HMS、管理/HMS 到数据库、KDC/DNS/时间源。实际端口和动态端口范围以最后生效配置为准。服务身份启用 Kerberos，数据库与外部连接校验证书；Ranger 等附加产品须另行备包、锁版和验收。

数据库做定期基础备份及 WAL 归档、检验恢复到指定时间点。故障时先隔离旧主并核查回放位置，再由 DBA 提升单个备库，更新稳定写入入口，验证 Ambari 心跳和 Hive 写入。管理面冷备需保留同版 RPM、JDK、/etc/ambari-server/conf、Server 密钥证书、credential store、数据库、Stack 修改及签名仓库。只允许一个可写 Ambari Server，隔离 bd09 后才在替代节点恢复；沿用正式管理域名与匹配证书。保存 NN、JournalNode、ZK 快照及事务日志，重要业务数据另存离集群副本。演练在隔离环境还原；线上异常保留原始目录、日志和快照，禁止以重新格式化 NN 或清空 ZooKeeper 作为恢复方式。
