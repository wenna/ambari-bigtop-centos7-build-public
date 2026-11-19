# 先安装 Ambari，再由 Ambari 安装 BIGTOP 3.3.0

适用对象为新建 CentOS Linux 7.9.2009 x86_64 主机。现有数据和集群迁移需单独规划。此前 `el7-operations-44467569272` 的 `all` 阶段由外部脚本管理数据服务。生产选用 Ambari 管理时，使用包含本手册、`ops/ambari-stack-el7.py` 和签名 `unzip` RPM 的原生安装交付包。

在新的下载目录获取同一版本的全部附件，先校验分卷，再核对归档中的文件清单。

```bash
sha256sum -c SHA256SUMS
mkdir kit && cat ambari-native-el7.tar.part-* | tar xf - -C kit
(cd kit && sha256sum -c ../kit-manifest.sha256 && sha256sum --quiet -c SHA256SUMS)
``` 

## 1. 准备主机和数据库

按 `ops/README.md` 的安装前准备核对每台主机的 FQDN、机架、免密 SSH、sudo、NTP、挂载点和防火墙。将解包并校验过的同一份软件挂载到所有节点的 `KIT_ROOT`。服务器上的 yum 在 Ambari 任务中使用系统的仓库设置。由现场管理员停用已失效的 CentOS 7 镜像和会提供同名 RPM 的其他仓库，以 `yum repolist enabled` 和 `yum list --showduplicates` 核对实际来源。应用 RPM 通过交付摘要验证，系统依赖保留 CentOS/EPEL 签名。

准备两个独立的 PostgreSQL 库及账号，管理库供 Ambari，Hive 库供 Metastore。预置数据库 CA、管理库口令文件、Ambari API 的 netrc 凭据，以及两个 NameNode 所需的双向 SSH fencing 密钥。数据库 TLS 地址的域名须与证书相符。以下命令在可信部署账户下运行，密码文件仅其所有者可读。

生成 `hosts.csv` 并按真实角色调整。复制 `ops/site.env.example` 和 `production/site.example.json`，在 `site.env` 填清单路径、交付摘要、磁盘、SSH、时钟、管理库和 API 参数。在 `site.json` 配置 nameservice、Hive 数据库 JDBC、磁盘和 YARN 资源。本版原生 Stack 默认上传 Tez 到 `/bigtop/apps/3.3.0/tez/tez.tar.gz`，请将 `tez_archive` 设为该路径。

```bash
install -d -m 0700 /etc/bigtop-deploy
python3 ops/generate-inventory.py --nodes 20 --domain prod.example.internal > /etc/bigtop-deploy/hosts.csv
cp ops/site.env.example /etc/bigtop-deploy/site.env
cp production/site.example.json /etc/bigtop-deploy/site.json
```

## 2. 只安装 Ambari 管理面

在部署机的交付根目录执行：

```bash
bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env ambari
```

这个阶段在清单中标记 `ambari-server` 的节点安装 Server，在每个节点安装 Agent，使用 Java 17 启动管理面，保留 Java 8 给数据服务。脚本在 Server 首次启动前设置 EL7 的 BIGTOP 服务 RPM 清单，连接 PostgreSQL 并等待清单中的全部 Agent 注册为 `HEALTHY`。首次登录后在受限管理网中轮换管理员密码，同步更新 API netrc。记录管理节点地址、服务账号和证书。

## 3. 通过 Ambari 下发服务安装

在 Ambari Server 上准备 `/etc/bigtop-deploy/hosts.csv`、填好的 `site.json`、Hive 库口令文件 `hive-db.password` 和该机的 `ambari.netrc`，并进入本机的交付根目录。下面使用 loopback API；启用了 HTTPS 时改成有受信证书的地址。仓库 URL 应能从所有 Agent 访问。示例的 file URL 要求每台主机使用完全一致的只读挂载路径；也可填写内部 HTTP(S) 仓库地址。

```bash
umask 077
s=/etc/bigtop-deploy
chmod 600 "$s/hive-db.password" "$s/ambari.netrc"
python3 ops/ambari-blueprint.py --inventory "$s/hosts.csv" --site "$s/site.json" \
  --blueprint prod-bigtop --hive-password-file "$s/hive-db.password" --out "$s/native"
bash ops/ambari-provision.sh http://localhost:8080 "$s/ambari.netrc" prod prod-bigtop \
  "$s/native/blueprint.json" "$s/native/cluster.json" file:///srv/bigtop-kit/yum-staging
```

蓝图依据 slot、机架、角色和容量生成主机映射。`blueprint.json` 可以审阅。`cluster.json` 包含 Hive 密码，请限制访问，勿上传到工单、Git 或日志。控制器向 Ambari 注册本地仓库版本、蓝图和集群，然后等待 Ambari 的请求完成。登录 Web UI，打开 **后台操作** 查看各主机的 INSTALL、START 和日志，再到 **Services** 查看 HDFS、YARN、MapReduce2、ZooKeeper、Hive、Tez、Spark。客户端组件通常为 `INSTALLED`，服务进程应为 `STARTED`。Timeline 的两个可选组件按蓝图只安装。

## 4. 复查和恢复

同一命令追加 `--check` 可读取组件状态，不下发新任务。控制器在 `/var/lib/bigtop-deploy/native/集群名` 保留请求编号；在管理进程中断后复用相同输入可继续等待。Ambari 报错时，在后台操作中记录请求、任务、主机和首个错误，在解决缺包、文件权限、数据库或名称解析问题后于 Ambari 内重试。保留已有 NameNode、JournalNode、ZooKeeper 和元数据库的数据目录。

生产验收应留存两台 NN 和 RM 的状态、真实的 HDFS 读写、YARN 作业、Hive on Tez 查询及 Spark on YARN 输出，再做现场故障切换。当前熟悉的 20/100 Agent 心跳验收仅覆盖管理面。此配置默认采用 Hadoop simple 认证。开启多租户前需要按站点要求配置 Kerberos、TLS 和授权，并验证允许与拒绝访问的结果。
