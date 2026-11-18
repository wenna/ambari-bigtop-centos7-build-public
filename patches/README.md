# 兼容补丁

`bigtop/0001-selector-python3.patch` 基于 Bigtop 正式 `rel/3.3.0` 提交
`d44a5845eeffe6bab7037a3ca816cf3c9df44029`。

已复现上游 distro-select 在 Python 3 中因 `0755` 语法报错。
补丁仅处理选择器的解释器、八进制语法和字典视图排序，声明 python3 运行依赖，
并将 bigtop-select 的 RPM release 改为 `2.compat1`，避免与原版 `1.el7` 混淆。
未改动 CentOS 系统 Python，也未声明已完成全部 Ambari 服务适配。

重新构建：在仓库根目录创建 `upstream/bigtop` 并检出上述提交，然后执行
`bash scripts/build-foundation.sh`。脚本应用并记录补丁；官方编译镜像已固定 digest。
二次修改时保留原始提交，在 patches 下按顺序增加补丁，并变更自定义 RPM release。

上游源文件遵循 Apache License 2.0，源码与对应 SRPM 中保留许可材料。
