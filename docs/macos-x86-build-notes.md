# Intel Mac 编译排查笔记

一次真实编译过程中踩到的坑，按出现顺序记录。多数不是项目本身的问题，
而是 macOS 环境 / qmake 行为的坑，换台机器还会再遇到。

---

## 坑位 1：aqtinstall 解压失败

**现象**：Qt 归档全部下载完成，卡在解压阶段，报找不到 `7z`。

**原因**：macOS 不自带 `7z`，aqtinstall 默认调外部 `7z` 二进制。

**解法**：

```bash
aqt install-qt ... --internal          # 改用 Python 内置解压器
pip install pycryptodomex              # 内置解压器依赖它解密
```

**二次坑**：`pip install pycryptodomex` 如果被中断，包目录在但
`Cryptodome/Cipher/*.so` 缺失，`import py7zr` 报
`ModuleNotFoundError: No module named 'Cryptodome.Cipher'`。
此时 `pip install` 会认为已装好而跳过，必须 `--force-reinstall --no-cache-dir`。

**教训**：判断依赖是否装好，要实际 `import` 验证，别只看 pip 退出码。

---

## 坑位 2：`git submodule update` 报成功但源码没落地

**现象**：编译报 `src/src/abstractserver.cpp: No such file or directory`。
进目录一看，只有 `.git` 指针文件，工作区是空的。

**验证方法**（别信命令的退出码）：

```bash
for d in moonlight-common-c/moonlight-common-c qmdnsengine/qmdnsengine \
         app/SDL_GameControllerDB usb-helper/third_party/libusb; do
  echo -n "$d: "; find "$d" -type f -not -path '*/.git/*' | wc -l
done
```

**解法**：

```bash
git submodule update --init --recursive --force
```

加 `--force` 才会真正把文件写进工作区。

---

## 坑位 3：qmake 不递归刷新子目录 Makefile（最折腾的一个）

**现象**：编译全部通过，链接时崩出一堆未定义符号：

```
Undefined symbols for architecture x86_64:
  "vtable for QMdnsEngine::AbstractServer", referenced from: ...
  "QMdnsEngine::Server::staticMetaObject", referenced from: ...
```

`moc_*.cpp` 一个都没生成。

**根因（两层）**：

1. 第一次跑 qmake 时，坑位 2 还没解决，`qmdnsengine` 子模块是空的，
   于是那份 `Makefile.Release` 里**压根没有 moc 规则**。
2. 之后重跑顶层 qmake，**不会覆盖已存在的子目录 Makefile**，
   所以错误状态被冻结在第一次生成的那份里。

**解法**：

```bash
make qmake_all     # 递归重新生成所有子目录 Makefile
```

**教训**：子模块状态变化后，构建产物里的 Makefile 是脏的。
「重新 qmake 一遍」不等于「Makefile 是新的」，必须显式递归刷新。
这一条已写进 `scripts/build-macos-x86.sh`。

---

## 坑位 4：macdeployqt 漏打包剪贴板 helper

**现象**：app 在本机跑得好好的，换个路径 / 换台机器启动即崩。

**原因**：`moonlight-clipboard-helper` 是独立可执行文件，
macdeployqt 默认只处理主程序，helper 里的 Qt 路径仍指向构建机的绝对路径。

**解法**：显式声明

```bash
macdeployqt Moonlight.app -qmldir=app/gui \
  -executable=Moonlight.app/Contents/MacOS/moonlight-clipboard-helper
```

**验证**：

```bash
otool -L Moonlight.app/Contents/MacOS/Moonlight | grep -c "$HOME/Qt"   # 期望 0
```

---

## 坑位 5：`cp -R` 复制 .app 会撑大体积

**现象**：272 MB 的 app 复制完变成 290 MB，耗时 11 分钟。

**原因**：`.app` 内的 framework 大量使用符号链接，`cp -R` 会把链接展开成实体文件。

**解法**：用 `ditto`，同样的复制**只花 8 秒**，符号链接保持不变：

```bash
ditto src/Moonlight.app /Applications/Moonlight.app
```

---

## 坑位 6：GitHub 细粒度令牌的两个坑

准备把成果推到 fork 上时遇到的。

**6a. `gh repo sync --force` 返回 403**
不是权限不够，是 `gh repo sync` 走的 merge-upstream 接口不支持 fine-grained token。
改用 git 直接 push 即可。

**6b. push 被拒，提示需要 `workflow` 权限**
GitHub 规定：只要改动 `.github/workflows/` 下任意文件，令牌必须额外带
`Workflows: Read and write` 权限，光有 `Contents: Read and write` 不够。
同步上游（含新增工作流）时必然触发。

---

## 坑位 7：未签名 → 本地网络被静默拒绝（最隐蔽的一个）

**现象**：app 能正常启动、界面正常，但**永远搜不到主机**；手动输入 IP 也连不上。
日志只有一行，且看不出是权限问题：

```
Executing request: "http://192.168.50.156:47989/serverinfo?..."
"serverinfo" request failed with error: QNetworkReply::UnknownNetworkError
```

**误判方向**：一开始会以为是主机没开、防火墙、端口错、系统代理。
但 `curl http://<ip>:47989/serverinfo` 在同一台机器上是 **200 正常**的 —— 网络没问题。

**真正的判别信号**：请求与报错在**同一秒**。超时会等几秒；立刻失败说明是系统层面直接拒，
不是网络不通。

**根因**：macOS 15 的「本地网络」隐私权限只授予**已签名**的代码。
`codesign -dv` 显示 `code object is not signed at all` 时，
**系统连权限框都不弹，静默拒绝所有 LAN 连接**（mDNS 发现和 HTTP 请求一起挂）。

**解法**：ad-hoc 签名即可，不需要开发者证书

```bash
codesign --force --deep --sign - /Applications/Moonlight.app
```

签名后 CDHash 变化，macOS 会把它当新应用重新弹「本地网络」授权框，点允许即可。

**已写进 `scripts/build-macos-x86.sh`**，构建时自动执行，别手动省掉这一步。

> 顺带：`NSLocalNetworkUsageDescription` 与 `NSBonjourServices` 项目 Info.plist 里本来就有，
> 缺的只是签名，不是声明。

## 坑位 8：在 fork 上发布 Release 会触发整套 CI

自己编译的产物要发到 fork 仓库备份时容易踩到：`build.yml` 的触发条件里写了

```yaml
on:
  push:
    branches: [ master, main ]
  release:
    types: [ published ]
```

也就是说 **push 到 master 和「发布 Release」都会触发全平台构建**（Linux AppImage / Windows exe / macOS arm64 dmg），
一次约 20 分钟，并且会把 12 个 ci 产物上传到同一个 Release，与自己上传的本机产物混在一起。

**处理顺序很重要**：不要试图「推一个提交去禁用 workflow」——那个 push 本身就会先触发一遍构建，
等于为了省钱先花一笔。正确做法是先在网页端关掉：

> fork 仓库 → **Settings** → **Actions** → **General** → **Disable actions** → Save

细粒度令牌没有 `Administration` 权限，这个开关 API 改不了（`403`），只能手点。

**如何确认真的关掉了**：直接访问 `<fork 仓库>/actions`，返回 **404** 即表示已禁用
（正常情况下是 200，可以拿上游同一个仓库的 `/actions` 做对照）。
注意不要用「工作流列表里 state 是否为 active」来判断——仓库级开关不会改单个工作流的状态，
那些 workflow 依旧显示 `active` 但不会执行。

一个附带好处：仓库级关掉后，`upstream-status.yml` 里每周一次的 cron 定时任务也一并停了。

**顺带澄清计费**：用量详细的 **SKU 明细与费率** 页，`Gross amount` 是按标价折算的用量价值，
`Billed amount` 才是实际扣款金额。public 仓库用的是标准 runner（`ubuntu-*` / `windows-*` / `macos-*`），
不含 larger runner 与 self-hosted，这部分**全部走免费额度，Billed 列是 $0**。
看到 Gross 出现两位数别慌，认准 `Billed amount` 那一列。

## 附带结论

- Qt 6.11.2 的 macOS 包确认是 universal，`lipo -info` 显示 `x86_64 arm64`；
  用 `QMAKE_APPLE_DEVICE_ARCHS=x86_64` 编译后产物是纯 x86_64 非 fat 二进制。
- macdeployqt 报的 `ERROR: ... odbc/psql` 是 SQL 驱动插件找不到系统库，
  以及未签名警告，**不影响主体**，可忽略。
- 官方 `generate-dmg.sh` 强制依赖 cmake（只为 USB helper）；
  不要 USB 转发时，自己写等价步骤（见 `scripts/build-macos-x86.sh`）反而更简单。
