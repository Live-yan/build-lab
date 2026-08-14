# Dahua NetSDK MP4 download examples

本目录提供 `Dhua` 中三套 Linux SDK 的最小可运行示例：

- C SDK Linux x86_64：`设备网络SDK_C_Linux64_IS_V3.061.0000000.0.R.260515`
- C SDK Linux aarch64：`设备网络SDK_C_aarch64_IS_V3.061.0000000.0.R.260515`
- JAR SDK Linux ARM64：`设备网络SDK_JAR_LinuxARM_IS_V3.061.0000000.0.R.260511`

重点功能：SDK 初始化、登录/登出、配置文件批量任务、多个设备、多个时间段、真实 MP4 输出、下载进度、超时和资源清理。

完整说明请看：[`SDK_GUIDE_CN.md`](./SDK_GUIDE_CN.md)。

## 推荐：配置文件批量下载

先复制配置：

```bash
cp config.example.yaml config.yaml
```

建议把真实账号密码放在环境变量中：

```bash
export DAHUA_USERNAME='admin'
export DAHUA_PASSWORD='your-password'
```

先只检查配置，不访问设备：

```bash
./run.sh --config-check ./config.yaml
```

确认设备名、`channelId`、`sdkChannel`、时间段和输出文件名正确后：

```bash
./run.sh --config ./config.yaml
```

默认输出示例：

```text
recordings/
├── 1号集合点云台_20260814_100000_20260814_100500.mp4
├── 1号集合点云台_20260814_140000_20260814_140300.mp4
└── 2号应急集合点摄像头_20260814_100000_20260814_100500.mp4
```

## 配置结构

```yaml
version: 1

defaults:
  host: "192.168.1.108"
  port: 37777
  username: "${DAHUA_USERNAME}"
  password: "${DAHUA_PASSWORD}"
  outputDir: "./recordings"
  filenameTemplate: "{name}_{start}_{end}.mp4"
  recordType: 0
  downloadTimeoutSeconds: 600
  overwrite: false

devices:
  - name: "1号集合点云台"
    channelId: "1000040$1$0$3"
    sdkChannel: 3
    timeRanges:
      - start: "2026-08-14T10:00:00"
        end: "2026-08-14T10:05:00"
      - start: "2026-08-14T14:00:00"
        end: "2026-08-14T14:03:00"

  - name: "2号应急集合点摄像头"
    channelId: "1000040$1$0$1"
    sdkChannel: 1
    timeRanges:
      - start: "2026-08-14T10:00:00"
        end: "2026-08-14T10:05:00"
```

`channelId` 是保留的 DSS/ICC 平台字符串通道标识；直接 NetSDK 下载实际需要整数 `sdkChannel`。生产环境建议显式配置 `sdkChannel`。如果省略，示例会尝试从最后一个 `$<number>` 推导并打印警告。

## 单次调用

### SDK 加载/初始化

```bash
./run.sh --sdk-smoke
```

### 登录/登出

```bash
./run.sh --login-test 192.168.1.108 37777 admin 'password'
```

### 单时间段 MP4 下载

```bash
./run.sh 192.168.1.108 37777 admin 'password' 3 \
  2026-08-14T10:00:00 2026-08-14T10:05:00 \
  ./recordings/1号集合点云台.mp4
```

C 版使用 `CLIENT_DownloadByDataType + EM_REAL_DATA_TYPE_MP4`；JAR 版使用 `CLIENT_DownloadByTimeEx2`，其中 MP4 转换类型为 `3`。两者都由 Dahua SDK 输出 MP4，不是仅修改文件后缀。

## GitHub Actions

`.github/workflows/dahua-sdk-diagnostics.yml` 会：

1. Git LFS 拉取 C SDK 实体并解包。
2. 在 x86_64 和原生 ARM64 Runner 上分别编译 C++11 示例。
3. 实际执行 C SDK `init/cleanup` smoke test。
4. 将 Java 示例编译为 Java 8 字节码，并在 ARM64 Runner 上实际加载 Dahua ARM64 原生库执行 smoke test。
5. C/JAR 都执行 `--config-check config.example.yaml`。
6. 如仓库配置了设备 Secrets，则执行真实登录/登出；配置了开始/结束时间后再下载 MP4 并验证文件非空。
7. 汇总三套可运行示例、SDK 动态库/JAR、配置样例和中文完整说明，生成最终 Artifact。

真机 Secrets：

- `DAHUA_HOST`
- `DAHUA_PORT`（可选，默认 `37777`）
- `DAHUA_USERNAME`
- `DAHUA_PASSWORD`
- `DAHUA_CHANNEL`（可选，默认 `0`）
- `DAHUA_START`，格式 `YYYY-MM-DDTHH:MM:SS`
- `DAHUA_END`，格式 `YYYY-MM-DDTHH:MM:SS`

如果未配置 Secrets，CI 会明确跳过真实设备测试；这不等同于真实摄像机端到端下载已通过。
