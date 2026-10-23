# CLI、MCP 与浏览器连接器

## 本地 API

在应用「设置 → 集成」启用本地 API，默认地址为 `http://127.0.0.1:29467`。服务仅监听 loopback，写操作还需要应用允许写入。关闭 API 时没有独立服务器或守护进程。

## 原生 CLI

应用内置 `Contents/Helpers/PaperManagerCLI`。独立构建入口为 `scripts/build-cli.sh`，产物在 `.build/cli/`。

```sh
dist/PaperManager.app/Contents/Helpers/PaperManagerCLI status
dist/PaperManager.app/Contents/Helpers/PaperManagerCLI search --query transformer
dist/PaperManager.app/Contents/Helpers/PaperManagerCLI --help
```

支持文献、CSL、文集、标签读取及显式授权后的创建和 PDF 附加。默认只读；客户端允许写入后，仍检查服务端能力。`--port`、`--base-url` 或 `PAPERMANAGER_CLI_PORT`、`PAPERMANAGER_CLI_BASE_URL` 可覆盖地址。网络请求限定 loopback，包含超时和重定向拒绝。

## MCP 与 Agent 配置

`PaperManagerCLI mcp` 提供 stdio JSON-RPC，输出仅含协议帧。`export-skill` 和 `export-mcp-config` 导出所选端口及当前可执行文件路径；导出不修改任何客户端的配置。设置页提供对应导出入口。

## 浏览器

[BrowserExtension](../BrowserExtension/README.md) 是可手动载入的 MV3 源码包，包含页面元数据提取、预览、重复项处理和可选 PDF 上传。源码随应用打包；没有自动安装，也没有签名 Safari 扩展。

## 验证

`Tests/Connector/run.sh` 使用独立文库启动真实 TCP 服务，对 CLI 子进程、持久 MCP 会话及浏览器核心模块进行端到端测试。需要 Node.js 18+；应用和 CLI 运行不依赖 Node.js。
