# 从交付包启动 PostgreSQL 15

已有 PostgreSQL 15 写入服务的站点直接建两个专用空库。单实例隔离验收可在已有 Docker Engine 的 x86_64 数据库主机载入交付镜像。将下列变量改成真实地址与路径。数据目录、证书、私钥和数据库初始管理员密码文件由 DBA 创建，数据库名称与凭据不随交付包分发。

```bash
export KIT=/srv/bigtop-kit
export PG_LISTEN_IP=10.0.0.19
export PG_STORAGE=/srv/postgres15/ambari-data
export PG_TLS=/etc/bigtop-deploy/pg-tls
export PG_ADMIN_SECRET=/etc/bigtop-deploy/pg-bootstrap.password
docker load -i "$KIT/runtimes/postgres15-image.tar.gz"
docker run --rm --network none offline/postgres:15 postgres --version
docker run --rm --network none offline/postgres:15 id postgres
```

证书文件命名为 server.crt 与 server.key，证书 SAN 包含站点写入域名。将空的数据目录和模式 0600 的服务器私钥设为上述 postgres UID 所有，给该 UID 数据目录写权限及证书、密码文件读权限。若数据目录已包含数据库，请按已有实例恢复规程操作。数据库主机防火墙和站点 pg_hba.conf 仅放行实际管理、Hive 和 DBA 来源。

```bash
docker run -d --name bigtop-catalog-db --restart unless-stopped \
  -p "$PG_LISTEN_IP:5432:5432" \
  -v "$PG_STORAGE:/var/lib/postgresql/data" \
  -v "$PG_TLS:/run/site-tls:ro" \
  -v "$PG_ADMIN_SECRET:/run/secrets/pg-bootstrap:ro" \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/pg-bootstrap \
  -e POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 \
  offline/postgres:15 -c ssl=on -c ssl_cert_file=/run/site-tls/server.crt \
  -c ssl_key_file=/run/site-tls/server.key
docker exec bigtop-catalog-db pg_isready
docker exec -it bigtop-catalog-db psql -U postgres -d postgres
```

在 psql 中按 ops/README.md 第 2 节创建 ambari 和 hive 数据库，使用 SCRAM 密码。正式节点连接地址设置为匹配证书的稳定域名，客户端使用 verify-full 和受信任 CA。生产主备复制、WAL 归档、PITR、故障切换和备份恢复由现场数据库方案提供。单实例容器只覆盖数据库启动与应用联通。
