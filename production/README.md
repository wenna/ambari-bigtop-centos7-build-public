# 十节点服务配置快照

在有 Python 3.6 或更高版本的交付机上运行。将清单和站点 JSON 复制到站点配置库，填写真实 FQDN、机架、数据库写端点、受信 CA 文件、服务账号、存储和资源容量。

```bash
python3 production/check.py
python3 production/render.py --inventory /srv/site/hosts.csv --site /srv/site/site.json --out /srv/site/render-001
```

每个 `bdXX/` 子树对应该主机的绝对路径。`plan.json` 列出本机运行的数据服务及 Unix 身份。相同输入可重复核验相同快照，已有目录出现差异时请生成新的版本目录并比较变更。运维总入口 `ops/deploy-cluster.sh` 的 `data` 阶段调用 `production/start-cluster.sh`，逐台预检并分发角色配置，注册 systemd 单元，初始化新集群的持久状态，等待服务就绪。单独预览时可运行：

```bash
bash production/start-cluster.sh --inventory /srv/site/hosts.csv --site /srv/site/site.json --snapshot /srv/site/render-001 --action plan
```

| 节点 | 常驻数据服务 |
| --- | --- |
| bd01 | nn1、ZKFC、JournalNode、ZooKeeper 1 |
| bd02 | nn2、ZKFC、JournalNode、ZooKeeper 2、rm1 |
| bd03 | JournalNode、ZooKeeper 3、rm2、JobHistory |
| bd04–08 | DataNode、NodeManager |
| bd09 | Hive Metastore、HiveServer2 |
| bd10 | Hive Metastore、HiveServer2、Spark History |

- Hadoop 服务加载 `/etc/hadoop/conf/bigtop-env.sh` 和对应的组件 env；Hive、Spark 及服务单元也可直接加载这个文件。Tez 配置目录为 `/etc/tez/conf`。HiveServer2 使用 `HIVE_CONF_DIR=/etc/hive/conf`；仅在两个 Metastore 服务及其 schematool 会话上使用 `HIVE_CONF_DIR=/etc/hive/metastore`。核验服务实际读取的 env 和 XML，特别是 RPM 的配置软链接、JDBC 驱动 `/opt/cluster/postgresql.jar` 和数据面的 Java 8。客户端通过 ZooKeeper 的 `hiveserver2` 命名空间发现 HS2。
- 在 bd09、bd10 以配置的 Hive 身份通过 `hadoop credential create javax.jdo.option.ConnectionPassword -provider localjceks://file/etc/security/hive/metastore.jceks` 交互设置数据库口令。若修改了 JSON 中的路径，同步修改命令。密钥库和其口令保护由站点管理，文件权限限制为服务身份可读。CA 文件和带有匹配 DNS 名称的数据库证书须现场配置。JSON 仅接收示例定义的字段。JDBC URL 使用示例的参数顺序，不接受用户或密码参数。
- HDFS SSH fencing 使用站点账号与专用私钥路径。两台 NN 上 ZKFC 的身份须可读该私钥，且对端账号须有权终止持有 NN RPC 端口的进程。安装 `fuser`、`nc` 和 SSH 客户端/服务端并实测双向 fencing。安装 ZooKeeper 的 `myid` 前对照已有持久状态。三台仲裁节点应位于独立故障域。Hadoop 的机架脚本可用 FQDN 或已配置反向 DNS 的 IP 查询。现场用 `hdfs dfsadmin -printTopology` 核对五台工作节点。
- 由服务管理器创建 `log_dir/<服务账号>`、`run_dir/<服务账号>` 及匹配角色的数据目录，设置服务身份和最小权限。将 Tez 包 `/usr/bigtop/3.3.0/usr/lib/tez/lib/tez.tar.gz` 放到 `tez_archive` 配置的 HDFS 路径。创建并授权 Hive warehouse、YARN staging/logs、JobHistory 和 Spark 事件目录 `/spark-history`。根据站点提交用户和队列配置 Hive 代理组及资源。源库、元数据目录与 HA 初始化均按部署手册单独管理。
- 此模板沿用验收集群的 Hadoop simple 认证。多租户上线所需 Kerberos、服务间 TLS、Ranger 授权和 ZooKeeper ACL 需应用站点安全配置，并在目标主机另行验收。配置检查覆盖静态角色与路径，实际 DNS、目录、私钥权限、数据库证书和故障切换需由现场演练验证。
