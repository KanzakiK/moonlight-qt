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

## 6. 验证与安装

```bash
lipo -info build/build-x86_64/app/Moonlight.app/Contents/MacOS/Moonlight
# 期望输出：Non-fat file: ... is architecture: x86_64

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
