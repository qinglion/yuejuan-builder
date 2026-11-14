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
DSH 自己的签名、公证、更新清单与 OSS 安全发布命令，再把安装包和发布审计记录保留为
Actions artifact。

下载域名统一复用 `https://d.qinglion.com`：测试固定下载位于 `test/desktop/`，生产固定下载
位于 `desktop/`；自动更新文件继续使用 DSH 的 `qingclaw-desktop/` 版本化对象布局。不要把
旧的 Yuejuan `build.sh`、`upload_to_oss.sh` 或 `release.sh` 用于 QingClaw，它们的产物和更新
协议不同。

`d.qinglion.com` 前面有阿里云 CDN。DSH 会给版本化二进制写入长期 immutable 缓存头，给
更新 feed 和 `qingclaw-latest-*` 固定别名写入禁止缓存头。CDN 已为
`qingclaw-desktop/`、`desktop/`、`test/desktop/` 配置 0 秒目录缓存规则（权重 99），根目录
原有 1 个月规则降为权重 1；发布后仍要用响应头和文件哈希复核实际命中行为。

工作流复用现有 macOS 与 OSS secrets，并会从 P12 的 Developer ID Application 证书自动读取
签名身份。必要时可以用非敏感的 Repository Variable 显式覆盖：

```text
QINGCLAW_MACOS_SIGNING_IDENTITY=公司名称 (TEAMID)
```

首版先开放 macOS arm64/x64。Windows 需适配 DSH 的完整签名树与 NSIS/blockmap 后再加入，
不能仅在最后一步给安装器补签。
