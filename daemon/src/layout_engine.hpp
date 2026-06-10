#pragma once

#include <string>
#include <vector>
#include <optional>
#include "protocol.hpp"
#include "kwin_dbus.hpp"
#include "cdp_manager.hpp"

namespace rp {

struct Monitor {
    std::string name;
    int x = 0, y = 0;
    int width = 1920, height = 1080;
};

struct ComputedLayout {
    int x = 0, y = 0;
    int width = 1920, height = 1080;
    int panel_width = 960;
    std::string panel_side = "right";
};

class LayoutEngine {
public:
    // Load slot from ~/.reprompty/layouts.json
    static std::optional<ComputedLayout> load_slot(const std::string& slot_letter);

    // Detect monitors using kscreen-doctor --json
    static std::vector<Monitor> detect_monitors();

    // Compute layout for dual/single mode
    static ComputedLayout compute_layout(const std::vector<Monitor>& monitors,
                                          const std::string& mode,
                                          const std::string& panel_side);

    // Apply a layout request: resolve slot/mode, find window, move/resize, panel drag
    static LayoutResponse apply(const LayoutRequest& req, DBusService* dbus_service, CDPManager* cdp);

    // List all VS Code: windows
    static LayoutResponse list_windows(DBusService* dbus_service);
};

} // namespace rp
