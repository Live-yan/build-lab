# Kafbat UI Offline Packages

为无互联网环境自动构建可直接运行的 Kafbat UI 离线包，目前支持：

- Windows x64：无 Docker Desktop、无需系统安装 Java。
- 银河麒麟高级服务器操作系统 V10 SP3 / Linux aarch64：无 Docker、无需系统安装 Java，通过浏览器使用 Web UI。

Kafbat UI 是 Web 管理界面。麒麟服务器本身不需要安装桌面环境；服务启动后，在能够访问服务器的电脑浏览器中打开 `http://服务器IP:8080` 即可。

## Windows x64 离线包

GitHub Actions：**Build Kafbat UI Offline Windows Package**

自动执行：

1. 查询 Kafbat UI 最新 GitHub Release。
2. 下载官方可执行 JAR（`api-v*.jar`）。
3. 下载 Eclipse Temurin Windows x64 / JRE 25 / HotSpot ZIP。
4. 校验官方 SHA256（来源提供校验值时）。
5. 生成自带 Java 的便携目录。
6. 使用随包 JRE 实际启动 Kafbat UI，并检查 `/actuator/health`。
7. 上传 `kafbat-ui-offline-windows-x64` Actions Artifact。

### Windows 使用

下载 Artifact ZIP，复制到离线 Windows 后解压，然后双击：

```text
start.bat
```

浏览器访问：

```text
http://localhost:8080
```

## 银河麒麟 V10 SP3 ARM64 离线包

GitHub Actions：**Build Kafbat UI Offline Kylin ARM64 Package**

构建运行在 GitHub 原生 `aarch64` Runner 上，并自动：

1. 查询 Kafbat UI 最新 GitHub Release 并下载官方 JAR。
2. 下载 Eclipse Temurin Linux aarch64 / JRE 25 / HotSpot `tar.gz`。
3. 校验 JAR/JRE SHA256。
4. 验证随包 `java` 确实是 ARM64 ELF。
5. 扫描随包 JRE 中 ELF 文件的 GLIBC symbol version，要求最大依赖不高于 `GLIBC_2.28`，用于适配麒麟 V10 SP3 的 glibc 2.28 基线。
6. 在原生 ARM64 Runner 上实际启动 Kafbat UI，并检查 `/actuator/health`。
7. 生成 `tar.gz`，保留 Linux 脚本可执行权限和 JRE 文件权限。
8. 上传 `kafbat-ui-offline-kylin-v10sp3-arm64` Artifact。

### 麒麟离线使用

将生成的文件复制到离线 ARM64 麒麟服务器：

```text
kafbat-ui-offline-kylin-v10sp3-arm64.tar.gz
kafbat-ui-offline-kylin-v10sp3-arm64.tar.gz.sha256
```

校验：

```bash
sha256sum -c kafbat-ui-offline-kylin-v10sp3-arm64.tar.gz.sha256
```

解压：

```bash
tar -xzf kafbat-ui-offline-kylin-v10sp3-arm64.tar.gz
cd KafbatUI-Kylin-ARM64
```

启动：

```bash
./start.sh
```

查看状态：

```bash
./status.sh
```

查看日志：

```bash
tail -f logs/kafbat-ui.log
```

停止：

```bash
./stop.sh
```

然后在同网络电脑浏览器中访问：

```text
http://麒麟服务器IP:8080
```

如果服务器防火墙启用，需要允许 TCP/8080；也可以通过环境变量修改端口：

```bash
SERVER_PORT=18080 ./start.sh
```

## Kafka 配置与持久化

两个平台的启动脚本都默认开启：

```text
DYNAMIC_CONFIG_ENABLED=true
```

因此可以直接在 Kafbat UI 网页的 Configuration Wizard 中新增/修改 Kafka 集群，不需要把 Kafka 地址写死在启动参数中。

动态配置保存在程序目录：

```text
data/dynamic_config.yaml
```

上传的 truststore、keystore 等配置相关文件保存在：

```text
data/uploads/
```

更新离线包时保留 `data` 目录即可保留已有 UI 配置。

## 手动重新构建

进入仓库 **Actions**，选择对应工作流，然后点击 **Run workflow**：

- `Build Kafbat UI Offline Windows Package`
- `Build Kafbat UI Offline Kylin ARM64 Package`

构建相关文件推送到 `main` 或针对 `main` 的相关 PR，也会自动运行验证。

## 安全与可验证性

`VERSION.txt` 会记录实际打包的 Kafbat UI 版本、JRE 包名和 SHA256。麒麟 ARM64 包额外包含 `COMPATIBILITY.txt`，记录构建时扫描到的最高 GLIBC 依赖版本。

> 本仓库不提交 Kafbat UI 或 JRE 二进制文件；二进制文件只在 GitHub Actions 运行时从各自官方来源下载、校验、验证并打包。
