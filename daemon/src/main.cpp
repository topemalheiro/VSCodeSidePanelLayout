#include "daemon.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

int main(int argc, char* argv[]) {
    bool daemonize = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--daemonize") == 0 || std::strcmp(argv[i], "-d") == 0) {
            daemonize = true;
        } else if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
            std::printf("Usage: %s [--daemonize]\n", argv[0]);
            return 0;
        }
    }

    if (daemonize) {
        if (daemon(true, false) != 0) {
            std::perror("daemon");
            return 1;
        }
    }

    rp::Daemon daemon;
    if (!daemon.start()) {
        std::fprintf(stderr, "Failed to start daemon\n");
        return 1;
    }

    std::printf("reprompty-layoutd started\n");
    daemon.run();
    daemon.stop();
    return 0;
}
