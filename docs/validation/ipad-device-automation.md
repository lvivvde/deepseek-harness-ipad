# 真机连接

工具入口：`python3 scripts/device.py --help`。只读：不配对、不索要密码、不安装或启动 App。CLI 日志和设备 JSON 只保存到本地私有输出目录（默认 `build/device-acceptance/<时间>/`），终端只报告固定结果。

旧正式 App 的独立 UI-testing runner（`DeviceAcceptance`）、`status`、`build`、`run` 子命令和 Xcode 辅助脚本已随旧 App 删除，见提交 `111817f` 之前的历史。

## 先只读连接

```sh
python3 scripts/device.py probe
```

工具自动选唯一已连接、已配对的物理 iPad，读取锁定状态和 DeepSeek Harness（`org.lvivvde.harness.candidate`）的安装状态。无设备、未配对或多设备会报固定阻塞；多设备用 `--device-file build/device-acceptance/selected-device-private.json` 指定本地 JSON 的 `identifier`，不要打印其值。失败退出码 1，原始细节留 `*-private.log`。

私有设备脚本（忽略的 `build/app/device/`）导入这个文件的 `Session`，在它之上安装、启动、结束和拉取文件，见[交接](../agents/handoff.md)。

## App 名额

免费个人团队可能只有少量签名 App 名额，满了会报 `APP_SLOT_FULL`。卸载 App 及其数据只能在当前会话或交接记录的明确授权范围内；2026-10-06 用户明确允许删除本项目占位 App 及后续项目 IPA，该范围内不重复询问，不扩展到其他 App。

## 读取 App 容器

`devicectl device copy from` 每次只复制一个文件。要拉取整个目录，得先列出目录内容再逐个复制。`devicectl device info files --recurse` 可能漏掉某个目录的内容：2026-10-11 从 App 的工作区根递归列出时，两次都列出了目录 `ro` 本身，但没有它里面的文件；单独列 `ro` 能列出。原因未查明，见 [#17 测量](ipad-candidate-measurements.md)“旧导出器备份”。所以逐个目录单独列出，不用 `--recurse`；只有用递归结果核对文件是否齐全时，才可能误报“缺文件”。

## 隐私

原始日志、签名配置和截图均不公开；对外仅给出结论、范围、耗时与固定阶段。跨机器需要新的配对/权限和该机器的签名条件，已有开发授权不是可搬迁的文件。
