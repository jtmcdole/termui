#define _GNU_SOURCE
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <termios.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

#if defined(__linux__)
#include <sys/syscall.h>
#endif

#if defined(__GNUC__) || defined(__clang__)
#define PTY2_EXPORT __attribute__((visibility("default")))
#else
#define PTY2_EXPORT
#endif

static void pty2_close_extra_fds(void) {
#if defined(__linux__) && defined(SYS_close_range)
  if (syscall(SYS_close_range, 3U, ~0U, 0U) == 0) {
    return;
  }
#endif
  struct rlimit rl;
  int max_fd = 4096;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY &&
      rl.rlim_cur <= 65536) {
    max_fd = (int)rl.rlim_cur;
  }
  for (int fd = 3; fd < max_fd; fd++) {
    close(fd);
  }
}

PTY2_EXPORT int32_t pty2_spawn_unix(
    const char* executable,
    char* const* argv,
    char* const* envp,
    const char* working_dir,
    uint16_t cols,
    uint16_t rows,
    int32_t raw,
    int32_t* out_ptm) {
  if (executable == NULL || argv == NULL || envp == NULL || out_ptm == NULL) {
    return -1;
  }

  struct winsize ws;
  ws.ws_col = cols;
  ws.ws_row = rows;
  ws.ws_xpixel = 0;
  ws.ws_ypixel = 0;

  int ptm = -1;
  int pts = -1;
  if (openpty(&ptm, &pts, NULL, NULL, &ws) != 0) {
    return -2;
  }

  fcntl(ptm, F_SETFD, FD_CLOEXEC);
  fcntl(pts, F_SETFD, FD_CLOEXEC);

  if (raw != 0) {
    struct termios term;
    if (tcgetattr(ptm, &term) == 0) {
      cfmakeraw(&term);
      tcsetattr(ptm, TCSANOW, &term);
    }
  }

  pid_t pid = fork();
  if (pid < 0) {
    close(pts);
    close(ptm);
    return -3;
  }

  if (pid == 0) {
    // Child process: strictly async-signal-safe POSIX calls only.
    // Never return to the Dart VM or allocate heap memory.
    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    sigprocmask(SIG_SETMASK, &empty_mask, NULL);

    struct sigaction default_sa;
    default_sa.sa_handler = SIG_DFL;
    sigemptyset(&default_sa.sa_mask);
    default_sa.sa_flags = 0;
#ifndef NSIG
#define NSIG 32
#endif
    for (int sig = 1; sig < NSIG; sig++) {
      if (sig == SIGKILL || sig == SIGSTOP) continue;
      sigaction(sig, &default_sa, NULL);
    }

    close(ptm);

    if (setsid() == -1) {
      _exit(1);
    }

    if (ioctl(pts, TIOCSCTTY, 0) == -1) {
      _exit(1);
    }

    while (dup2(pts, STDIN_FILENO) == -1) {
      if (errno != EINTR) _exit(1);
    }
    while (dup2(pts, STDOUT_FILENO) == -1) {
      if (errno != EINTR) _exit(1);
    }
    while (dup2(pts, STDERR_FILENO) == -1) {
      if (errno != EINTR) _exit(1);
    }

    if (pts > STDERR_FILENO) {
      close(pts);
    }

    pty2_close_extra_fds();

    if (working_dir != NULL && chdir(working_dir) != 0) {
      _exit(1);
    }

    execve(executable, argv, envp);
    _exit(1);
  }

  close(pts);
  *out_ptm = (int32_t)ptm;
  return (int32_t)pid;
}
