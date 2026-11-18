适用于干净的 CentOS 7.9.2009 x86_64。下载全部编号分卷及 SHA256SUMS 到同一新目录，执行以下命令。留出至少 8 GiB 可用空间用于解包。下载的 INSTALL.zh-CN.md 与归档内部版本相同。

```bash
sha256sum -c SHA256SUMS
mkdir kit
cat ambari-bigtop-el7.tar.part-* | tar xf - -C kit
(cd kit && sha256sum -c ../kit-manifest.sha256)
(cd kit && sha256sum -c SHA256SUMS)
less kit/INSTALL.zh-CN.md
```

应用仓库在 yum-staging/，系统依赖仓库在 runtime-repo/，双 JDK、数据库与 JDBC 的资料见 runtimes/、manifests/ 和手册。已验证的 RPM 版本见 runtime-versions.tsv，各应用 RPM 声明的依赖及版本约束见 application-rpm-requires.txt。将 ops/hosts.example.csv、ops/site.env.example 和 production/site.example.json 复制到站点配置目录，填写生产参数，按手册配置存储、凭据和 fencing。十节点入口为 `bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env all`。evidence/ 保存验收作业的原始记录。
