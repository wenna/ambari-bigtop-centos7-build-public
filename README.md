# Ambari 3.0.0 / Apache Bigtop 3.3.0 on CentOS 7.9 x86_64

## 通过 Ambari 安装 BIGTOP

在 CentOS 7.9 x86_64 新建集群上，先部署 Ambari Server 和 Agent，再由 Ambari 安装并管理 BIGTOP 服务。[离线运维包（草稿）](https://github.com/wenna/ambari-bigtop-centos7-build-public/releases/tag/untagged-fd5f6235b2f548e4ab24) · [原生安装手册](ops/AMBARI.zh-CN.md)。[三节点完整验收](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44569426175)通过全部七项服务检查、NameNode 和 ResourceManager 主备切换、HDFS 读写、WordCount、Hive on Tez 和 Spark on YARN。现场的容量和容灾目标需要在目标环境验证。

## 可变节点数的离线运维包（systemd 管理数据服务）

面向新建 CentOS Linux 7.9.2009 x86_64 集群。每台服务器在清单中指定角色和机架，可按节点覆盖磁盘、内存与 vCore。当前草稿为 [el7-operations-44467569272](https://github.com/wenna/ambari-bigtop-centos7-build-public/releases/tag/untagged-551c6355d1c8078330b1)。使用有草稿访问权的 GitHub 账号下载：

```bash
gh release download el7-operations-44467569272 -R wenna/ambari-bigtop-centos7-build-public -D delivery
cd delivery
sha256sum -c SHA256SUMS
mkdir kit && cat ambari-bigtop-el7.tar.part-* | tar xf - -C kit
(cd kit && sha256sum -c ../kit-manifest.sha256 && sha256sum --quiet -c SHA256SUMS)
```

按[现场操作手册](ops/README.md)准备 SSH、FQDN、时钟、磁盘、数据库和凭据，在 `hosts.csv`、`site.env`、`site.json` 填写站点值。从交付根目录运行 `bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env all`。两个离线 YUM 仓库含 60 个应用 RPM 和 283 个运行依赖 RPM，包内另附 JDK、PostgreSQL 镜像、JDBC 驱动、配置模板、构建源码快照及依赖清单。

[20 和 100 个 Agent 容器的注册验收](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44455375014)覆盖重复初始化和全部主机 HEALTHY。[六容器数据服务验收](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44347128227)覆盖 HDFS fencing、YARN 在途作业切换、Hive on Tez 和 Spark on YARN。[本版打包记录](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44467569272)包含新清单和预检测试、两个分卷及其中每个文件的校验。现场仍需验证真实磁盘、网络、负载及故障域。

## 历史版本（十节点离线运维包）

[运维交付草稿 el7-operations-44349066611](https://github.com/wenna/ambari-bigtop-centos7-build-public/releases/tag/untagged-aef804c2bcd10519bdf1) 包含两个 YUM 仓库、60 个应用 RPM、283 个运行依赖 RPM、JDK 17、pgJDBC、PostgreSQL 15 镜像、配置模板与部署脚本。两个分卷共 1,949,511,680 字节。登录有草稿访问权的账号下载所有附件：

```bash
gh release download el7-operations-44349066611 -R wenna/ambari-bigtop-centos7-build-public -D delivery
cd delivery && sha256sum -c SHA256SUMS
mkdir kit && cat ambari-bigtop-el7.tar.part-* | tar xf - -C kit
(cd kit && sha256sum -c ../kit-manifest.sha256 && sha256sum --quiet -c SHA256SUMS)
```

现场入口为 `kit/INSTALL.zh-CN.md` 和 `kit/ops/deploy-cluster.sh`。该版本随包手册给出数据库、fencing 和十个节点的站点参数。[六容器验收](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44347128227)检查了 HDFS 隔离、运行中 MapReduce 作业跨 RM 切换、Hive on Tez、跨节点 Beeline 和 Spark on YARN。[十 Agent 与数据库 TLS 验收](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44340595879)使用运维脚本完成两遍初始化和注册核验。[发布工作流](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44349066611)逐文件校验最终分卷。

## 早期组件包与二次编译

**[统一 yum 仓库下载草稿](https://github.com/wenna/ambari-bigtop-centos7-build-public/releases/tag/untagged-4a4f5003a6e9a1dbfa52)** 包含 60 个二进制 RPM 和仓库元数据，可由有权查看草稿的账号下载。归档 SHA-256 为 `d69a4b61d3ff26971d9705bbfe6d648093496872361bf6f6a7bc047e2e2c91db`。源包、补丁及原始构建记录按 source-releases.txt 所列标签获取。管理面三容器验证已通过，[运行记录](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44247038617)包含 Agent 心跳和 Stack 版本结果。

本仓库提供社区适配构建脚本、补丁和验证流程。目标为 EL7 x86_64，Apache Ambari 源码固定为 15feafb7dfa2f4964a01edac47c0956ab29ad99e，Apache Bigtop 源码固定为 d44a5845eeffe6bab7037a3ca816cf3c9df44029。

使用有草稿访问权的账号下载统一仓库：

```bash
gh release download el7-yum-44247482610 -R wenna/ambari-bigtop-centos7-build-public -D delivery
cd delivery
sha256sum -c el7-x86_64-yum.tar.sha256
tar xf el7-x86_64-yum.tar
(cd yum-staging && sha256sum -c SHA256SUMS)
```

本次 EL7 修订和验证：

| 组件 | 二次构建时保留的改动 | 已验证范围 |
|---|---|---|
| Ambari 3.0.0 | 使用 JDK 17 与 Python 3，修正 Agent reset 写入配置的文件模式，RPM release 2.compat2.el7 | PostgreSQL 初始化、服务端启动、Agent reset/注册、HEALTHY 心跳、BIGTOP 3.3.0 API |
| Bigtop 工具和 ZooKeeper 3.7.2 | Python 3 选择器、版本化路径和包名 | 基础包在 EL7 安装；早期固定版本构建完成三节点选举与 leader 故障切换 |
| Hadoop 3.3.6 | 固定 YARN 前端依赖锁文件，固定 GlassFish EL 3.0.1-b12，保留上游 Bigtop 修补 | 从最终归档安装，版本检查，MapReduce 本地 WordCount 输出校验 |
| Hive 3.1.3 | 预取并校验 Apache 18 父 POM | 最终归档安装、Hive CLI 版本检查 |
| Tez 0.10.2 | 补充测试的 Hamcrest 依赖，启用容器内前端构建配置 | 最终归档安装、Tez API JAR 检查 |
| Spark 3.3.4 | Bigtop 正式构建配置与版本化包名 | 最终归档安装、spark-submit 版本检查 |

公共运行记录：[组合仓库元数据验证](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44247046348)、[最终归档安装和 WordCount](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44248922277)。生产节点签名、实际 HDFS/YARN 高可用、Hive on Tez 与 Spark on YARN 作业应在部署环境单独验收。

在带 Docker、Python 3、Git 和 Bash 的 x86_64 Linux 构建机上，以独立目录重编：

```bash
mkdir -p upstream
git clone --depth 1 --branch release-3.0.0 https://github.com/apache/ambari.git upstream/ambari
bash scripts/build-ambari.sh
git clone --depth 1 --branch rel/3.3.0 https://github.com/apache/bigtop.git upstream/bigtop
BUILD_EXTRA=zookeeper bash scripts/build-foundation.sh
```

使用单独的干净工作目录构建 Hadoop、Hive、Tez 或 Spark 时，将 BUILD_EXTRA 改为相应的小写名称。Bigtop 产物在 upstream/bigtop/output，Ambari 产物在 Server 和 Agent 模块的 target/rpm 下。输出以实际运行记录和 SHA-256 清单为准。Actions 由维护者手动触发，使用标准 Ubuntu 运行器。上传到 Release 的包保留为待验收草稿。

## 准备内部 yum 仓库

每个草稿的资产下载到单独目录，保留二进制包、源码 RPM 和校验清单。使用有权读取草稿的 GitHub 账号。例如：

```bash
gh release download c7-foundation-zookeeper-20261117 -R wenna/ambari-bigtop-centos7-build-public -D downloads/foundation
gh release download c7-hive-44231489365 -R wenna/ambari-bigtop-centos7-build-public -D downloads/hive
python3 scripts/make-yum-repo.py yum-staging downloads/foundation downloads/hive
```

示例集合用于检查元数据；安装完整服务前还需提供对应的 Hadoop 和其他运行依赖。命令需要 Python 3.6+ 及 createrepo_c 或 createrepo，并要求输出目录尚不存在。脚本校验输入 RPM 摘要、检查重名冲突，将二进制包复制到新目录并生成 repodata。正式发布需按内部流程对包签名并重新生成元数据。
