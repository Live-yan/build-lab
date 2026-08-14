import com.netsdk.lib.NetSDKLib;
import com.netsdk.module.BaseModule;
import com.netsdk.module.entity.DeviceInfo;
import com.sun.jna.Memory;
import com.sun.jna.Pointer;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class DahuaDownloadExample {
    private static final NetSDKLib SDK = NetSDKLib.NETSDK_INSTANCE;
    private static final AtomicBoolean DOWNLOAD_DONE = new AtomicBoolean(false);
    private static final AtomicInteger LAST_PERCENT = new AtomicInteger(-1);

    // JNA callbacks must stay strongly reachable for the complete native call lifecycle.
    private static final NetSDKLib.fTimeDownLoadPosCallBack DOWNLOAD_CALLBACK =
            new NetSDKLib.fTimeDownLoadPosCallBack() {
                @Override
                public void invoke(NetSDKLib.LLong handle, int total, int downloaded, int index,
                                   NetSDKLib.NET_RECORDFILE_INFO.ByValue recordInfo, Pointer user) {
                    if (downloaded == -1) {
                        LAST_PERCENT.set(100);
                        DOWNLOAD_DONE.set(true);
                        System.out.println("download completed");
                        return;
                    }
                    if (total > 0) {
                        int percent = (int) Math.min(100L, ((long) downloaded * 100L) / total);
                        int old = LAST_PERCENT.getAndSet(percent);
                        if (percent != old && (percent % 10 == 0 || percent == 100)) {
                            System.out.println("download progress: " + percent + "%");
                        }
                    }
                }
            };

    private static class TimeRange {
        String start = "";
        String end = "";
    }

    private static class Defaults {
        String host = "";
        int port = 37777;
        String username = "";
        String password = "";
        String outputDir = "./recordings";
        String filenameTemplate = "{name}_{start}_{end}.mp4";
        int recordType = 0;
        int timeoutSeconds = 600;
        boolean overwrite = false;
    }

    private static class Device {
        String name = "";
        String channelId = "";
        int sdkChannel = -1;
        String host = "";
        int port = -1;
        String username = "";
        String password = "";
        String outputDir = "";
        String filenameTemplate = "";
        int recordType = -1;
        int timeoutSeconds = -1;
        Boolean overwrite = null;
        List<TimeRange> timeRanges = new ArrayList<TimeRange>();
    }

    private static class Config {
        Defaults defaults = new Defaults();
        List<Device> devices = new ArrayList<Device>();
    }

    private static class ResolvedDevice {
        String host;
        int port;
        String username;
        String password;
        String outputDir;
        String filenameTemplate;
        int recordType;
        int timeoutSeconds;
        boolean overwrite;
        int channel;
    }

    private static String trim(String s) {
        return s == null ? "" : s.trim();
    }

    private static String stripInlineComment(String input) {
        boolean single = false;
        boolean dbl = false;
        for (int i = 0; i < input.length(); i++) {
            char c = input.charAt(i);
            if (c == '\'' && !dbl) single = !single;
            else if (c == '"' && !single) dbl = !dbl;
            else if (c == '#' && !single && !dbl &&
                    (i == 0 || Character.isWhitespace(input.charAt(i - 1)))) {
                return input.substring(0, i);
            }
        }
        return input;
    }

    private static String unquote(String value) {
        value = trim(value);
        if (value.length() >= 2) {
            char a = value.charAt(0);
            char b = value.charAt(value.length() - 1);
            if ((a == '"' && b == '"') || (a == '\'' && b == '\'')) {
                return value.substring(1, value.length() - 1);
            }
        }
        return value;
    }

    private static String[] splitKeyValue(String input) {
        boolean single = false;
        boolean dbl = false;
        for (int i = 0; i < input.length(); i++) {
            char c = input.charAt(i);
            if (c == '\'' && !dbl) single = !single;
            else if (c == '"' && !single) dbl = !dbl;
            else if (c == ':' && !single && !dbl) {
                String key = trim(input.substring(0, i));
                String value = unquote(input.substring(i + 1));
                if (!key.isEmpty()) return new String[]{key, value};
            }
        }
        return null;
    }

    private static boolean parseBoolean(String value) {
        String v = value.toLowerCase();
        return "true".equals(v) || "yes".equals(v) || "1".equals(v);
    }

    private static void setDefaultField(Defaults d, String key, String value) {
        if ("host".equals(key)) d.host = value;
        else if ("port".equals(key)) d.port = Integer.parseInt(value);
        else if ("username".equals(key)) d.username = value;
        else if ("password".equals(key)) d.password = value;
        else if ("outputDir".equals(key)) d.outputDir = value;
        else if ("filenameTemplate".equals(key)) d.filenameTemplate = value;
        else if ("recordType".equals(key)) d.recordType = Integer.parseInt(value);
        else if ("downloadTimeoutSeconds".equals(key)) d.timeoutSeconds = Integer.parseInt(value);
        else if ("overwrite".equals(key)) d.overwrite = parseBoolean(value);
    }

    private static void setDeviceField(Device d, String key, String value) {
        if ("name".equals(key)) d.name = value;
        else if ("channelId".equals(key)) d.channelId = value;
        else if ("sdkChannel".equals(key)) d.sdkChannel = Integer.parseInt(value);
        else if ("host".equals(key)) d.host = value;
        else if ("port".equals(key)) d.port = Integer.parseInt(value);
        else if ("username".equals(key)) d.username = value;
        else if ("password".equals(key)) d.password = value;
        else if ("outputDir".equals(key)) d.outputDir = value;
        else if ("filenameTemplate".equals(key)) d.filenameTemplate = value;
        else if ("recordType".equals(key)) d.recordType = Integer.parseInt(value);
        else if ("downloadTimeoutSeconds".equals(key)) d.timeoutSeconds = Integer.parseInt(value);
        else if ("overwrite".equals(key)) d.overwrite = parseBoolean(value);
    }

    private static Config loadConfig(String path) throws Exception {
        Config config = new Config();
        BufferedReader reader = new BufferedReader(new InputStreamReader(
                new FileInputStream(path), StandardCharsets.UTF_8));
        String raw;
        int lineNo = 0;
        int section = 0; // 0 root, 1 defaults, 2 devices, 3 ranges
        Device currentDevice = null;
        TimeRange currentRange = null;
        try {
            while ((raw = reader.readLine()) != null) {
                lineNo++;
                if (raw.indexOf('\t') >= 0) {
                    throw new IllegalArgumentException("config line " + lineNo + ": tabs are not supported");
                }
                String line = stripInlineComment(raw);
                if (trim(line).isEmpty()) continue;
                int indent = 0;
                while (indent < line.length() && line.charAt(indent) == ' ') indent++;
                String content = trim(line.substring(indent));

                if (indent == 0) {
                    currentDevice = null;
                    currentRange = null;
                    if ("defaults:".equals(content)) section = 1;
                    else if ("devices:".equals(content)) section = 2;
                    else {
                        String[] kv = splitKeyValue(content);
                        if (kv != null && "version".equals(kv[0])) continue;
                        throw new IllegalArgumentException("config line " + lineNo + ": unsupported root entry " + content);
                    }
                    continue;
                }

                if (section == 1 && indent == 2) {
                    String[] kv = splitKeyValue(content);
                    if (kv == null) throw new IllegalArgumentException("config line " + lineNo + ": expected key: value");
                    setDefaultField(config.defaults, kv[0], kv[1]);
                    continue;
                }

                if ((section == 2 || section == 3) && indent == 2 && content.startsWith("-")) {
                    currentDevice = new Device();
                    config.devices.add(currentDevice);
                    currentRange = null;
                    section = 2;
                    String rest = trim(content.substring(1));
                    if (!rest.isEmpty()) {
                        String[] kv = splitKeyValue(rest);
                        if (kv == null) throw new IllegalArgumentException("config line " + lineNo + ": invalid device entry");
                        setDeviceField(currentDevice, kv[0], kv[1]);
                    }
                    continue;
                }

                if (currentDevice != null && indent == 4) {
                    if ("timeRanges:".equals(content)) {
                        section = 3;
                        currentRange = null;
                        continue;
                    }
                    String[] kv = splitKeyValue(content);
                    if (kv == null) throw new IllegalArgumentException("config line " + lineNo + ": invalid device field");
                    setDeviceField(currentDevice, kv[0], kv[1]);
                    continue;
                }

                if (currentDevice != null && section == 3 && indent == 6 && content.startsWith("-")) {
                    currentRange = new TimeRange();
                    currentDevice.timeRanges.add(currentRange);
                    String rest = trim(content.substring(1));
                    if (!rest.isEmpty()) {
                        String[] kv = splitKeyValue(rest);
                        if (kv == null) throw new IllegalArgumentException("config line " + lineNo + ": invalid time range");
                        if ("start".equals(kv[0])) currentRange.start = kv[1];
                        else if ("end".equals(kv[0])) currentRange.end = kv[1];
                    }
                    continue;
                }

                if (currentRange != null && indent == 8) {
                    String[] kv = splitKeyValue(content);
                    if (kv == null) throw new IllegalArgumentException("config line " + lineNo + ": invalid time field");
                    if ("start".equals(kv[0])) currentRange.start = kv[1];
                    else if ("end".equals(kv[0])) currentRange.end = kv[1];
                    continue;
                }

                throw new IllegalArgumentException("config line " + lineNo + ": unsupported indentation/entry " + content);
            }
        } finally {
            reader.close();
        }
        if (config.devices.isEmpty()) throw new IllegalArgumentException("config has no devices");
        return config;
    }

    private static String expandEnv(String input, boolean strict) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < input.length();) {
            if (i + 2 < input.length() && input.charAt(i) == '$' && input.charAt(i + 1) == '{') {
                int end = input.indexOf('}', i + 2);
                if (end < 0) {
                    out.append(input.substring(i));
                    break;
                }
                String name = input.substring(i + 2, end);
                String value = System.getenv(name);
                if (value != null) out.append(value);
                else if (strict) throw new IllegalArgumentException("missing environment variable: " + name);
                else out.append(input.substring(i, end + 1));
                i = end + 1;
            } else {
                out.append(input.charAt(i++));
            }
        }
        return out.toString();
    }

    private static int deriveSdkChannel(Device d) {
        if (d.sdkChannel >= 0) return d.sdkChannel;
        int pos = d.channelId.lastIndexOf('$');
        if (pos < 0 || pos + 1 >= d.channelId.length()) return -1;
        try {
            int channel = Integer.parseInt(d.channelId.substring(pos + 1));
            System.err.println("[WARN] " + d.name + ": sdkChannel omitted; derived " + channel +
                    " from channelId=" + d.channelId +
                    ". Prefer explicit sdkChannel after verifying the device/NVR mapping.");
            return channel;
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    private static ResolvedDevice resolveDevice(Config config, Device d, boolean strictEnv) {
        ResolvedDevice r = new ResolvedDevice();
        r.host = expandEnv(d.host.isEmpty() ? config.defaults.host : d.host, strictEnv);
        r.port = d.port >= 0 ? d.port : config.defaults.port;
        r.username = expandEnv(d.username.isEmpty() ? config.defaults.username : d.username, strictEnv);
        r.password = expandEnv(d.password.isEmpty() ? config.defaults.password : d.password, strictEnv);
        r.outputDir = expandEnv(d.outputDir.isEmpty() ? config.defaults.outputDir : d.outputDir, strictEnv);
        r.filenameTemplate = d.filenameTemplate.isEmpty() ? config.defaults.filenameTemplate : d.filenameTemplate;
        r.recordType = d.recordType >= 0 ? d.recordType : config.defaults.recordType;
        r.timeoutSeconds = d.timeoutSeconds >= 0 ? d.timeoutSeconds : config.defaults.timeoutSeconds;
        r.overwrite = d.overwrite != null ? d.overwrite.booleanValue() : config.defaults.overwrite;
        r.channel = deriveSdkChannel(d);
        if (d.name.isEmpty() || r.host.isEmpty() || r.port <= 0 || r.username.isEmpty() ||
                (strictEnv && r.password.isEmpty()) || r.channel < 0 || d.timeRanges.isEmpty()) {
            throw new IllegalArgumentException("invalid device config for '" + d.name +
                    "': need name, host, port, credentials, sdkChannel/channelId and timeRanges");
        }
        return r;
    }

    private static NetSDKLib.NET_TIME parseTime(String text) {
        String normalized = text.replace('T', ' ');
        String[] parts = normalized.split("[\\- :]");
        if (parts.length != 6) throw new IllegalArgumentException("expected YYYY-MM-DDTHH:MM:SS: " + text);
        NetSDKLib.NET_TIME time = new NetSDKLib.NET_TIME();
        time.dwYear = Integer.parseInt(parts[0]);
        time.dwMonth = Integer.parseInt(parts[1]);
        time.dwDay = Integer.parseInt(parts[2]);
        time.dwHour = Integer.parseInt(parts[3]);
        time.dwMinute = Integer.parseInt(parts[4]);
        time.dwSecond = Integer.parseInt(parts[5]);
        if (time.dwMonth < 1 || time.dwMonth > 12 || time.dwDay < 1 || time.dwDay > 31 ||
                time.dwHour < 0 || time.dwHour > 23 || time.dwMinute < 0 || time.dwMinute > 59 ||
                time.dwSecond < 0 || time.dwSecond > 59) {
            throw new IllegalArgumentException("invalid date/time: " + text);
        }
        return time;
    }

    private static String sanitizeName(String value) {
        String s = value.replaceAll("[\\\\/:*?\"<>|\\s]+", "_");
        s = s.replaceAll("_+", "_");
        s = s.replaceAll("[_.]+$", "");
        return s.isEmpty() ? "camera" : s;
    }

    private static String compactTime(String value) {
        String digits = value.replaceAll("[^0-9]", "");
        if (digits.length() >= 14) return digits.substring(0, 8) + "_" + digits.substring(8, 14);
        return sanitizeName(value);
    }

    private static String renderFilename(String pattern, Device d, int channel, TimeRange range) {
        String result = pattern == null || pattern.isEmpty() ? "{name}_{start}_{end}.mp4" : pattern;
        result = result.replace("{name}", sanitizeName(d.name));
        result = result.replace("{channel}", Integer.toString(channel));
        result = result.replace("{channelId}", sanitizeName(d.channelId));
        result = result.replace("{start}", compactTime(range.start));
        result = result.replace("{end}", compactTime(range.end));
        result = sanitizeName(result);
        if (!result.toLowerCase().endsWith(".mp4")) result += ".mp4";
        return result;
    }

    private static File chooseOutput(File dir, String filename, boolean overwrite) {
        File output = new File(dir, filename);
        if (overwrite || !output.exists()) return output;
        int dot = filename.lastIndexOf('.');
        String stem = dot < 0 ? filename : filename.substring(0, dot);
        String ext = dot < 0 ? "" : filename.substring(dot);
        for (int i = 1; i < 10000; i++) {
            File candidate = new File(dir, stem + String.format("_%03d", i) + ext);
            if (!candidate.exists()) return candidate;
        }
        return new File(dir, stem + "_overflow" + ext);
    }

    private static DeviceInfo login(BaseModule base, String ip, int port, String user, String password) {
        DeviceInfo info = base.login(ip, port, user, password);
        if (info == null || info.getLoginHandler() == 0) {
            throw new IllegalStateException("login failed: " + ip + ":" + port + " SDK error=0x" +
                    Integer.toHexString(SDK.CLIENT_GetLastError()));
        }
        System.out.println("login success: " + ip + ":" + port +
                ", loginHandle=" + info.getLoginHandler());
        return info;
    }

    private static boolean downloadMp4(long loginHandle, int channel, int recordType,
                                       String startText, String endText, String output,
                                       int timeoutSeconds) throws Exception {
        NetSDKLib.NET_TIME start = parseTime(startText);
        NetSDKLib.NET_TIME end = parseTime(endText);
        DOWNLOAD_DONE.set(false);
        LAST_PERCENT.set(-1);

        NetSDKLib.LLong handle = SDK.CLIENT_DownloadByTimeEx2(
                new NetSDKLib.LLong(loginHandle), channel, recordType, start, end, output,
                DOWNLOAD_CALLBACK, null, null, null,
                NetSDKLib.EM_REAL_DATA_TYPE.EM_REAL_DATA_TYPE_MP4, null);
        if (handle == null || handle.longValue() == 0) {
            throw new IllegalStateException("CLIENT_DownloadByTimeEx2(MP4) failed, SDK error=0x" +
                    Integer.toHexString(SDK.CLIENT_GetLastError()));
        }

        if (timeoutSeconds <= 0) timeoutSeconds = 600;
        long deadline = System.nanoTime() + timeoutSeconds * 1_000_000_000L;
        boolean success = false;
        Memory totalMem = new Memory(4);
        Memory downloadedMem = new Memory(4);
        try {
            while (System.nanoTime() < deadline) {
                if (DOWNLOAD_DONE.get()) {
                    success = true;
                    break;
                }
                if (SDK.CLIENT_GetDownloadPos(handle, totalMem, downloadedMem)) {
                    int total = totalMem.getInt(0);
                    int downloaded = downloadedMem.getInt(0);
                    if (downloaded == -1 || (total > 0 && downloaded >= total)) {
                        success = true;
                        break;
                    }
                }
                Thread.sleep(500);
            }
        } finally {
            if (!SDK.CLIENT_StopDownload(handle)) {
                System.err.println("CLIENT_StopDownload warning, SDK error=0x" +
                        Integer.toHexString(SDK.CLIENT_GetLastError()));
            }
        }

        if (!success) throw new IllegalStateException("download timed out after " + timeoutSeconds + " seconds: " + output);
        File file = new File(output);
        if (!file.isFile() || file.length() <= 0) {
            throw new IllegalStateException("download reported complete but output is empty/missing: " + output);
        }
        System.out.println("MP4 download OK: " + output + " (" + file.length() + " bytes)");
        return true;
    }

    private static String sessionKey(ResolvedDevice r) {
        return r.host + ":" + r.port + "\n" + r.username + "\n" + r.password;
    }

    private static int runConfig(BaseModule base, String path, boolean dryRun) throws Exception {
        Config config = loadConfig(path);
        Map<String, Long> sessions = new HashMap<String, Long>();
        boolean anyError = false;
        try {
            for (Device d : config.devices) {
                ResolvedDevice r;
                try {
                    r = resolveDevice(config, d, !dryRun);
                } catch (Exception e) {
                    System.err.println(e.getMessage());
                    anyError = true;
                    continue;
                }
                File outputDir = new File(r.outputDir);
                if (!outputDir.isDirectory() && !outputDir.mkdirs()) {
                    System.err.println("cannot create output directory: " + outputDir.getAbsolutePath());
                    anyError = true;
                    continue;
                }

                long loginHandle = 0;
                String key = sessionKey(r);
                if (!dryRun) {
                    Long existing = sessions.get(key);
                    if (existing == null) {
                        try {
                            DeviceInfo info = login(base, r.host, r.port, r.username, r.password);
                            loginHandle = info.getLoginHandler();
                            sessions.put(key, loginHandle);
                        } catch (Exception e) {
                            System.err.println(e.getMessage());
                            anyError = true;
                            continue;
                        }
                    } else {
                        loginHandle = existing.longValue();
                        System.out.println("reuse login session: " + r.host + ":" + r.port + " user=" + r.username);
                    }
                }

                for (TimeRange range : d.timeRanges) {
                    try {
                        parseTime(range.start);
                        parseTime(range.end);
                        String filename = renderFilename(r.filenameTemplate, d, r.channel, range);
                        File output = chooseOutput(outputDir, filename, r.overwrite);
                        System.out.println((dryRun ? "PLAN" : "DOWNLOAD") +
                                " | name=" + d.name +
                                " | channelId=" + d.channelId +
                                " | sdkChannel=" + r.channel +
                                " | " + range.start + " -> " + range.end +
                                " | output=" + output.getPath());
                        if (!dryRun) {
                            downloadMp4(loginHandle, r.channel, r.recordType,
                                    range.start, range.end, output.getPath(), r.timeoutSeconds);
                        }
                    } catch (Exception e) {
                        System.err.println(d.name + ": " + e.getMessage());
                        anyError = true;
                    }
                }
            }
        } finally {
            for (Long handle : sessions.values()) {
                if (!base.logout(handle.longValue())) {
                    System.err.println("logout warning, SDK error=0x" +
                            Integer.toHexString(SDK.CLIENT_GetLastError()));
                    anyError = true;
                }
            }
        }
        return anyError ? 11 : 0;
    }

    private static void usage() {
        System.err.println("Usage:");
        System.err.println("  java ... DahuaDownloadExample --sdk-smoke");
        System.err.println("  java ... DahuaDownloadExample --login-test <ip> <port> <user> <password>");
        System.err.println("  java ... DahuaDownloadExample --config-check <config.yaml>");
        System.err.println("  java ... DahuaDownloadExample --config <config.yaml>");
        System.err.println("  java ... DahuaDownloadExample <ip> <port> <user> <password> <channel> <start> <end> <output.mp4> [recordType]");
        System.err.println("Time format: YYYY-MM-DDTHH:MM:SS");
        System.err.println("MP4 uses CLIENT_DownloadByTimeEx2 with scType=3.");
    }

    public static void main(String[] args) throws Exception {
        BaseModule base = new BaseModule(SDK);
        if (!base.init(null, null, false)) {
            throw new IllegalStateException("SDK init failed, SDK error=0x" +
                    Integer.toHexString(SDK.CLIENT_GetLastError()));
        }

        int exit = 0;
        try {
            if (args.length == 1 && "--sdk-smoke".equals(args[0])) {
                System.out.println("JAR SDK native load/init/cleanup smoke test: OK");
            } else if (args.length == 5 && "--login-test".equals(args[0])) {
                DeviceInfo info = login(base, args[1], Integer.parseInt(args[2]), args[3], args[4]);
                if (!base.logout(info.getLoginHandler())) {
                    throw new IllegalStateException("logout failed, SDK error=0x" +
                            Integer.toHexString(SDK.CLIENT_GetLastError()));
                }
                System.out.println("logout: OK");
            } else if (args.length == 2 && "--config-check".equals(args[0])) {
                exit = runConfig(base, args[1], true);
            } else if (args.length == 2 && "--config".equals(args[0])) {
                exit = runConfig(base, args[1], false);
            } else if (args.length >= 8 && args.length <= 9) {
                String ip = args[0];
                int port = Integer.parseInt(args[1]);
                String user = args[2];
                String password = args[3];
                int channel = Integer.parseInt(args[4]);
                String start = args[5];
                String end = args[6];
                String output = args[7];
                if (!output.toLowerCase().endsWith(".mp4")) output += ".mp4";
                int recordType = args.length == 9 ? Integer.parseInt(args[8]) : 0;
                int timeout = Integer.parseInt(System.getenv().containsKey("DAHUA_DOWNLOAD_TIMEOUT_SECONDS")
                        ? System.getenv("DAHUA_DOWNLOAD_TIMEOUT_SECONDS") : "600");
                File parent = new File(output).getAbsoluteFile().getParentFile();
                if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
                    throw new IllegalStateException("cannot create output directory: " + parent);
                }
                DeviceInfo info = login(base, ip, port, user, password);
                try {
                    downloadMp4(info.getLoginHandler(), channel, recordType, start, end, output, timeout);
                } finally {
                    if (!base.logout(info.getLoginHandler())) {
                        System.err.println("logout warning, SDK error=0x" +
                                Integer.toHexString(SDK.CLIENT_GetLastError()));
                    }
                }
            } else {
                usage();
                exit = 1;
            }
        } finally {
            base.clean();
        }
        if (exit != 0) System.exit(exit);
    }
}
