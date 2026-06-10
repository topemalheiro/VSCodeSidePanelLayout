#include "daemon.hpp"
#include "layout_engine.hpp"
#include "protocol.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <boost/json.hpp>

namespace rp {

static std::atomic<bool> g_signal_received{false};

static void signal_handler(int) {
    g_signal_received = true;
}

static void setup_signals() {
    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGPIPE, &sa, nullptr); // ignore SIGPIPE
}

static std::string get_socket_path() {
    const char* runtime_dir = std::getenv("XDG_RUNTIME_DIR");
    if (!runtime_dir) runtime_dir = std::getenv("RUNTIME_DIR");
    if (!runtime_dir) runtime_dir = "/tmp";
    return std::string(runtime_dir) + "/reprompty/daemon.sock";
}

static bool ensure_dir(const std::string& path) {
    struct stat st;
    if (stat(path.c_str(), &st) == 0) {
        return S_ISDIR(st.st_mode);
    }
    return mkdir(path.c_str(), 0755) == 0;
}

Daemon::Daemon() {}

Daemon::~Daemon() {
    stop();
}

bool Daemon::start() {
    setup_signals();

    dbus_service_.start();

    socket_path_ = get_socket_path();
    std::string dir = socket_path_.substr(0, socket_path_.rfind('/'));
    if (!ensure_dir(dir)) {
        std::fprintf(stderr, "Failed to create socket directory: %s\n", dir.c_str());
        return false;
    }

    // Remove stale socket
    unlink(socket_path_.c_str());

    server_fd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (server_fd_ < 0) {
        std::perror("socket");
        return false;
    }

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, socket_path_.c_str(), sizeof(addr.sun_path) - 1);

    if (bind(server_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        std::perror("bind");
        close(server_fd_);
        server_fd_ = -1;
        return false;
    }

    if (listen(server_fd_, 8) < 0) {
        std::perror("listen");
        close(server_fd_);
        server_fd_ = -1;
        return false;
    }

    running_ = true;
    accept_thread_ = std::thread(&Daemon::accept_loop, this);
    return true;
}

void Daemon::stop() {
    running_ = false;
    if (server_fd_ >= 0) {
        close(server_fd_);
        server_fd_ = -1;
    }
    if (accept_thread_.joinable()) {
        accept_thread_.join();
    }
    unlink(socket_path_.c_str());
    dbus_service_.stop();
}

void Daemon::run() {
    while (running_ && !g_signal_received) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

void Daemon::accept_loop() {
    while (running_) {
        int client = accept4(server_fd_, nullptr, nullptr, SOCK_NONBLOCK);
        if (client < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                continue;
            }
            if (errno == EINTR) continue;
            std::perror("accept");
            break;
        }
        std::thread t(&Daemon::handle_client, this, client);
        t.detach();
    }
}

void Daemon::handle_client(int client_fd) {
    // Read one line
    std::string line;
    char buf[256];
    while (true) {
        ssize_t n = read(client_fd, buf, sizeof(buf) - 1);
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            break;
        }
        buf[n] = '\0';
        line += buf;
        if (line.find('\n') != std::string::npos) {
            break;
        }
    }

    LayoutResponse resp;
    if (line.empty()) {
        resp.error = "Empty request";
    } else {
        // Trim to first newline
        auto pos = line.find('\n');
        if (pos != std::string::npos) {
            line = line.substr(0, pos);
        }
        try {
            boost::json::value jv = boost::json::parse(line);
            LayoutRequest req = parse_request(jv.as_object());
            if (req.cmd == "list_windows") {
                resp = LayoutEngine::list_windows(&dbus_service_);
            } else if (req.cmd == "ping") {
                resp.ok = true;
                resp.message = "pong";
            } else {
                resp = LayoutEngine::apply(req, &dbus_service_, &cdp_manager_);
            }
        } catch (const std::exception& e) {
            resp.error = std::string("Parse error: ") + e.what();
        }
    }

    std::string response = boost::json::serialize(to_json(resp)) + "\n";
    write(client_fd, response.data(), response.size());
    close(client_fd);
}

} // namespace rp
