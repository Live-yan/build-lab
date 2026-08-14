#include "dhnetsdk.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

namespace {
std::atomic<bool> g_download_done{false};
std::atomic<int> g_download_percent{-1};

void CALLBACK on_disconnect(LLONG, char* ip, LONG port, LDWORD) {
    std::fprintf(stderr, "device disconnected: %s:%ld\n", ip ? ip : "<unknown>", static_cast<long>(port));
}

void CALLBACK on_download_pos(LLONG, DWORD total, DWORD downloaded, int,
                              NET_RECORDFILE_INFO, LDWORD) {
    if (downloaded == static_cast<DWORD>(-1)) {
        g_download_percent.store(100);
        g_download_done.store(true);
        std::printf("download completed\n");
        return;
    }
    if (total > 0 && total != static_cast<DWORD>(-1)) {
        int percent = static_cast<int>((static_cast<unsigned long long>(downloaded) * 100ULL) / total);
        int old = g_download_percent.exchange(percent);
        if (percent != old && (percent % 10 == 0 || percent == 100)) {
            std::printf("download progress: %d%%\n", percent);
        }
    }
}

bool parse_time(const char* text, NET_TIME& out) {
    int y = 0, mon = 0, d = 0, h = 0, min = 0, s = 0;
    if (std::sscanf(text, "%d-%d-%dT%d:%d:%d", &y, &mon, &d, &h, &min, &s) != 6 &&
        std::sscanf(text, "%d-%d-%d %d:%d:%d", &y, &mon, &d, &h, &min, &s) != 6) {
        return false;
    }
    std::memset(&out, 0, sizeof(out));
    out.dwYear = y;
    out.dwMonth = mon;
    out.dwDay = d;
    out.dwHour = h;
    out.dwMinute = min;
    out.dwSecond = s;
    return true;
}

LLONG login_device(const char* ip, int port, const char* user, const char* password) {
    NET_IN_LOGIN_WITH_HIGHLEVEL_SECURITY in{};
    NET_OUT_LOGIN_WITH_HIGHLEVEL_SECURITY out{};
    in.dwSize = sizeof(in);
    out.dwSize = sizeof(out);
    std::snprintf(in.szIP, sizeof(in.szIP), "%s", ip);
    in.nPort = port;
    std::snprintf(in.szUserName, sizeof(in.szUserName), "%s", user);
    std::snprintf(in.szPassword, sizeof(in.szPassword), "%s", password);

    LLONG handle = CLIENT_LoginWithHighLevelSecurity(&in, &out);
    if (handle == 0) {
        std::fprintf(stderr, "login failed, SDK error=0x%08x, login error=%d\n",
                     CLIENT_GetLastError(), out.nError);
    } else {
        std::printf("login success: %s:%d, channels=%d\n", ip, port,
                    static_cast<int>(out.stuDeviceInfo.nChanNum));
    }
    return handle;
}

void usage(const char* exe) {
    std::fprintf(stderr,
        "Usage:\n"
        "  %s --sdk-smoke\n"
        "  %s --login-test <ip> <port> <user> <password>\n"
        "  %s <ip> <port> <user> <password> <channel> <start> <end> <output.dav> [recordType]\n\n"
        "Time format: YYYY-MM-DDTHH:MM:SS\n"
        "recordType default: 0 (all recordings)\n",
        exe, exe, exe);
}
}  // namespace

int main(int argc, char** argv) {
    if (!CLIENT_Init(on_disconnect, 0)) {
        std::fprintf(stderr, "CLIENT_Init failed, SDK error=0x%08x\n", CLIENT_GetLastError());
        return 2;
    }

    if (argc == 2 && std::strcmp(argv[1], "--sdk-smoke") == 0) {
        std::printf("C SDK native load/init/cleanup smoke test: OK\n");
        CLIENT_Cleanup();
        return 0;
    }

    if (argc == 6 && std::strcmp(argv[1], "--login-test") == 0) {
        LLONG login = login_device(argv[2], std::atoi(argv[3]), argv[4], argv[5]);
        if (login == 0) {
            CLIENT_Cleanup();
            return 3;
        }
        bool ok = CLIENT_Logout(login) != FALSE;
        std::printf("logout: %s\n", ok ? "OK" : "FAILED");
        CLIENT_Cleanup();
        return ok ? 0 : 4;
    }

    if (argc < 9 || argc > 10) {
        usage(argv[0]);
        CLIENT_Cleanup();
        return 1;
    }

    const char* ip = argv[1];
    int port = std::atoi(argv[2]);
    const char* user = argv[3];
    const char* password = argv[4];
    int channel = std::atoi(argv[5]);
    const char* start_text = argv[6];
    const char* end_text = argv[7];
    const char* output = argv[8];
    int record_type = argc == 10 ? std::atoi(argv[9]) : 0;

    NET_TIME start{};
    NET_TIME end{};
    if (!parse_time(start_text, start) || !parse_time(end_text, end)) {
        std::fprintf(stderr, "invalid time; expected YYYY-MM-DDTHH:MM:SS\n");
        CLIENT_Cleanup();
        return 1;
    }

    LLONG login = login_device(ip, port, user, password);
    if (login == 0) {
        CLIENT_Cleanup();
        return 3;
    }

    g_download_done.store(false);
    g_download_percent.store(-1);
    LLONG download = CLIENT_DownloadByTimeEx(
        login, channel, record_type, &start, &end, const_cast<char*>(output),
        on_download_pos, 0, nullptr, 0, nullptr);

    if (download == 0) {
        std::fprintf(stderr, "CLIENT_DownloadByTimeEx failed, SDK error=0x%08x\n", CLIENT_GetLastError());
        CLIENT_Logout(login);
        CLIENT_Cleanup();
        return 5;
    }

    const char* timeout_env = std::getenv("DAHUA_DOWNLOAD_TIMEOUT_SECONDS");
    int timeout_seconds = timeout_env ? std::atoi(timeout_env) : 300;
    if (timeout_seconds <= 0) timeout_seconds = 300;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_seconds);

    bool success = false;
    while (std::chrono::steady_clock::now() < deadline) {
        if (g_download_done.load()) {
            success = true;
            break;
        }
        int total = 0;
        int downloaded = 0;
        if (CLIENT_GetDownloadPos(download, &total, &downloaded)) {
            if (downloaded == -1 || (total > 0 && downloaded >= total)) {
                success = true;
                break;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }

    CLIENT_StopDownload(download);
    bool logout_ok = CLIENT_Logout(login) != FALSE;
    CLIENT_Cleanup();

    if (!success) {
        std::fprintf(stderr, "download timed out after %d seconds\n", timeout_seconds);
        return 6;
    }
    if (!logout_ok) {
        std::fprintf(stderr, "download completed but logout failed\n");
        return 7;
    }

    std::printf("download OK: %s\nlogout: OK\n", output);
    return 0;
}
