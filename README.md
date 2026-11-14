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

首版先开放 macOS arm64/x64。Windows 需适配 DSH 的完整签名树与 NSIS/blockmap 后再加入，
不能仅在最后一步给安装器补签。
