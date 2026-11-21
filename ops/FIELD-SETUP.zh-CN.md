# 现场配置与安装操作单

适用环境为 CentOS Linux 7.9.2009 x86_64。所有命令在可信 Linux 控制机上由普通运维账号执行，当前目录为已校验交付包的根目录。下面按 20 台举例，10 台、100 台或更多节点使用同一流程。主机清单决定部署范围。

## 1. 准备现场入口

首次建账号需要已有管理权限。镜像、云初始化或企业配置管理应预置一个可公钥登录的普通管理账号（示例 `siteadmin`），允许它非交互执行 `/bin/bash -s` 进行首次引导。这相当于系统管理权限，只交给受信任的初始化管理员。已有现场管理平台也可以承担这些前置操作。仅有一个无授权的普通账号时，需由基础设施管理员先提供该入口。

- 所有节点已禁用 SSH root 登录，已启用 SSH 公钥认证，初始管理用户具备免终端的非交互 sudo。脚本检查 SSH 服务配置并验证普通账号登录。控制机需有 Bash 4+、Python 3、OpenSSH 客户端、tar、base64 和 GNU coreutils；目标机需有 sudo、visudo、sshd、runuser、flock。
- 从现场可信渠道取得每台机器的 SSH 主机公钥指纹并准备控制机的 known_hosts。按 IP 引导时同时登记初始 IP 和最终 FQDN，非 22 端口按 `[主机]:端口` 登记。控制机须能解析最终 FQDN。
- 按管理面手册校验全部分卷。基础设施侧把同一份可信交付目录放到每台机器的同一路径（示例 `/srv/bigtop-kit`），用受控只读挂载或 root 管理的目录保护它。上级目录由 root 管理，部署账号不能修改交付内容，包括只读挂载的后端文件。目标机需能读取交付文件。保留独立取得的 `kit-manifest.sha256`。
- 现场准备 PostgreSQL、数据库 CA、凭据文件、磁盘挂载、防火墙和可信时钟源。配置脚本和公钥授权不会自动取得数据库密码。管理库与 Hive 库独立。

## 2. 复制模板，填写一次

以下初始化命令在首次创建现场配置时执行。已有配置请直接编辑，以免覆盖。

```bash
umask 077
s="$HOME/bigtop-deploy"
mkdir -p "$s"
cp ops/site.env.example "$s/site.env"
cp ops/access.env.example "$s/access.env"
cp production/site.example.json "$s/site.json"
cp ops/web-install.example.json "$s/web-install.json"
python3 ops/generate-inventory.py --nodes 20 --domain prod.example.internal > "$s/hosts.csv"
```

| 文件 | 现场需要填写的值 |
|---|---|
| `hosts.csv` | 每行填写唯一的 slot、真实 FQDN、实际机架、空格分隔的角色。只给一台机器分配 `ambari-server`。样例的 bd001 等是稳定的 slot，主机名可另填。按现场故障域调整，生成的机架名只是占位。 |
| `access.env` | `BOOTSTRAP_USER`、`BOOTSTRAP_IDENTITY_FILE` 指已有管理员及其私钥。默认复用现有部署密钥对；如允许脚本在控制机生成专用无口令 Ed25519 密钥，填 `GENERATE_DEPLOY_KEY=1`。使用加密私钥时提前装入 ssh-agent。 |
| `site.env` SSH 与交付 | `SSH_USER` 填待创建的专用普通用户，与初始管理员不同。`AMBARI_ACCESS_MODE=managed`、`SSH_PORT`、`SSH_IDENTITY_FILE`（部署私钥，同路径须有 .pub，自动生成时可均不存在）、`SSH_KNOWN_HOSTS`、`KIT_ROOT`、`INVENTORY`。把已验证的 `kit-manifest.sha256` 第一列的 64 位摘要填入 `MANIFEST_SHA256`。 |
| `site.env` 主机与时间 | `REQUIRED_MOUNTS`、`WORKER_MOUNTS`、`MIN_FREE_MIB`、`NTP_SOURCES`、`MAX_CLOCK_OFFSET_SECONDS`。默认 `PREPARE_OS=0` 使用已配置的主机。需要脚本准备主机时设为 1，另从 `ops/bootstrap.example.csv` 复制 `bootstrap.csv`，每个 slot 填一个现场管理 IP，设置 `BOOTSTRAP_INVENTORY`。按需开启 `SET_HOSTNAME`、`MANAGE_ETC_HOSTS`。 |
| `site.env` Ambari 管理库 | `PG_HOST`、`PG_PORT`、`PG_DATABASE`、`PG_USER`、`PG_CA`、`PG_PASSWORD_FILE`。后两项是 Ambari Server 上的受控文件路径。`API_BASE` 和 `API_NETRC` 用于 Server 本机验证 Agent，netrc 的 machine 要匹配 API 主机名。密码文件和 netrc 仅授予所需读取权限。 |
| `site.json` 数据服务 | Hive 的 `pg_url`、`pg_user`；DataNode 目录、NodeManager 本地目录、内存及 vCore；服务账号和按 slot 配置的 `node_overrides`。JDBC 地址使用与证书匹配的域名和现场 CA，密码仅在页面输入。原生 Stack 的 `tez_archive` 填 `/bigtop/apps/3.3.0/tez/tez.tar.gz`。 |
| `web-install.json` 页面参数 | 集群名、应用和系统依赖仓库 URL、Hive 库名、首次安装的主角色 slot、客户端 slot、元数据目录、NodeManager 日志目录及现场队列。仓库地址指向分别包含 `repodata/repomd.xml` 的根目录。使用自定义队列时须另在 YARN 调度器里配置。 |

管理库口令文件和 API netrc 应由 root 所有，权限为 0400 或 0600。管理库口令为单行，至少含一个非十六进制字符。env 文件是 Bash 输入，仅由受信任管理员编辑。私钥留在控制机；选用现有密钥时，确保 .pub 与私钥匹配。首次管理员应审阅现场配置和生成的动作后再授权。

## 3. 建账号、分发公钥并授权

```bash
bash ops/bootstrap-access.sh "$s/site.env" "$s/access.env" plan
mkdir -p "$s/review"
bash ops/deploy-cluster.sh "$s/site.env" ambari --export-actions "$s/review"
# 复核 review 内按主机列出的安装命令，然后执行
bash ops/bootstrap-access.sh "$s/site.env" "$s/access.env" apply
```

apply 逐台校验交付包，创建部署账号，加入其 SSH 公钥，用 visudo 校验并安装 sudo 授权，随后以该部署账号重新连接。每台应出现 `deployment login and sudo policy verified`。部署账号通过固定入口执行该主机被批准的安装动作。已有同名、非本脚本管理的账号会被拒绝，改用独立账号或由现有站点策略接管。相同输入可以重新执行，已成功的公钥不会重复添加。更换密钥后单独按现场流程撤销旧公钥；更改节点、关键参数或交付包后重新生成并审阅动作，再次 apply。审阅目录每次使用空目录。首次管理员的权限可在授权结束后由现场收回。

## 4. 安装 Ambari Server 和 Agent

```bash
bash ops/deploy-cluster.sh "$s/site.env" ambari
```

脚本用部署账号登录，内部调用非交互 sudo。成功条件是唯一的 Server 可访问，清单中每台 Agent 都已注册并报告 HEALTHY。详情见[管理面安装手册](AMBARI.zh-CN.md)。此时可登录 Ambari Web。

## 5. 生成页面填写单并安装 Hadoop 服务

```bash
python3 ops/web-install-values.py --inventory "$s/hosts.csv" --site "$s/site.json" \
  --web "$s/web-install.json" > "$s/页面填写单.txt"
cat "$s/页面填写单.txt"
```

浏览器进入 **Launch Install Wizard**，按填写单选择 BIGTOP-3.3.0、redhat7、内网应用仓库，使用 **Perform manual registration**，SSH 私钥栏留空。选择服务、分配角色并填写目录、资源和 Hive PostgreSQL 连接信息。在受控页面输入现场密码并测试连接，然后在 **Review** 确认并提交。具体页面、截图、Router 选项和验收记录见[页面向导手册](WEB-INSTALL.zh-CN.md)。填写单可重复生成，生成动作仅在控制机写文件。浏览器中仍由运维人员确认并点击安装。首次向导后另行启用和验证 NameNode、ResourceManager 高可用。
