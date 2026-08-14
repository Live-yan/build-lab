# Dahua NetSDK login / logout / recording download examples

This directory contains minimal command-line examples for the SDKs stored under `Dhua`:

- C SDK Linux x86_64: `设备网络SDK_C_Linux64_IS_V3.061.0000000.0.R.260515`
- C SDK Linux aarch64: `设备网络SDK_C_aarch64_IS_V3.061.0000000.0.R.260515`
- JAR SDK Linux ARM: `设备网络SDK_JAR_LinuxARM_IS_V3.061.0000000.0.R.260511`

The examples use the SDK's high-security login API and `CLIENT_DownloadByTimeEx` for recording download.

## Commands in packaged artifacts

Each packaged SDK example exposes the same three modes.

### 1. Native SDK smoke test

```bash
./run.sh --sdk-smoke
```

Loads the SDK native libraries, calls SDK initialization, and cleans up. It does not connect to a device.

### 2. Login / logout test

```bash
./run.sh --login-test 192.168.1.108 37777 admin 'password'
```

### 3. Download recording by time

```bash
./run.sh 192.168.1.108 37777 admin 'password' 0 \
  2026-08-14T10:00:00 2026-08-14T10:05:00 ./download.dav
```

The final optional argument is the record type. The default is `0`, meaning all recording types.

```bash
./run.sh <ip> <port> <user> <password> <channel> <start> <end> <output.dav> [recordType]
```

The download timeout defaults to 300 seconds and can be changed with:

```bash
export DAHUA_DOWNLOAD_TIMEOUT_SECONDS=600
```

## GitHub Actions device integration test

Compilation, native-library loading, SDK initialization, and packaging always run in GitHub Actions. Real device tests run only when repository Secrets are configured, because device credentials must not be committed.

Supported Secrets:

- `DAHUA_HOST`
- `DAHUA_PORT` (optional, default `37777`)
- `DAHUA_USERNAME`
- `DAHUA_PASSWORD`
- `DAHUA_CHANNEL` (optional, default `0`)
- `DAHUA_START` in `YYYY-MM-DDTHH:MM:SS`
- `DAHUA_END` in `YYYY-MM-DDTHH:MM:SS`

If host/username/password are present, Actions performs login/logout. If start/end are also present, it additionally downloads the requested recording segment.

## Action artifact

The final `package` job uploads `dahua-sdk-download-examples`. It contains:

- `c-linux64/`: x86_64 executable, required `.so` files, source, `run.sh`
- `c-aarch64/`: ARM64 executable, required `.so` files, source, `run.sh`
- `jar-linuxarm/`: runnable example JAR, Dahua/JNA dependency JARs, source, `run.sh`
- compressed `.tar.gz` and `.zip` copies of the complete bundle

Use these examples only with devices and recordings you are authorized to access.
