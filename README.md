# Ambari 3.0.0 / Apache Bigtop 3.3.0 on CentOS 7.9 x86_64

**[统一 yum 仓库下载草稿](https://github.com/wenna/ambari-bigtop-centos7-build-public/releases/tag/untagged-4a4f5003a6e9a1dbfa52)** 包含 60 个二进制 RPM 和仓库元数据，可由有权查看草稿的账号下载。归档 SHA-256 为 `d69a4b61d3ff26971d9705bbfe6d648093496872361bf6f6a7bc047e2e2c91db`。源包、补丁及原始构建记录按 source-releases.txt 所列标签获取。管理面三容器验证已通过，[运行记录](https://github.com/wenna/ambari-bigtop-centos7-build-public/actions/runs/44247038617)包含 Agent 心跳和 Stack 版本结果。

本仓库提供社区适配构建脚本、补丁和验证流程。目标为 EL7 x86_64，Apache Ambari 源码固定为 15feafb7dfa2f4964a01edac47c0956ab29ad99e，Apache Bigtop 源码固定为 d44a5845eeffe6bab7037a3ca816cf3c9df44029。

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
