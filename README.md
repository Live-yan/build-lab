# Kafbat UI Offline Package for Windows

为无互联网、无 Docker Desktop 的 Windows 环境自动构建 Kafbat UI 离线绿色包。

GitHub Actions 会自动：

1. 查询 Kafbat UI 最新 GitHub Release。
2. 下载官方可执行 JAR（`api-v*.jar`）。
3. 从 Eclipse Adoptium API 下载 Windows x64 / JRE 25 / HotSpot ZIP。
4. 校验官方提供的 SHA256（来源提供校验值时）。
5. 解压并整理为自带 Java 的便携目录。
6. 使用随包 JRE 实际启动 Kafbat UI，并检查 `/actuator/health`。
7. 验证成功后上传 `kafbat-ui-offline-windows-x64` Actions Artifact。

从 GitHub Actions 下载 Artifact 时，GitHub 会以 ZIP 文件形式下载，可以直接复制到离线 Windows。

## 离线电脑使用

下载 GitHub Actions 生成的 Artifact ZIP，复制到离线 Windows 后解压，然后双击：

```text
start.bat
```

浏览器访问：

```text
http://localhost:8080
```

启动脚本默认开启：

```text
DYNAMIC_CONFIG_ENABLED=true
```

因此可以在 Kafbat UI 网页界面中新增和修改 Kafka 集群配置，不需要在启动命令里写 Kafka 地址。

动态配置会保存到程序目录：

```text
data\dynamic_config.yaml
```

上传的 truststore、keystore 等配置相关文件会保存在：

```text
data\uploads\
```

以后更新离线包时保留 `data` 目录即可保留已有 UI 配置。

## 构建

进入仓库的 **Actions** -> **Build Kafbat UI Offline Windows Package** -> **Run workflow**。

构建相关文件推送到 `main`，或者针对 `main` 的相关 PR，也会自动运行验证。

## 包内容

```text
KafbatUI/
├─ api.jar
├─ jre/
│  └─ bin\java.exe
├─ data/
│  └─ uploads/
├─ logs/
├─ start.bat
├─ README.txt
└─ VERSION.txt
```

`VERSION.txt` 会记录实际打包的 Kafbat UI 版本、JRE 包名以及 SHA256，方便离线环境核对来源。

> 本仓库不提交 Kafbat UI 或 JRE 二进制文件；二进制文件只在 GitHub Actions 运行时从各自官方来源下载并打包。
