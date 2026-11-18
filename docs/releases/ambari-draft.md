Ambari 3.0.0 CentOS 7 x86_64 构建草稿。

源码固定为正式 release-3.0.0 的 15feafb7dfa2f4964a01edac47c0956ab29ad99e。
JDK 17.0.21+9、编译镜像及 Python 构建依赖使用记录的固定校验值。
构建过程将 `python` 命令单独映射到 Python 3，保留系统 Python 2，RPM release 标为兼容构建。

本阶段仅编译、打包并保存输入源码，不声称已通过数据库初始化、Server/Agent 注册和 BIGTOP 服务集成。
完整 Web 界面参与 Maven reactor；上游单元测试按官方构建路径跳过，后续安装与集成验证单独记录。
