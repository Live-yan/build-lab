# Node-RED 离线可移植包

本仓库除 Kafbat UI 离线包外，还提供 Node-RED 多协议测试环境的离线可移植包。

## 构建产物

GitHub Actions workflow：`.github/workflows/build-node-red-offline.yml`

每次构建生成两套 Artifact：

1. `node-red-offline-kylin-v10sp3-arm64`
   - 目标：银河麒麟高级服务器 V10 SP3 / ARM64 / aarch64
   - glibc 基线：2.28
   - 文件：`node-red-offline-kylin-v10sp3-arm64.tar.gz`
   - 运行时已经包含 Node.js 和全部 npm 依赖

2. `node-red-offline-windows-x64`
   - 目标：Windows x64
   - 文件：`node-red-offline-windows-x64.zip`
   - 运行时已经包含 Node.js 和全部 npm 依赖

两个 Artifact 都同时提供 SHA256 校验文件。

## 固定版本

- Node.js `24.18.1`
- Node-RED `5.0.1`
- `node-red-contrib-modbus` `5.60.1`
- `node-red-contrib-opcua` `0.2.354`
- `@oriolrius/node-red-contrib-kafka` `6.1.1`

Node-RED 自带 MQTT、HTTP、TCP、UDP、WebSocket 等常用节点。

## 麒麟 V10 SP3 ARM64

把 Artifact 下载到联网电脑，再把 `node-red-offline-kylin-v10sp3-arm64.tar.gz` 拷入离线生产环境。

```bash
sha256sum -c node-red-offline-kylin-v10sp3-arm64.tar.gz.sha256

tar -xzf node-red-offline-kylin-v10sp3-arm64.tar.gz
cd NodeRED-Kylin-V10SP3-ARM64

./check-environment.sh
./start-node-red.sh
```

浏览器访问：

```text
http://<麒麟服务器IP>:1880
```

目标服务器不需要安装 Node.js、npm，也不需要执行 `npm install`。

ARM64 包在 GitHub Actions 的原生 ARM64 runner 上构建，其中 npm 依赖安装阶段放在 AlmaLinux 8 ARM64 容器内执行，以 glibc 2.28 作为编译/运行兼容基线。构建完成后 workflow 会扫描包内全部 ELF 文件的 GLIBC 符号版本，如果发现高于 `GLIBC_2.28` 的依赖，构建会直接失败，不会发布 Artifact。

## Windows x64

解压 `node-red-offline-windows-x64.zip`，然后：

1. 双击 `check-environment.cmd`
2. 双击 `start-node-red.cmd`
3. 浏览器打开 `http://127.0.0.1:1880`

服务器或不需要自动打开浏览器时，运行：

```bat
start-node-red-no-browser.cmd
```

Windows 目标机同样不需要安装 Node.js 或 npm。

## 协议能力

### Kafka

安装包预置 `@oriolrius/node-red-contrib-kafka`，用于 Kafka Producer / Consumer 等测试。

### Modbus

安装包预置 `node-red-contrib-modbus`，可用于 Modbus TCP 和 Serial/RTU 场景。

### OPC UA

安装包预置 `node-red-contrib-opcua`，可进行 Browse、Read、Write、Subscribe 等操作。

### Node-RED 内置

Node-RED 自身已经带有 MQTT、HTTP、TCP、UDP、WebSocket 等节点，不需要额外下载。

## 运行参数

Linux 和 Windows 包都支持以下环境变量：

```text
NODE_RED_HOST=0.0.0.0
NODE_RED_PORT=1880
NODE_RED_LOG_LEVEL=info
NODE_RED_CREDENTIAL_SECRET=<your-secret>
```

默认监听 `0.0.0.0:1880`，方便局域网中的浏览器访问。

## 安全说明

为了避免在公开仓库中固化一个所有人都知道的默认密码，离线包不会内置固定管理员账号密码，因此默认 Node-RED Editor 没有 `adminAuth`。

在生产网使用时至少应：

- 使用麒麟 firewalld/iptables 或 Windows Firewall 限制 TCP/1880 的来源 IP；
- 根据实际环境在 `data/settings.js` 中配置 Node-RED `adminAuth`；
- 不要将 1880 端口暴露到不可信网络。

## GitHub Actions 自检

发布 Artifact 前会执行：

- Node.js 可执行文件架构检查；
- Node-RED、Kafka、Modbus、OPC UA 模块存在性检查；
- Node-RED 实际启动 smoke test；
- 协议节点加载错误日志检查；
- 麒麟 ARM64 包 GLIBC 2.28 兼容性扫描；
- SHA256 生成。

只有全部检查成功才上传最终离线包。
