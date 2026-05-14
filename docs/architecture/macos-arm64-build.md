# macOS arm64 双架构构建方案

**Status**: Design
**Created**: 2026-05-14
**Owner**: 张润胜 / 大胜龙虾

## 背景

`yuejuan-macos` 工作流当前只产出 x64 包，Apple Silicon 用户跑 Rosetta 体验差。
直接把工作流换成 `macos-14`（arm64 runner）跑不通，因为 Yuejuan 前端构建链锁死 Node 14（`node-sass ^4.0.0` + 一堆配套 webpack loader），而 Node 14 没有 Apple Silicon 官方二进制。

## 客户端协议确认

通过阅读 `qinglion_yuejuan/src/main/update/updateService.darwin.js:17` 与运行日志 `logs/main.log:539` 确认：

- 客户端走自研 `latest.json` 协议（**不是** `electron-updater` 的 `latest-mac.yml`）
- feedURL 拼接规则：`{updateUrl}/{quality}/darwin/{arch}/latest.json`
- arch 取自 `process.arch`，arm64 用户访问的是 `darwin/arm64/latest.json`
- 两个 arch 路径完全分流，**没有合并 metadata 的需求**

`build/latest-mac.yml` 是 electron-builder 自动生成的废产物，`build.sh` collect 阶段不收集，可继续无视。

## 方案：3-job 拆分

```
Job A: prepare-renderer  (macos-13 + Node 14)
   └─ 产出 dist/electron/ + 注入后的 package.json，打包成 renderer-dist artifact
       │
       ├──────────────────────────┬──────────────────────────┐
       ▼                          ▼
   Job B: package-x64        Job C: package-arm64
   (macos-13 + Node 20)      (macos-14 + Node 20)
   - 下载 renderer-dist      - 下载 renderer-dist
   - yarn install            - yarn install (npm_config_arch=arm64)
     (auto rebuild sqlite3)    (rebuild sqlite3 for arm64)
   - electron-builder dist   - electron-builder dist --arm64
   - 签名 + 公证              - 签名 + 公证
   - sha1/sha256             - sha1/sha256
   - 上传 OSS                - 上传 OSS
   - 写 darwin/x64/latest.json - 写 darwin/arm64/latest.json
```

## 改造清单

### 1. `build.sh` — 引入两种执行模式

新增环境变量控制：

| 变量 | 值 | 行为 |
|---|---|---|
| `BUILD_STAGE` 未设置 | (默认) | 完整流程：install + 前端 build + dist + collect |
| `BUILD_STAGE=renderer-only` | | 只跑 install + `yarn run build`（webpack）；跳过 dist 与 collect |
| `BUILD_STAGE=package-only` | | 跳过 webpack（前端产物已就位）；跑 install + dist + collect |

具体实现要点：
- `renderer-only`：跑到 `yarn run build` 后退出，保留 `${APP_DIR}/dist/electron/` 和注入后的 `${APP_DIR}/package.json`
- `package-only`：要求 `RENDERER_DIST_TARBALL` 指向已下载的 tar.gz，解压到 `${APP_DIR}/`，**跳过** `yarn run build:css` 和 `yarn run build`，直接进 `yarn run dist`
- `package-only` 模式 `yarn install` 时由 GitHub Actions 在外部设置 `npm_config_arch` 控制原生模块编译目标

### 2. 新增 `package_renderer.sh`（可选辅助脚本）

把 `dist/electron/`、`package.json`（已注入 quality/arch placeholder）、`static/`、`build/`（含 entitlements、icons）打包成 `renderer-dist.tar.gz`。

> 设计权衡：也可以直接在 workflow 里用 `tar` 命令完成，避免增加新脚本。倾向后者，保持 builder 仓脚本数量稳定。

### 3. `.github/workflows/build-macos.yml` — 全面重写为 3-job

- 删除 matrix.strategy 改成 jobs 显式拆分
- Job A：`runs-on: macos-13`，Node 14，跑 `BUILD_STAGE=renderer-only bash build.sh`，上传 `renderer-dist.tar.gz` 作为 artifact
- Job B：`runs-on: macos-13`，Node 20，`needs: prepare-renderer`，下载 artifact，跑 `BUILD_STAGE=package-only bash build.sh`，然后 checksums + OSS + release
- Job C：与 Job B 同结构，`runs-on: macos-14`，`VSCODE_ARCH=arm64`，`npm_config_arch=arm64`

### 4. `release.sh` — 不用改

现有逻辑：
- `VSCODE_ARCH` 已支持 `arm64`
- `VERSION_PATH=${APP_QUALITY}/darwin/${VSCODE_ARCH}` 天然按 arch 分目录
- `git push ... || { git pull; git push }` 已处理两个 job 并发 push 的冲突

唯一一个潜在 bug（`ASSET_NAME` glob 不带 arch 过滤）在我们的拆分模型下不触发，因为 Job B/C 各自的 `assets/` 目录里只有自己 arch 的产物。**不修**。

### 5. `upload_to_oss.sh` — 不用改

OSS 路径 `{APP_NAME}/{quality}/{version}/{platform}/{filename}` 中 filename 已带 arch（`Yuejuan-3.0.37-arm64.dmg` vs `Yuejuan-3.0.37-x64.dmg`），不会冲突。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 公证耗时翻倍（流水线从 ~30 分钟拉到 ~50 分钟） | 接受。两个 package job 并行公证而非串行 |
| `macos-14` minutes 收费 10× | 用 insider quality 触发，频率低；后续观察 |
| `yarn install` 在 Node 20 上可能因 lockfile 锁 Node 14 依赖报警告 | 用 `--ignore-engines` 通过；若有 hard fail 再单独排查 |
| 跨 Node 版本前端产物兼容性 | 前端产物纯 JS，无 Node native binding，不会冲突 |
| 两 job 同时 `git push` 到 yuejuan-versions | release.sh 已有 pull-retry-push |

## 验收标准

| # | 步骤 | 验证点 |
|---|---|---|
| 1 | 手动触发 yuejuan-macos，quality=insider, branch=master | 三个 job 顺序成功，总耗时 < 60 分钟 |
| 2 | 下载 yuejuan-macos-arm64 artifact 在 M 系列 Mac 安装 | 启动正常，无 sqlite3 架构错误 |
| 3 | 下载 yuejuan-macos-x64 artifact 在 Intel Mac 安装 | 与改造前行为一致 |
| 4 | OSS `Yuejuan/insider/{version}/darwin/` 目录 | 同时存在 `*-x64.dmg/.zip` 和 `*-arm64.dmg/.zip`（含 sha1/sha256） |
| 5 | yuejuan-versions 仓 `insider/darwin/arm64/latest.json` | 文件存在，url 指向 arm64 包 |
| 6 | yuejuan-versions 仓 `insider/darwin/x64/latest.json` | url 指向 x64 包，未被 arm64 覆盖 |

## 不在范围

- Windows / Linux 工作流改造
- stable quality 推流（先 insider 跑稳）
- 客户端 in-app updater 自动切换 arch（已支持，不用动）
- `latest-mac.yml` 任何处理（协议不用，永久无视）
