#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

static std::string get_socket_path() {
    const char* runtime_dir = getenv("XDG_RUNTIME_DIR");
    if (!runtime_dir) runtime_dir = getenv("RUNTIME_DIR");
    if (!runtime_dir) runtime_dir = "/tmp";
    return std::string(runtime_dir) + "/reprompty/daemon.sock";
}

static bool send_request(const std::string& json, std::string& out_response) {
    std::string path = get_socket_path();
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return false;
    }

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

    if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        perror("connect");
        close(fd);
        return false;
    }

    std::string req = json + "\n";
    if (write(fd, req.data(), req.size()) != static_cast<ssize_t>(req.size())) {
        perror("write");
        close(fd);
        return false;
    }

    char buf[4096];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);

    if (n < 0) {
        perror("read");
        return false;
    }
    if (n == 0) {
        fprintf(stderr, "read: daemon closed connection\n");
        return false;
    }
    buf[n] = '\0';
    out_response = buf;

    // Trim to first newline
    auto pos = out_response.find('\n');
    if (pos != std::string::npos) {
        out_response = out_response.substr(0, pos);
    }
    return true;
}

int main(int argc, char* argv[]) {
    std::string cmd = R"({"cmd":"layout"})";
    std::string panel_side = "right";
    std::string mode;
    std::string slot;
    std::string window_title;
    std::string window_handle;
    bool has_override = false;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--slot") == 0 && i + 1 < argc) {
            slot = argv[++i];
        } else if (strcmp(argv[i], "--dual") == 0) {
            mode = "dual";
        } else if (strcmp(argv[i], "--single") == 0) {
            mode = "single";
        } else if (strcmp(argv[i], "--panel-left") == 0) {
            panel_side = "left";
        } else if (strcmp(argv[i], "--panel-right") == 0) {
            panel_side = "right";
        } else if (strcmp(argv[i], "--window-title") == 0 && i + 1 < argc) {
            window_title = argv[++i];
        } else if (strcmp(argv[i], "--window-handle") == 0 && i + 1 < argc) {
            window_handle = argv[++i];
        } else if (strcmp(argv[i], "--x") == 0 && i + 1 < argc) {
            cmd += ", \"x\":" + std::string(argv[++i]);
            has_override = true;
        } else if (strcmp(argv[i], "--y") == 0 && i + 1 < argc) {
            cmd += ", \"y\":" + std::string(argv[++i]);
            has_override = true;
        } else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            cmd += ", \"width\":" + std::string(argv[++i]);
            has_override = true;
        } else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            cmd += ", \"height\":" + std::string(argv[++i]);
            has_override = true;
        } else if (strcmp(argv[i], "--panel-width") == 0 && i + 1 < argc) {
            cmd += ", \"panel_width\":" + std::string(argv[++i]);
            has_override = true;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: %s [--slot A|B] [--dual|--single] [--panel-left|--panel-right]\n"
                   "       [--window-title TITLE] [--window-handle UUID]\n"
                   "       [--x X] [--y Y] [--width W] [--height H] [--panel-width PW]\n",
                   argv[0]);
            return 0;
        }
    }

    // Build JSON
    std::string json = "{\"cmd\":\"layout\"";
    if (!slot.empty()) {
        json += ", \"slot\":\"" + slot + "\"";
    }
    if (!mode.empty()) {
        json += ", \"mode\":\"" + mode + "\"";
    }
    json += ", \"panel_side\":\"" + panel_side + "\"";
    if (!window_title.empty()) {
        json += ", \"window_title\":\"" + window_title + "\"";
    }
    if (!window_handle.empty()) {
        json += ", \"window_handle\":\"" + window_handle + "\"";
    }
    if (has_override) {
        // Overrides already appended to cmd string above... wait, that approach was wrong.
        // Let me rebuild properly.
    }

    // Rebuild cleanly
    json = "{\"cmd\":\"layout\"";
    if (!slot.empty()) json += ", \"slot\":\"" + slot + "\"";
    if (!mode.empty()) json += ", \"mode\":\"" + mode + "\"";
    json += ", \"panel_side\":\"" + panel_side + "\"";
    if (!window_title.empty()) json += ", \"window_title\":\"" + window_title + "\"";
    if (!window_handle.empty()) json += ", \"window_handle\":\"" + window_handle + "\"";

    // Re-parse args for overrides since we didn't store them
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--x") == 0 && i + 1 < argc) {
            json += ", \"x\":" + std::string(argv[++i]);
        } else if (strcmp(argv[i], "--y") == 0 && i + 1 < argc) {
            json += ", \"y\":" + std::string(argv[++i]);
        } else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            json += ", \"width\":" + std::string(argv[++i]);
        } else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            json += ", \"height\":" + std::string(argv[++i]);
        } else if (strcmp(argv[i], "--panel-width") == 0 && i + 1 < argc) {
            json += ", \"panel_width\":" + std::string(argv[++i]);
        }
    }
    json += "}";

    std::string response;
    if (!send_request(json, response)) {
        fprintf(stderr, "Error: failed to communicate with daemon. Is it running?\n");
        return 1;
    }

    printf("%s\n", response.c_str());

    // Quick parse to check ok field
    if (response.find("\"ok\":true") != std::string::npos) {
        return 0;
    }
    return 1;
}
