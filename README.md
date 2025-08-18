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