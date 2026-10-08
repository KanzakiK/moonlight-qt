# 在 Intel Mac (x86_64) 上编译 Moonlight

上游只发布 Apple Silicon 版或通用版，Intel Mac 需要自己编译。本文记录一套
可复现的最小流程，产物是纯 x86_64 的 `Moonlight.app`，不做代码签名。

> 环境样例：Intel Core i7 / 16 GB / macOS 15 / Xcode Command Line Tools（不需要完整 Xcode）。
> 全程耗时约 1 小时，其中绝大部分是下载。

---

## 0. 为什么能直接编出 x86_64

- 机器本身就是 Intel，**不存在交叉编译或 Rosetta 的坑**，原生编译即 x86_64。
- 上游 CI 用的 Qt 6.11.2 macOS 包是 **universal（x86_64 + arm64）**，x86_64 可直接用
  （Qt 官方要到 6.13 才停止提供 macOS x86_64 二进制）。
- `setup-deps.py` 拉的预编译依赖（ffmpeg / SDL2 / opus / openssl / MoltenVK）同样是 universal。
- 官方 `scripts/generate-dmg.sh` 里的 `MOONLIGHT_ARCH` 会自动识别 x86_64，
  所以**不需要改动任何项目代码**。

## 1. 前置条件

```bash
xcode-select --install      # Command Line Tools，含 clang / swiftc
python3 --version           # 3.9+ 即可
```

不需要完整 Xcode：`swiftc` 在 Command Line Tools 里就有（File Provider 扩展用得上）。

## 2. 拉取源码

```bash
git clone --recurse-submodules --depth 1 https://github.com/qiin2333/moonlight-qt.git
cd moonlight-qt
git submodule update --init --recursive --force   # 见「坑位 2」
```

## 3. 安装 Qt 6.11.2

用 [aqtinstall](https://github.com/miurahr/aqtinstall)（Qt 官方安装器也要登录，命令行更省事）：

```bash
python3 -m venv ~/.venv-aqt
~/.venv-aqt/bin/pip install aqtinstall pycryptodomex
~/.venv-aqt/bin/aqt install-qt mac desktop 6.11.2 clang_64 \
  -m qtmultimedia qtimageformats -O ~/Qt --internal
```

- `--internal` 用 Python 内置解压器，省掉额外装 `7z`（macOS 默认没有）。
- 装完在 `~/Qt/6.11.2/macos`（部分版本目录名是 `clang_64`，脚本两个都会找）。
- `macdeployqt` 随 Qt 一起装好了，打包要用。

## 4. 下载预编译依赖

```bash
python3 setup-deps.py
```

约 28 MB，落在 `libs/mac/`。

## 5. 编译

```bash
bash scripts/build-macos-x86.sh release
```

产出：`build/build-x86_64/app/Moonlight.app`

这条脚本等价于官方 `generate-dmg.sh` 的主体步骤，但**跳过**了：

| 跳过的组件 | 原因 |
|---|---|
| USB 转发 `moonlight-usbd` | 需要 cmake 单独构建 libusb，只影响手柄/键鼠 USB 透传 |
| File Provider 扩展 | 只影响「文件夹映射」挂载功能，需要 Xcode 工程 |
| DMG 封装 | 直接拿 `.app` 更省事，需要 DMG 时再补 |

串流主体（画面 / 音频 / 手柄 / 剪贴板）不受影响。

### 为什么跳过：实测结论（与 x86_64 无关）

容易误以为是「Intel Mac 不支持」，实际查下来**两个组件的构建脚本都把 x86_64 当成一等目标**：

- `generate-dmg.sh` 的 `MOONLIGHT_ARCH` 默认取 `uname -m`，非 arm64 一律归一成 `x86_64`；
  注释里明确写了「Intel Mac 上装了才发现打不开」，产出的 DMG 名字带架构后缀。
- `build-macos-fileprovider-extension.sh` 显式分支 `if [ arch != arm64 ] && [ arch != x86_64 ]; then arch=x86_64; fi`，
  部署目标 `macos11.0`。实测 `swiftc -target x86_64-apple-macos11.0` 能直接编出 x86_64 的 appex。

真正的阻碍是另外两件事：

| 组件 | 能否编译 x86_64 | 实际阻碍 |
|---|---|---|
| USB 转发 `moonlight-usbd` | 能（libusb 用 Darwin 后端 `os/darwin_usb.c`，纯 IOKit/CF 代码，无架构分支） | 需要 `cmake ≥ 3.24` 与 `pkg-config`（usbipdcpp 走 `pkg_check_modules`）。另外 macOS 下系统驱动占用的接口（HID 手柄/键鼠、存储、摄像头）libusb 无法 claim，列表里会标「In use by macOS」且不可共享，这是平台权限限制 |
| File Provider 扩展 | 能（已实测编出 x86_64） | **运行时必须代码签名**。entitlements 含 `app-sandbox` 与 `application-groups`(`group.com.alkaidlab.vpluspc.FileProvider`)，App Group 需要真实 Developer ID + provisioning profile；未签名的 appex 不会被 `fileproviderd` 加载，编了也用不了 |

结论：自用且不需要文件夹映射时，跳过这两项是合理的；
只在需要 USB 转发且愿意装 cmake/pkg-config 时才值得补上。

## 6. 验证与安装

```bash
lipo -info build/build-x86_64/app/Moonlight.app/Contents/MacOS/Moonlight
# 期望输出：Non-fat file: ... is architecture: x86_64

codesign -dv /Applications/Moonlight.app 2>&1 | grep Signature
# 期望输出：Signature=adhoc —— 不能是 "code object is not signed at all"

# 安装（ditto 能正确保留 framework 里的符号链接，别用 cp -R）
sudo ditto build/build-x86_64/app/Moonlight.app /Applications/Moonlight.app
xattr -dr com.apple.quarantine /Applications/Moonlight.app
```

未签名，所以：

- 本机首次打开可能被 Gatekeeper 拦 → 右键「打开」，或跑一次上面的 `xattr` 命令。
- 拷到别的 Intel Mac 同样需要那句 `xattr`。

## 7. 分发打包

```bash
ditto -c -k --sequesterRsrc --keepParent /Applications/Moonlight.app \
      Moonlight-VPlus-<版本>-x86_64.zip
```

272 MB 的 app 压缩后约 99 MB。
