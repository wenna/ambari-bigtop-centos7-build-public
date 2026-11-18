CentOS 7.9 x86_64 验收用二进制仓库，含 RPM、SHA-256 清单与 yum 元数据。运行下列命令核对并解包：

```bash
sha256sum -c el7-x86_64-yum.tar.sha256
tar -xf el7-x86_64-yum.tar
(cd yum-staging && sha256sum -c SHA256SUMS)
```

操作系统、EPEL 7 和 Java 运行依赖需另行准备。输入草稿见 source-releases.txt，SRPM 或对应源码与补丁随各组件草稿提供。正式部署前按组织流程签名并验收。
