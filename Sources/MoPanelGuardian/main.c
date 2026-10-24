/* MoPanelGuardian — process lifetime ownership, not a privileged helper.
 * SPDX-License-Identifier: GPL-3.0-or-later
 * The parent's private stdin pipe is a lifeline. EOF always cancels the child.
 * No shell is involved: execv receives the exact executable and argv.
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <poll.h>
#include <dirent.h>
#include <termios.h>
#ifdef __APPLE__
#include <util.h>
#include <libproc.h>
#include <sys/proc_info.h>
#else
#include <pty.h>
#include <sys/prctl.h>
#endif

#define FRAME_LIMIT 65536U
#define BUFFER_LIMIT (1024U * 1024U)
#define FAMILY_LIMIT 4096

static int wake_pipe[2] = {-1, -1};
static volatile sig_atomic_t interrupted = 0;
static pid_t child = -1;
static int terminal_master = -1;
typedef struct { pid_t pid; uint64_t born; } identity;
static identity family[FAMILY_LIMIT];
static size_t family_count = 0;

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void signal_handler(int number) {
    int saved = errno;
    if (number != SIGCHLD) interrupted = 1;
    if (wake_pipe[1] >= 0) { unsigned char b = 1; ssize_t ignored = write(wake_pipe[1], &b, 1); (void)ignored; }
    errno = saved;
}
static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
#ifndef __APPLE__
static int proc_namespace_matches(void) {
    static int result = -1;
    if (result < 0) {
        char buffer[64]; ssize_t count = readlink("/proc/self", buffer, sizeof(buffer) - 1);
        if (count <= 0) return 0;
        buffer[count] = 0; result = strtol(buffer, NULL, 10) == (long)getpid();
    }
    return result;
}
#endif
static uint64_t birth_time(pid_t pid) {
#ifdef __APPLE__
    struct proc_bsdinfo info;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (n != (int)sizeof(info)) return 0;
    return (uint64_t)info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec;
#else
    if (!proc_namespace_matches()) return 0;
    char path[80], data[4096];
    snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    size_t n = fread(data, 1, sizeof(data) - 1, fp); fclose(fp); data[n] = 0;
    char *p = strrchr(data, ')'); if (!p || !p[1]) return 0; p += 2;
    /* Fields 3 through 22; a process comm may contain spaces/parentheses. */
    for (int field = 3; field < 22; ++field) {
        p = strchr(p, ' '); if (!p) return 0; ++p;
    }
    return strtoull(p, NULL, 10);
#endif
}
static void remember(pid_t pid) {
    if (pid <= 1 || pid == getpid()) return;
    uint64_t born = birth_time(pid); if (!born) return;
    for (size_t i = 0; i < family_count; ++i) {
        if (family[i].pid == pid && family[i].born == born) return;
    }
    if (family_count < FAMILY_LIMIT) family[family_count++] = (identity){pid, born};
}
static void discover_children(pid_t parent, unsigned depth) {
    if (depth > 24 || family_count == FAMILY_LIMIT) return;
#ifdef __APPLE__
    pid_t children[512];
    int bytes = proc_listpids(PROC_PPID_ONLY, (uint32_t)parent, children, sizeof(children));
    if (bytes <= 0) return;
    size_t count = (size_t)bytes / sizeof(pid_t);
    if (count > 512) count = 512;
    for (size_t i = 0; i < count; ++i) {
        if (children[i] > 1) { remember(children[i]); discover_children(children[i], depth + 1); }
    }
#else
    if (!proc_namespace_matches()) return;
    char path[100]; snprintf(path, sizeof(path), "/proc/%ld/task/%ld/children", (long)parent, (long)parent);
    FILE *fp = fopen(path, "r");
    if (fp) {
        long candidate;
        while (fscanf(fp, "%ld", &candidate) == 1) {
            if (candidate > 1) { remember((pid_t)candidate); discover_children((pid_t)candidate, depth + 1); }
        }
        fclose(fp);
    } else {
        /* /proc/.../children is absent without CONFIG_CHECKPOINT_RESTORE. */
        DIR *directory = opendir("/proc"); if (!directory) return;
        struct dirent *entry;
        while ((entry = readdir(directory)) != NULL) {
            char *end = NULL; long candidate = strtol(entry->d_name, &end, 10);
            if (!end || *end || candidate <= 1) continue;
            snprintf(path, sizeof(path), "/proc/%ld/stat", candidate);
            FILE *stat_file = fopen(path, "r"); if (!stat_file) continue;
            char data[4096]; size_t n = fread(data, 1, sizeof(data) - 1, stat_file);
            fclose(stat_file); data[n] = 0;
            char *fields = strrchr(data, ')'); long ppid = -1; char state;
            if (fields && sscanf(fields + 1, " %c %ld", &state, &ppid) == 2 && ppid == parent) {
                remember((pid_t)candidate); discover_children((pid_t)candidate, depth + 1);
            }
        }
        closedir(directory);
    }
#endif
}
static void discover_family(void) {
    remember(child); discover_children(child, 0);
    /* Previously observed processes can create children after the CLI exits. */
    size_t count = family_count;
    for (size_t i = 0; i < count; ++i) {
        if (birth_time(family[i].pid) == family[i].born) discover_children(family[i].pid, 0);
    }
}
static void signal_family(int sig) {
    discover_family();
    if (terminal_master >= 0) {
        pid_t foreground = tcgetpgrp(terminal_master);
        if (foreground > 1 && foreground != getpgrp()) (void)kill(-foreground, sig);
    }
    if (child > 1) (void)kill(-child, sig);
    for (size_t i = family_count; i > 0; --i) {
        identity id = family[i - 1];
        if (birth_time(id.pid) == id.born) (void)kill(id.pid, sig);
    }
}
static uint32_t read_u32(const unsigned char *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}
static int valid_number(const char *s, long *value) {
    char *end = NULL; errno = 0; long n = strtol(s, &end, 10);
    if (errno || !end || *end || n < 0 || n > 86400000) return 0;
    *value = n; return 1;
}
int main(int argc, char **argv) {
    int cooperative = argc > 4 && !strcmp(argv[4], "--cooperative");
    int separator = cooperative ? 5 : 4;
    if (argc < 6 || (strcmp(argv[1], "--capture") && strcmp(argv[1], "--pty")) ||
        strcmp(argv[2], "--timeout-ms") || argc <= separator + 1 || strcmp(argv[separator], "--") || argv[separator + 1][0] != '/') {
        fputs("MoPanelGuardian: invalid invocation\n", stderr); return 125;
    }
    long timeout = 0;
    if (!valid_number(argv[3], &timeout)) return 125;
    int interactive = !strcmp(argv[1], "--pty");
    if (pipe(wake_pipe) || nonblocking(wake_pipe[0]) || nonblocking(wake_pipe[1])) return 125;
    fcntl(wake_pipe[0], F_SETFD, FD_CLOEXEC); fcntl(wake_pipe[1], F_SETFD, FD_CLOEXEC);
    struct sigaction action; memset(&action, 0, sizeof(action));
    action.sa_handler = signal_handler; sigemptyset(&action.sa_mask); action.sa_flags = SA_RESTART;
    sigaction(SIGCHLD, &action, NULL); sigaction(SIGTERM, &action, NULL);
    sigaction(SIGHUP, &action, NULL); sigaction(SIGINT, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
#ifndef __APPLE__
    /* Reap orphaned grandchildren on the test platform. macOS has no subreaper. */
    (void)prctl(PR_SET_CHILD_SUBREAPER, 1);
#endif
    struct winsize size = {.ws_row = 32, .ws_col = 110};
    child = interactive ? forkpty(&terminal_master, NULL, NULL, &size) : fork();
    if (child == -1) { perror("MoPanelGuardian: fork"); return 125; }
    if (child == 0) {
        signal(SIGCHLD, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL);
        signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_DFL);
        close(wake_pipe[0]); close(wake_pipe[1]);
        if (!interactive) {
            if (setsid() == -1) _exit(125);
            int nullfd = open("/dev/null", O_RDONLY); if (nullfd < 0) _exit(125);
            dup2(nullfd, STDIN_FILENO); if (nullfd != STDIN_FILENO) close(nullfd);
        }
        execv(argv[separator + 1], &argv[separator + 1]);
        int exec_error = errno;
        dprintf(STDERR_FILENO, "MoPanelGuardian: exec failed: %s\n", strerror(exec_error));
        _exit(exec_error == ENOENT ? 127 : 126);
    }
    (void)nonblocking(STDIN_FILENO);
    if (interactive) { (void)nonblocking(terminal_master); (void)nonblocking(STDOUT_FILENO); }
    unsigned char control[FRAME_LIMIT + 5], pending_input[FRAME_LIMIT], pending_output[BUFFER_LIMIT];
    size_t control_used = 0, input_used = 0, output_used = 0;
    int control_open = 1, master_open = interactive, output_open = 1, status = 0, reaped = 0, reason = 0;
    int64_t start = now_ms(), stopping = 0, drained = 0, family_scan = 0;
    for (;;) {
        int64_t now = now_ms();
        if (now - family_scan >= 1000) { discover_family(); family_scan = now; }
        if (!stopping && (interrupted || !control_open)) { if (!reason) reason = 130; stopping = now; signal_family(SIGINT); }
        if (!stopping && timeout && now - start >= timeout) { reason = 124; stopping = now; signal_family(SIGINT); }
        /* Slim may be swapping an app atomically. Let its deferred signal trap
         * finish the current transaction instead of killing between renames. */
        if (stopping && !cooperative && now - stopping >= 2000) signal_family(SIGKILL);
        if (!reaped) {
            pid_t result = waitpid(child, &status, WNOHANG);
            if (result == child) { reaped = 1; drained = now; signal_family(SIGKILL); }
        }
        if (reaped && (!interactive || (output_used == 0 && (!master_open || now - drained > 300)))) break;
        struct pollfd fds[4] = {
            {control_open ? STDIN_FILENO : -1, POLLIN, 0},
            {wake_pipe[0], POLLIN, 0},
            {master_open ? terminal_master : -1,
             (short)((!output_open || output_used < BUFFER_LIMIT ? POLLIN : 0) | (input_used ? POLLOUT : 0)), 0},
            {interactive && output_open && output_used ? STDOUT_FILENO : -1, POLLOUT, 0}
        };
        int wait = 1000;
        if (timeout && !stopping) { int64_t left = timeout - (now - start); if (left < wait) wait = left > 0 ? (int)left : 0; }
        if (stopping || reaped) wait = 50;
        int rc = poll(fds, 4, wait); if (rc < 0 && errno != EINTR) { interrupted = 1; continue; }
        if (fds[1].revents & POLLIN) { unsigned char discard[64]; while (read(wake_pipe[0], discard, sizeof(discard)) > 0) {} }
        if (fds[3].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            /* The GUI's output reader is gone. Never poll that destination
             * again, and keep draining the PTY without retaining its output.
             * Closing the PTY instead could interrupt a cooperative app swap
             * before the child reaches its own safe cancellation boundary. */
            output_open = 0; output_used = 0; interrupted = 1;
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(STDIN_FILENO, control + control_used, sizeof(control) - control_used);
            if (n == 0) control_open = 0;
            else if (n > 0) {
                control_used += (size_t)n;
                while (control_used >= 5) {
                    uint32_t length = read_u32(control + 1);
                    if (length > FRAME_LIMIT) { interrupted = 1; reason = 125; break; }
                    if (control_used < length + 5U) break;
                    unsigned char kind = control[0]; const unsigned char *data = control + 5;
                    if (kind == 'C' && length == 0) interrupted = 1;
                    else if (kind == 'R' && length == 4 && interactive) {
                        unsigned cols = ((unsigned)data[0] << 8) | data[1];
                        unsigned rows = ((unsigned)data[2] << 8) | data[3];
                        if (cols >= 20 && cols <= 1000 && rows >= 5 && rows <= 500) {
                            struct winsize ws = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
                            (void)ioctl(terminal_master, TIOCSWINSZ, &ws);
                        }
                    } else if (kind == 'I' && interactive && !stopping && length <= FRAME_LIMIT - input_used) {
                        memcpy(pending_input + input_used, data, length); input_used += length;
                    } else { interrupted = 1; reason = 125; }
                    memmove(control, control + 5 + length, control_used - 5 - length); control_used -= 5 + length;
                }
            } else if (errno != EAGAIN && errno != EINTR) control_open = 0;
        }
        if (master_open && fds[2].revents & POLLOUT && input_used) {
            ssize_t n = write(terminal_master, pending_input, input_used);
            if (n > 0) { /* Erase consumed input; password bytes are never printed or retained. */
                memmove(pending_input, pending_input + n, input_used - (size_t)n);
                memset(pending_input + input_used - n, 0, (size_t)n); input_used -= (size_t)n;
            }
        }
        if (master_open && fds[2].revents & (POLLIN | POLLHUP | POLLERR) && (!output_open || output_used < BUFFER_LIMIT)) {
            size_t offset = output_open ? output_used : 0;
            ssize_t n = read(terminal_master, pending_output + offset, BUFFER_LIMIT - offset);
            if (n > 0) { if (output_open) output_used += (size_t)n; }
            else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) master_open = 0;
        }
        if (output_open && output_used && (fds[3].revents & POLLOUT || reaped)) {
            ssize_t n = write(STDOUT_FILENO, pending_output, output_used);
            if (n > 0) { memmove(pending_output, pending_output + n, output_used - (size_t)n); output_used -= (size_t)n; }
            else if (n < 0 && errno != EAGAIN && errno != EINTR) { interrupted = 1; output_open = 0; output_used = 0; }
        }
    }
    signal_family(SIGKILL);
    if (terminal_master >= 0) close(terminal_master);
    memset(control, 0, sizeof(control)); memset(pending_input, 0, sizeof(pending_input));
    if (!reaped) while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    close(wake_pipe[0]); close(wake_pipe[1]);
    if (reason) return reason;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 125;
}
