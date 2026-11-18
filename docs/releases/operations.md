适用于干净的 CentOS 7.9.2009 x86_64。下载全部编号分卷及 SHA256SUMS 到同一新目录，执行以下命令。留出至少 8 GiB 可用空间用于解包。下载的 INSTALL.zh-CN.md 与归档内部版本相同。

```bash
sha256sum -c SHA256SUMS
mkdir kit
cat ambari-bigtop-el7.tar.part-* | tar xf - -C kit
(cd kit && sha256sum -c SHA256SUMS)
less kit/INSTALL.zh-CN.md
```

应用仓库在 yum-staging/，系统依赖仓库在 runtime-repo/，双 JDK、数据库与 JDBC 的资料见 runtimes/、manifests/ 和手册。已验证的 RPM 版本见 runtime-versions.tsv，各应用 RPM 声明的依赖及版本约束见 application-rpm-requires.txt。按 ops/ 中的步骤设置生产主机、存储、数据库和资源参数。evidence/ 提供容器切换与 SQL、Spark 作业记录。
