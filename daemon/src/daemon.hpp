#pragma once

#include <atomic>
#include <thread>
#include <string>
#include "kwin_dbus.hpp"
#include "cdp_manager.hpp"

namespace rp {

class Daemon {
public:
    Daemon();
    ~Daemon();

    bool start();
    void stop();
    void run(); // blocking

private:
    void accept_loop();
    void handle_client(int client_fd);

    DBusService dbus_service_;
    CDPManager cdp_manager_;
    std::thread accept_thread_;
    std::atomic<bool> running_{false};
    int server_fd_ = -1;
    std::string socket_path_;
};

} // namespace rp
