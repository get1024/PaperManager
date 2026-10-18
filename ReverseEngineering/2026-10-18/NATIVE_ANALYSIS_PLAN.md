# Lattice 原生函数分析方案

检查日期：2026-10-18。此报告区分宿主检查、REA 已保存证据和后续分析计划；环境检查本身不产生 REA Evidence ID。

## 已核实环境与目标

- 目标仍为 `/Applications/Lattice.app/Contents/MacOS/Lattice`，3.0 build 26，arm64/x86_64 universal Mach-O。
- 2026-10-18 重新计算 SHA-256：`dc53de855a679eb91f4ad3d6732cd754aecfb655ac5d2f0aa7331517e43f05ea`，与 10 月 13 日证据一致。
- `java_home -V` 报告未安装 Java Runtime；`/usr/bin/java` 为系统占位启动器。常见安装目录和 PATH 没有可用 Ghidra、Hopper、IDA。
- 已有 CLT：`/Library/Developer/CommandLineTools`，包含 clang、Swift、swift-demangle、make 和 bison 2.3。系统原 DEVELOPER_DIR 指向缺失的 Xcode；只为本次命令设置 CLT 路径，不改全局配置。
- 已安装 npm REA 6.4.0：`~/.npm/_npx/dea9475797100b20/node_modules/rea-agents`。本地 `GhidraInstallationPolicy.js` 验证版本为 12.1.4，接受 12.1.x；完整 JDK 的最低默认版本为 21，最终读取目标 Ghidra 的 java.min/java.max。

## 官方依赖与完整性

以下大小和 digest 由官方 GitHub release API 读取，并与 release 页核对。下载将保存在项目忽略目录 `.build/tools/`，不会安装系统软件、修改 Codex 配置或替换共享 MCP 会话。

| 依赖 | 压缩大小 | 官方 SHA-256 |
| --- | ---: | --- |
| Ghidra 12.1.4 PUBLIC 20260921 ZIP | 569,649,598 bytes (543.26 MiB) | `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db` |
| Temurin JDK 21.0.12.1+1 macOS aarch64 tar.gz | 200,073,404 bytes (190.80 MiB) | `3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998` |

官方资源：

- [Ghidra release 与 digest](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.1.4_build)
- [Ghidra ZIP](https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip)
- [Ghidra 12.1.4 入门文档](https://github.com/NationalSecurityAgency/ghidra/blob/Ghidra_12.1.4_build/GhidraDocs/GettingStarted.md)
- [Temurin release](https://github.com/adoptium/temurin21-binaries/releases/tag/jdk-21.0.12.1%2B1)
- [Temurin JDK tar.gz](https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz)
- [REA provider 与 arm64 构建说明](https://github.com/morluto/rea/blob/main/docs/installation.md#macos-arm64-native-decompiler)

总下载约 734 MiB；Ghidra 文档要求安装本体约 1 GB，另外预留 JDK、构建目录和临时 analysis database 空间。没有实测解压体积前，不报告精确磁盘占用。

## Apple Silicon 所需步骤

Ghidra 官方多平台 ZIP 没有 macOS 原生 decompiler；它带有源码。REA 检查实际可执行文件头而不只检查目录名，因此不能把 Linux/x86_64 binary 放在 mac_arm_64 目录蒙混通过。

只需在提取后的官方目录使用已有 CLT：

```sh
cd "$GHIDRA_INSTALL_DIR/Ghidra/Features/Decompiler/src/decompile/cpp"
DEVELOPER_DIR=/Library/Developer/CommandLineTools make ghidra_opt ARCH_TYPE="-arch arm64" OSDIR=mac_arm_64
```

构建后，目标位置为 `Ghidra/Features/Decompiler/os/mac_arm_64/decompile`，仅当目标文件不存在时复制。REA 官方文档已验证此命令配合 clang 17/bison 2.3 的 arm64 输出；若当前 SDK 拒绝旧 deployment target，可使用该文档给出的 `ADDITIONAL_FLAGS="-w"`。本次仍须检查生成文件 `file` 结果和 provider doctor；文档成功不代替本机验证。

JDK 解压后的 `Contents/Home` 以进程环境 `JAVA_HOME` 指定；使用 arm64 JDK。REA 的 `GHIDRA_INSTALL_DIR`、`DEVELOPER_DIR`、`GHIDRA_SWIFT_DEMANGLER` 也仅作用于项目 CLI 进程。无需 Homebrew、sudo、修改 shell 配置或修改 Codex MCP 注册。

## Swift 与证据边界

- 原 Lattice 大部分 Swift 函数名已剥离。反编译器提供机器码推导的 C 风格伪代码、函数范围、静态 xref、控制流和部分类型，不会还原可编译的原始 Swift 项目或 SwiftUI 源码。
- Ghidra 12.1.4 有 Swift 类型元数据分析器和 Swift demangler；后者依赖已有 `swift-demangle`。其官方 [SwiftDemangler README](https://github.com/NationalSecurityAgency/ghidra/blob/Ghidra_12.1.4_build/Ghidra/Features/SwiftDemangler/README.md) 列出 `GHIDRA_SWIFT_DEMANGLER`。被剥离的名称无法凭 demangle 凭空恢复。
- [REA 的 Swift 验证通道](https://github.com/morluto/rea/blob/main/docs/testing.md) 验证 macOS x64/arm64 Mach-O 的现代/旧式 mangled names 和 dSYM 有无差异；这不承诺对任意商业 Swift 程序的所有泛型、闭包、async、witness table 和动态调用都完整恢复。
- 安装版 `ReaGhidraBridge.java` 明确说明静态 ReferenceManager 调用目标不分类 Objective-C/Swift/vtable/closure 机制；未解析计算调用需保留 unknown，不能当作不存在。
- REA main 文档已有部分 6.4.0 未暴露的环境开关，例如 `REA_GHIDRA_DISABLED_ANALYZERS`；必须依据本地安装版源码/实际 schema，不直接照搬新文档。
- 当前 Lattice 没有 get-task-allow。离线反编译无需改签名；不把静态分析扩展为 LLDB attach，也不改变原应用/原文库。

## 此次函数分析目标

优先根据已保存 Swift/ObjC metadata 中的可复现地址、字符串 xref 选择 DuplicateDetector / import / citekey / metadata / FileLibrary 一处关键实现，运行私有 REA CLI `--provider ghidra`，保存完整 Evidence。不能只根据帮助文本推断 duplicate matching 或文件移动规则。

对选定函数输出：目标 SHA、provider/version、canonical procedure address、伪代码和引用 Evidence ID、观察到的输入/比较/状态变化，以及仍未确定的动态派发和运行行为。保持共享 MCP 会话由 root 管理。

## 执行状态

- 官方 release URL、大小、hash 已核对。
- 已获授权在 `.build/tools/` 下载并构建依赖。初次 Ghidra 下载在 GitHub release-assets TLS 连接失败；采用同一官方 URL 的有界重试。Adoptium API TLS 失败后改读其官方 GitHub release API，未改用镜像。
- 下载/解压/编译/真实函数分析成功与否将在此报告追加实际结果。

### 依赖已在本机完成

两份下载均通过上述官方完整 SHA-256 校验。Ghidra 本体解压约 880 MiB，JDK 约 336 MiB；构建生成的 decompiler 已由 `file` 确认为 Mach-O arm64。所有范围下载临时片段在最终 hash 通过后已删除，保留官方原始压缩包和构建日志。

`native/ghidra-doctor-summary.json` 实际结果 `healthy: true`；Node、provider、平台、arm64 架构、安装元数据、Ghidra 12.1.4 版本、headless launcher、原生 decompiler 与完整 JDK 共九项通过。JDK 实际报告 aarch64 / Mac OS X / 64-bit / 21.0.12.1。

可复现命令包装器为 `.build/tools/rea-ghidra`，环境只作用于启动的进程。例如：

```sh
.build/tools/rea-ghidra doctor --provider ghidra --json
.build/tools/rea-ghidra function .build/tools/native-analysis/Lattice.arm64 0x100361020 --provider ghidra --format json
```

安装版 Ghidra provider 明确拒绝 universal Mach-O，以免错误选择 slice。因此已用系统 `lipo -thin arm64` 生成独立派生副本，未写原文件：

| 对象 | SHA-256 |
| --- | --- |
| 原 universal Lattice | `dc53de855a679eb91f4ad3d6732cd754aecfb655ac5d2f0aa7331517e43f05ea` |
| 派生 `.build/tools/native-analysis/Lattice.arm64` | `1376e0583a56bb9c27e8a430038f3ebc2a296a57870f48c9a17b7955b6e07679` |

原文件和派生文件的地址映射保持同一 arm64 VM 基址；函数 Evidence 的 subject digest 必须使用派生 SHA，并保留此转换链，不能把派生分析假报为原 universal 文件的同一个 Evidence。

### 第一条真实函数 Evidence 已完成

`native/rename-pdf-action.function.json` 已产生完整 REA 函数记录（约 252 KiB）：

- Evidence ID：`ev_bffa7281e6dda7d75a1429c07e2993c06a1a2fd95440bf2cf15187f5d0273c83`。
- Provider：Ghidra 12.1.4；操作 `analyze_function`；subject 为上述 arm64 派生 SHA。
- 完整函数范围 `0x100361020`–`0x10036118b`，364 bytes，91 条 ARM64 指令；伪代码、完整函数体、静态引用、控制流和 value-flow 均在完整记录中。
- 原 dispatch metadata 的 `renamePDFsClicked:` 入口为 `0x10036118c`。普通 CLT 反汇编将其连到共享 MainActor 包装器 `0x100360e7c`，再以函数参数指定 `0x100361020`。Ghidra 进一步显示 refreshMetadata / BibTeX/RIS/详细导出/复制 / organizePDFs / renamePDFs 等多个操作都以参数数据引用该共享函数；这些 PARAM xref 不是直接 call edges。
- 可确认的操作边界：处理一个枚举式选择结果、取得/转换文献数组；只有数组非空且回调指针非空时，才调用该回调；调用前后存在闭包上下文的 retain/release。具体重命名规则、文件路径变化和回调实现仍未在此函数中解析。
- 不应把自动生成的 C 伪代码当作 Swift 类型真值。该例有 `undefined` 参数、`unaff_x20` 和把 Swift 寄存器返回误表为零值地址的片段；判断输入/控制流时需回看 ARM64 指令。未运行目标来验证这些静态推断。

这次默认全程序导入约 6 分钟，最终正常完成并由 CLI 关闭私有 session、删除其临时数据库。导入期间若干其他函数出现无法读地址或 VarnodeContext 地址空间警告；它们不能外推成当前函数全部类型恢复成功，也不是原应用崩溃证据。本次没有为读取同一结果重复分析。

摘要和供人工阅读的伪代码分别为 `native/rename-pdf-action.summary.json` 和 `native/rename-pdf-action.pseudocode.c`；后续可复用完整 Evidence 做投影视图，无需再次导入。
