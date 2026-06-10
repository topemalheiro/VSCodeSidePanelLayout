#pragma once

#include <string>
#include <map>
#include <optional>
#include <mutex>
#include <boost/json.hpp>
#include <boost/beast/websocket.hpp>
#include <boost/asio/ip/tcp.hpp>

namespace rp {

struct CDPTarget {
    int port = 9222;
    std::string id;
    std::string title;
    std::string url;
    std::string ws_url;
};

struct CDPSession {
    CDPTarget target;
    std::unique_ptr<boost::beast::websocket::stream<boost::asio::ip::tcp::socket>> ws;
    int next_msg_id = 1;
    std::mutex mtx;
};

class CDPManager {
public:
    CDPManager();
    ~CDPManager();

    // Scan for CDP targets from DevToolsActivePort files
    std::vector<CDPTarget> discover_targets();

    // Get or create a persistent session for a target
    CDPSession* get_or_create_session(const CDPTarget& target);

    // Send a CDP command and wait for response
    boost::json::value send_command(CDPSession* session, const std::string& method, const boost::json::object& params);

    // Resize auxiliary bar by dragging sash
    bool resize_panel(CDPSession* session, int target_width, int window_width, const std::string& panel_side);

    // Close all sessions
    void close_all();

private:
    bool connect(CDPSession* session);
    std::optional<int> read_cdp_port(const std::string& path);
    std::vector<CDPTarget> fetch_targets(int port);

    std::mutex sessions_mtx_;
    std::map<std::string, std::unique_ptr<CDPSession>> sessions_;
    boost::asio::io_context io_;
};

} // namespace rp
