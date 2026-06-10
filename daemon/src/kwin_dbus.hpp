#pragma once

#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <map>
#include <atomic>
#include <dbus/dbus.h>

namespace rp {

struct KWinWindow {
    std::string uuid;
    std::string caption;
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
};

// D-Bus service that receives callbacks from KWin scripts.
class DBusService {
public:
    DBusService();
    ~DBusService();

    // Start the dispatch thread.
    void start();

    // Signal the dispatch thread to stop.
    void stop();

    // Called by the D-Bus dispatch thread when a KWin script calls SubmitResult.
    void submit_result(const std::string& request_id, const std::string& json);

    // Blocking wait for a result. Returns true if result arrived within timeout.
    bool wait_for_result(const std::string& request_id, std::string& out_json, int timeout_ms = 5000);

private:
    void dispatch_loop();
    static DBusHandlerResult handle_message_static(DBusConnection* conn, DBusMessage* msg, void* data);
    DBusHandlerResult handle_message(DBusConnection* conn, DBusMessage* msg);

    DBusConnection* conn_ = nullptr;
    std::thread thread_;
    std::atomic<bool> running_{false};

    std::mutex mtx_;
    std::condition_variable cv_;
    std::map<std::string, std::string> results_;
};

// Thin wrapper around KWin's D-Bus scripting API.
class KWinClient {
public:
    explicit KWinClient(DBusService* service);
    ~KWinClient();

    // Find all VS Code: windows via KWin script callback.
    std::vector<KWinWindow> find_windows();

    // Move and resize a window by KWin UUID.
    bool move_resize(const std::string& uuid, int x, int y, int w, int h);

    // Activate a window by KWin UUID.
    bool activate(const std::string& uuid);

private:
    bool run_script_with_callback(const std::string& js_body, std::string& out_json, int timeout_ms = 5000);
    bool run_script_no_callback(const std::string& js_body);

    // Generate a unique request ID.
    static std::string make_request_id();

    DBusService* service_;
    DBusConnection* conn_ = nullptr;
};

} // namespace rp
