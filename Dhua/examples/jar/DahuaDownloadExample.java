import com.netsdk.lib.NetSDKLib;
import com.netsdk.module.BaseModule;
import com.netsdk.module.entity.DeviceInfo;
import com.sun.jna.Pointer;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class DahuaDownloadExample {
    private static final NetSDKLib SDK = NetSDKLib.NETSDK_INSTANCE;
    private static final AtomicBoolean DOWNLOAD_DONE = new AtomicBoolean(false);
    private static final AtomicInteger LAST_PERCENT = new AtomicInteger(-1);

    // Keep a strong reference for JNA for the whole download lifecycle.
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

    private static NetSDKLib.NET_TIME parseTime(String text) {
        String normalized = text.replace('T', ' ');
        String[] parts = normalized.split("[\\- :]");
        if (parts.length != 6) {
            throw new IllegalArgumentException("expected YYYY-MM-DDTHH:MM:SS");
        }
        NetSDKLib.NET_TIME time = new NetSDKLib.NET_TIME();
        time.dwYear = Integer.parseInt(parts[0]);
        time.dwMonth = Integer.parseInt(parts[1]);
        time.dwDay = Integer.parseInt(parts[2]);
        time.dwHour = Integer.parseInt(parts[3]);
        time.dwMinute = Integer.parseInt(parts[4]);
        time.dwSecond = Integer.parseInt(parts[5]);
        return time;
    }

    private static DeviceInfo login(BaseModule base, String ip, int port, String user, String password) {
        DeviceInfo info = base.login(ip, port, user, password);
        if (info == null || info.getLoginHandler() == 0) {
            throw new IllegalStateException("login failed, SDK error=0x" +
                    Integer.toHexString(SDK.CLIENT_GetLastError()));
        }
        System.out.println("login success: " + ip + ":" + port +
                ", loginHandle=" + info.getLoginHandler());
        return info;
    }

    private static void usage() {
        System.err.println("Usage:");
        System.err.println("  java ... DahuaDownloadExample --sdk-smoke");
        System.err.println("  java ... DahuaDownloadExample --login-test <ip> <port> <user> <password>");
        System.err.println("  java ... DahuaDownloadExample <ip> <port> <user> <password> <channel> <start> <end> <output.dav> [recordType]");
        System.err.println("Time format: YYYY-MM-DDTHH:MM:SS");
        System.err.println("recordType default: 0 (all recordings)");
    }

    public static void main(String[] args) throws Exception {
        BaseModule base = new BaseModule(SDK);
        if (!base.init(null, null, false)) {
            throw new IllegalStateException("SDK init failed");
        }

        long loginHandle = 0;
        NetSDKLib.LLong downloadHandle = null;
        try {
            if (args.length == 1 && "--sdk-smoke".equals(args[0])) {
                System.out.println("JAR SDK native load/init/cleanup smoke test: OK");
                return;
            }

            if (args.length == 5 && "--login-test".equals(args[0])) {
                DeviceInfo info = login(base, args[1], Integer.parseInt(args[2]), args[3], args[4]);
                loginHandle = info.getLoginHandler();
                if (!base.logout(loginHandle)) {
                    throw new IllegalStateException("logout failed, SDK error=0x" +
                            Integer.toHexString(SDK.CLIENT_GetLastError()));
                }
                loginHandle = 0;
                System.out.println("logout: OK");
                return;
            }

            if (args.length < 8 || args.length > 9) {
                usage();
                System.exit(1);
            }

            String ip = args[0];
            int port = Integer.parseInt(args[1]);
            String user = args[2];
            String password = args[3];
            int channel = Integer.parseInt(args[4]);
            NetSDKLib.NET_TIME start = parseTime(args[5]);
            NetSDKLib.NET_TIME end = parseTime(args[6]);
            String output = args[7];
            int recordType = args.length == 9 ? Integer.parseInt(args[8]) : 0;

            DeviceInfo info = login(base, ip, port, user, password);
            loginHandle = info.getLoginHandler();
            DOWNLOAD_DONE.set(false);
            LAST_PERCENT.set(-1);

            downloadHandle = SDK.CLIENT_DownloadByTimeEx(
                    new NetSDKLib.LLong(loginHandle), channel, recordType, start, end, output,
                    DOWNLOAD_CALLBACK, null, null, null, null);
            if (downloadHandle == null || downloadHandle.longValue() == 0) {
                throw new IllegalStateException("CLIENT_DownloadByTimeEx failed, SDK error=0x" +
                        Integer.toHexString(SDK.CLIENT_GetLastError()));
            }

            int timeoutSeconds = Integer.parseInt(
                    System.getenv().getOrDefault("DAHUA_DOWNLOAD_TIMEOUT_SECONDS", "300"));
            if (timeoutSeconds <= 0) timeoutSeconds = 300;
            long deadline = System.nanoTime() + timeoutSeconds * 1_000_000_000L;
            boolean success = false;

            while (System.nanoTime() < deadline) {
                if (DOWNLOAD_DONE.get()) {
                    success = true;
                    break;
                }
                Thread.sleep(500);
            }

            SDK.CLIENT_StopDownload(downloadHandle);
            downloadHandle = null;
            if (!success) {
                throw new IllegalStateException("download timed out after " + timeoutSeconds + " seconds");
            }

            if (!base.logout(loginHandle)) {
                throw new IllegalStateException("download completed but logout failed, SDK error=0x" +
                        Integer.toHexString(SDK.CLIENT_GetLastError()));
            }
            loginHandle = 0;
            System.out.println("download OK: " + output);
            System.out.println("logout: OK");
        } finally {
            if (downloadHandle != null && downloadHandle.longValue() != 0) {
                SDK.CLIENT_StopDownload(downloadHandle);
            }
            if (loginHandle != 0) {
                base.logout(loginHandle);
            }
            base.clean();
        }
    }
}
