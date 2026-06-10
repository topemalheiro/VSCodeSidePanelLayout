#pragma once

#include <string>
#include <optional>
#include <boost/json.hpp>

namespace rp {

struct LayoutRequest {
    std::string cmd;           // "layout", "list_windows", "ping"
    std::optional<std::string> slot;       // "A", "B", ...
    std::optional<std::string> mode;       // "dual", "single"
    std::optional<std::string> panel_side; // "left", "right"
    std::optional<std::string> window_title;
    std::optional<std::string> window_handle;
    
    // Coordinate overrides
    std::optional<int> x;
    std::optional<int> y;
    std::optional<int> width;
    std::optional<int> height;
    std::optional<int> panel_width;
};

struct LayoutResponse {
    bool ok = false;
    std::string message;
    std::string error;
    boost::json::value data; // optional extra data
};

// Parse request from JSON object
inline LayoutRequest parse_request(const boost::json::object& obj) {
    LayoutRequest req;
    if (auto* v = obj.if_contains("cmd")) {
        req.cmd = v->as_string().c_str();
    }
    if (auto* v = obj.if_contains("slot")) {
        req.slot = std::string(v->as_string().c_str());
    }
    if (auto* v = obj.if_contains("mode")) {
        req.mode = std::string(v->as_string().c_str());
    }
    if (auto* v = obj.if_contains("panel_side")) {
        req.panel_side = std::string(v->as_string().c_str());
    }
    if (auto* v = obj.if_contains("window_title")) {
        req.window_title = std::string(v->as_string().c_str());
    }
    if (auto* v = obj.if_contains("window_handle")) {
        req.window_handle = std::string(v->as_string().c_str());
    }
    if (auto* v = obj.if_contains("x")) {
        req.x = static_cast<int>(v->as_int64());
    }
    if (auto* v = obj.if_contains("y")) {
        req.y = static_cast<int>(v->as_int64());
    }
    if (auto* v = obj.if_contains("width")) {
        req.width = static_cast<int>(v->as_int64());
    }
    if (auto* v = obj.if_contains("height")) {
        req.height = static_cast<int>(v->as_int64());
    }
    if (auto* v = obj.if_contains("panel_width")) {
        req.panel_width = static_cast<int>(v->as_int64());
    }
    return req;
}

inline boost::json::object to_json(const LayoutResponse& resp) {
    boost::json::object obj;
    obj["ok"] = resp.ok;
    obj["message"] = resp.message;
    if (!resp.error.empty()) {
        obj["error"] = resp.error;
    }
    if (!resp.data.is_null()) {
        obj["data"] = resp.data;
    }
    return obj;
}

} // namespace rp
