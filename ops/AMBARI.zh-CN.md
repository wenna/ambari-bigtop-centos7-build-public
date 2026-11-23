# 先安装 Ambari，再由 Ambari 安装 BIGTOP 3.3.0

适用对象为新建 CentOS Linux 7.9.2009 x86_64 主机。现有数据和集群迁移需单独规划。此前 `el7-operations-44467569272` 的 `all` 阶段由外部脚本管理数据服务。生产选用 Ambari 管理时，使用包含本手册、`ops/ambari-stack-el7.py` 和签名 `unzip` RPM 的原生安装交付包。

在新的下载目录获取同一版本的全部附件，先校验分卷，再核对归档中的文件清单。

```bash
sha256sum -c SHA256SUMS
mkdir kit && cat ambari-native-el7.tar.part-* | tar xf - -C kit
(cd kit && sha256sum -c ../kit-manifest.sha256 && sha256sum --quiet -c SHA256SUMS)
```

## 1. 准备主机和数据库

从[现场配置与安装操作单](FIELD-SETUP.zh-CN.md) 复制模板，填好现场参数，以已有普通管理账号运行 `bootstrap-access.sh` 完成部署账号、公钥和非交互授权。完成该操作单第 1–3 节后，本手册第 2 节的管理面安装命令即可使用。

按 `ops/README.md` 的安装前准备核对每台主机的 FQDN、机架、免密 SSH、sudo、NTP、挂载点和防火墙。将解包并校验过的同一份软件挂载到所有节点的 `KIT_ROOT`。服务器上的 yum 在 Ambari 任务中使用系统的仓库设置。由现场管理员停用已失效的 CentOS 7 镜像和会提供同名 RPM 的其他仓库，以 `yum repolist enabled` 和 `yum list --showduplicates` 核对实际来源。应用 RPM 通过交付摘要验证，系统依赖保留 CentOS/EPEL 签名。

准备两个独立的 PostgreSQL 库及账号，管理库供 Ambari，Hive 库供 Metastore。预置数据库 CA、管理库口令文件、Ambari API 的 netrc 凭据，以及两个 NameNode 所需的双向 SSH fencing 密钥。数据库 TLS 地址的域名须与证书相符。以下命令在可信部署账户下运行，密码文件仅其所有者可读。

沿用现场操作单已经填写并审核的 `hosts.csv`、`site.env`、`site.json` 和 `web-install.json`。原生 Stack 使用 `/bigtop/apps/3.3.0/tez/tez.tar.gz`。后续步骤均在已校验的 kit 根目录执行。

## 2. 只安装 Ambari 管理面

在部署机的交付根目录执行：

```bash
bash ops/deploy-cluster.sh $HOME/bigtop-deploy/site.env ambari
```

这个阶段在清单中标记 `ambari-server` 的节点安装 Server，在每个节点安装 Agent，使用 Java 17 启动管理面，保留 Java 8 给数据服务。脚本在 Server 首次启动前设置 EL7 的 BIGTOP 服务 RPM 清单，连接 PostgreSQL 并等待清单中的全部 Agent 注册为 `HEALTHY`。首次登录后在受限管理网中轮换管理员密码，同步更新 API netrc。记录管理节点地址、服务账号和证书。

## 3. 通过 Ambari 下发服务安装

完成第 2 节后，请选择一种新建集群方式。使用浏览器时，直接转到下方“使用 Ambari Web 向导”。使用清单自动映射角色时，执行以下 Blueprint 命令。两种方式仅需提交一种。

在 Ambari Server 上准备 `$HOME/bigtop-deploy/hosts.csv`、填好的 `site.json`、Hive 库口令文件 `hive-db.password` 和该机的 `ambari.netrc`，并进入本机的交付根目录。下面使用 loopback API；启用了 HTTPS 时改成有受信证书的地址。仓库 URL 应能从所有 Agent 访问。示例的 file URL 要求每台主机使用完全一致的只读挂载路径；也可填写内部 HTTP(S) 仓库地址。

```bash
umask 077
s=$HOME/bigtop-deploy
chmod 600 "$s/hive-db.password" "$s/ambari.netrc"
python3 ops/ambari-blueprint.py --inventory "$s/hosts.csv" --site "$s/site.json" \
  --blueprint prod-bigtop --hive-password-file "$s/hive-db.password" --out "$s/native"
bash ops/ambari-provision.sh http://localhost:8080 "$s/ambari.netrc" prod prod-bigtop \
  "$s/native/blueprint.json" "$s/native/cluster.json" file:///srv/bigtop-kit/yum-staging --state-dir "$s/native-state"
```

蓝图依据 slot、机架、角色和容量生成主机映射。`blueprint.json` 可以审阅。`cluster.json` 包含 Hive 密码，请限制访问，勿上传到工单、Git 或日志。控制器向 Ambari 注册本地仓库版本、蓝图和集群，然后等待 Ambari 的请求完成。登录 Web UI，打开 **后台操作** 查看各主机的 INSTALL、START 和日志，再到 **Services** 查看 HDFS、YARN、MapReduce2、ZooKeeper、Hive、Tez、Spark。客户端组件通常为 `INSTALLED`，服务进程应为 `STARTED`。Timeline 的两个可选组件按蓝图只安装。

### 使用 Ambari Web 向导

浏览器建群的操作步骤、参数和验收记录见交付目录的 `ops/WEB-INSTALL.zh-CN.md`。仓库中也可直接阅读[页面向导手册](WEB-INSTALL.zh-CN.md)。请先完成主机、数据库和管理面的准备，再从 **Launch Install Wizard** 进入。

## 4. 复查和恢复

**Hive 驱动核对。** Hive 3.1 的 schematool 在独立 JVM 中运行，会从自己的 lib 目录加载驱动。安装器将交付的 pgJDBC 42.7.7 放入该目录，保留旧 RPM 驱动文件名以兼容已有脚本。用文件名判断版本容易误判。在 Metastore 主机执行以下检查，三个摘要应与交付驱动一致（SHA-256 为 157963d60ae66d607e09466e8c0cdf8087e9cb20d0159899ffca96bca2528460）。数据库继续使用 SCRAM 和证书校验。

```bash
sha256sum /opt/cluster/postgresql.jar /usr/bigtop/3.3.0/usr/lib/hive/lib/postgresql{,-9.4.1208.jre7}.jar
bash ops/check-hive-driver.sh
```

**作业与切换。** Ambari Web 的 Hive 和 Spark 服务检查通过后，另用业务测试账号执行带 GROUP BY 的 Hive 查询和 Spark cluster 模式作业，核对 YARN 应用编号和 HDFS 输出。安排停机演练时记录活动 NN/RM、停机时刻、对端接管时刻和原节点恢复备用状态的时刻。普通业务账号运行作业，HA 管理命令使用获授权的 HDFS 和 YARN 身份。

同一命令追加 `--check` 可读取组件状态，不下发新任务。控制器在 `$HOME/bigtop-deploy/native-state/集群名` 保留请求编号；在管理进程中断后复用相同输入可继续等待。Ambari 报错时，在后台操作中记录请求、任务、主机和首个错误，在解决缺包、文件权限、数据库或名称解析问题后于 Ambari 内重试。保留已有 NameNode、JournalNode、ZooKeeper 和元数据库的数据目录。

生产验收应留存两台 NN 和 RM 的状态、真实的 HDFS 读写、YARN 作业、Hive on Tez 查询及 Spark on YARN 输出，再做现场故障切换。当前熟悉的 20/100 Agent 心跳验收仅覆盖管理面。此配置默认采用 Hadoop simple 认证。开启多租户前需要按站点要求配置 Kerberos、TLS 和授权，并验证允许与拒绝访问的结果。
