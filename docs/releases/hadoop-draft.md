Hadoop 3.3.6 / Bigtop 3.3.0 CentOS 7 x86_64 构建记录。

这是私有仓库中的草稿，仅保存本次实际生成的 RPM/SRPM，不标记为生产可用版本。
源码固定为 Bigtop rel/3.3.0 的 d44a5845eeffe6bab7037a3ca816cf3c9df44029，
包含本仓库记录的 Python 3 选择器兼容补丁。SHA-256 清单随包提供。

该阶段只完成编译和打包；HDFS/YARN 启动、读写及 Ambari 管理验证尚未完成。
实际构建日志和工作流运行记录以当前 GitHub Actions 任务为准。
