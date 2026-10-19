// magicswipe-keyd: root helper that owns a Karabiner virtual HID keyboard and
// presses Globe+Left / Globe+Right when the MagicSwipe app asks for it.
//
// It runs only while the app is switched on: launchd starts it when the app
// connects to kSocketPath (socket activation), and it exits when the app
// disconnects. While running it also keeps Karabiner's VirtualHIDDevice daemon
// alive, starting it if nothing else (such as Karabiner-Elements) already has.
//
// Usage:
//   magicswipe-keyd --uid <uid>     serve one app session on kSocketPath from that uid
//   magicswipe-keyd --test <L|R|U|H> wait 5s, send one Globe shortcut, exit
//   --focus-button <n>              first press mouse button n (e.g. 4) on a virtual
//                                   mouse so Universal Control moves keyboard focus
//                                   to the device under the pointer

#include <atomic>
#include <csignal>
#include <iostream>
#include <launch.h>
#include <spawn.h>
#include <sys/wait.h>
#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

namespace vhid = pqrs::karabiner::driverkit::virtual_hid_device_service;
namespace report = pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report;

namespace {
constexpr const char* kSocketPath = "/var/run/magicswipe.sock";
constexpr const char* kVhidDaemonPath =
    "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/"
    "Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon";
pid_t vhid_daemon_pid = 0; // set only when this process started the daemon

std::atomic<bool> exit_flag(false);
std::atomic<bool> keyboard_ready(false);
std::atomic<bool> pointing_ready(false);
int focus_button = 0;
std::mutex client_mutex;
std::unique_ptr<vhid::client> client;

void log(const std::string& message) {
  std::cerr << "[magicswipe-keyd] " << message << std::endl;
}

const char* arrow_name(char direction) {
  switch (direction) {
    case 'L': return "Left";
    case 'R': return "Right";
    case 'U': return "Up";
    default: return "H";
  }
}

// Press and release Globe+key: 'L' / 'R' / 'U' arrows, or 'H' (Home Screen). Globe lives on the Apple top-case usage page,
// the arrow on the regular keyboard page, so this takes two report types.
void send_globe_arrow(char direction, bool focus_click) {
  std::lock_guard<std::mutex> lock(client_mutex);
  if (!client || !keyboard_ready) {
    log("keyboard not ready; dropping request");
    return;
  }

  // Universal Control sends keys to the device that was last clicked, so click
  // a button the iPad ignores to move keyboard focus to where the pointer is.
  if (focus_click && focus_button > 0) {
    if (pointing_ready) {
      report::pointing_input button_down;
      button_down.buttons.insert(static_cast<uint8_t>(focus_button));
      client->async_post_report(button_down);
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      client->async_post_report(report::pointing_input());
      std::this_thread::sleep_for(std::chrono::milliseconds(40));
    } else {
      log("virtual mouse not ready; skipping focus click");
    }
  }

  auto arrow = direction == 'L'   ? pqrs::hid::usage::keyboard_or_keypad::keyboard_left_arrow
               : direction == 'R' ? pqrs::hid::usage::keyboard_or_keypad::keyboard_right_arrow
               : direction == 'U' ? pqrs::hid::usage::keyboard_or_keypad::keyboard_up_arrow
                                  : pqrs::hid::usage::keyboard_or_keypad::keyboard_h;

  report::apple_vendor_top_case_input fn_down;
  fn_down.keys.insert(type_safe::get(pqrs::hid::usage::apple_vendor_top_case::keyboard_fn));
  client->async_post_report(fn_down);
  std::this_thread::sleep_for(std::chrono::milliseconds(8));

  report::keyboard_input arrow_down;
  arrow_down.keys.insert(type_safe::get(arrow));
  client->async_post_report(arrow_down);
  std::this_thread::sleep_for(std::chrono::milliseconds(15));

  client->async_post_report(report::keyboard_input());
  std::this_thread::sleep_for(std::chrono::milliseconds(8));
  client->async_post_report(report::apple_vendor_top_case_input());

  log(std::string("sent Globe+") + arrow_name(direction) + (focus_click ? " (with focus click)" : ""));
}

void start_client() {
  client = std::make_unique<vhid::client>();

  client->connected.connect([] {
    log("connected to Karabiner VirtualHIDDevice daemon");
    // Present as an Apple keyboard, like Karabiner-Elements does. With the default
    // pqrs IDs macOS opens Keyboard Setup Assistant and does not treat fn as Globe.
    vhid::virtual_hid_keyboard_parameters parameters(pqrs::hid::vendor_id::value_t(0x05ac),
                                                     pqrs::hid::product_id::value_t(0x024f),
                                                     pqrs::hid::country_code::not_supported);
    client->async_virtual_hid_keyboard_initialize(parameters);
    if (focus_button > 0) {
      client->async_virtual_hid_pointing_initialize();
    }
  });
  client->connect_failed.connect([](auto&& error_code) {
    log("connect_failed " + error_code.message());
  });
  client->closed.connect([] {
    log("closed");
    keyboard_ready = false;
  });
  client->warning_reported.connect([](auto&& message) {
    log("warning: " + message);
  });
  client->virtual_hid_keyboard_ready.connect([](auto&& ready) {
    if (keyboard_ready != ready) {
      log(std::string("virtual keyboard ready: ") + (ready ? "yes" : "no"));
    }
    keyboard_ready = ready;
  });
  client->virtual_hid_pointing_ready.connect([](auto&& ready) {
    if (pointing_ready != ready) {
      log(std::string("virtual mouse ready: ") + (ready ? "yes" : "no"));
    }
    pointing_ready = ready;
  });

  client->async_start();
}

bool wait_for_keyboard(std::chrono::seconds timeout) {
  auto deadline = std::chrono::steady_clock::now() + timeout;
  while ((!keyboard_ready || (focus_button > 0 && !pointing_ready)) &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  return keyboard_ready && (focus_button == 0 || pointing_ready);
}

int run_test(char direction) {
  if (!wait_for_keyboard(std::chrono::seconds(10))) {
    log("virtual keyboard never became ready");
    return 1;
  }
  std::cout << "Move the pointer onto the iPad... sending Globe+" << arrow_name(direction)
            << " in 5s" << std::endl;
  std::this_thread::sleep_for(std::chrono::seconds(5));
  send_globe_arrow(direction, true);
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  return 0;
}

bool vhid_daemon_running() {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, vhid::constants::get_server_socket_file_path().c_str(), sizeof(addr.sun_path));
  bool running = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0;
  close(fd);
  return running;
}

void start_vhid_daemon_if_needed() {
  if (vhid_daemon_running()) {
    return;
  }
  char* argv[] = {const_cast<char*>(kVhidDaemonPath), nullptr};
  if (posix_spawn(&vhid_daemon_pid, kVhidDaemonPath, nullptr, nullptr, argv, nullptr) == 0) {
    log("started Karabiner VirtualHIDDevice daemon (pid " + std::to_string(vhid_daemon_pid) + ")");
  } else {
    vhid_daemon_pid = 0;
    log("could not start " + std::string(kVhidDaemonPath) + " — is the Karabiner driver package installed?");
  }
}

void stop_vhid_daemon() {
  if (vhid_daemon_pid > 0) {
    kill(vhid_daemon_pid, SIGTERM);
    waitpid(vhid_daemon_pid, nullptr, 0);
    log("stopped Karabiner VirtualHIDDevice daemon");
    vhid_daemon_pid = 0;
  }
}

// The listening socket: handed over by launchd, or bound here when run by hand.
int listening_socket() {
  int* fds = nullptr;
  size_t count = 0;
  if (launch_activate_socket("Listener", &fds, &count) == 0 && count > 0) {
    int fd = fds[0];
    free(fds);
    return fd;
  }

  unlink(kSocketPath);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, kSocketPath, sizeof(addr.sun_path));
  if (fd < 0 || bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(fd, 4) != 0) {
    return -1;
  }
  chmod(kSocketPath, 0666); // access is enforced per-connection via getpeereid below
  return fd;
}

// Serve one session of one-byte commands from the logged-in user's app, then exit.
int run_server(uid_t allowed_uid) {
  int fd = listening_socket();
  if (fd < 0) {
    log("cannot listen on " + std::string(kSocketPath));
    return 1;
  }

  while (!exit_flag) {
    int conn = accept(fd, nullptr, nullptr);
    if (conn < 0) {
      continue;
    }

    uid_t peer_uid;
    gid_t peer_gid;
    if (getpeereid(conn, &peer_uid, &peer_gid) != 0 || peer_uid != allowed_uid) {
      log("rejected connection from uid " + std::to_string(peer_uid));
      close(conn);
      continue;
    }

    log("MagicSwipe switched on");
    char command;
    while (!exit_flag && read(conn, &command, 1) == 1) {
      // The daemon and virtual keyboard take a moment to come up after switching on.
      wait_for_keyboard(std::chrono::seconds(3));
      // Uppercase: click first to move Universal Control's keyboard focus. Lowercase: keys only.
      if (command == 'L' || command == 'R' || command == 'U' || command == 'H') {
        send_globe_arrow(command, true);
      } else if (command == 'l' || command == 'r' || command == 'u' || command == 'h') {
        send_globe_arrow(static_cast<char>(command - ('a' - 'A')), false);
      }
    }
    close(conn);
    log("MagicSwipe switched off");
    break;
  }

  close(fd);
  return 0;
}
} // namespace

int main(int argc, char** argv) {
  // No SA_RESTART, so a blocking accept()/read() returns and we can clean up.
  struct sigaction stop_action{};
  stop_action.sa_handler = [](int) { exit_flag = true; };
  sigaction(SIGINT, &stop_action, nullptr);
  sigaction(SIGTERM, &stop_action, nullptr);
  std::signal(SIGPIPE, SIG_IGN);

  if (geteuid() != 0) {
    log("must run as root (Karabiner's driver socket is root-only)");
    return 1;
  }

  std::string mode, value;
  for (int i = 1; i + 1 < argc; i += 2) {
    std::string flag = argv[i];
    if (flag == "--focus-button") {
      focus_button = std::atoi(argv[i + 1]);
    } else {
      mode = flag;
      value = argv[i + 1];
    }
  }
  if ((mode != "--test" && mode != "--uid") || value.empty()) {
    std::cerr << "usage: magicswipe-keyd (--uid <uid> | --test <L|R>) [--focus-button <n>]" << std::endl;
    return 2;
  }

  start_vhid_daemon_if_needed();
  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  start_client();

  int result = mode == "--test" ? run_test(std::string("LRUH").find(value[0]) != std::string::npos ? value[0] : 'R')
                                : run_server(static_cast<uid_t>(std::stoul(value)));

  {
    std::lock_guard<std::mutex> lock(client_mutex);
    if (client) {
      client->async_virtual_hid_keyboard_terminate();
      client->async_virtual_hid_pointing_terminate();
    }
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  {
    std::lock_guard<std::mutex> lock(client_mutex);
    client = nullptr;
  }
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  stop_vhid_daemon();
  return result;
}
