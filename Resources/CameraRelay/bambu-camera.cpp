// bambu-camera: one Bambu Cloud session for a printer through Bambu Studio's own network plugin.
//
// libbambu_networking signs print commands and camera requests the way Studio does, so printers that
// refuse unsigned commands still take them; libBambuSource opens the TUTK/Agora camera tunnel and hands
// back H.264 samples. Both are loaded from Bambu Studio's plugin folder, so this runs in its own process:
// a crash or hang inside them never takes the app down.
//
// stdin: "key=value" lines (the account token never goes on argv), then an empty line, then commands:
//   "send <json>" publishes to the printer, "camera <firmware>" starts the camera, "nocamera" stops it.
//   EOF ends the session.
// stdout: frames of [type u8][length u32 BE][payload]:
//   'S' status JSON (session states, then "ready"; camera states are prefixed "camera:")
//   'A' the printer's answer to a sent command: command, result, reason, sequence_id
//   'I' stream info: width, height, fps, format_type, sub_type (i32 LE), format bytes
//   'V' video sample: flags u8, decode_time u64 LE, data
// Anything the plugins print goes to /dev/null. This tool's own log (never secrets) goes to log_file, or to
// stderr with BAMBU_CAMERA_VERBOSE set; dump_file receives the raw H.264.

#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

#include <cstdlib>

#include <atomic>
#include <chrono>
#include <charconv>
#include <regex>
#include <condition_variable>
#include <cerrno>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

extern "C" bool camera_signature_use_plugin(const char* path);
extern "C" unsigned camera_signature_inspections();

namespace {

using OnPrinterConnectedFn = std::function<void(std::string)>;
using OnLocalConnectedFn = std::function<void(int, std::string, std::string)>;
using OnServerConnectedFn = std::function<void(int, int)>;
using OnMessageFn = std::function<void(std::string, std::string)>;
using OnHttpErrorFn = std::function<void(unsigned, std::string)>;
using GetCountryCodeFn = std::function<std::string()>;
using OnSubscribeFailureFn = std::function<void(std::string)>;
using OnMsgArrivedFn = std::function<void(std::string)>;
using QueueOnMainFn = std::function<void(std::function<void()>)>;
using OnServerErrFn = std::function<void(std::string, int)>;
using UrlFn = std::function<void(std::string)>;

struct Network {
    void* handle = nullptr;
    std::string (*get_version)() = nullptr;
    void* (*create_agent)(std::string) = nullptr;
    int (*set_config_dir)(void*, std::string) = nullptr;
    int (*init_log)(void*) = nullptr;
    int (*set_cert_file)(void*, std::string, std::string) = nullptr;
    int (*set_extra_http_header)(void*, std::map<std::string, std::string>) = nullptr;
    int (*set_country_code)(void*, std::string) = nullptr;
    int (*start)(void*) = nullptr;
    int (*set_on_printer_connected_fn)(void*, OnPrinterConnectedFn) = nullptr;
    int (*set_on_server_connected_fn)(void*, OnServerConnectedFn) = nullptr;
    int (*set_on_http_error_fn)(void*, OnHttpErrorFn) = nullptr;
    int (*set_get_country_code_fn)(void*, GetCountryCodeFn) = nullptr;
    int (*set_on_subscribe_failure_fn)(void*, OnSubscribeFailureFn) = nullptr;
    int (*set_on_message_fn)(void*, OnMessageFn) = nullptr;
    int (*set_on_user_message_fn)(void*, OnMessageFn) = nullptr;
    int (*set_on_local_connect_fn)(void*, OnLocalConnectedFn) = nullptr;
    int (*set_on_local_message_fn)(void*, OnMessageFn) = nullptr;
    int (*set_queue_on_main_fn)(void*, QueueOnMainFn) = nullptr;
    int (*set_on_ssdp_msg_fn)(void*, OnMsgArrivedFn) = nullptr;
    int (*set_server_callback)(void*, OnServerErrFn) = nullptr;
    void (*enable_multi_machine)(void*, bool) = nullptr;
    bool (*start_discovery)(void*, bool, bool) = nullptr;
    int (*change_user)(void*, std::string) = nullptr;
    bool (*is_user_login)(void*) = nullptr;
    int (*update_cert)(void*) = nullptr;
    int (*get_user_print_info)(void*, unsigned int*, std::string*) = nullptr;
    int (*connect_server)(void*) = nullptr;
    int (*add_subscribe)(void*, std::vector<std::string>) = nullptr;
    int (*set_user_selected_machine)(void*, std::string) = nullptr;
    int (*send_message)(void*, std::string, std::string, int, int) = nullptr;
    int (*refresh_connection)(void*) = nullptr;
    void (*install_device_cert)(void*, std::string, bool) = nullptr;
    int (*get_camera_url)(void*, std::string, UrlFn) = nullptr;
};

extern "C" {
struct Bambu_StreamInfo {
    int type;
    int sub_type;
    union {
        struct { int width; int height; int frame_rate; } video;
        struct { int sample_rate; int channel_count; int sample_size; } audio;
    } format;
    int format_type;
    int format_size;
    int max_frame_size;
    unsigned char const* format_buffer;
};

struct Bambu_Sample {
    int itrack;
    int size;
    int flags;
    unsigned char const* buffer;
    unsigned long long decode_time;
};
}

enum { Bambu_success = 0, Bambu_stream_end = 1, Bambu_would_block = 2, Bambu_buffer_limit = 3 };

using Logger = void (*)(void*, int, char const*);

struct Source {
    void* handle = nullptr;
    int (*init)() = nullptr;
    int (*create)(void**, char const*) = nullptr;
    void (*set_logger)(void*, Logger, void*) = nullptr;
    int (*open)(void*) = nullptr;
    int (*start_stream)(void*, bool) = nullptr;
    int (*get_stream_count)(void*) = nullptr;
    int (*get_stream_info)(void*, int, Bambu_StreamInfo*) = nullptr;
    int (*read_sample)(void*, Bambu_Sample*) = nullptr;
    void (*close)(void*) = nullptr;
    void (*destroy)(void*) = nullptr;
    void (*free_log_msg)(char const*) = nullptr;
};

int g_out = -1;
int g_log = -1;
FILE* g_dump = nullptr;
std::atomic<bool> g_unauthorized{false};
std::mutex g_out_mutex;
Source g_source;

void trace(const char* format, ...)
{
    if (g_log < 0) return;
    char line[1024];
    va_list args;
    va_start(args, format);
    int n = std::vsnprintf(line, sizeof line - 1, format, args);
    va_end(args);
    if (n < 0) return;
    n = std::min(n, int(sizeof line) - 2);
    line[n++] = '\n';
    (void)!::write(g_log, "bambu-camera: ", 14);
    (void)!::write(g_log, line, n);
}

[[noreturn]] void quit(int code)
{
    // The plugin's destructors join worker threads for up to a minute; nothing here needs them.
    ::_exit(code);
}

void write_all(const void* data, size_t size)
{
    auto bytes = static_cast<const uint8_t*>(data);
    while (size > 0) {
        ssize_t n = ::write(g_out, bytes, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) quit(0);
        bytes += n;
        size -= size_t(n);
    }
}

void frame(char type, const std::string& head, const uint8_t* body = nullptr, size_t body_size = 0)
{
    std::lock_guard<std::mutex> lock(g_out_mutex);
    const uint32_t length = uint32_t(head.size() + body_size);
    const uint8_t header[5] = {uint8_t(type), uint8_t(length >> 24), uint8_t(length >> 16), uint8_t(length >> 8), uint8_t(length)};
    write_all(header, sizeof header);
    if (!head.empty()) write_all(head.data(), head.size());
    if (body_size) write_all(body, body_size);
}

std::string escaped(const std::string& text)
{
    std::string out;
    for (char c : text) {
        if (c == '"' || c == '\\') { out += '\\'; out += c; }
        else if (uint8_t(c) < 0x20) out += ' ';
        else out += c;
    }
    return out;
}

void status(const std::string& state, const std::string& detail = "")
{
    trace("%s%s%s", state.c_str(), detail.empty() ? "" : ": ", detail.c_str());
    std::string json = "{\"state\":\"" + escaped(state) + "\"";
    if (!detail.empty()) json += ",\"detail\":\"" + escaped(detail) + "\"";
    json += "}";
    frame('S', json);
}

[[noreturn]] void fail(const std::string& reason, const std::string& detail, int code)
{
    status("error:" + reason, detail);
    quit(code);
}

template <typename T>
void bind(void* handle, T& slot, const char* name, bool required = true)
{
    slot = reinterpret_cast<T>(::dlsym(handle, name));
    if (!slot && required) fail("plugin", std::string("Bambu Studio's network plugin has no ") + name + ".", 4);
}

[[noreturn]] void load_failed(const std::string& path)
{
    const std::string error = ::dlerror() ?: "unknown error";
    trace("dlopen %s: %s", path.c_str(), error.c_str());
    const std::string name = path.substr(path.rfind('/') + 1);
    if (error.find("different Team IDs") != std::string::npos)
        fail("plugin", "macOS blocked Bambu Studio's " + name + ": this build of the camera helper isn't signed to load it.", 4);
    fail("plugin", "Couldn't load Bambu Studio's " + name + ". Open Bambu Studio once so it repairs its plugin.", 4);
}

void load_network(Network& n, const std::string& path)
{
    n.handle = ::dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!n.handle) load_failed(path);
    void* h = n.handle;
    bind(h, n.get_version, "bambu_network_get_version");
    bind(h, n.create_agent, "bambu_network_create_agent");
    bind(h, n.set_config_dir, "bambu_network_set_config_dir");
    bind(h, n.init_log, "bambu_network_init_log");
    bind(h, n.set_cert_file, "bambu_network_set_cert_file");
    bind(h, n.set_extra_http_header, "bambu_network_set_extra_http_header");
    bind(h, n.set_country_code, "bambu_network_set_country_code");
    bind(h, n.start, "bambu_network_start");
    bind(h, n.set_on_printer_connected_fn, "bambu_network_set_on_printer_connected_fn");
    bind(h, n.set_on_server_connected_fn, "bambu_network_set_on_server_connected_fn");
    bind(h, n.set_on_http_error_fn, "bambu_network_set_on_http_error_fn");
    bind(h, n.set_get_country_code_fn, "bambu_network_set_get_country_code_fn");
    bind(h, n.set_on_subscribe_failure_fn, "bambu_network_set_on_subscribe_failure_fn");
    bind(h, n.set_on_message_fn, "bambu_network_set_on_message_fn");
    bind(h, n.set_on_user_message_fn, "bambu_network_set_on_user_message_fn");
    bind(h, n.set_on_local_connect_fn, "bambu_network_set_on_local_connect_fn");
    bind(h, n.set_on_local_message_fn, "bambu_network_set_on_local_message_fn");
    bind(h, n.set_queue_on_main_fn, "bambu_network_set_queue_on_main_fn", false);
    bind(h, n.set_on_ssdp_msg_fn, "bambu_network_set_on_ssdp_msg_fn");
    bind(h, n.set_server_callback, "bambu_network_set_server_callback", false);
    bind(h, n.enable_multi_machine, "bambu_network_enable_multi_machine", false);
    bind(h, n.start_discovery, "bambu_network_start_discovery", false);
    bind(h, n.change_user, "bambu_network_change_user");
    bind(h, n.is_user_login, "bambu_network_is_user_login");
    bind(h, n.update_cert, "bambu_network_update_cert", false);
    bind(h, n.get_user_print_info, "bambu_network_get_user_print_info", false);
    bind(h, n.connect_server, "bambu_network_connect_server");
    bind(h, n.add_subscribe, "bambu_network_add_subscribe");
    bind(h, n.set_user_selected_machine, "bambu_network_set_user_selected_machine", false);
    bind(h, n.send_message, "bambu_network_send_message");
    bind(h, n.refresh_connection, "bambu_network_refresh_connection", false);
    bind(h, n.install_device_cert, "bambu_network_install_device_cert", false);
    bind(h, n.get_camera_url, "bambu_network_get_camera_url");
}

void load_source(const std::string& path)
{
    Source& s = g_source;
    s.handle = ::dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!s.handle) load_failed(path);
    bind(s.handle, s.init, "Bambu_Init", false);
    bind(s.handle, s.create, "Bambu_Create");
    bind(s.handle, s.set_logger, "Bambu_SetLogger");
    bind(s.handle, s.open, "Bambu_Open");
    bind(s.handle, s.start_stream, "Bambu_StartStream");
    bind(s.handle, s.get_stream_count, "Bambu_GetStreamCount");
    bind(s.handle, s.get_stream_info, "Bambu_GetStreamInfo");
    bind(s.handle, s.read_sample, "Bambu_ReadSample");
    bind(s.handle, s.close, "Bambu_Close");
    bind(s.handle, s.destroy, "Bambu_Destroy");
    bind(s.handle, s.free_log_msg, "Bambu_FreeLogMsg", false);
}

void source_log(void*, int, char const* message)
{
    if (message && g_source.free_log_msg) g_source.free_log_msg(message);
}

struct Latch {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    void signal() { { std::lock_guard<std::mutex> lock(mutex); done = true; } cv.notify_all(); }
    bool wait(std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex);
        return cv.wait_for(lock, timeout, [this] { return done; });
    }
};

std::map<std::string, std::string> read_config()
{
    std::map<std::string, std::string> config;
    std::string line;
    while (std::getline(std::cin, line) && !line.empty()) {
        auto eq = line.find('=');
        if (eq != std::string::npos) config[line.substr(0, eq)] = line.substr(eq + 1);
    }
    return config;
}

std::string mint(Network& n, void* agent, const std::string& key)
{
    for (int attempt = 1; attempt <= 4; ++attempt) {
        struct Result { std::mutex mutex; std::condition_variable cv; bool done = false; std::string url; };
        auto result = std::make_shared<Result>();
        int rc = n.get_camera_url(agent, key, [result](std::string url) {
            std::lock_guard<std::mutex> lock(result->mutex);
            result->url = std::move(url);
            result->done = true;
            result->cv.notify_all();
        });
        std::unique_lock<std::mutex> lock(result->mutex);
        if (result->cv.wait_for(lock, 15s, [&] { return result->done; })) return result->url;
        trace("get_camera_url attempt %d: no answer (rc=%d)", attempt, rc);
    }
    return "";
}

// Only log numeric failure fields: callback bodies can contain credentials or camera URLs.
int parse_code(const std::string& value)
{
    int code = -1;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), code);
    return result.ec == std::errc() && result.ptr == value.data() + value.size() ? code : -1;
}

int http_body_code(const std::string& body)
{
    static const std::regex field(R"("code"\s*:\s*(-?[0-9]+)\s*[,}])");
    std::smatch match;
    if (body.size() > 65536 || !std::regex_search(body, match, field)) return -1;
    return parse_code(match[1].str());
}

// The plugin reports failures as a short non-URL string ending in "[code]".
int error_code(const std::string& answer)
{
    auto open = answer.rfind('[');
    if (open == std::string::npos || answer.back() != ']') return -1;
    return parse_code(answer.substr(open + 1, answer.size() - open - 2));
}

struct Session {
    Network net;
    void* agent = nullptr;
    std::string dev_id, net_version, cli_id, client_version;
};
Session g_session;
Latch g_ready;

std::mutex g_sent_mutex;
std::set<std::string> g_sent;

struct CameraControl {
    std::mutex mutex;
    std::condition_variable cv;
    bool wanted = false;
    unsigned generation = 0;
    std::string dev_ver;
};
CameraControl g_camera;

bool camera_active(unsigned generation)
{
    std::lock_guard<std::mutex> lock(g_camera.mutex);
    return g_camera.wanted && g_camera.generation == generation;
}

void camera_status(unsigned generation, const std::string& state, const std::string& detail = "")
{
    if (camera_active(generation)) status("camera:" + state, detail);
}

void camera_failed(unsigned generation, const std::string& reason, const std::string& detail)
{
    std::lock_guard<std::mutex> lock(g_camera.mutex);
    if (!g_camera.wanted || g_camera.generation != generation) return;
    g_camera.wanted = false;
    status("camera:error:" + reason, detail);
}

std::string json_field(const std::string& body, const std::regex& pattern)
{
    std::smatch match;
    return std::regex_search(body, match, pattern) ? match[1].str() : std::string();
}

void ack(const std::string& command, const std::string& result, const std::string& reason, const std::string& sequence)
{
    trace("ack command=%s result=%s reason=%s", command.c_str(), result.c_str(), reason.c_str());
    frame('A', "{\"command\":\"" + escaped(command) + "\",\"result\":\"" + escaped(result) + "\",\"reason\":\"" + escaped(reason) +
                   "\",\"sequence_id\":\"" + escaped(sequence) + "\"}");
}

// Reports carry the whole printer state; only acks for commands sent from here are forwarded, by sequence id.
void cloud_message(const std::string& body)
{
    if (body.find("\"result\"") == std::string::npos) return;
    static const std::regex sequence(R"re("sequence_id"\s*:\s*"([0-9]+)")re"), command(R"re("command"\s*:\s*"([a-z_]+)")re"),
        result(R"re("result"\s*:\s*"([A-Za-z_]+)")re"), reason(R"re("reason"\s*:\s*"([^"]{0,120})")re");
    const std::string id = json_field(body, sequence);
    {
        std::lock_guard<std::mutex> lock(g_sent_mutex);
        if (id.empty() || g_sent.erase(id) == 0) return;
    }
    ack(json_field(body, command), json_field(body, result), json_field(body, reason), id);
}

void send_command(const std::string& json)
{
    static const std::regex sequence(R"re("sequence_id"\s*:\s*"([0-9]+)")re"), command(R"re("command"\s*:\s*"([a-z_]+)")re");
    const std::string id = json_field(json, sequence), name = json_field(json, command);
    if (!g_ready.wait(90s)) return ack(name, "failed", "Bambu Cloud didn't connect.", id);
    if (!id.empty()) {
        std::lock_guard<std::mutex> lock(g_sent_mutex);
        g_sent.insert(id);
    }
    const int rc = g_session.net.send_message(g_session.agent, g_session.dev_id, json, 1, 0);
    trace("send %s rc=%d", name.c_str(), rc);
    if (rc != 0) {
        {
            std::lock_guard<std::mutex> lock(g_sent_mutex);
            g_sent.erase(id);
        }
        ack(name, "failed", "Bambu Cloud didn't take the command (" + std::to_string(rc) + ").", id);
    }
}

void want_camera(bool on, const std::string& dev_ver = "")
{
    {
        std::lock_guard<std::mutex> lock(g_camera.mutex);
        g_camera.wanted = on;
        ++g_camera.generation;
        if (on) g_camera.dev_ver = dev_ver;
    }
    g_camera.cv.notify_all();
}

// stdin after the settings: "send <json>", "camera <firmware>", "nocamera". EOF ends the session.
void read_commands()
{
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.rfind("send ", 0) == 0) std::thread(send_command, line.substr(5)).detach();
        else if (line.rfind("camera", 0) == 0) want_camera(true, line.size() > 7 ? line.substr(7) : "");
        else if (line == "nocamera") want_camera(false);
    }
    quit(0);
}

enum class StreamEnd { failed, ended, gotSamples, stopped };

StreamEnd play(const std::string& url, unsigned generation)
{
    Source& s = g_source;
    void* tunnel = nullptr;
    if (s.create(&tunnel, url.c_str()) != Bambu_success || !tunnel) {
        trace("Bambu_Create failed");
        return StreamEnd::failed;
    }
    s.set_logger(tunnel, source_log, nullptr);
    auto finish = [&](StreamEnd end, bool opened) {
        if (opened) s.close(tunnel);
        s.destroy(tunnel);
        return end;
    };
    int rc = s.open(tunnel);
    if (rc != Bambu_success && rc != Bambu_would_block) {
        trace("Bambu_Open rc=%d", rc);
        return finish(StreamEnd::failed, false);
    }
    const auto deadline = std::chrono::steady_clock::now() + 20s;
    do {
        if (!camera_active(generation)) return finish(StreamEnd::stopped, true);
        rc = s.start_stream(tunnel, true);
        if (rc != Bambu_would_block) break;
        std::this_thread::sleep_for(50ms);
    } while (std::chrono::steady_clock::now() < deadline);
    if (rc != Bambu_success) {
        trace("Bambu_StartStream rc=%d", rc);
        return finish(StreamEnd::failed, true);
    }

    const int streams = s.get_stream_count(tunnel);
    for (int i = 0; i < streams; ++i) {
        Bambu_StreamInfo info {};
        if (s.get_stream_info(tunnel, i, &info) != Bambu_success || info.type != 0) continue;
        if (g_dump && info.format_buffer && info.format_size > 0) std::fwrite(info.format_buffer, 1, size_t(info.format_size), g_dump);
        trace("video %dx%d@%d format_type=%d sub_type=%d format_size=%d", info.format.video.width, info.format.video.height,
            info.format.video.frame_rate, info.format_type, info.sub_type, info.format_size);
        int32_t fields[5] = {info.format.video.width, info.format.video.height, info.format.video.frame_rate, info.format_type, info.sub_type};
        std::string head(reinterpret_cast<const char*>(fields), sizeof fields);
        const size_t format_size = info.format_buffer && info.format_size > 0 ? size_t(info.format_size) : 0;
        frame('I', head, info.format_buffer, format_size);
        break;
    }
    camera_status(generation, "streaming");

    bool any = false;
    StreamEnd end = StreamEnd::failed;
    for (;;) {
        if (!camera_active(generation)) return finish(StreamEnd::stopped, true);
        Bambu_Sample sample {};
        rc = s.read_sample(tunnel, &sample);
        if (rc == Bambu_would_block || rc == Bambu_buffer_limit) {
            std::this_thread::sleep_for(5ms);
            continue;
        }
        if (rc != Bambu_success) {
            trace("Bambu_ReadSample rc=%d", rc);
            end = rc == Bambu_stream_end ? StreamEnd::ended : StreamEnd::failed;
            break;
        }
        if (!sample.buffer || sample.size <= 0) continue;
        any = true;
        uint8_t head[9];
        head[0] = uint8_t(sample.flags);
        for (int i = 0; i < 8; ++i) head[1 + i] = uint8_t(sample.decode_time >> (8 * i));
        frame('V', std::string(reinterpret_cast<const char*>(head), sizeof head), sample.buffer, size_t(sample.size));
        if (g_dump) {
            std::fwrite(sample.buffer, 1, size_t(sample.size), g_dump);
            std::fflush(g_dump);
        }
    }
    return finish(any ? StreamEnd::gotSamples : end, true);
}

void run_camera(unsigned generation, const std::string& dev_ver)
{
    Session& session = g_session;
    const std::string key = session.dev_id + "|" + dev_ver + "|\"tutk\",\"agora\"";
    int failures = 0;
    auto backoff = 2s;
    auto pause = [&] {
        for (auto waited = 0ms; waited < backoff && camera_active(generation); waited += 100ms) std::this_thread::sleep_for(100ms);
        backoff = std::min(backoff * 2, std::chrono::seconds(30));
    };
    while (camera_active(generation)) {
        camera_status(generation, "minting");
        const std::string answer = mint(session.net, session.agent, key);
        if (!camera_active(generation)) return;
        if (answer.rfind("bambu:///", 0) != 0) {
            const int code = error_code(answer);
            trace("camera mint failed: attempt=%d code=%d empty=%s", failures + 1, code, answer.empty() ? "yes" : "no");
            if (code == 1) return camera_failed(generation, "busy", "Another app is already watching this camera.");
            if (g_unauthorized) fail("auth", "Bambu didn't accept the account sign-in.", 3);
            if (++failures >= 4) {
                return camera_failed(generation, "mint",
                    answer.empty() ? "Bambu didn't hand out a camera link." : "Bambu refused the camera link (" + std::to_string(code) + ").");
            }
            pause();
            continue;
        }
        std::string url = answer + "&device=" + session.dev_id + "&net_ver=" + session.net_version + "&dev_ver=" + dev_ver;
        if (!session.cli_id.empty()) url += "&cli_id=" + session.cli_id;
        url += "&cli_ver=" + session.client_version;

        camera_status(generation, "opening");
        switch (play(url, generation)) {
        case StreamEnd::stopped:
            return;
        case StreamEnd::gotSamples:
            failures = 0;
            backoff = 2s;
            break;
        case StreamEnd::ended:
        case StreamEnd::failed:
            if (++failures >= 4) return camera_failed(generation, "stream", "The camera stream didn't start.");
            pause();
            break;
        }
    }
}

void camera_worker()
{
    if (g_source.init) g_source.init();
    for (;;) {
        unsigned generation;
        std::string dev_ver;
        {
            std::unique_lock<std::mutex> lock(g_camera.mutex);
            g_camera.cv.wait(lock, [] { return g_camera.wanted; });
            generation = g_camera.generation;
            dev_ver = g_camera.dev_ver;
        }
        run_camera(generation, dev_ver);
    }
}

} // namespace

int main()
{
    ::signal(SIGPIPE, SIG_IGN);
    g_out = ::dup(STDOUT_FILENO);
    g_log = ::dup(STDERR_FILENO);
    const int null = ::open("/dev/null", O_WRONLY);
    ::dup2(null, STDOUT_FILENO);
    ::dup2(null, STDERR_FILENO);
    ::fcntl(g_out, F_SETFD, FD_CLOEXEC);
    ::fcntl(g_log, F_SETFD, FD_CLOEXEC);
    if (!std::getenv("BAMBU_CAMERA_VERBOSE")) g_log = -1;

    auto config = read_config();
    auto get = [&](const char* key) { auto it = config.find(key); return it == config.end() ? std::string() : it->second; };
    if (const std::string path = get("log_file"); !path.empty() && g_log < 0) {
        g_log = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    }
    if (const std::string path = get("dump_file"); !path.empty()) {
        const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd >= 0) g_dump = ::fdopen(fd, "wb");
    }
    const std::string plugin_dir = get("plugin_dir"), data_dir = get("data_dir"), cert_dir = get("cert_dir");
    const std::string dev_id = get("dev_id"), user_info = get("user_info");
    const std::string client_version = get("client_version"), country = get("country").empty() ? "US" : get("country");
    const std::string cli_id = get("cli_id");
    if (plugin_dir.empty() || data_dir.empty() || dev_id.empty() || user_info.empty())
        fail("config", "Missing settings.", 64);

    std::thread(read_commands).detach();

    status("loading");
    Network& n = g_session.net;
    const char* signature_source = std::getenv("CAMERA_SIGNATURE_SOURCE");
    // The plugin reserves Executable-info and derives it internally. Use its own real
    // signature by default; CAMERA_SIGNATURE_SOURCE=host is an opt-out for diagnostics.
    if (!signature_source || std::strcmp(signature_source, "host") != 0) {
        if (!camera_signature_use_plugin((plugin_dir + "/libbambu_networking.dylib").c_str()))
            fail("config", "Couldn't locate the camera plugin's signing metadata.", 64);
        trace("signature source: installed Bambu networking plugin");
    }
    load_network(n, plugin_dir + "/libbambu_networking.dylib");
    load_source(plugin_dir + "/libBambuSource.dylib");
    const std::string net_version = n.get_version();
    trace("network plugin %s", net_version.c_str());

    void* agent = n.create_agent(data_dir);
    if (!agent) fail("plugin", "The network plugin didn't start.", 4);
    trace("plugin signature inspections=%u", camera_signature_inspections());

    Latch server_connected;
    n.set_on_printer_connected_fn(agent, [](std::string) {});
    n.set_on_server_connected_fn(agent, [&server_connected](int rc, int reason) {
        trace("server connected rc=%d reason=%d", rc, reason);
        server_connected.signal();
    });
    n.set_on_http_error_fn(agent, [](unsigned code, std::string body) {
        trace("http error status=%u api_code=%d", code, http_body_code(body));
        if (code == 401) g_unauthorized = true;
    });
    n.set_get_country_code_fn(agent, [country] { return country; });
    n.set_on_subscribe_failure_fn(agent, [](std::string) { trace("subscribe failed"); });
    n.set_on_message_fn(agent, [](std::string, std::string body) { cloud_message(body); });
    n.set_on_user_message_fn(agent, [](std::string, std::string) {});
    n.set_on_local_connect_fn(agent, [](int, std::string, std::string) {});
    n.set_on_local_message_fn(agent, [](std::string, std::string) {});
    n.set_on_ssdp_msg_fn(agent, [](std::string) {});
    if (n.set_queue_on_main_fn) n.set_queue_on_main_fn(agent, [](std::function<void()> fn) { if (fn) fn(); });
    if (n.set_server_callback) n.set_server_callback(agent, [](std::string, int status) { trace("server callback %d", status); });

    n.set_config_dir(agent, data_dir);
    n.init_log(agent);
    n.set_cert_file(agent, cert_dir, "slicer_base64.cer");

    // Plugin 02.08.02.60 ignores external Executable-info headers and supplies its own.
    // Keep the native macOS platform paired with the plugin's certificate.
    const std::string os_type = getenv("CAMERA_OS_TYPE") ? getenv("CAMERA_OS_TYPE") : "macos";
    trace("requested X-BBL-OS-Type=%s; executable-info supplied by plugin", os_type.c_str());

    std::map<std::string, std::string> headers = {
        {"X-BBL-Client-Type", "slicer"},
        {"X-BBL-Client-Name", "BambuStudio"},
        {"X-BBL-Client-Version", client_version},
        {"X-BBL-OS-Type", os_type},
        {"X-BBL-OS-Version", get("os_version")},
        {"X-BBL-Language", "en"},
    };
    if (!cli_id.empty()) headers["X-BBL-Device-ID"] = cli_id;
    trace("set_extra_http_header rc=%d (plugin reserves executable-info)", n.set_extra_http_header(agent, headers));
    n.set_country_code(agent, country);
    n.start(agent);
    if (n.enable_multi_machine) n.enable_multi_machine(agent, false);
    if (n.start_discovery) n.start_discovery(agent, true, false);

    status("signing_in");
    const int user_rc = n.change_user(agent, user_info);
    bool logged_in = n.is_user_login(agent);
    for (int i = 0; i < 10 && !logged_in; ++i) {
        std::this_thread::sleep_for(500ms);
        logged_in = n.is_user_login(agent);
    }
    trace("change_user rc=%d, logged in: %s", user_rc, logged_in ? "yes" : "no");

    status("connecting");
    if (n.update_cert) {
        trace("update_cert rc=%d", n.update_cert(agent));
        std::this_thread::sleep_for(3s);
    }
    if (n.get_user_print_info) {
        unsigned int code = 0;
        std::string body;
        n.get_user_print_info(agent, &code, &body);
        trace("bound printers http %u", code);
    }
    if (n.enable_multi_machine) n.enable_multi_machine(agent, true);
    n.connect_server(agent);
    if (!server_connected.wait(15s)) trace("cloud MQTT not confirmed after 15 s");
    if (g_unauthorized) fail("auth", "Bambu didn't accept the account sign-in.", 3);
    n.add_subscribe(agent, {dev_id});
    if (n.set_user_selected_machine) n.set_user_selected_machine(agent, dev_id);
    std::this_thread::sleep_for(1s);
    for (const char* message : {
             R"({"pushing":{"sequence_id":"20000","command":"pushall","version":1,"push_target":1}})",
             R"({"info":{"sequence_id":"20001","command":"get_version"}})",
             R"({"system":{"sequence_id":"20002","command":"get_access_code"}})",
         })
        n.send_message(agent, dev_id, message, 0, 0);

    // Studio repeats these every second for the selected printer; signed commands and the camera
    // mint both wait until the device certificate is installed for this session.
    std::thread([agent, dev_id] {
        for (;;) {
            if (n.refresh_connection) n.refresh_connection(agent);
            if (n.install_device_cert) n.install_device_cert(agent, dev_id, false);
            std::this_thread::sleep_for(1s);
        }
    }).detach();
    std::this_thread::sleep_for(3s);

    g_session.agent = agent;
    g_session.dev_id = dev_id;
    g_session.net_version = net_version;
    g_session.cli_id = cli_id;
    g_session.client_version = client_version;
    status("ready");
    g_ready.signal();
    camera_worker();
}
