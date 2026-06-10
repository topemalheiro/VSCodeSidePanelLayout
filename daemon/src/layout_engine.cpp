#include "layout_engine.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <boost/json.hpp>

namespace rp {

static std::string read_file(const std::string& path) {
    std::ifstream f(path);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

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

std::optional<ComputedLayout> LayoutEngine::load_slot(const std::string& slot_letter) {
    const char* home = std::getenv("HOME");
    if (!home) home = ".";
    std::string path = std::string(home) + "/.reprompty/layouts.json";
    std::string content = read_file(path);
    if (content.empty()) return std::nullopt;

    try {
        boost::json::value doc = boost::json::parse(content);
        const auto& slots = doc.as_object().at("slots").as_array();
        for (const auto& s : slots) {
            const auto& obj = s.as_object();
            if (std::string(obj.at("letter").as_string()) == slot_letter) {
                ComputedLayout layout;
                layout.x = static_cast<int>(obj.at("windowX").as_int64());
                layout.y = static_cast<int>(obj.at("windowY").as_int64());
                layout.width = static_cast<int>(obj.at("windowWidth").as_int64());
                layout.height = static_cast<int>(obj.at("windowHeight").as_int64());
                layout.panel_width = static_cast<int>(obj.at("panelWidth").as_int64());
                return layout;
            }
        }
    } catch (const std::exception& e) {
        std::fprintf(stderr, "Failed to parse layouts.json: %s\n", e.what());
    }
    return std::nullopt;
}

std::vector<Monitor> LayoutEngine::detect_monitors() {
    std::vector<Monitor> result;
    std::string json = exec("kscreen-doctor --json 2>/dev/null");
    if (json.empty()) {
        result.push_back({"fallback", 0, 0, 1920, 1080});
        return result;
    }

    try {
        boost::json::value doc = boost::json::parse(json);
        const auto& outputs = doc.as_object().at("outputs").as_array();
        for (const auto& out : outputs) {
            const auto& obj = out.as_object();
            if (!obj.at("enabled").as_bool()) continue;
            if (!obj.at("connected").as_bool()) continue;

            Monitor m;
            m.name = std::string(obj.at("name").as_string());
            const auto& pos = obj.at("pos").as_object();
            const auto& size = obj.at("size").as_object();
            m.x = static_cast<int>(pos.at("x").as_int64());
            m.y = static_cast<int>(pos.at("y").as_int64());
            m.width = static_cast<int>(size.at("width").as_int64());
            m.height = static_cast<int>(size.at("height").as_int64());
            result.push_back(m);
        }
    } catch (const std::exception& e) {
        std::fprintf(stderr, "Failed to parse kscreen-doctor output: %s\n", e.what());
    }

    if (result.empty()) {
        result.push_back({"fallback", 0, 0, 1920, 1080});
    }
    std::sort(result.begin(), result.end(), [](const Monitor& a, const Monitor& b) {
        return a.x < b.x;
    });
    return result;
}

ComputedLayout LayoutEngine::compute_layout(const std::vector<Monitor>& monitors,
                                             const std::string& mode,
                                             const std::string& panel_side) {
    ComputedLayout layout;
    layout.panel_side = panel_side;

    if (monitors.empty()) {
        layout.width = 1920;
        layout.height = 1080;
        layout.panel_width = 960;
        return layout;
    }

    std::vector<Monitor> by_area = monitors;
    std::sort(by_area.begin(), by_area.end(), [](const Monitor& a, const Monitor& b) {
        return (a.width * a.height) > (b.width * b.height);
    });

    if (mode == "dual" && monitors.size() >= 2) {
        const Monitor* left = nullptr;
        const Monitor* right = nullptr;
        int best_score = -1;

        for (std::size_t i = 0; i < monitors.size(); ++i) {
            for (std::size_t j = i + 1; j < monitors.size(); ++j) {
                const Monitor& a = monitors[i];
                const Monitor& b = monitors[j];
                if (std::abs((a.x + a.width) - b.x) < 10 || std::abs((b.x + b.width) - a.x) < 10) {
                    bool same_size = (a.width == b.width && a.height == b.height);
                    bool y_aligned = std::abs(a.y - b.y) < 100;
                    int total_area = a.width * a.height + b.width * b.height;
                    int score = (same_size ? 1000000 : 0) + (y_aligned ? 500000 : 0) + total_area;
                    if (score > best_score) {
                        best_score = score;
                        if (a.x <= b.x) {
                            left = &a; right = &b;
                        } else {
                            left = &b; right = &a;
                        }
                    }
                }
            }
        }

        if (!left) {
            for (std::size_t i = 0; i + 1 < monitors.size(); ++i) {
                if (std::abs((monitors[i].x + monitors[i].width) - monitors[i+1].x) < 10) {
                    left = &monitors[i];
                    right = &monitors[i+1];
                    break;
                }
            }
        }
        if (!left) {
            left = &monitors[0];
            right = &monitors[1];
        }

        layout.x = left->x;
        layout.y = std::min(left->y, right->y);
        layout.width = (right->x + right->width) - left->x;
        layout.height = std::max(left->y + left->height, right->y + right->height) - layout.y;
        layout.panel_width = left->width;
    } else {
        const Monitor& m = by_area[0];
        layout.x = m.x;
        layout.y = m.y;
        layout.width = m.width;
        layout.height = m.height;
        layout.panel_width = m.width / 2;
    }

    return layout;
}

LayoutResponse LayoutEngine::apply(const LayoutRequest& req, DBusService* dbus_service, CDPManager* cdp) {
    LayoutResponse resp;

    // Resolve layout
    std::optional<ComputedLayout> layout;
    if (req.slot) {
        layout = load_slot(*req.slot);
        if (!layout) {
            resp.error = "Slot " + *req.slot + " not found in layouts.json";
            return resp;
        }
    }

    if (!layout) {
        auto monitors = detect_monitors();
        std::string mode = req.mode.value_or("single");
        std::string side = req.panel_side.value_or("right");
        layout = compute_layout(monitors, mode, side);
    }

    // Apply overrides
    if (req.x) layout->x = *req.x;
    if (req.y) layout->y = *req.y;
    if (req.width) layout->width = *req.width;
    if (req.height) layout->height = *req.height;
    if (req.panel_width) layout->panel_width = *req.panel_width;

    // Find window
    KWinClient kwin(dbus_service);
    auto windows = kwin.find_windows();

    if (windows.empty()) {
        resp.error = "No VS Code: window found";
        return resp;
    }

    // Pick target window
    const KWinWindow* target = nullptr;
    if (req.window_handle) {
        for (const auto& w : windows) {
            if (w.uuid == *req.window_handle) {
                target = &w;
                break;
            }
        }
    } else if (req.window_title) {
        for (const auto& w : windows) {
            if (w.caption.find(*req.window_title) != std::string::npos) {
                target = &w;
                break;
            }
        }
    }
    if (!target) {
        target = &windows[0];
    }

    // Activate, move, resize
    kwin.activate(target->uuid);
    kwin.move_resize(target->uuid, layout->x, layout->y, layout->width, layout->height);

    // Try CDP panel resize
    bool cdp_ok = false;
    if (cdp) {
        auto targets = cdp->discover_targets();
        CDPSession* session = nullptr;
        for (const auto& t : targets) {
            if (t.title == target->caption || target->caption.find(t.title) != std::string::npos || t.title.find(target->caption) != std::string::npos) {
                session = cdp->get_or_create_session(t);
                break;
            }
        }
        if (!session && !targets.empty()) {
            session = cdp->get_or_create_session(targets[0]);
        }
        if (session) {
            cdp_ok = cdp->resize_panel(session, layout->panel_width, layout->width, layout->panel_side);
        }
    }

    resp.ok = true;
    resp.message = "Moved window '" + target->caption + "' to " +
                   std::to_string(layout->x) + "," + std::to_string(layout->y) +
                   " size " + std::to_string(layout->width) + "x" + std::to_string(layout->height);
    if (cdp_ok) {
        resp.message += " + CDP panel resized";
    }
    return resp;
}

LayoutResponse LayoutEngine::list_windows(DBusService* dbus_service) {
    LayoutResponse resp;
    KWinClient kwin(dbus_service);
    auto windows = kwin.find_windows();

    boost::json::array arr;
    for (const auto& w : windows) {
        boost::json::object obj;
        obj["uuid"] = w.uuid;
        obj["caption"] = w.caption;
        obj["x"] = w.x;
        obj["y"] = w.y;
        obj["width"] = w.width;
        obj["height"] = w.height;
        arr.push_back(obj);
    }
    resp.ok = true;
    resp.message = std::to_string(windows.size()) + " window(s) found";
    resp.data = arr;
    return resp;
}

} // namespace rp
