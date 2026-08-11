# Kafbat UI Offline Package for Windows

为无互联网、无 Docker Desktop 的 Windows 环境自动构建 Kafbat UI 离线绿色包。

GitHub Actions 会自动：

1. 查询 Kafbat UI 最新 GitHub Release。
2. 下载官方可执行 JAR（`api-v*.jar`）。
3. 从 Eclipse Adoptium API 下载 Windows x64 / JRE 25 / HotSpot ZIP。
4. 解压并整理为便携目录。
5. 生成 `start.bat`。
6. 压缩为 `kafbat-ui-offline-windows-x64.zip` 并上传到 Actions Artifact。

## 离线电脑使用

下载 GitHub Actions 生成的 ZIP，复制到离线 Windows 后解压，然后双击：

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

因此可以在 Kafbat UI 网页界面中新增和修改 Kafka 集群配置。

## 构建

进入仓库的 **Actions** -> **Build Kafbat UI Offline Windows Package** -> **Run workflow**。

也会在构建相关文件推送到 `main` 时自动运行。

## 包内容

```text
KafbatUI/
├─ api.jar
├─ jre/
├─ start.bat
├─ stop.bat
├─ README.txt
└─ VERSION.txt
```

> 本仓库不提交 Kafbat UI 或 JRE 二进制文件；二进制文件只在 GitHub Actions 运行时从各自官方来源下载并打包。
