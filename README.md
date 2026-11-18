# Ambari 3.0.0 / Apache Bigtop 3.3.0 on CentOS 7.9 x86_64

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
