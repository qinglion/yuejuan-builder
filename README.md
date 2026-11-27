# Yuejuan Builder

基于 `void-builder` 的思想，为 `qinglion_yuejuan`（青狮阅卷 Electron 应用）提供本地/CI 一键打包、校验、上传与版本 JSON 更新的脚本集合。

## 目录

- `utils.sh`: 通用工具与变量，自动识别平台/架构，读取版本号
- `build.sh`: 在 `qinglion_yuejuan` 内执行构建（electron-builder），将产物收集至本仓库 `assets/`
- `prepare_checksums.sh`: 对 `assets/` 中所有文件生成 `.sha1` 与 `.sha256`
- `upload_to_oss.sh`: 将 `assets/` 文件上传到阿里云 OSS，并输出可公开下载的 URL
- `release.sh`: 生成/更新 `qinglion/versions` 仓库中的 `latest.json`

## 使用

1) 设置 APP 源码目录（默认相邻目录）：

```bash
export APP_DIR="../qinglion_yuejuan"
```

2) 构建产物：

```bash
bash build.sh
```

3) 生成校验：

```bash
bash prepare_checksums.sh
```

4) 上传到 OSS（可选）：

```bash
export OSS_ACCESS_KEY_ID=...
export OSS_ACCESS_KEY_SECRET=...
export OSS_BUCKET_NAME=cdn
export OSS_ENDPOINT=oss-cn-shanghai.aliyuncs.com
export PUBLIC_DOWNLOAD_DOMAIN=d.qinglion.com

bash upload_to_oss.sh
```

5) 更新版本 JSON（需要 GitHub Token）：

```bash
export GH_TOKEN=ghp_xxx
export SHOULD_BUILD=yes
export APP_NAME="Yuejuan"
export APP_QUALITY=stable
export ASSETS_REPOSITORY="qinglion/binaries"
export VERSIONS_REPOSITORY="qinglion/versions"

bash release.sh
```

备注：
- `RELEASE_VERSION` 默认读取 `APP_DIR/package.json` 的 `version`
- 自动识别平台：`osx|linux|windows`，并映射为 `darwin|linux|win32`
- 产物默认从 `APP_DIR/build/` 收集（由 electron-builder 输出目录决定）

## 青狮龙虾（QingClaw）

青狮龙虾使用独立的手动工作流 `.github/workflows/build-qingclaw-macos.yml`。该工作流在
GitHub 托管的 Intel 与 Apple Silicon macOS runner 上检出 `qinglion/qingclaw-dsh`，调用
DSH 自己的签名、公证与更新清单命令，并在同一个 macOS job 内把产物上传到 OSS。

正式版与测试版取自不同的分支：

- `beta`：日常开发主线；测试构建（`deployment=test`、`nightly`）只接受它的提交；
- `release`：正式环境分支，发布时把 `beta` 合并进来；生产构建（`deployment=production`、`stable`）只接受 `release` 分支或基于它的 `dsh-v*` tag；
- `master`：只用于同步上游 `deepseek-ai/deepseek-harness`，不参与任何构建。

工作流在打包前校验检出提交属于对应分支；正式版还要求 `dsh_ref` 就是 `release`（或 `dsh-v*` tag），否则拒绝使用发布凭据。

官网下载、electron-updater 和打包上传共用同一个根：

```text
qingclaw/<quality>/desktop/
  qingclaw-<version>-macos-arm64.dmg
  qingclaw-<version>-macos-x64.dmg
  arm64/nightly-mac.yml
  arm64/qingclaw-<version>-mac-arm64.zip
  arm64/qingclaw-<version>-mac-arm64.zip.blockmap
  x64/nightly-mac.yml
  x64/qingclaw-<version>-mac-x64.zip
  x64/qingclaw-<version>-mac-x64.zip.blockmap
```

`<quality>` 测试为 `beta`、生产为 `stable`。客户端更新地址是
`https://d.qinglion.com/qingclaw/<quality>/desktop/<arch>/`，electron-updater 读取目录下的
`nightly-mac.yml`；官网读取同一个 YAML 的 `version`，再拼带版本号的 DMG 地址，因此不再需要
按版本配置环境变量。

上传统一走 `utils.sh` 中的 `oss_upload_file`：ossutil 三次重试、`public-read` ACL、显式
`--region`、`--cache-control`。带版本号的 DMG/ZIP 写入长期 immutable 缓存；YAML 写入
`no-store`，CDN 返回 `x-swift-cachetime: 0`，发布后应回源复核版本号。`d.qinglion.com`
前面是阿里云 CDN，`qingclaw/` 前缀使用 0 秒目录缓存。

`scripts/qingclaw/upload-desktop.sh` 可单独重跑已保留的 Actions artifact；需要只补上传而不
重新打包时，使用 `.github/workflows/upload-qingclaw-artifacts.yml`。不要把旧的 Yuejuan
`build.sh` 或 `release.sh` 用于 QingClaw，它们的产物和更新协议不同。

工作流复用现有 macOS 与 OSS secrets，并会从 P12 的 Developer ID Application 证书自动读取
签名身份。必要时可以用非敏感的 Repository Variable 显式覆盖：

```text
QINGCLAW_MACOS_SIGNING_IDENTITY=公司名称 (TEAMID)
```

### Computer Use helper

macOS 与 Windows 工作流在依赖安装之后、桌面打包之前，从本次检出的 QingClaw 源码构建
Computer Use helper 并放入 provider 包：macOS 用 `scripts/cua-helper/package.ts` +
`stage.ts`，以 QingClaw 自己的 Developer ID 签名并公证（复用同一份私有打包配置）；
Windows 用 `dotnet publish` 后放入 `native/bin/win-x64`，随现有 SSL.com 签名树一起
Authenticode 签名。不下载、不复用官方 DeepSeek 的 helper 产物或 npm tarball。

macOS runner 镜像默认的 Xcode 16.4（Swift 6.1/6.2）会对 helper 的 actor 隔离
同步闭包报 region-isolation 误报。补丁把 AXWorker 该处闭包捕获改为
`WindowGeometry.resolve` 的普通同步参数重载（187 个 Swift 测试通过），Swift
6.1–6.4 均可编译。runner 镜像的 cctools lipo 要求输入文件在前，补丁把 helper
verify 的 lipo 调用改为输入优先顺序（与 `scripts/ssh-helper/native.ts` 一致，
新旧工具链通用）。

打包补丁同时把 helper 的 bundle identifier 重品牌为
`com.qinglion.qingclaw.computer-use`（显示名 `QingClaw Computer Use`），避免与官方
`com.deepseek.harness.computer-use` 共用 macOS 辅助功能/屏幕录制的权限身份。macOS
运行时签名校验要求 helper 的叶证书与 Team ID 与 QingClaw 应用签名身份一致，官方签名
的 helper 无法混入 QingClaw 安装包。

首版先开放 macOS arm64/x64。Windows 需适配 DSH 的完整签名树与 NSIS/blockmap 后再加入，
不能仅在最后一步给安装器补签。
