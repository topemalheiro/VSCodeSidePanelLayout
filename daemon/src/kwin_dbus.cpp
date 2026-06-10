#include "kwin_dbus.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <boost/json.hpp>

namespace rp {

// ------------------------------------------------------------------
// DBusService
// ------------------------------------------------------------------

DBusService::DBusService() {}

DBusService::~DBusService() {
    stop();
    if (conn_) {
        dbus_connection_close(conn_);
        dbus_connection_unref(conn_);
        conn_ = nullptr;
    }
}

void DBusService::start() {
    DBusError err;
    dbus_error_init(&err);
    conn_ = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!conn_) {
        std::fprintf(stderr, "DBusService: failed to connect to session bus: %s\n", err.message);
        dbus_error_free(&err);
        return;
    }

    int ret = dbus_bus_request_name(conn_, "org.reprompty.LayoutDaemon",
                                    DBUS_NAME_FLAG_REPLACE_EXISTING, &err);
    if (dbus_error_is_set(&err)) {
        std::fprintf(stderr, "DBusService: request_name error: %s\n", err.message);
        dbus_error_free(&err);
        return;
    }
    if (ret != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER &&
        ret != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        std::fprintf(stderr, "DBusService: failed to acquire name (ret=%d)\n", ret);
        return;
    }

    static const DBusObjectPathVTable vtable = {
        nullptr,                       // unregister_function
        handle_message_static,         // message_function
        nullptr, nullptr, nullptr, nullptr
    };

    if (!dbus_connection_register_object_path(conn_, "/org/reprompty/LayoutDaemon",
                                               &vtable, this)) {
        std::fprintf(stderr, "DBusService: failed to register object path\n");
        return;
    }

    running_ = true;
    thread_ = std::thread(&DBusService::dispatch_loop, this);
}

void DBusService::stop() {
    running_ = false;
    if (thread_.joinable()) {
        thread_.join();
    }
}

void DBusService::submit_result(const std::string& request_id, const std::string& json) {
    std::lock_guard<std::mutex> lock(mtx_);
    results_[request_id] = json;
    cv_.notify_all();
}

bool DBusService::wait_for_result(const std::string& request_id, std::string& out_json, int timeout_ms) {
    std::unique_lock<std::mutex> lock(mtx_);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);

    while (results_.find(request_id) == results_.end()) {
        if (cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
            return false;
        }
    }

    out_json = results_[request_id];
    results_.erase(request_id);
    return true;
}

void DBusService::dispatch_loop() {
    while (running_) {
        dbus_connection_read_write_dispatch(conn_, 100);
    }
}

DBusHandlerResult DBusService::handle_message_static(DBusConnection* conn, DBusMessage* msg, void* data) {
    auto* self = static_cast<DBusService*>(data);
    return self->handle_message(conn, msg);
}

DBusHandlerResult DBusService::handle_message(DBusConnection* conn, DBusMessage* msg) {
    if (dbus_message_is_method_call(msg, "org.reprompty.LayoutDaemon", "SubmitResult")) {
        DBusMessageIter args;
        if (!dbus_message_iter_init(msg, &args)) {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        }

        const char* request_id = nullptr;
        const char* json = nullptr;

        if (dbus_message_iter_get_arg_type(&args) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&args, &request_id);
        }
        dbus_message_iter_next(&args);
        if (dbus_message_iter_get_arg_type(&args) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&args, &json);
        }

        if (request_id && json) {
            submit_result(request_id, json);
        }

        DBusMessage* reply = dbus_message_new_method_return(msg);
        if (reply) {
            dbus_connection_send(conn, reply, nullptr);
            dbus_message_unref(reply);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

// ------------------------------------------------------------------
// KWinClient helpers
// ------------------------------------------------------------------

static bool write_temp_script(const std::string& js, std::string& out_path) {
    char path[] = "/tmp/reprompty_kwin_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return false;
    ssize_t written = ::write(fd, js.data(), js.size());
    ::close(fd);
    if (written != static_cast<ssize_t>(js.size())) {
        unlink(path);
        return false;
    }
    out_path = path;
    return true;
}

static bool send_method_call(DBusConnection* conn, const char* dest, const char* path,
                              const char* iface, const char* method,
                              DBusMessage** out_reply) {
    DBusMessage* msg = dbus_message_new_method_call(dest, path, iface, method);
    if (!msg) return false;

    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err);
    dbus_message_unref(msg);

    if (dbus_error_is_set(&err)) {
        std::fprintf(stderr, "D-Bus %s.%s on %s failed: %s\n", iface, method, path, err.message);
        dbus_error_free(&err);
        return false;
    }

    if (out_reply) *out_reply = reply;
    else if (reply) dbus_message_unref(reply);
    return true;
}

static bool send_method_call_with_string(DBusConnection* conn, const char* dest, const char* path,
                                          const char* iface, const char* method,
                                          const char* arg, DBusMessage** out_reply) {
    DBusMessage* msg = dbus_message_new_method_call(dest, path, iface, method);
    if (!msg) return false;

    dbus_message_append_args(msg, DBUS_TYPE_STRING, &arg, DBUS_TYPE_INVALID);

    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err);
    dbus_message_unref(msg);

    if (dbus_error_is_set(&err)) {
        std::fprintf(stderr, "D-Bus %s.%s on %s failed: %s\n", iface, method, path, err.message);
        dbus_error_free(&err);
        return false;
    }

    if (out_reply) *out_reply = reply;
    else if (reply) dbus_message_unref(reply);
    return true;
}

// ------------------------------------------------------------------
// KWinClient
// ------------------------------------------------------------------

KWinClient::KWinClient(DBusService* service) : service_(service) {
    DBusError err;
    dbus_error_init(&err);
    conn_ = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!conn_) {
        std::fprintf(stderr, "KWinClient: dbus connect failed: %s\n", err.message);
        dbus_error_free(&err);
    }
}

KWinClient::~KWinClient() {
    if (conn_) {
        dbus_connection_close(conn_);
        dbus_connection_unref(conn_);
        conn_ = nullptr;
    }
}

std::string KWinClient::make_request_id() {
    static std::atomic<std::uint64_t> counter{0};
    std::uint64_t id = ++counter;
    char buf[32];
    std::snprintf(buf, sizeof(buf), "req_%lu", static_cast<unsigned long>(id));
    return std::string(buf);
}

bool KWinClient::run_script_with_callback(const std::string& js_body, std::string& out_json, int timeout_ms) {
    if (!conn_) return false;

    std::string req_id = make_request_id();

    // Embed request ID into the JS
    std::string js = js_body;
    std::size_t pos = js.find("REQUEST_ID");
    if (pos != std::string::npos) {
        js.replace(pos, 10, req_id);
    }

    std::string path;
    if (!write_temp_script(js, path)) return false;

    auto cleanup = [&]() {
        send_method_call_with_string(conn_, "org.kde.KWin", "/Scripting",
                                      "org.kde.kwin.Scripting", "unloadScript",
                                      path.c_str(), nullptr);
        unlink(path.c_str());
    };

    // Load script
    DBusMessage* reply = nullptr;
    if (!send_method_call_with_string(conn_, "org.kde.KWin", "/Scripting",
                                       "org.kde.kwin.Scripting", "loadScript",
                                       path.c_str(), &reply)) {
        cleanup();
        return false;
    }

    int script_id = 0;
    DBusMessageIter iter;
    dbus_message_iter_init(reply, &iter);
    if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_INT32) {
        dbus_message_iter_get_basic(&iter, &script_id);
    }
    dbus_message_unref(reply);

    if (script_id <= 0) {
        cleanup();
        return false;
    }

    // Run script
    char script_path[64];
    std::snprintf(script_path, sizeof(script_path), "/Scripting/Script%d", script_id);

    if (!send_method_call(conn_, "org.kde.KWin", script_path,
                           "org.kde.kwin.Script", "run", nullptr)) {
        cleanup();
        return false;
    }

    // Wait for callback
    bool got_result = service_->wait_for_result(req_id, out_json, timeout_ms);

    cleanup();
    return got_result;
}

bool KWinClient::run_script_no_callback(const std::string& js_body) {
    if (!conn_) return false;

    std::string path;
    if (!write_temp_script(js_body, path)) return false;

    auto cleanup = [&]() {
        send_method_call_with_string(conn_, "org.kde.KWin", "/Scripting",
                                      "org.kde.kwin.Scripting", "unloadScript",
                                      path.c_str(), nullptr);
        unlink(path.c_str());
    };

    DBusMessage* reply = nullptr;
    if (!send_method_call_with_string(conn_, "org.kde.KWin", "/Scripting",
                                       "org.kde.kwin.Scripting", "loadScript",
                                       path.c_str(), &reply)) {
        cleanup();
        return false;
    }

    int script_id = 0;
    DBusMessageIter iter;
    dbus_message_iter_init(reply, &iter);
    if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_INT32) {
        dbus_message_iter_get_basic(&iter, &script_id);
    }
    dbus_message_unref(reply);

    if (script_id <= 0) {
        cleanup();
        return false;
    }

    char script_path[64];
    std::snprintf(script_path, sizeof(script_path), "/Scripting/Script%d", script_id);

    bool ok = send_method_call(conn_, "org.kde.KWin", script_path,
                                "org.kde.kwin.Script", "run", nullptr);

    cleanup();
    return ok;
}

std::vector<KWinWindow> KWinClient::find_windows() {
    std::vector<KWinWindow> result;

    const char* js = R"({
var vscode_windows = [];
for (var i = 0; i < workspace.windowList().length; i++) {
    var w = workspace.windowList()[i];
    var cap = w.caption;
    if (cap.indexOf("Visual Studio Code") >= 0 || cap.indexOf("Kilo Code") >= 0 || cap.indexOf("Kimi Code") >= 0 || cap.indexOf("VSCodium") >= 0 || cap.indexOf("Code: - OSS") >= 0) {
        vscode_windows.push({
            uuid: w.internalId,
            caption: w.caption,
            x: w.frameGeometry.x,
            y: w.frameGeometry.y,
            width: w.frameGeometry.width,
            height: w.frameGeometry.height
        });
    }
}
callDBus("org.reprompty.LayoutDaemon", "/org/reprompty/LayoutDaemon", "org.reprompty.LayoutDaemon", "SubmitResult", "REQUEST_ID", JSON.stringify(vscode_windows));
})";

    std::string json;
    if (!run_script_with_callback(js, json, 5000)) {
        return result;
    }

    try {
        boost::json::value val = boost::json::parse(json);
        if (val.is_array()) {
            for (const auto& item : val.as_array()) {
                const auto& obj = item.as_object();
                KWinWindow win;
                win.uuid = std::string(obj.at("uuid").as_string());
                win.caption = std::string(obj.at("caption").as_string());
                win.x = static_cast<int>(obj.at("x").as_int64());
                win.y = static_cast<int>(obj.at("y").as_int64());
                win.width = static_cast<int>(obj.at("width").as_int64());
                win.height = static_cast<int>(obj.at("height").as_int64());
                result.push_back(win);
            }
        }
    } catch (const std::exception& e) {
        std::fprintf(stderr, "Failed to parse KWin window list: %s\njson=%s\n", e.what(), json.c_str());
    }

    return result;
}

bool KWinClient::move_resize(const std::string& uuid, int x, int y, int w, int h) {
    std::string js =
        "var target = null;\n"
        "for (var i = 0; i < workspace.windowList().length; i++) {\n"
        "    if (workspace.windowList()[i].internalId === \"" + uuid + "\") {\n"
        "        target = workspace.windowList()[i];\n"
        "        break;\n"
        "    }\n"
        "}\n"
        "if (target) {\n"
        "    target.frameGeometry = {x: " + std::to_string(x) + ", y: " + std::to_string(y) +
        ", width: " + std::to_string(w) + ", height: " + std::to_string(h) + "};\n"
        "}\n";

    return run_script_no_callback(js);
}

bool KWinClient::activate(const std::string& uuid) {
    std::string js =
        "var target = null;\n"
        "for (var i = 0; i < workspace.windowList().length; i++) {\n"
        "    if (workspace.windowList()[i].internalId === \"" + uuid + "\") {\n"
        "        target = workspace.windowList()[i];\n"
        "        break;\n"
        "    }\n"
        "}\n"
        "if (target) {\n"
        "    workspace.activeWindow = target;\n"
        "}\n";

    return run_script_no_callback(js);
}

} // namespace rp
