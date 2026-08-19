# SB CPU Floating

一个面向 RootHide / iOS 17 的 SpringBoard CPU 悬浮监控插件。

功能：
- 只显示 SpringBoard CPU
- 每秒刷新一次
- 可拖动
- 不监控内存
- 不限制 CPU
- 不杀进程
- 不枚举其他进程

## GitHub Actions

上传整个工程到 GitHub 后：

Actions → Build SB CPU Floating → Run workflow

构建完成后：

Actions → 对应运行记录 → Artifacts → SB-CPU-Floating-deb

官方 RootHide 文档说明，RootHide Theos 可通过 `THEOS_PACKAGE_SCHEME=roothide` 打包。
