#include "dhnetsdk.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <sys/stat.h>
#include <sys/types.h>

namespace {

std::atomic<bool> g_download_done(false);
std::atomic<int> g_download_percent(-1);

struct TimeRange {
    std::string start;
    std::string end;
};

struct Defaults {
    std::string host;
    int port = 37777;
    std::string username;
    std::string password;
    std::string outputDir = "./recordings";
    std::string filenameTemplate = "{name}_{start}_{end}.mp4";
    int recordType = 0;
    int timeoutSeconds = 600;
    bool overwrite = false;
};

struct Device {
    std::string name;
    std::string channelId;
    int sdkChannel = -1;
    std::string host;
    int port = -1;
    std::string username;
    std::string password;
    std::string outputDir;
    std::string filenameTemplate;
    int recordType = -1;
    int timeoutSeconds = -1;
    int overwrite = -1; // -1 inherit, 0 false, 1 true
    std::vector<TimeRange> timeRanges;
};

struct Config {
    Defaults defaults;
    std::vector<Device> devices;
};

void CALLBACK on_disconnect(LLONG, char* ip, LONG port, LDWORD) {
    std::fprintf(stderr, "device disconnected: %s:%ld\n",
                 ip ? ip : "<unknown>", static_cast<long>(port));
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
        int percent = static_cast<int>(
            (static_cast<unsigned long long>(downloaded) * 100ULL) / total);
        int old = g_download_percent.exchange(percent);
        if (percent != old && (percent % 10 == 0 || percent == 100)) {
            std::printf("download progress: %d%%\n", percent);
        }
    }
}

std::string trim(const std::string& input) {
    std::size_t begin = 0;
    while (begin < input.size() && std::isspace(static_cast<unsigned char>(input[begin]))) {
        ++begin;
    }
    std::size_t end = input.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(input[end - 1]))) {
        --end;
    }
    return input.substr(begin, end - begin);
}

std::string strip_inline_comment(const std::string& input) {
    bool in_single = false;
    bool in_double = false;
    for (std::size_t i = 0; i < input.size(); ++i) {
        char c = input[i];
        if (c == '\'' && !in_double) in_single = !in_single;
        else if (c == '"' && !in_single) in_double = !in_double;
        else if (c == '#' && !in_single && !in_double &&
                 (i == 0 || std::isspace(static_cast<unsigned char>(input[i - 1])))) {
            return input.substr(0, i);
        }
    }
    return input;
}

std::string unquote(const std::string& input) {
    std::string value = trim(input);
    if (value.size() >= 2 &&
        ((value.front() == '"' && value.back() == '"') ||
         (value.front() == '\'' && value.back() == '\''))) {
        value = value.substr(1, value.size() - 2);
    }
    return value;
}

bool split_key_value(const std::string& input, std::string& key, std::string& value) {
    bool in_single = false;
    bool in_double = false;
    for (std::size_t i = 0; i < input.size(); ++i) {
        char c = input[i];
        if (c == '\'' && !in_double) in_single = !in_single;
        else if (c == '"' && !in_single) in_double = !in_double;
        else if (c == ':' && !in_single && !in_double) {
            key = trim(input.substr(0, i));
            value = unquote(input.substr(i + 1));
            return !key.empty();
        }
    }
    return false;
}

bool parse_bool(const std::string& value, bool& out) {
    std::string v = value;
    std::transform(v.begin(), v.end(), v.begin(), ::tolower);
    if (v == "true" || v == "yes" || v == "1") { out = true; return true; }
    if (v == "false" || v == "no" || v == "0") { out = false; return true; }
    return false;
}

bool parse_int(const std::string& value, int& out) {
    if (value.empty()) return false;
    char* end = NULL;
    long parsed = std::strtol(value.c_str(), &end, 10);
    if (!end || *end != '\0') return false;
    out = static_cast<int>(parsed);
    return true;
}

std::string expand_env(const std::string& input, bool strict, bool* ok = NULL) {
    std::string result;
    bool success = true;
    for (std::size_t i = 0; i < input.size();) {
        if (i + 2 < input.size() && input[i] == '$' && input[i + 1] == '{') {
            std::size_t end = input.find('}', i + 2);
            if (end == std::string::npos) {
                result.append(input.substr(i));
                break;
            }
            std::string name = input.substr(i + 2, end - (i + 2));
            const char* env = std::getenv(name.c_str());
            if (env) {
                result.append(env);
            } else if (strict) {
                std::fprintf(stderr, "missing environment variable: %s\n", name.c_str());
                success = false;
            } else {
                result.append(input.substr(i, end - i + 1));
            }
            i = end + 1;
        } else {
            result.push_back(input[i++]);
        }
    }
    if (ok) *ok = success;
    return result;
}

bool parse_time(const char* text, NET_TIME& out) {
    int y = 0, mon = 0, d = 0, h = 0, min = 0, s = 0;
    if (std::sscanf(text, "%d-%d-%dT%d:%d:%d", &y, &mon, &d, &h, &min, &s) != 6 &&
        std::sscanf(text, "%d-%d-%d %d:%d:%d", &y, &mon, &d, &h, &min, &s) != 6) {
        return false;
    }
    if (mon < 1 || mon > 12 || d < 1 || d > 31 || h < 0 || h > 23 ||
        min < 0 || min > 59 || s < 0 || s > 59) {
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

void set_default_field(Defaults& d, const std::string& key, const std::string& value) {
    if (key == "host") d.host = value;
    else if (key == "port") parse_int(value, d.port);
    else if (key == "username") d.username = value;
    else if (key == "password") d.password = value;
    else if (key == "outputDir") d.outputDir = value;
    else if (key == "filenameTemplate") d.filenameTemplate = value;
    else if (key == "recordType") parse_int(value, d.recordType);
    else if (key == "downloadTimeoutSeconds") parse_int(value, d.timeoutSeconds);
    else if (key == "overwrite") parse_bool(value, d.overwrite);
}

void set_device_field(Device& d, const std::string& key, const std::string& value) {
    if (key == "name") d.name = value;
    else if (key == "channelId") d.channelId = value;
    else if (key == "sdkChannel") parse_int(value, d.sdkChannel);
    else if (key == "host") d.host = value;
    else if (key == "port") parse_int(value, d.port);
    else if (key == "username") d.username = value;
    else if (key == "password") d.password = value;
    else if (key == "outputDir") d.outputDir = value;
    else if (key == "filenameTemplate") d.filenameTemplate = value;
    else if (key == "recordType") parse_int(value, d.recordType);
    else if (key == "downloadTimeoutSeconds") parse_int(value, d.timeoutSeconds);
    else if (key == "overwrite") {
        bool b = false;
        if (parse_bool(value, b)) d.overwrite = b ? 1 : 0;
    }
}

bool load_config(const std::string& path, Config& config) {
    std::ifstream file(path.c_str());
    if (!file.is_open()) {
        std::fprintf(stderr, "cannot open config: %s\n", path.c_str());
        return false;
    }

    enum Section { ROOT, DEFAULTS_SECTION, DEVICES_SECTION, RANGES_SECTION };
    Section section = ROOT;
    Device* current_device = NULL;
    TimeRange* current_range = NULL;
    std::string raw;
    int line_no = 0;

    while (std::getline(file, raw)) {
        ++line_no;
        if (raw.find('\t') != std::string::npos) {
            std::fprintf(stderr, "config line %d: tabs are not supported; use spaces\n", line_no);
            return false;
        }
        std::string without_comment = strip_inline_comment(raw);
        if (trim(without_comment).empty()) continue;

        std::size_t indent = 0;
        while (indent < without_comment.size() && without_comment[indent] == ' ') ++indent;
        std::string content = trim(without_comment.substr(indent));

        if (indent == 0) {
            current_device = NULL;
            current_range = NULL;
            if (content == "defaults:") section = DEFAULTS_SECTION;
            else if (content == "devices:") section = DEVICES_SECTION;
            else {
                std::string key, value;
                if (split_key_value(content, key, value) && key == "version") continue;
                std::fprintf(stderr, "config line %d: unsupported root entry: %s\n", line_no, content.c_str());
                return false;
            }
            continue;
        }

        if (section == DEFAULTS_SECTION && indent == 2) {
            std::string key, value;
            if (!split_key_value(content, key, value)) {
                std::fprintf(stderr, "config line %d: expected key: value\n", line_no);
                return false;
            }
            set_default_field(config.defaults, key, value);
            continue;
        }

        if ((section == DEVICES_SECTION || section == RANGES_SECTION) && indent == 2 &&
            content.size() >= 1 && content[0] == '-') {
            config.devices.push_back(Device());
            current_device = &config.devices.back();
            current_range = NULL;
            section = DEVICES_SECTION;
            std::string rest = trim(content.substr(1));
            if (!rest.empty()) {
                std::string key, value;
                if (!split_key_value(rest, key, value)) return false;
                set_device_field(*current_device, key, value);
            }
            continue;
        }

        if (current_device && indent == 4) {
            if (content == "timeRanges:") {
                section = RANGES_SECTION;
                current_range = NULL;
                continue;
            }
            std::string key, value;
            if (!split_key_value(content, key, value)) return false;
            set_device_field(*current_device, key, value);
            continue;
        }

        if (current_device && section == RANGES_SECTION && indent == 6 &&
            content.size() >= 1 && content[0] == '-') {
            current_device->timeRanges.push_back(TimeRange());
            current_range = &current_device->timeRanges.back();
            std::string rest = trim(content.substr(1));
            if (!rest.empty()) {
                std::string key, value;
                if (!split_key_value(rest, key, value)) return false;
                if (key == "start") current_range->start = value;
                else if (key == "end") current_range->end = value;
            }
            continue;
        }

        if (current_range && indent == 8) {
            std::string key, value;
            if (!split_key_value(content, key, value)) return false;
            if (key == "start") current_range->start = value;
            else if (key == "end") current_range->end = value;
            continue;
        }

        std::fprintf(stderr, "config line %d: unsupported indentation/entry: %s\n",
                     line_no, content.c_str());
        return false;
    }

    if (config.devices.empty()) {
        std::fprintf(stderr, "config has no devices\n");
        return false;
    }
    return true;
}

int derive_sdk_channel(const Device& device) {
    if (device.sdkChannel >= 0) return device.sdkChannel;
    std::size_t pos = device.channelId.find_last_of('$');
    if (pos == std::string::npos || pos + 1 >= device.channelId.size()) return -1;
    int channel = -1;
    if (!parse_int(device.channelId.substr(pos + 1), channel) || channel < 0) return -1;
    std::fprintf(stderr,
                 "[WARN] %s: sdkChannel omitted; derived %d from channelId=%s. "
                 "Prefer explicit sdkChannel after verifying the device/NVR mapping.\n",
                 device.name.c_str(), channel, device.channelId.c_str());
    return channel;
}

std::string sanitize_name(const std::string& input) {
    std::string out;
    bool previous_underscore = false;
    for (std::size_t i = 0; i < input.size(); ++i) {
        unsigned char c = static_cast<unsigned char>(input[i]);
        bool allowed = (c >= 0x80) || std::isalnum(c) || c == '-' || c == '_' || c == '.';
        char append = allowed ? static_cast<char>(c) : '_';
        if (append == '_' && previous_underscore) continue;
        out.push_back(append);
        previous_underscore = (append == '_');
    }
    while (!out.empty() && (out.back() == '_' || out.back() == '.')) out.pop_back();
    return out.empty() ? "camera" : out;
}

std::string compact_time(const std::string& input) {
    std::string digits;
    for (std::size_t i = 0; i < input.size(); ++i) {
        if (std::isdigit(static_cast<unsigned char>(input[i]))) digits.push_back(input[i]);
    }
    if (digits.size() >= 14) return digits.substr(0, 8) + "_" + digits.substr(8, 6);
    return sanitize_name(input);
}

void replace_all(std::string& text, const std::string& from, const std::string& to) {
    if (from.empty()) return;
    std::size_t pos = 0;
    while ((pos = text.find(from, pos)) != std::string::npos) {
        text.replace(pos, from.size(), to);
        pos += to.size();
    }
}

std::string render_filename(const std::string& pattern, const Device& device,
                            int channel, const TimeRange& range) {
    std::string result = pattern.empty() ? "{name}_{start}_{end}.mp4" : pattern;
    replace_all(result, "{name}", sanitize_name(device.name));
    replace_all(result, "{channel}", std::to_string(channel));
    replace_all(result, "{channelId}", sanitize_name(device.channelId));
    replace_all(result, "{start}", compact_time(range.start));
    replace_all(result, "{end}", compact_time(range.end));
    result = sanitize_name(result);
    if (result.size() < 4 || result.substr(result.size() - 4) != ".mp4") result += ".mp4";
    return result;
}

bool directory_exists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool file_exists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

long long file_size(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 ? static_cast<long long>(st.st_size) : -1;
}

bool make_directory(const std::string& path) {
    if (path.empty() || path == ".") return true;
    if (directory_exists(path)) return true;
    if (::mkdir(path.c_str(), 0755) == 0 || errno == EEXIST) return true;
    return false;
}

bool ensure_directory(const std::string& path) {
    if (path.empty() || path == ".") return true;
    std::string current;
    if (!path.empty() && path[0] == '/') current = "/";
    std::stringstream ss(path);
    std::string part;
    while (std::getline(ss, part, '/')) {
        if (part.empty() || part == ".") continue;
        if (!current.empty() && current != "/") current += "/";
        current += part;
        if (!make_directory(current)) {
            std::fprintf(stderr, "cannot create directory %s: %s\n", current.c_str(), std::strerror(errno));
            return false;
        }
    }
    return true;
}

std::string join_path(const std::string& dir, const std::string& name) {
    if (dir.empty() || dir == ".") return name;
    if (dir[dir.size() - 1] == '/') return dir + name;
    return dir + "/" + name;
}

std::string choose_output_path(const std::string& dir, const std::string& filename, bool overwrite) {
    std::string base = join_path(dir, filename);
    if (overwrite || !file_exists(base)) return base;
    std::size_t dot = base.find_last_of('.');
    std::string stem = dot == std::string::npos ? base : base.substr(0, dot);
    std::string ext = dot == std::string::npos ? "" : base.substr(dot);
    for (int i = 1; i < 10000; ++i) {
        char suffix[16];
        std::snprintf(suffix, sizeof(suffix), "_%03d", i);
        std::string candidate = stem + suffix + ext;
        if (!file_exists(candidate)) return candidate;
    }
    return stem + "_overflow" + ext;
}

LLONG login_device(const char* ip, int port, const char* user, const char* password) {
    NET_IN_LOGIN_WITH_HIGHLEVEL_SECURITY in;
    NET_OUT_LOGIN_WITH_HIGHLEVEL_SECURITY out;
    std::memset(&in, 0, sizeof(in));
    std::memset(&out, 0, sizeof(out));
    in.dwSize = sizeof(in);
    out.dwSize = sizeof(out);
    std::snprintf(in.szIP, sizeof(in.szIP), "%s", ip);
    in.nPort = port;
    std::snprintf(in.szUserName, sizeof(in.szUserName), "%s", user);
    std::snprintf(in.szPassword, sizeof(in.szPassword), "%s", password);

    LLONG handle = CLIENT_LoginWithHighLevelSecurity(&in, &out);
    if (handle == 0) {
        std::fprintf(stderr, "login failed: %s:%d SDK error=0x%08x login error=%d\n",
                     ip, port, CLIENT_GetLastError(), out.nError);
    } else {
        std::printf("login success: %s:%d, channels=%d\n", ip, port,
                    static_cast<int>(out.stuDeviceInfo.nChanNum));
    }
    return handle;
}

bool download_mp4(LLONG login, int channel, int record_type,
                  const std::string& start_text, const std::string& end_text,
                  const std::string& output, int timeout_seconds) {
    NET_TIME start;
    NET_TIME end;
    if (!parse_time(start_text.c_str(), start) || !parse_time(end_text.c_str(), end)) {
        std::fprintf(stderr, "invalid time; expected YYYY-MM-DDTHH:MM:SS\n");
        return false;
    }

    std::vector<char> output_buffer(output.begin(), output.end());
    output_buffer.push_back('\0');

    NET_IN_DOWNLOAD_BY_DATA_TYPE in;
    NET_OUT_DOWNLOAD_BY_DATA_TYPE out;
    std::memset(&in, 0, sizeof(in));
    std::memset(&out, 0, sizeof(out));
    in.dwSize = sizeof(in);
    out.dwSize = sizeof(out);
    in.nChannelID = channel;
    in.emRecordType = static_cast<EM_QUERY_RECORD_TYPE>(record_type);
    in.szSavedFileName = &output_buffer[0];
    in.stStartTime = start;
    in.stStopTime = end;
    in.cbDownLoadPos = on_download_pos;
    in.dwPosUser = 0;
    in.fDownLoadDataCallBack = NULL;
    in.emDataType = EM_REAL_DATA_TYPE_MP4;
    in.dwDataUser = 0;
    in.emAudioType = EM_AUDIO_DATA_TYPE_DEFAULT;

    g_download_done.store(false);
    g_download_percent.store(-1);
    LLONG download = CLIENT_DownloadByDataType(login, &in, &out, 5000);
    if (download == 0) {
        std::fprintf(stderr, "CLIENT_DownloadByDataType(MP4) failed, SDK error=0x%08x\n",
                     CLIENT_GetLastError());
        return false;
    }

    if (timeout_seconds <= 0) timeout_seconds = 600;
    std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(timeout_seconds);
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

    if (!CLIENT_StopDownload(download)) {
        std::fprintf(stderr, "CLIENT_StopDownload warning, SDK error=0x%08x\n", CLIENT_GetLastError());
    }

    if (!success) {
        std::fprintf(stderr, "download timed out after %d seconds: %s\n",
                     timeout_seconds, output.c_str());
        return false;
    }
    long long bytes = file_size(output);
    if (bytes <= 0) {
        std::fprintf(stderr, "download reported complete but output is empty/missing: %s\n", output.c_str());
        return false;
    }
    std::printf("MP4 download OK: %s (%lld bytes)\n", output.c_str(), bytes);
    return true;
}

struct ResolvedDevice {
    std::string host;
    int port;
    std::string username;
    std::string password;
    std::string outputDir;
    std::string filenameTemplate;
    int recordType;
    int timeoutSeconds;
    bool overwrite;
    int channel;
};

bool resolve_device(const Config& config, const Device& device, bool strict_env,
                    ResolvedDevice& r) {
    bool ok = true;
    r.host = expand_env(device.host.empty() ? config.defaults.host : device.host, strict_env, &ok);
    if (!ok) return false;
    r.port = device.port >= 0 ? device.port : config.defaults.port;
    r.username = expand_env(device.username.empty() ? config.defaults.username : device.username, strict_env, &ok);
    if (!ok) return false;
    r.password = expand_env(device.password.empty() ? config.defaults.password : device.password, strict_env, &ok);
    if (!ok) return false;
    r.outputDir = expand_env(device.outputDir.empty() ? config.defaults.outputDir : device.outputDir, strict_env, &ok);
    if (!ok) return false;
    r.filenameTemplate = device.filenameTemplate.empty() ? config.defaults.filenameTemplate : device.filenameTemplate;
    r.recordType = device.recordType >= 0 ? device.recordType : config.defaults.recordType;
    r.timeoutSeconds = device.timeoutSeconds >= 0 ? device.timeoutSeconds : config.defaults.timeoutSeconds;
    r.overwrite = device.overwrite >= 0 ? device.overwrite != 0 : config.defaults.overwrite;
    r.channel = derive_sdk_channel(device);

    if (r.host.empty() || r.username.empty() || (strict_env && r.password.empty()) ||
        r.port <= 0 || r.channel < 0 || device.name.empty() || device.timeRanges.empty()) {
        std::fprintf(stderr,
                     "invalid device config for '%s': need name, host, port, credentials, sdkChannel/channelId and timeRanges\n",
                     device.name.c_str());
        return false;
    }
    return true;
}

std::string session_key(const ResolvedDevice& r) {
    std::ostringstream ss;
    ss << r.host << ':' << r.port << '\n' << r.username << '\n' << r.password;
    return ss.str();
}

int run_config(const std::string& path, bool dry_run) {
    Config config;
    if (!load_config(path, config)) return 10;

    bool any_error = false;
    std::map<std::string, LLONG> sessions;

    for (std::size_t i = 0; i < config.devices.size(); ++i) {
        const Device& device = config.devices[i];
        ResolvedDevice r;
        if (!resolve_device(config, device, !dry_run, r)) {
            any_error = true;
            continue;
        }
        if (!ensure_directory(r.outputDir)) {
            any_error = true;
            continue;
        }

        LLONG login = 0;
        std::string key = session_key(r);
        if (!dry_run) {
            std::map<std::string, LLONG>::iterator it = sessions.find(key);
            if (it == sessions.end()) {
                login = login_device(r.host.c_str(), r.port, r.username.c_str(), r.password.c_str());
                if (login == 0) {
                    any_error = true;
                    continue;
                }
                sessions[key] = login;
            } else {
                login = it->second;
                std::printf("reuse login session: %s:%d user=%s\n",
                            r.host.c_str(), r.port, r.username.c_str());
            }
        }

        for (std::size_t j = 0; j < device.timeRanges.size(); ++j) {
            const TimeRange& range = device.timeRanges[j];
            NET_TIME tmp_start;
            NET_TIME tmp_end;
            if (!parse_time(range.start.c_str(), tmp_start) || !parse_time(range.end.c_str(), tmp_end)) {
                std::fprintf(stderr, "%s: invalid time range %s -> %s\n",
                             device.name.c_str(), range.start.c_str(), range.end.c_str());
                any_error = true;
                continue;
            }
            std::string filename = render_filename(r.filenameTemplate, device, r.channel, range);
            std::string output = choose_output_path(r.outputDir, filename, r.overwrite);
            std::printf("%s | channelId=%s | sdkChannel=%d | %s -> %s | output=%s\n",
                        dry_run ? "PLAN" : "DOWNLOAD", device.channelId.c_str(), r.channel,
                        range.start.c_str(), range.end.c_str(), output.c_str());
            if (!dry_run && !download_mp4(login, r.channel, r.recordType,
                                          range.start, range.end, output, r.timeoutSeconds)) {
                any_error = true;
            }
        }
    }

    for (std::map<std::string, LLONG>::iterator it = sessions.begin(); it != sessions.end(); ++it) {
        if (!CLIENT_Logout(it->second)) {
            std::fprintf(stderr, "logout warning, SDK error=0x%08x\n", CLIENT_GetLastError());
            any_error = true;
        }
    }
    return any_error ? 11 : 0;
}

void usage(const char* exe) {
    std::fprintf(stderr,
        "Usage:\n"
        "  %s --sdk-smoke\n"
        "  %s --login-test <ip> <port> <user> <password>\n"
        "  %s --config-check <config.yaml>\n"
        "  %s --config <config.yaml>\n"
        "  %s <ip> <port> <user> <password> <channel> <start> <end> <output.mp4> [recordType]\n\n"
        "Time format: YYYY-MM-DDTHH:MM:SS\n"
        "Direct and config download modes produce real MP4 using CLIENT_DownloadByDataType + EM_REAL_DATA_TYPE_MP4.\n"
        "recordType default: 0 (all recordings).\n",
        exe, exe, exe, exe, exe);
}

}  // namespace

int main(int argc, char** argv) {
    if (!CLIENT_Init(on_disconnect, 0)) {
        std::fprintf(stderr, "CLIENT_Init failed, SDK error=0x%08x\n", CLIENT_GetLastError());
        return 2;
    }

    int rc = 0;
    if (argc == 2 && std::strcmp(argv[1], "--sdk-smoke") == 0) {
        std::printf("C SDK native load/init/cleanup smoke test: OK\n");
    } else if (argc == 6 && std::strcmp(argv[1], "--login-test") == 0) {
        LLONG login = login_device(argv[2], std::atoi(argv[3]), argv[4], argv[5]);
        if (login == 0) rc = 3;
        else {
            bool ok = CLIENT_Logout(login) != FALSE;
            std::printf("logout: %s\n", ok ? "OK" : "FAILED");
            rc = ok ? 0 : 4;
        }
    } else if (argc == 3 && std::strcmp(argv[1], "--config-check") == 0) {
        rc = run_config(argv[2], true);
    } else if (argc == 3 && std::strcmp(argv[1], "--config") == 0) {
        rc = run_config(argv[2], false);
    } else if (argc >= 9 && argc <= 10) {
        int channel = std::atoi(argv[5]);
        int record_type = argc == 10 ? std::atoi(argv[9]) : 0;
        const char* timeout_env = std::getenv("DAHUA_DOWNLOAD_TIMEOUT_SECONDS");
        int timeout_seconds = timeout_env ? std::atoi(timeout_env) : 600;
        LLONG login = login_device(argv[1], std::atoi(argv[2]), argv[3], argv[4]);
        if (login == 0) rc = 3;
        else {
            std::string output = argv[8];
            if (output.size() < 4 || output.substr(output.size() - 4) != ".mp4") output += ".mp4";
            std::size_t slash = output.find_last_of('/');
            if (slash != std::string::npos && !ensure_directory(output.substr(0, slash))) {
                rc = 5;
            } else if (!download_mp4(login, channel, record_type, argv[6], argv[7], output, timeout_seconds)) {
                rc = 5;
            }
            if (!CLIENT_Logout(login)) {
                std::fprintf(stderr, "logout failed, SDK error=0x%08x\n", CLIENT_GetLastError());
                if (rc == 0) rc = 7;
            }
        }
    } else {
        usage(argv[0]);
        rc = 1;
    }

    CLIENT_Cleanup();
    return rc;
}
