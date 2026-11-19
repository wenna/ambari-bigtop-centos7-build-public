# Ambari 与 Bigtop 离线安装手册

适用于 **CentOS Linux 7.9.2009 x86_64** 上的新建集群。安装器按主机清单中的角色部署，总台数没有预设上限。可用同一份软件包生成 20 台、100 台或其他规模的配置。每行是一台服务器，空角色行安装客户端与 Ambari Agent。容量取决于主机、故障域、磁盘、网络、数据库和业务负载。

## 下载和安装入口

用有草稿访问权限的 GitHub 账号下载同一版的两个分卷、`SHA256SUMS` 和 `kit-manifest.sha256`。在空目录核验后，将交付目录通过只读共享盘或受控文件分发放到每个节点相同的 `KIT_ROOT`。预留下载和解包空间（管理机建议至少 8 GiB），软件目录仅允许受信维护账户写。保存发布页、两份清单和版本标签。

```bash
sha256sum -c SHA256SUMS
mkdir kit
cat ambari-bigtop-el7.tar.part-* | tar xf - -C kit
(cd kit && sha256sum -c ../kit-manifest.sha256 && sha256sum --quiet -c SHA256SUMS)
cd kit
install -d -m 0700 /etc/bigtop-deploy
cp ops/site.env.example /etc/bigtop-deploy/site.env
cp production/site.example.json /etc/bigtop-deploy/site.json
# 例如 20 台；100 台改成 --nodes 100。仅在新建清单时执行。
python3 ops/generate-inventory.py --nodes 20 --domain prod.example.internal > /etc/bigtop-deploy/hosts.csv
```

按下面三节填写参数并完成现场准备。在能连接每台主机的 Linux 管理机，从交付根目录运行一键安装：

```bash
bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env all
```

`all` 依次执行现场预检、离线 RPM 安装、管理面注册、数据服务初始化和就绪检查。设置 `PREPARE_OS=1` 时会先执行已选择的主机准备动作。可分步运行 `prepare`、`preflight`、`packages`、`management`、`data`。第一次上线宜先用 `production/start-cluster.sh --action plan` 核对目标，再运行 `all`。最终数据服务由 systemd 管理，Ambari 提供 Server、Agent、API 和心跳。如要用 Ambari 作为数据服务的配置及生命周期管理者，应在独立环境走 BIGTOP Stack 的建群流程，避免两个管理工具同时启停同一个进程。

## 1. 主机清单和站点参数

`ops/hosts.example.csv` 是可编辑的四列示例。生成器生成的 20 台示例含 3 台控制节点、2 台 SQL/管理节点和 15 台 Worker；100 台示例含 95 台 Worker。请按真实服务器及机架调整角色。生成器的示例布局至少需要 8 台，手工清单可以采用满足下列 HA 条件的其他布局。

| CSV 字段 | 填写方式 |
|---|---|
| slot | 站点内唯一、稳定的小写标识，例如 ctrl-a、worker-017。使用 DNS 标签字符。 |
| fqdn | 每台主机的唯一小写完整域名。须与该机 hostname -f 相同，所有节点可解析。 |
| rack | 真实故障域，例如 rack-c。三台仲裁成员尽可能分散到不同机架。 |
| roles | 在同一字段以空格列出角色，例如 datanode nodemanager。主机可合置多个角色。 |

| 角色 | 拓扑条件 |
|---|---|
| namenode、zkfc | 两台 NameNode，每台同机配置一个 ZKFC |
| resourcemanager | 两台 RM |
| journalnode、zookeeper | 两组分别为至少三台的奇数仲裁成员，两组可独立选址 |
| datanode、nodemanager | 三副本需要至少三台 DN；至少一台 NM。两组可分别部署 |
| metastore、hiveserver2 | 各至少一台；需要服务冗余时分别配置多台 |
| jobhistory、sparkhistory、ambari-server | 各一台，可按容量与其他角色合置 |

同一角色内按 slot 字典序分配 nn1/nn2、rm1/rm2 和 ZooKeeper myid。清单行顺序不影响这些标识。已部署集群的控制节点 slot、主机名和持久目录必须保留。此包支持以任意规模**新建**环境；在线给已有集群增删节点、迁移控制角色或重分配 myid，应按单独变更流程实施。

| 文件 | 需确认或修改的参数 |
|---|---|
| site.env | SSH_USER、SSH_PORT、SSH_IDENTITY_FILE、SSH_KNOWN_HOSTS；各节点的 KIT_ROOT、MANIFEST_SHA256（发布的 kit-manifest.sha256 第一列）；控制机的 INVENTORY、DATA_SITE、SNAPSHOT 路径 |
| site.env 主机准备 | PREPARE_OS、BOOTSTRAP_INVENTORY、SET_HOSTNAME、MANAGE_ETC_HOSTS；站点 NTP_SOURCES、MAX_CLOCK_OFFSET_SECONDS；REQUIRED_MOUNTS、WORKER_MOUNTS 和各挂载点最低可用 MIN_FREE_MIB |
| site.env 管理面 | 从 ambari-server 角色确定 Server。可用 AMBARI_FQDN 再次核对；填写 PG_HOST、PG_PORT、PG_DATABASE、PG_USER、PG_CA、PG_PASSWORD_FILE、API_BASE、API_NETRC |
| site.json 存储和身份 | nameservice、state_dir、datanode_dirs、nm_local_dirs、log_dir、run_dir、fence_user、fence_port、fence_key、accounts、proxy_groups |
| site.json 计算和 SQL | nm_memory_mb、nm_vcores、task_memory_mb、tez_archive、pg_url、pg_user、hms_keystore；node_overrides 可按 slot 覆盖个别机器的数据盘、YARN 本地盘、NM 内存和核数 |

站点文件保存在软件包外部。site.env 是可执行的 Bash 配置，只允许受信维护账号写。数值以物理资源减去操作系统和常驻进程预留量后填写。站点统一的挂载预检列表应只列同类机器共有的挂载点；不同盘型的机器另外逐机执行 `bash ops/check-node.sh /etc/bigtop-deploy/hosts.csv /实际挂载点`，清单需在该机可读。示例异构覆盖：

```json
"node_overrides": {
  "worker-017": {
    "datanode_dirs": ["/disk3/hdfs/data", "/disk4/hdfs/data"],
    "nm_local_dirs": ["/disk3/yarn/local", "/disk4/yarn/local"],
    "nm_memory_mb": 65536,
    "nm_vcores": 20
  }
}
```

## 2. 安装前准备

**操作系统与数据盘。** 在所有机器检查发行版、架构、系统管理器、依赖包和磁盘健康。基础镜像需自带可用的 Bash、sshd、sudo、rpm/yum、coreutils、iproute、util-linux 和系统 Python；管理机需 Python 3.6+ 和 OpenSSH 客户端。保留 CentOS 系统 Python 2 供 yum 使用。确认文件系统容量、inode、读写权限、云盘设备身份和故障域；按 UUID 配置 /etc/fstab 并验证重启后的挂载。准备程序保留已有分区和数据。根盘、业务盘、YARN 临时盘可按角色独立规划。

```bash
cat /etc/centos-release
uname -m
ps -p 1 -o comm=
lsblk -f
findmnt --verify
df -hPT
df -i
free -m
getenforce
systemctl is-active firewalld
```

**主机名与解析。** 在管理机和各节点配置正向解析，使用机架映射和数据库证书校验时同时检查反向解析及 SAN。多网卡主机填写集群内部能够双向通信的地址。已有平台托管 DNS、cloud-init 或 NetworkManager 时先确定配置归属，确保重启后名称不被改回。两种准备方式：

- 站点已有标准镜像时，保持 `PREPARE_OS=0`。如需手工改名，在**对应新机**执行 `hostnamectl set-hostname 实际FQDN`，配置 DNS 或 /etc/hosts，然后运行 `hostname -f`、`getent ahosts 实际FQDN` 核对。
- 在全新主机启用 `PREPARE_OS=1`，准备表头为 `slot,address` 的 `bootstrap.csv`，每台主机填一个实际的本机管理地址。按需设置 `SET_HOSTNAME=1`、`MANAGE_ETC_HOSTS=1`；控制机也必须能解析最终 FQDN。准备程序先检查整批映射、已安装集群与文件冲突，随后按主机更新并留存备份。已受管机器的改名或 IP 迁移走独立变更流程。

**免密登录。** 管理机的部署账号需能以公钥登录所有目标并执行 `sudo -n`。两台 NameNode 另外需要服务身份用于 fencing 的双向 SSH。两种身份分别授权。首次公钥分发和主机指纹由站点管理员或镜像系统完成。可用如下方式在管理机验证一台主机，再对清单逐台执行：

```bash
# 使用专用 Ed25519 或现场批准的 RSA 密钥，可用 ssh-agent 解锁受密码保护的私钥。
ssh-keygen -t ed25519 -f ~/.ssh/bigtop-deploy
# 先通过控制台或资产系统核对服务器 host key 指纹，再写入受信 known_hosts。
ssh-copy-id -p 22 -i ~/.ssh/bigtop-deploy.pub clusterops@实际FQDN
ssh -p 22 -i ~/.ssh/bigtop-deploy -o BatchMode=yes -o StrictHostKeyChecking=yes \
  clusterops@实际FQDN 'hostname -f; sudo -n id -u'
```

输出应包括预期 FQDN 和 UID 0。准备模式用 IP 首次连接、随后用 FQDN，两个目标都要建立主机信任；非标准端口的 known_hosts 条目使用 `[主机]:端口`。私钥权限 0600，控制机不得把部署私钥复制到整个集群。已有统一运维平台可通过 SSH 配置管理堡垒机和认证策略。HDFS 的 sshfence 使用独立的服务密钥和两台 NameNode 之间的连接，须按生产配置说明单独核验。

**时钟同步。** NTP_SOURCES 填企业批准的 NTP 主机名或地址，各节点可访问 UDP 123。若已有 chronyd 同步，填写允许偏差（秒）后直接跑 preflight。全新最小镜像可启用 prepare 自动离线安装 chrony、配置时间源并等待同步。也可单独执行 time-packages，再按企业规范配置 /etc/chrony.conf 中的 server 条目和 chronyd 服务。在有 ntpd、配置集中下发或时差很大的机器上先协调切换窗口。核对 `chronyc -n sources -v` 的已选源和 `chronyc tracking` 的校正值；机器时区按企业规范统一。

**网络与安全策略。** 核对所有角色间的路由、机房 ACL、容器与主机防火墙、出入站方向、SELinux AVC 和站点证书。保持现场安全策略，按需添加最小放通规则。常用路径如下，具体监听以生成的 XML、站点策略和实际进程为准：

| 来源 → 目的 | 用途与常用 TCP 端口 |
|---|---|
| 管理机 → 节点；NameNode ↔ NameNode | 运维 SSH；HDFS fencing SSH（模板默认 22） |
| Agent → Ambari Server；运维终端 → 管理入口 | 8440/8441、8080 或站点 HTTPS |
| 服务/客户端 → ZooKeeper；仲裁成员之间 | 2181、2888/3888 |
| NameNode → JournalNode；客户端/Worker → HDFS | 8485、8020、9866/9867、9870 等配置端口 |
| Worker/客户端 → RM；任务与 NM、Shuffle、历史服务 | RM 8030–8033、Web 8088/8090，NM 8042、Shuffle 13562、JobHistory 10020/19888；按站点策略规划容器间通信 |
| SQL 客户端 → HS2 → HMS → PostgreSQL；Spark History | 10000、9083、PG_PORT（默认 5432）、18080 |

**数据库、密钥与权限。** DBA 提供两个独立空库及 owner、可写端点、受信任 CA、备份和恢复流程。管理库使用 PG_* 参数，Hive 库使用 site.json 中的 `pg_url` 与 `pg_user`。随包 PostgreSQL 15 镜像可用于隔离验收；企业主备与恢复由 DBA 配置，详见 `ops/postgres-container.md`。示例 DBA 命令如下，执行前确认连接的实例和库归属。

```sql
CREATE ROLE ambari LOGIN;
\password ambari
CREATE DATABASE ambari OWNER ambari ENCODING 'UTF8' TEMPLATE template0;
CREATE ROLE hive_catalog LOGIN;
\password hive_catalog
CREATE DATABASE hive OWNER hive_catalog ENCODING 'UTF8' TEMPLATE template0;
```

在 Ambari Server 节点预置 PG_CA、root 所有且模式 0400/0600 的数据库单行密码文件和 curl netrc。此版本使用 EclipseLink，密码需包含非十六进制字符。netrc 的 machine 与 API_BASE 相符；首次启用应限制管理入口，轮换管理员密码后同步更新该文件。每台 Metastore 预置站点 CA 和 Hive 身份可读的 JCEKS，别名 `javax.jdo.option.ConnectionPassword`。HDFS fencing 私钥仅分发到两个 NameNode，现场验证对端授权、host key、fuser 和 nc。详见 `production/README.md`。如需先创建服务账号、JCEKS 或利用随包 Hadoop 命令安装密钥，先执行 packages 阶段，再补齐凭据后执行 all。

## 3. 预演、一键执行与重试

```bash
python3 ops/render-layout.py /etc/bigtop-deploy/hosts.csv --site /etc/bigtop-deploy/site.json
bash production/start-cluster.sh --inventory /etc/bigtop-deploy/hosts.csv \
  --site /etc/bigtop-deploy/site.json --snapshot /var/lib/bigtop-deploy/site-001 --action plan
# 已准备好主机时可以先单独检查
bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env preflight
# 从管理机安装所有列入清单的节点。需要保留日志时使用 pipefail。
set -o pipefail
bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env all 2>&1 | tee bigtop-install.log
```

preflight 检查目标系统、名称解析、SSH、sudo、交付摘要、系统包冲突、预期挂载、磁盘余量和 chrony 同步。发现问题保留主机、阶段和错误，修正根因后复用原参数。SELinux/防火墙状态会报告，仍需按真实流向检查连通性。确认已有 Hadoop、HDP/CDH、受管 Ambari、ZooKeeper、yum 事务、数据库对象和服务端口的归属；已有数据需要先备份并按迁移或接管流程操作。分阶段失败后不得清空 NN、JN、DN、ZK 或数据库目录来绕过保护。

packages 只从经摘要核验的本地 file:// 应用仓和保留发行者签名的 runtime-repo 安装角色包。管理脚本在 TLS 事务内初始化新库并等待清单内全部 Agent HEALTHY。数据阶段按清单创建角色单元、初始化 HA、准备 HDFS 目录与 Tez 库，再启动 Hive 和 Spark History。相同站点输入可核对已有快照；输入漂移会被拒绝。生产配置迁移先生成新快照并审阅差异，不能用新槽位直接覆盖既有持久状态。

## 4. 来源、版本与现场验收

发行包包括 60 个应用 RPM、283 个 CentOS/EPEL 基础及运行 RPM，另含 Temurin 17.0.21+9、pgJDBC 42.7.7、PostgreSQL 15 镜像。Hadoop/Hive/Tez/Spark 使用 EL7 OpenJDK 8；保留系统 yum 使用的 Python。分角色依赖、最低版本约束和实测版本分别见 `manifests/application-rpm-requires.txt`、`manifests/runtime-versions.tsv`、`DEPENDENCIES.zh-CN.md`。企业镜像可参考 `ops/cluster.repo.example`，在单独的快照副本上做 RPM/仓库签名并记录新摘要。CentOS 7 已结束社区维护，站点需落实持续补丁来源和迁移计划。

| 验收 | 核对和留档 |
|---|---|
| 管理面 | 清单中全部 FQDN、相同版本 Agent、API HEALTHY；重启后重新注册，确认管理员权限和证书 |
| HDFS | 两 NN 一主一备；用逻辑 URI 读写同一文件并比对摘要；Live DN 集合、机架与清单一致；受控故障后复查副本与 fencing |
| YARN / MapReduce | 核对 RM 互备、RUNNING NM 集合、队列；网关用测试用户运行 `HDFS_TEST_PARENT=/user/acceptance bash ops/smoke-yarn.sh`。核实在途任务跨 RM 切换成功 |
| Hive on Tez / Spark on YARN | Beeline 经 HS2 访问持久表并执行有 GROUP BY 的查询；在 YARN 核对相应 Tez DAG。Spark 以 cluster 模式提交，核对应用 ID、最终状态与 HDFS 输出 |
| 生产投运 | 磁盘和机架故障、真实业务并发、队列隔离、服务开机自启；备份及恢复 Ambari、Hive、ZK、HDFS 和 PostgreSQL/WAL；核验安全审计、容量、RTO/RPO |

`evidence/` 保存验收证据。容器测试覆盖管理面心跳、HDFS/RM 切换与实际 SQL/Spark 作业；软件没有固定总主机数，容量和现场容灾仍以自身压测结果为准。默认数据面使用 Hadoop simple 认证。多租户或需要强身份认证的生产环境须先接入站点 Kerberos、TLS、ACL 和审计，并做允许/拒绝双向验证。
