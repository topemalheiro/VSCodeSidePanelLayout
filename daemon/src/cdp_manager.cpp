#include "cdp_manager.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <boost/beast/websocket.hpp>
#include <boost/asio/connect.hpp>

namespace rp {

static std::string exec(const char* cmd) {
    std::array<char, 4096> buffer{};
    std::string result;
    FILE* pipe = popen(cmd, "r");
    if (!pipe) return {};
    while (std::fgets(buffer.data(), buffer.size(), pipe) != nullptr) {
        result += buffer.data();
    }
    pclose(pipe);
    return result;
}

static void set_socket_timeout(int fd, int seconds) {
    struct timeval tv;
    tv.tv_sec = seconds;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

CDPManager::CDPManager() {}

CDPManager::~CDPManager() {
    close_all();
}

std::optional<int> CDPManager::read_cdp_port(const std::string& path) {
    std::FILE* f = std::fopen(path.c_str(), "r");
    if (!f) return std::nullopt;
    char line[64];
    if (std::fgets(line, sizeof(line), f)) {
        std::fclose(f);
        return std::atoi(line);
    }
    std::fclose(f);
    return std::nullopt;
}

std::vector<CDPTarget> CDPManager::fetch_targets(int port) {
    std::vector<CDPTarget> result;
    char cmd[256];
    std::snprintf(cmd, sizeof(cmd), "curl -s --max-time 2 http://127.0.0.1:%d/json 2>/dev/null", port);
    std::string json = exec(cmd);
    if (json.empty()) return result;

    try {
        boost::json::value doc = boost::json::parse(json);
        if (!doc.is_array()) return result;
        for (const auto& item : doc.as_array()) {
            const auto& obj = item.as_object();
            if (std::string(obj.at("type").as_string()) != "page") continue;
            CDPTarget t;
            t.port = port;
            t.id = std::string(obj.at("id").as_string());
            t.title = std::string(obj.at("title").as_string());
            t.url = std::string(obj.at("url").as_string());
            if (auto* v = obj.if_contains("webSocketDebuggerUrl")) {
                t.ws_url = std::string(v->as_string());
            }
            result.push_back(t);
        }
    } catch (const std::exception& e) {
        std::fprintf(stderr, "CDP: failed to parse targets: %s\n", e.what());
    }
    return result;
}

std::vector<CDPTarget> CDPManager::discover_targets() {
    std::vector<CDPTarget> all;
    const char* home = std::getenv("HOME");
    if (!home) home = ".";

    std::vector<std::string> candidates = {
        std::string(home) + "/.config/Code/DevToolsActivePort",
        std::string(home) + "/.config/VSCodium/DevToolsActivePort",
        std::string(home) + "/.config/Code - OSS/DevToolsActivePort",
    };

    for (const auto& p : candidates) {
        auto port_opt = read_cdp_port(p);
        if (port_opt) {
            auto targets = fetch_targets(*port_opt);
            all.insert(all.end(), targets.begin(), targets.end());
        }
    }

    // Fallback to default port
    if (all.empty()) {
        all = fetch_targets(9222);
    }
    return all;
}

bool CDPManager::connect(CDPSession* session) {
    if (session->ws && session->ws->is_open()) return true;

    // Parse ws_url: ws://host:port/path
    const std::string& url = session->target.ws_url;
    if (url.empty()) return false;

    std::size_t pos = url.find("://");
    if (pos == std::string::npos) return false;
    pos += 3;

    std::size_t path_pos = url.find('/', pos);
    if (path_pos == std::string::npos) path_pos = url.size();

    std::string host_port = url.substr(pos, path_pos - pos);
    std::string path = (path_pos < url.size()) ? url.substr(path_pos) : "/";

    std::string host;
    std::string port_str = "80";
    std::size_t colon = host_port.find(':');
    if (colon != std::string::npos) {
        host = host_port.substr(0, colon);
        port_str = host_port.substr(colon + 1);
    } else {
        host = host_port;
    }

    try {
        boost::asio::ip::tcp::resolver resolver(io_);
        auto results = resolver.resolve(host, port_str);

        session->ws = std::make_unique<boost::beast::websocket::stream<boost::asio::ip::tcp::socket>>(io_);
        boost::asio::connect(session->ws->next_layer(), results);

        int native = session->ws->next_layer().native_handle();
        set_socket_timeout(native, 5);

        session->ws->handshake(host, path);
        return true;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "CDP: WebSocket connect failed: %s\n", e.what());
        session->ws.reset();
        return false;
    }
}

CDPSession* CDPManager::get_or_create_session(const CDPTarget& target) {
    std::lock_guard<std::mutex> lock(sessions_mtx_);
    auto it = sessions_.find(target.id);
    if (it != sessions_.end()) {
        return it->second.get();
    }

    auto session = std::make_unique<CDPSession>();
    session->target = target;
    CDPSession* ptr = session.get();
    sessions_[target.id] = std::move(session);

    if (!connect(ptr)) {
        sessions_.erase(target.id);
        return nullptr;
    }
    return ptr;
}

boost::json::value CDPManager::send_command(CDPSession* session, const std::string& method, const boost::json::object& params) {
    if (!session || !session->ws) {
        return boost::json::value{};
    }

    std::lock_guard<std::mutex> lock(session->mtx);

    int msg_id = session->next_msg_id++;
    boost::json::object msg;
    msg["id"] = msg_id;
    msg["method"] = method;
    msg["params"] = params;

    std::string payload = boost::json::serialize(msg);
    try {
        session->ws->write(boost::asio::buffer(payload));
    } catch (const std::exception& e) {
        std::fprintf(stderr, "CDP: write failed: %s\n", e.what());
        return boost::json::value{};
    }

    // Read until we get response with matching id
    while (true) {
        boost::beast::flat_buffer buffer;
        try {
            session->ws->read(buffer);
        } catch (const std::exception& e) {
            std::fprintf(stderr, "CDP: read failed: %s\n", e.what());
            return boost::json::value{};
        }

        std::string response(static_cast<const char*>(buffer.data().data()), buffer.size());
        try {
            boost::json::value resp = boost::json::parse(response);
            if (resp.is_object()) {
                const auto& obj = resp.as_object();
                if (auto* idv = obj.if_contains("id")) {
                    if (idv->is_int64() && idv->as_int64() == msg_id) {
                        return resp;
                    }
                }
            }
        } catch (const std::exception& e) {
            std::fprintf(stderr, "CDP: parse response failed: %s\n", e.what());
        }
    }
}

bool CDPManager::resize_panel(CDPSession* session, int target_width, int window_width, const std::string& panel_side) {
    if (!session) return false;

    // Query sash position
    const char* query_js = R"((() => {
    const auxBar = document.getElementById('workbench.parts.auxiliarybar');
    if (!auxBar) return JSON.stringify({error: 'no-auxiliary-bar'});
    const auxRect = auxBar.getBoundingClientRect();
    const isLeft = auxRect.left < window.innerWidth / 2;
    if (auxRect.width === 0) return JSON.stringify({error: 'auxiliary-bar-hidden'});
    const vertSashes = document.querySelectorAll('.monaco-sash.vertical');
    let bestSash = null, bestDist = Infinity;
    for (const s of vertSashes) {
        const r = s.getBoundingClientRect();
        const sashCenter = r.left + r.width / 2;
        const dist = isLeft ? Math.abs(sashCenter - (auxRect.left + auxRect.width)) : Math.abs(sashCenter - auxRect.left);
        if (dist < bestDist) { bestDist = dist; bestSash = s; }
    }
    if (!bestSash || bestDist > 20) return JSON.stringify({error: 'no-sash-found'});
    const sr = bestSash.getBoundingClientRect();
    return JSON.stringify({
        sashX: Math.round(sr.left + sr.width / 2),
        sashY: Math.round(sr.top + sr.height / 2),
        windowWidth: window.innerWidth,
        isLeft: isLeft
    });
})())";

    boost::json::object eval_params;
    eval_params["expression"] = query_js;
    eval_params["returnByValue"] = true;

    auto resp = send_command(session, "Runtime.evaluate", eval_params);
    if (!resp.is_object()) return false;

    try {
        const auto& result_obj = resp.as_object().at("result").as_object().at("result").as_object();
        std::string value = std::string(result_obj.at("value").as_string());
        auto info = boost::json::parse(value).as_object();

        if (info.contains("error")) {
            std::fprintf(stderr, "CDP: sash query error: %s\n", std::string(info.at("error").as_string()).c_str());
            return false;
        }

        int current_sash_x = static_cast<int>(info.at("sashX").as_int64());
        int sash_y = static_cast<int>(info.at("sashY").as_int64());
        int effective_width = window_width > 0 ? window_width : static_cast<int>(info.at("windowWidth").as_int64());
        bool is_left = info.at("isLeft").as_bool();

        int target_sash_x;
        if (is_left || panel_side == "left") {
            target_sash_x = target_width;
        } else {
            target_sash_x = effective_width - target_width;
        }

        if (std::abs(current_sash_x - target_sash_x) <= 5) {
            return true; // already at target
        }

        // Drag sash
        auto dispatch = [&](const char* type, int x, int y) {
            boost::json::object p;
            p["type"] = type;
            p["x"] = x;
            p["y"] = y;
            p["button"] = "left";
            if (std::strcmp(type, "mousePressed") == 0) {
                p["clickCount"] = 1;
            } else if (std::strcmp(type, "mouseMoved") == 0) {
                p["buttons"] = 1;
            }
            send_command(session, "Input.dispatchMouseEvent", p);
        };

        // Move physical cursor away from sash to avoid interference
        // with synthetic CDP mouse events
        std::system("ydotool mousemove 0 0 >/dev/null 2>&1");

        dispatch("mousePressed", current_sash_x, sash_y);

        int dx = target_sash_x - current_sash_x;
        int distance = std::abs(dx);
        int steps = std::max(3, distance / 40);
        for (int i = 1; i <= steps; ++i) {
            int ix = current_sash_x + (dx * i / steps);
            dispatch("mouseMoved", ix, sash_y);
            usleep(10000); // 10ms
        }

        dispatch("mouseReleased", target_sash_x, sash_y);
        usleep(100000); // 100ms for VS Code: to settle

        return true;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "CDP: resize panel error: %s\n", e.what());
        return false;
    }
}

void CDPManager::close_all() {
    std::lock_guard<std::mutex> lock(sessions_mtx_);
    for (auto& [id, session] : sessions_) {
        if (session->ws) {
            try {
                session->ws->close(boost::beast::websocket::close_code::normal);
            } catch (...) {}
        }
    }
    sessions_.clear();
}

} // namespace rp
