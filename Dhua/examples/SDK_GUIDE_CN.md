# Dahua NetSDK C / JAR Linux SDK：登录、登出与 MP4 录像下载完整说明

> 本文对应 `build-lab/Dhua` 中当前测试的三套 SDK：C Linux x86_64、C Linux aarch64、JAR Linux ARM64。重点讲清这套示例**实际使用的全部调用链**、配置文件、动态库/JAR 加载方式、ARM64 Runner 验证方式和部署环境要求。
>
> Dahua NetSDK 本身包含大量设备配置、报警、预览、回放、智能分析等 API。本文不是把整个 NetSDK 几万行接口定义逐条复制，而是完整覆盖“初始化 → 登录 → 选择通道 → 按时间下载 MP4 → 查询进度 → 停止下载 → 登出 → 清理”这条业务链，并补充最相关的替代接口。

---

## 1. 当前验证的 SDK

| SDK | 仓库目录/版本 | CPU 架构 | 示例产物 |
|---|---|---|---|
| C Linux64 | `设备网络SDK_C_Linux64_IS_V3.061.0000000.0.R.260515` | x86_64 | `c-linux64/` |
| C aarch64 | `设备网络SDK_C_aarch64_IS_V3.061.0000000.0.R.260515` | ARM64 / aarch64 | `c-aarch64/` |
| JAR LinuxARM | `设备网络SDK_JAR_LinuxARM_IS_V3.061.0000000.0.R.260511` | ARM64 / aarch64 | `jar-linuxarm/` |

三套示例提供相同的使用入口：

```bash
# 只测试 SDK 动态库是否能加载、初始化和清理
./run.sh --sdk-smoke

# 测试一次登录和登出
./run.sh --login-test 192.168.1.108 37777 admin 'password'

# 只检查 YAML 配置、通道和输出文件名，不访问摄像机
./run.sh --config-check ./config.example.yaml

# 按 YAML 配置真正登录并批量下载 MP4
./run.sh --config ./config.yaml
```

也支持不使用 YAML，直接下载单个时间段：

```bash
./run.sh \
  192.168.1.108 37777 admin 'password' \
  3 \
  2026-08-14T10:00:00 \
  2026-08-14T10:05:00 \
  ./recordings/1号集合点云台.mp4
```

---

## 2. 整体连接关系：到底连接谁

这套 C/JAR NetSDK 示例走的是**设备直连**，不是 HTTP 调 DSS/ICC 平台接口。

```text
你的程序
   │
   │ Dahua NetSDK TCP
   │ host + port（常见默认端口 37777）
   ▼
摄像机 / NVR / 设备
   │
   ├─ 登录账号、密码
   ├─ 整数视频通道 nChannelID
   └─ 设备本地/存储中的历史录像

下载后
   ▼
本机 outputDir/*.mp4
```

程序首先连接配置里的 `host:port`，然后用 `username/password` 登录。登录成功得到一个 `LLONG` 登录句柄。后续所有录像下载调用都基于这个登录句柄和设备侧整数通道号执行。

如果你的系统只有 DSS/ICC 平台地址、平台 Token、类似 `1000040$1$0$3` 的通道编码，却没有该设备/NVR 的直连 IP、NetSDK 端口和账号密码，那么这是另一种“平台 API”接入架构，不能只靠当前直连 NetSDK 示例完成。

---

## 3. `channelId` 与 `sdkChannel` 必须区分

配置中支持两个字段：

```yaml
name: "1号集合点云台"
channelId: "1000040$1$0$3"
sdkChannel: 3
```

它们不是同一种参数。

### `channelId`

`channelId` 保存 DSS/ICC 一类平台中的字符串通道编码，例如：

```text
1000040$1$0$3
```

示例会保留它用于日志、配置可读性和可选文件名模板，但**不会把整个字符串传给 NetSDK**。

### `sdkChannel`

NetSDK 下载接口实际需要：

```cpp
int nChannelID
```

因此直接调用 SDK 时最终必须得到一个整数，例如：

```yaml
sdkChannel: 3
```

这是实际传入 C：

```cpp
in.nChannelID = 3;
```

或 Java：

```java
CLIENT_DownloadByTimeEx2(loginHandle, 3, ...)
```

### 为什么示例仍支持从 `channelId` 推导

如果没有填写 `sdkChannel`，示例会尝试读取 `channelId` 最后一个 `$` 后面的整数。例如：

```text
1000040$1$0$3
              └── 尝试推导为 sdkChannel = 3
```

但程序会打印 `[WARN]`，因为不同 DSS/ICC 版本、设备组织方式、NVR 通道映射方式可能存在差异。

**生产配置推荐明确写 `sdkChannel`，并在目标设备/NVR 上实际确认。**

---

## 4. 推荐的 YAML 配置

仓库提供 `config.example.yaml`。完整结构如下：

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

### 默认值和设备覆盖

`defaults` 中的连接参数会被所有设备继承。如果某个摄像机位于另一个设备/NVR，可以单独覆盖：

```yaml
- name: "独立摄像头"
  host: "192.168.1.109"
  port: 37777
  username: "admin"
  password: "${DAHUA_CAMERA_109_PASSWORD}"
  sdkChannel: 0
  outputDir: "./recordings/camera-109"
  timeRanges:
    - start: "2026-08-14T09:30:00"
      end: "2026-08-14T09:40:00"
```

### 不建议把真实密码提交进 Git

支持环境变量：

```yaml
username: "${DAHUA_USERNAME}"
password: "${DAHUA_PASSWORD}"
```

运行前：

```bash
export DAHUA_USERNAME='admin'
export DAHUA_PASSWORD='你的密码'
./run.sh --config ./config.yaml
```

不同设备也可以用不同环境变量：

```bash
export DAHUA_CAMERA_109_PASSWORD='另一台设备密码'
```

---

## 5. 多设备、多时间段如何执行

程序不是“每个时间段重新初始化 SDK”。整体生命周期是：

```text
CLIENT_Init / BaseModule.init
        │
        ▼
读取 YAML
        │
        ▼
按 host + port + username + password 建立登录会话
        │
        ├─ 设备 A / 时间段 1 → MP4
        ├─ 设备 A / 时间段 2 → MP4
        ├─ 设备 B / 时间段 1 → MP4
        │
        └─ 如果 B 使用同一连接账号，则复用同一个 loginHandle
        │
        ▼
所有任务完成
        │
        ▼
CLIENT_Logout / BaseModule.logout
        │
        ▼
CLIENT_Cleanup / BaseModule.clean
```

同一个 `host:port + username + password` 会复用一个登录句柄，减少重复登录。

如果两个设备配置了不同 IP 或不同账号，则会分别建立登录会话。

当前示例按配置顺序串行下载，优点是简单、稳定、设备负载可控。如果以后要并发下载，应额外限制并发数，并确保每个下载句柄、进度状态和回调上下文独立，不能直接把当前全局进度变量无修改地并发使用。

---

## 6. MP4 文件如何命名

默认：

```yaml
filenameTemplate: "{name}_{start}_{end}.mp4"
```

例如：

```text
1号集合点云台_20260814_100000_20260814_100500.mp4
2号应急集合点摄像头_20260814_100000_20260814_100500.mp4
```

模板支持：

| 占位符 | 含义 |
|---|---|
| `{name}` | 设备名称 |
| `{start}` | 开始时间，压缩为 `YYYYMMDD_HHMMSS` |
| `{end}` | 结束时间 |
| `{channel}` | 最终 NetSDK 整数通道 |
| `{channelId}` | 原 DSS/ICC 字符串通道标识 |

如果文件已存在且：

```yaml
overwrite: false
```

程序会生成：

```text
...mp4
..._001.mp4
..._002.mp4
```

如果希望覆盖：

```yaml
overwrite: true
```

---

# 7. C SDK：完整调用链

C x86_64 与 C ARM64 使用同一份源码 `c/dahua_download.cpp`，区别只在链接的 SDK `.so` 架构不同。

## 7.1 `CLIENT_Init`

```cpp
CLIENT_Init(on_disconnect, 0);
```

作用：

- 初始化 NetSDK 全局运行环境；
- 注册设备断线回调；
- 后续登录、下载等接口应在初始化成功之后调用。

示例程序只初始化一次。

如果失败：

```cpp
CLIENT_GetLastError()
```

可取得 SDK 错误码。

---

## 7.2 `CLIENT_LoginWithHighLevelSecurity`

核心结构：

```cpp
NET_IN_LOGIN_WITH_HIGHLEVEL_SECURITY in;
NET_OUT_LOGIN_WITH_HIGHLEVEL_SECURITY out;
```

填入：

```cpp
in.szIP       = host
in.nPort      = port
in.szUserName = username
in.szPassword = password
```

调用：

```cpp
LLONG loginHandle = CLIENT_LoginWithHighLevelSecurity(&in, &out);
```

返回非 0：登录成功。

返回 0：登录失败。

登录成功后 `out.stuDeviceInfo.nChanNum` 可获得设备报告的视频通道数量之一类基础设备信息。

后续下载 API 的第一个参数都使用这个 `loginHandle`。

---

## 7.3 C 版为什么使用 `CLIENT_DownloadByDataType`

当前 C SDK 头文件正式公开：

```cpp
CLIENT_DownloadByDataType(...)
```

对应输入结构：

```cpp
NET_IN_DOWNLOAD_BY_DATA_TYPE
```

里面直接包含：

```cpp
nChannelID
emRecordType
szSavedFileName
stStartTime
stStopTime
cbDownLoadPos
emDataType
emAudioType
```

示例构造：

```cpp
NET_IN_DOWNLOAD_BY_DATA_TYPE in = {};
NET_OUT_DOWNLOAD_BY_DATA_TYPE out = {};

in.dwSize = sizeof(in);
out.dwSize = sizeof(out);

in.nChannelID = sdkChannel;
in.emRecordType = (EM_QUERY_RECORD_TYPE)recordType;
in.szSavedFileName = outputPath;
in.stStartTime = start;
in.stStopTime = end;
in.cbDownLoadPos = on_download_pos;
in.emDataType = EM_REAL_DATA_TYPE_MP4;
in.emAudioType = EM_AUDIO_DATA_TYPE_DEFAULT;

LLONG downloadHandle = CLIENT_DownloadByDataType(
    loginHandle,
    &in,
    &out,
    5000
);
```

最重要的是：

```cpp
in.emDataType = EM_REAL_DATA_TYPE_MP4;
```

因此这是要求 SDK 做 MP4 输出，而不是把 DAV 文件后缀伪装成 `.mp4`。

### 为什么不用 C 的 `CLIENT_DownloadByTimeEx2`

当前 `libdhnetsdk.so` 动态导出符号中能看到 `CLIENT_DownloadByTimeEx2`，但这版 C 头文件没有公开对应函数声明。

为了避免自行猜测 ABI/签名，C 示例选择头文件正式公开、结构体定义完整的 `CLIENT_DownloadByDataType`。这是更稳妥的调用方式。

---

## 7.4 `NET_TIME`

开始、结束时间被转换成：

```cpp
NET_TIME
```

例如：

```text
2026-08-14T10:05:30
```

转换为：

```cpp
dwYear   = 2026
dwMonth  = 8
dwDay    = 14
dwHour   = 10
dwMinute = 5
dwSecond = 30
```

示例按设备所在地/设备配置理解这个时间。跨时区环境要确保“程序给出的本地时间”和设备录像时间基准一致。

---

## 7.5 下载进度回调 `fTimeDownLoadPosCallBack`

C 回调类型：

```cpp
fTimeDownLoadPosCallBack
```

示例通过：

```cpp
on_download_pos(...)
```

接收：

- 总大小；
- 已下载大小；
- 下载结束状态。

当前 SDK/官方 Demo 使用的完成语义之一是 `downloaded == -1`，示例把它视为完成信号。

回调之外，示例还主动轮询 `CLIENT_GetDownloadPos`，因此不是只依赖单一路径判断完成。

---

## 7.6 `CLIENT_GetDownloadPos`

```cpp
int total = 0;
int downloaded = 0;
CLIENT_GetDownloadPos(downloadHandle, &total, &downloaded);
```

作用：查询当前下载进度。

示例用它辅助判断：

```text
downloaded == -1
```

或：

```text
total > 0 && downloaded >= total
```

完成后仍会调用停止接口释放下载资源。

---

## 7.7 `CLIENT_StopDownload`

```cpp
CLIENT_StopDownload(downloadHandle);
```

作用：停止下载并释放该下载句柄对应的 SDK 资源。

即使下载已自然完成，也建议按 SDK 生命周期显式释放。

超时或异常路径同样要调用。

---

## 7.8 `CLIENT_Logout`

```cpp
CLIENT_Logout(loginHandle);
```

作用：关闭设备登录会话。

配置模式中，一个登录句柄完成它关联的所有设备/时间段后才统一登出。

---

## 7.9 `CLIENT_Cleanup`

```cpp
CLIENT_Cleanup();
```

作用：释放 NetSDK 全局资源。

应在所有下载、登出完成后调用。

---

# 8. JAR SDK：完整调用链

Java 示例：

```text
jar/DahuaDownloadExample.java
```

Java SDK 本质上是：

```text
Java 代码
   │
   ├─ netsdk-api-linuxARM-1.0.jar
   │       │
   │       └─ JNA 声明 / Java 包装层
   │
   ├─ jna.jar
   │
   └─ netsdk-dynamic-lib-linuxARM-1.0.jar
           │
           ├─ libdhnetsdk.so
           ├─ libdhconfigsdk.so
           ├─ libStreamConvertor.so
           └─ 其他 ARM64 原生库
```

最终真正和设备通信的仍是 ARM64 原生 `libdhnetsdk.so`。

---

## 8.1 `NetSDKLib.NETSDK_INSTANCE`

```java
private static final NetSDKLib SDK = NetSDKLib.NETSDK_INSTANCE;
```

这会获得 NetSDK 的 JNA 接口实例。

JAR 包中的 SDK 加载逻辑会准备对应的 ARM64 原生 `.so`，然后由 JNA 加载本地库。

之前 GitHub ARM64 Runner 的实际运行日志中可以看到类似：

```text
load library: /tmp/libdhnetsdk.so
load library: /tmp/libdhconfigsdk.so
```

这说明不是只通过 `javac` 做语法检查，而是 ARM64 Runner 真正加载了 ARM64 `.so` 并执行了 SDK 初始化。

---

## 8.2 `BaseModule.init`

示例使用 SDK 自带 Java 包装：

```java
BaseModule base = new BaseModule(SDK);
base.init(null, null, false);
```

它对应 C 层的 SDK 初始化过程。

---

## 8.3 `BaseModule.login`

```java
DeviceInfo info = base.login(
    ip,
    port,
    username,
    password
);
```

取得：

```java
long loginHandle = info.getLoginHandler();
```

后续原生接口通过：

```java
new NetSDKLib.LLong(loginHandle)
```

传回 NetSDK。

---

## 8.4 Java MP4：`CLIENT_DownloadByTimeEx2`

当前 JAR SDK 的 sources JAR 中明确给出：

```text
scType:
0 = DAV
1 = PS
3 = MP4
```

因此 Java 示例使用：

```java
NetSDKLib.LLong downloadHandle = SDK.CLIENT_DownloadByTimeEx2(
    new NetSDKLib.LLong(loginHandle),
    channel,
    recordType,
    start,
    end,
    outputPath,
    DOWNLOAD_CALLBACK,
    null,
    null,
    null,
    NetSDKLib.EM_REAL_DATA_TYPE.EM_REAL_DATA_TYPE_MP4,
    null
);
```

这里 MP4 对应值为：

```java
3
```

同样，这是 SDK 码流转换后的 MP4，不是文件扩展名替换。

---

## 8.5 为什么 Java 回调必须保存强引用

JNA 回调对象如果只创建成局部变量，而 Java GC 认为它已经不可达，在原生下载仍运行时可能发生不可预测问题。

因此示例：

```java
private static final NetSDKLib.fTimeDownLoadPosCallBack DOWNLOAD_CALLBACK = ...;
```

把回调保存为静态强引用，确保整个进程生命周期内不会被 GC 回收。

---

## 8.6 Java `CLIENT_GetDownloadPos`

Java 声明接收 JNA `Pointer`，因此示例申请两个 4 字节 `Memory`：

```java
Memory totalMem = new Memory(4);
Memory downloadedMem = new Memory(4);

SDK.CLIENT_GetDownloadPos(
    downloadHandle,
    totalMem,
    downloadedMem
);

int total = totalMem.getInt(0);
int downloaded = downloadedMem.getInt(0);
```

这样可读取 C 层 `int*` 输出参数。

---

## 8.7 `CLIENT_StopDownload`

```java
SDK.CLIENT_StopDownload(downloadHandle);
```

无论正常完成还是异常退出，示例都会尽量释放下载句柄。

---

## 8.8 `BaseModule.logout` 与 `BaseModule.clean`

```java
base.logout(loginHandle);
base.clean();
```

分别对应登录会话释放和 SDK 全局清理。

---

# 9. C 和 Java MP4 调用为什么不同

这是当前两套 SDK 封装暴露方式的差异。

| 项目 | C | Java JAR |
|---|---|---|
| MP4 主调用 | `CLIENT_DownloadByDataType` | `CLIENT_DownloadByTimeEx2` |
| MP4 参数 | `emDataType = EM_REAL_DATA_TYPE_MP4` | `scType = 3` |
| 通道类型 | `int nChannelID` | `int nChannelId` |
| 下载句柄 | `LLONG` | `NetSDKLib.LLong` |
| 进度输出 | callback + `CLIENT_GetDownloadPos` | callback + `CLIENT_GetDownloadPos` |
| 停止 | `CLIENT_StopDownload` | `CLIENT_StopDownload` |

两条路径最后都由 Dahua 原生 SDK 完成设备访问和 MP4 转换。

---

# 10. 相关但当前主流程没有使用的接口

## `CLIENT_DownloadByTimeEx`

C/JAR 都存在传统按时间下载接口。它更适合默认 DAV/私有码流下载。新示例需要明确 MP4，所以不再把它作为主路径。

## C 动态库中的 `CLIENT_DownloadByTimeEx2`

当前 `.so` 导出该符号，但 C 头文件未声明。本示例不手工声明隐藏 ABI。

## `CLIENT_PlayBackByDataType`

用于按指定数据类型回放，更偏播放/回放场景。当前目标是保存历史录像文件，所以 C 使用 `CLIENT_DownloadByDataType`。

## `CLIENT_AdaptiveDownloadByTime`

当前 C 头文件也提供自适应速度按时间下载结构。如果未来遇到大文件下载速度控制、复杂 UTC/加密录像等需求，可以进一步评估。当前最小可靠示例不引入它。

## `CLIENT_PauseDownload`

可以暂停/恢复下载。当前批量工具没有暴露暂停控制。

## `CLIENT_GetLastError`

所有关键失败路径应读取 SDK 错误码：

```cpp
CLIENT_GetLastError()
```

Java：

```java
SDK.CLIENT_GetLastError()
```

---

# 11. C SDK 需要什么外部环境

## 11.1 运行现成包

### x86_64

使用：

```text
c-linux64/
```

主机必须是 Linux x86_64。

### ARM64

使用：

```text
c-aarch64/
```

主机必须是 Linux aarch64/ARM64。

检查：

```bash
uname -m
```

预期分别类似：

```text
x86_64
```

或：

```text
aarch64
```

### 系统运行库

打包目录已经携带 Dahua SDK 的主要 `.so`。C `run.sh` 会执行：

```bash
export LD_LIBRARY_PATH="$DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

然后启动：

```bash
$DIR/dahua_download
```

因此优先从包内 `lib/` 加载 Dahua 动态库。

仍然依赖 Linux 系统基础运行库，例如：

```text
libc
libstdc++
libgcc_s
libpthread
libdl
libm
动态链接器 ld-linux
```

检查：

```bash
ldd ./dahua_download
```

如果出现：

```text
not found
```

必须先补齐对应系统库或检查 SDK `.so` 是否完整。

### 不需要外部 ffmpeg

当前 MP4 由 Dahua SDK 的码流转换能力完成，包中包含相关 SDK/StreamConvertor 动态库，不要求额外执行系统 `ffmpeg` 命令。

---

## 11.2 如果自己重新编译 C 示例

需要：

```text
g++
Dahua C SDK Include/Common
Dahua C SDK Bin
pthread
dl
```

GitHub Action 使用类似：

```bash
g++ -std=c++11 -O2 -Wall -Wextra \
  -I"$SDK/Include/Common" \
  dahua_download.cpp \
  -L"$SDK/Bin" \
  -Wl,-rpath,'$ORIGIN/lib' \
  -Wl,-rpath-link,"$SDK/Bin" \
  -ldhnetsdk -lpthread -ldl \
  -o dahua_download
```

运行最终产物不需要 g++，只有重新编译才需要。

---

# 12. JAR SDK 需要什么外部环境

JAR 示例包：

```text
jar-linuxarm/
├── dahua-download-example.jar
├── run.sh
└── lib/
    ├── jna.jar
    ├── netsdk-api-linuxARM-1.0.jar
    └── netsdk-dynamic-lib-linuxARM-1.0.jar
```

## CPU/系统

这套 `LinuxARM` JAR 内携带的是 ARM64 原生 `.so`，因此运行主机必须是 Linux ARM64/aarch64。

不能把这套 JAR 直接拿到 Windows x64 或 Linux x86_64 上期待原生 SDK 正常加载。

## Java

示例源码由 CI 使用 JDK 17 的 `javac --release 8` 编译，目标 class major version 为 52，即 Java 8 字节码级别。

因此示例应用自身目标是 Java 8+。不过最终部署时仍应在目标机器实际执行：

```bash
java -version
./run.sh --sdk-smoke
```

因为“Java 字节码版本兼容”和“ARM64 Dahua 原生库与现场 glibc/系统库兼容”是两个不同层面。

## JNA

无需单独联网 Maven 下载 JNA，包内已有：

```text
lib/jna.jar
```

`run.sh` classpath：

```bash
java -Dfile.encoding=UTF-8 \
  -cp "$DIR/dahua-download-example.jar:$DIR/lib/*" \
  DahuaDownloadExample "$@"
```

---

# 13. ARM64 GitHub Runner 是怎么验证和加载的

GitHub Action 的 ARM 任务使用：

```yaml
runs-on: ubuntu-24.04-arm
```

这是真正的 ARM64 Runner，不是 x86_64 上只做交叉编译。

## C ARM64

流程：

```text
checkout + Git LFS
      │
      ▼
解包 aarch64 C SDK
      │
      ▼
file libdhnetsdk.so
      │
      ▼
ARM64 Runner 上 g++ 编译、链接
      │
      ▼
./run.sh --sdk-smoke
      │
      ▼
CLIENT_Init → CLIENT_Cleanup
```

因此同时验证：

- SDK 大文件能从 Git LFS 拉下来；
- `.so` 架构匹配；
- 头文件与动态库可以链接；
- ARM64 Linux 能实际加载 SDK；
- 初始化/清理可以执行。

## Java ARM64

流程：

```text
ARM64 ubuntu runner
      │
      ├─ Java 编译示例
      ├─ classpath 加载 netsdk-api + jna + dynamic-lib JAR
      │
      ▼
NetSDKLib.NETSDK_INSTANCE
      │
      ▼
SDK/JNA 准备 ARM64 .so
      │
      ▼
加载 libdhnetsdk.so / libdhconfigsdk.so ...
      │
      ▼
BaseModule.init → BaseModule.clean
```

之前实际 smoke 日志已经观察到原生库从临时目录被加载，因此它不是只检查 JAR 内是否“存在一个文件名”。

---

# 14. 网络环境要求

无论 C 还是 Java，程序运行机器必须能访问目标设备/NVR。

至少检查：

```bash
ping <设备IP>
```

如果禁 ICMP，不要仅凭 ping 判断。

NetSDK 端口可用性更重要，例如默认 37777：

```bash
nc -vz 192.168.1.108 37777
```

没有 `nc` 时可用：

```bash
timeout 3 bash -c '</dev/tcp/192.168.1.108/37777' && echo OK
```

需要确保：

- 程序主机到设备/NVR 有路由；
- 中间防火墙允许 NetSDK TCP 端口；
- 账号具有登录和录像访问权限；
- 设备时间与请求的开始/结束时间一致；
- 该通道在指定时间确实存在录像。

---

# 15. GitHub Actions 真机测试怎么启用

仓库 Action 不应把真实设备密码写进 YAML。

支持 Secrets：

```text
DAHUA_HOST
DAHUA_PORT
DAHUA_USERNAME
DAHUA_PASSWORD
DAHUA_CHANNEL
DAHUA_START
DAHUA_END
```

如果只配置：

```text
HOST + USERNAME + PASSWORD
```

Action 会进行：

```text
真实登录 → 登出
```

再配置：

```text
DAHUA_START + DAHUA_END
```

则继续：

```text
登录 → MP4 下载 → 检查输出文件非空 → 登出
```

如果 Secrets 没配置，CI 会明确打印 `skipped` 原因。编译、动态库加载、SDK 初始化、配置解析和打包仍会执行，但不能把这种结果表述成“真实摄像机端到端下载已经通过”。

---

# 16. `--config-check` 有什么用

正式连接设备前先执行：

```bash
./run.sh --config-check ./config.yaml
```

它会输出类似：

```text
PLAN | name=1号集合点云台 | channelId=1000040$1$0$3 | sdkChannel=3 | 2026-08-14T10:00:00 -> 2026-08-14T10:05:00 | output=./recordings/1号集合点云台_20260814_100000_20260814_100500.mp4
```

重点检查：

- 设备名是否正确；
- `sdkChannel` 是否是期望整数；
- 每个时间段是否正确；
- 输出目录是否正确；
- 文件名是否正确；
- 是否出现 `sdkChannel omitted` 警告。

确认后再执行：

```bash
./run.sh --config ./config.yaml
```

---

# 17. 在麒麟 V10 / ARM64 现场优先做的检查

如果将 `c-aarch64` 或 `jar-linuxarm` 带到 ARM64 Linux，先执行：

```bash
uname -m
```

应为：

```text
aarch64
```

C：

```bash
cd c-aarch64
file ./dahua_download
ldd ./dahua_download
./run.sh --sdk-smoke
```

Java：

```bash
cd jar-linuxarm
java -version
./run.sh --sdk-smoke
```

然后检查配置：

```bash
./run.sh --config-check ./config.example.yaml
```

再检查目标设备端口：

```bash
timeout 3 bash -c '</dev/tcp/192.168.1.108/37777' && echo OK
```

最后才执行真实登录/下载。

如果 `--sdk-smoke` 都失败，就先处理本地动态库/JNA/系统依赖，不要先怀疑录像时间段。

如果 `--sdk-smoke` 成功、登录失败，则重点检查 IP、端口、账号密码、设备安全策略。

如果登录成功、下载失败，则重点检查：

- `sdkChannel`；
- 时间段；
- 录像是否存在；
- 账号录像权限；
- MP4 转换所需 SDK 动态库是否都在包内并能加载；
- SDK 错误码。

---

# 18. 常见错误定位顺序

推荐按层排查：

```text
1. CPU 架构
   uname -m

2. SDK 本地加载
   ./run.sh --sdk-smoke

3. 配置解析
   ./run.sh --config-check config.yaml

4. 网络端口
   TCP 37777（或实际配置端口）

5. 登录
   ./run.sh --login-test ...

6. 通道和录像时间
   sdkChannel / start / end

7. MP4 下载
   ./run.sh --config config.yaml
```

这样可以快速区分：

```text
系统兼容问题
SDK 加载问题
配置问题
网络问题
认证问题
通道映射问题
录像不存在问题
MP4 转换/下载问题
```

---

# 19. 最终包目录说明

Action 最终 Artifact `dahua-sdk-mp4-download-examples` 设计为：

```text
bundle/
├── README.md
├── SDK_GUIDE_CN.md
├── config.example.yaml
│
├── c-linux64/
│   ├── dahua_download
│   ├── dahua_download.cpp
│   ├── run.sh
│   ├── config.example.yaml
│   ├── README.md
│   ├── SDK_GUIDE_CN.md
│   └── lib/*.so*
│
├── c-aarch64/
│   ├── dahua_download
│   ├── dahua_download.cpp
│   ├── run.sh
│   ├── config.example.yaml
│   ├── README.md
│   ├── SDK_GUIDE_CN.md
│   └── lib/*.so*
│
└── jar-linuxarm/
    ├── dahua-download-example.jar
    ├── DahuaDownloadExample.java
    ├── run.sh
    ├── config.example.yaml
    ├── README.md
    ├── SDK_GUIDE_CN.md
    └── lib/*.jar
```

同时提供：

```text
dahua-sdk-mp4-download-examples.tar.gz
dahua-sdk-mp4-download-examples.zip
SHA256SUMS
```

因此拿到最终包后，不需要再从仓库手工寻找示例源码、JNA JAR 或 Dahua `.so`。

---

# 20. 推荐的生产使用方式

配置密码通过环境变量传入：

```bash
export DAHUA_USERNAME='admin'
export DAHUA_PASSWORD='********'
```

先检查：

```bash
./run.sh --sdk-smoke
./run.sh --config-check ./config.yaml
```

再执行：

```bash
./run.sh --config ./config.yaml
```

输出示例：

```text
recordings/
├── 1号集合点云台_20260814_100000_20260814_100500.mp4
├── 1号集合点云台_20260814_140000_20260814_140300.mp4
└── 2号应急集合点摄像头_20260814_100000_20260814_100500.mp4
```

这套结构把“设备连接信息、业务设备名称、DSS/ICC channelId、NetSDK 实际整数通道、多个下载时间段、输出目录和文件命名”集中在一个配置文件里，C 与 JAR 两套示例都使用同一种配置模型，便于在 x86_64 Linux 和 ARM64 Linux 环境之间切换验证。
