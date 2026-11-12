#define _GNU_SOURCE
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
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

typedef struct pty2_main_state {
  int32_t ptm;
  uint8_t stop_flag;
  uint8_t reaped;
  uint8_t status_valid;
  uint8_t mutex_init;
  int32_t status_fd;
  int32_t shim_pid;
  int32_t shell_pid;
  int32_t cached_status;
  int32_t active_pollers;
  int32_t ref_count;
  pthread_mutex_t lock;
  uint8_t write_buf[];
} pty2_main_state_t;

static void pty2_close_fds_from(int min_fd, int keep_fd) {
#if defined(__linux__) && defined(SYS_close_range)
  if (keep_fd < min_fd) {
    if (syscall(SYS_close_range, (unsigned int)min_fd, ~0U, 0U) == 0) {
      return;
    }
  } else if (keep_fd == min_fd) {
    if (syscall(SYS_close_range, (unsigned int)(min_fd + 1), ~0U, 0U) == 0) {
      return;
    }
  } else {
    if (syscall(SYS_close_range, (unsigned int)min_fd,
                (unsigned int)(keep_fd - 1), 0U) == 0 &&
        syscall(SYS_close_range, (unsigned int)(keep_fd + 1), ~0U, 0U) == 0) {
      return;
    }
  }
#endif
  struct rlimit rl;
  int max_fd = 4096;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY) {
    max_fd = rl.rlim_cur <= 65536 ? (int)rl.rlim_cur : 65536;
  }
  for (int fd = min_fd; fd < max_fd; fd++) {
    if (fd != keep_fd) {
      close(fd);
    }
  }
}

static int pty2_pipe_cloexec(int fds[2]) {
#if defined(__linux__) && defined(O_CLOEXEC)
  if (pipe2(fds, O_CLOEXEC) == 0) {
    return 0;
  }
  if (errno != ENOSYS) {
    return -1;
  }
#endif
  if (pipe(fds) != 0) {
    return -1;
  }
  if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) != 0 ||
      fcntl(fds[1], F_SETFD, FD_CLOEXEC) != 0) {
    int err = errno;
    close(fds[0]);
    close(fds[1]);
    errno = err;
    return -1;
  }
  return 0;
}

static int pty2_write_all(int fd, const void* buf, size_t len) {
  const uint8_t* p = (const uint8_t*)buf;
  size_t offset = 0;
  while (offset < len) {
    ssize_t n = write(fd, p + offset, len - offset);
    if (n > 0) {
      offset += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) {
      continue;
    }
    return -1;
  }
  return 0;
}

static ssize_t pty2_read_exact(int fd, void* buf, size_t len) {
  uint8_t* p = (uint8_t*)buf;
  size_t offset = 0;
  while (offset < len) {
    ssize_t n = read(fd, p + offset, len - offset);
    if (n > 0) {
      offset += (size_t)n;
      continue;
    }
    if (n == 0) {
      break;
    }
    if (errno == EINTR) {
      continue;
    }
    return -1;
  }
  return (ssize_t)offset;
}

static void pty2_wait_shim_pid(pid_t shim_pid) {
  if (shim_pid <= 0) {
    return;
  }
  pid_t wr;
  do {
    wr = waitpid(shim_pid, NULL, 0);
  } while (wr < 0 && errno == EINTR);
  // Ignore ECHILD if Dart VM's SIGCHLD reaper already reaped shim_pid.
}

static void pty2_reset_signals_for_child(void) {
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
}

static void pty2_ignore_sigpipe(void) {
  struct sigaction ign_sa;
  ign_sa.sa_handler = SIG_IGN;
  sigemptyset(&ign_sa.sa_mask);
  ign_sa.sa_flags = 0;
  sigaction(SIGPIPE, &ign_sa, NULL);
}

static void pty2_isolate_shim_signals(void) {
  static const int ignored_signals[] = {
      SIGINT,
      SIGQUIT,
      SIGTSTP,
      SIGTTIN,
      SIGTTOU,
      SIGHUP,
      SIGPIPE,
  };
  struct sigaction ign_sa;
  ign_sa.sa_handler = SIG_IGN;
  sigemptyset(&ign_sa.sa_mask);
  ign_sa.sa_flags = 0;
  size_t count = sizeof(ignored_signals) / sizeof(ignored_signals[0]);
  for (size_t i = 0; i < count; i++) {
    sigaction(ignored_signals[i], &ign_sa, NULL);
  }
}

static void pty2_run_shell_child(
    const char* executable,
    char* const* argv,
    char* const* envp,
    const char* working_dir,
    int ptm,
    int pts,
    int status_write_fd) {
  close(status_write_fd);
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

  pty2_close_fds_from(3, -1);

  if (working_dir != NULL && chdir(working_dir) != 0) {
    _exit(1);
  }

  execve(executable, argv, envp);
  _exit(1);
}

static void pty2_run_reaper_shim(
    const char* executable,
    char* const* argv,
    char* const* envp,
    const char* working_dir,
    int ptm,
    int pts,
    int status_read_fd,
    int status_write_fd) {
  // Intermediate reaper shim: strictly async-signal-safe POSIX calls only.
  // Never return to the Dart VM or allocate heap memory.
  close(status_read_fd);
  pty2_reset_signals_for_child();

  pid_t shell_pid = fork();
  if (shell_pid < 0) {
    int32_t err = errno > 0 ? -(int32_t)errno : -1;
    pty2_ignore_sigpipe();
    (void)pty2_write_all(status_write_fd, &err, sizeof(err));
    close(status_write_fd);
    close(pts);
    close(ptm);
    _exit(1);
  }

  if (shell_pid == 0) {
    pty2_run_shell_child(
        executable, argv, envp, working_dir, ptm, pts, status_write_fd);
  }

  (void)setpgid(0, 0);
  pty2_isolate_shim_signals();
  close(ptm);
  close(pts);

  // Move status_write_fd to FD 3 so all other inherited FDs (0, 1, 2, >= 4)
  // can be closed cleanly before reporting shell_pid to the parent.
  int wfd = status_write_fd;
  if (wfd != 3) {
    int r;
    do {
      r = dup2(wfd, 3);
    } while (r == -1 && errno == EINTR);
    if (r >= 0) {
      close(wfd);
      wfd = 3;
    }
  }
  for (int fd = 0; fd <= 2; fd++) {
    if (fd != wfd) {
      close(fd);
    }
  }
  if (wfd == 3) {
    pty2_close_fds_from(4, -1);
  } else {
    pty2_close_fds_from(3, wfd);
  }

  int32_t pid_msg = (int32_t)shell_pid;
  if (pty2_write_all(wfd, &pid_msg, sizeof(pid_msg)) != 0) {
    close(wfd);
    if (shell_pid > 1) {
      kill(-shell_pid, SIGKILL);
    }
    kill(shell_pid, SIGKILL);
    pid_t wr;
    do {
      wr = waitpid(shell_pid, NULL, 0);
    } while (wr < 0 && errno == EINTR);
    _exit(1);
  }

  int status = 0;
  pid_t wr;
  do {
    wr = waitpid(shell_pid, &status, 0);
  } while (wr < 0 && errno == EINTR);

  int32_t out_status = (wr == shell_pid) ? (int32_t)status : -1;
  (void)pty2_write_all(wfd, &out_status, sizeof(out_status));
  close(wfd);
  _exit(0);
}

PTY2_EXPORT int32_t pty2_spawn_unix(
    const char* executable,
    char* const* argv,
    char* const* envp,
    const char* working_dir,
    uint16_t cols,
    uint16_t rows,
    int32_t raw,
    int32_t* out_ptm,
    int32_t* out_status_fd,
    int32_t* out_shim_pid) {
  if (executable == NULL || argv == NULL || envp == NULL || out_ptm == NULL ||
      out_status_fd == NULL || out_shim_pid == NULL) {
    return -1;
  }

  *out_ptm = -1;
  *out_status_fd = -1;
  *out_shim_pid = -1;

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

  int status_pipe[2] = {-1, -1};
  if (pty2_pipe_cloexec(status_pipe) != 0) {
    close(pts);
    close(ptm);
    return -3;
  }

  pid_t shim_pid = fork();
  if (shim_pid < 0) {
    close(status_pipe[0]);
    close(status_pipe[1]);
    close(pts);
    close(ptm);
    return -3;
  }

  if (shim_pid == 0) {
    pty2_run_reaper_shim(
        executable,
        argv,
        envp,
        working_dir,
        ptm,
        pts,
        status_pipe[0],
        status_pipe[1]);
  }

  close(pts);
  close(status_pipe[1]);

  int32_t handshake = 0;
  ssize_t n = pty2_read_exact(status_pipe[0], &handshake, sizeof(handshake));
  if (n != (ssize_t)sizeof(handshake) || handshake <= 0) {
    close(status_pipe[0]);
    close(ptm);
    pty2_wait_shim_pid(shim_pid);
    return -3;
  }

  *out_ptm = (int32_t)ptm;
  *out_status_fd = (int32_t)status_pipe[0];
  *out_shim_pid = (int32_t)shim_pid;
  return handshake;
}

PTY2_EXPORT int32_t pty2_dup_cloexec(int32_t fd) {
  int nfd = dup((int)fd);
  if (nfd < 0) {
    return errno > 0 ? -(int32_t)errno : -1;
  }
  if (fcntl(nfd, F_SETFD, FD_CLOEXEC) < 0) {
    int err = errno;
    close(nfd);
    return err > 0 ? -(int32_t)err : -1;
  }
  return (int32_t)nfd;
}

PTY2_EXPORT intptr_t pty2_read(int32_t fd, void* buf, uintptr_t count) {
  ssize_t n;
  do {
    n = read((int)fd, buf, (size_t)count);
  } while (n < 0 && errno == EINTR);
  if (n < 0) {
    return errno > 0 ? -(intptr_t)errno : -1;
  }
  return (intptr_t)n;
}

PTY2_EXPORT intptr_t pty2_write(int32_t fd, const void* buf, uintptr_t count) {
  ssize_t n = write((int)fd, buf, (size_t)count);
  if (n < 0) {
    return errno > 0 ? -(intptr_t)errno : -1;
  }
  return (intptr_t)n;
}

PTY2_EXPORT int32_t pty2_poll(void* fds, uintptr_t nfds, int32_t timeout_ms) {
  int ret = poll((struct pollfd*)fds, (nfds_t)nfds, (int)timeout_ms);
  if (ret < 0) {
    return errno > 0 ? -(int32_t)errno : -1;
  }
  return (int32_t)ret;
}

PTY2_EXPORT int32_t pty2_waitpid(
    int32_t pid,
    int32_t* out_status,
    int32_t options) {
  if (out_status != NULL) {
    *out_status = 0;
  }
  int status = 0;
  pid_t ret;
  do {
    ret = waitpid((pid_t)pid, &status, (int)options);
  } while (ret < 0 && errno == EINTR && (options & WNOHANG) == 0);

  if (ret < 0) {
    return errno > 0 ? -(int32_t)errno : -1;
  }
  if (out_status != NULL && ret > 0) {
    *out_status = (int32_t)status;
  }
  return (int32_t)ret;
}

PTY2_EXPORT int32_t pty2_resize(
    int32_t fd,
    uint16_t cols,
    uint16_t rows,
    uint16_t xpixel,
    uint16_t ypixel) {
  struct winsize ws;
  ws.ws_col = cols;
  ws.ws_row = rows;
  ws.ws_xpixel = xpixel;
  ws.ws_ypixel = ypixel;
  if (ioctl((int)fd, TIOCSWINSZ, &ws) < 0) {
    return errno > 0 ? -(int32_t)errno : -1;
  }
  return 0;
}

PTY2_EXPORT void* pty2_alloc_main_state(
    uintptr_t buf_size,
    int32_t ptm,
    int32_t status_fd,
    int32_t shim_pid,
    int32_t shell_pid) {
  if (buf_size > SIZE_MAX - sizeof(pty2_main_state_t)) {
    return NULL;
  }
  pty2_main_state_t* state = (pty2_main_state_t*)calloc(
      1, sizeof(pty2_main_state_t) + (size_t)buf_size);
  if (state == NULL) {
    return NULL;
  }
  state->ptm = ptm;
  state->stop_flag = 0;
  state->reaped = 0;
  state->status_valid = 0;
  state->mutex_init = 0;
  state->status_fd = status_fd;
  state->shim_pid = shim_pid;
  state->shell_pid = shell_pid;
  state->cached_status = -1;
  state->active_pollers = 0;
  state->ref_count = 1;
  if (pthread_mutex_init(&state->lock, NULL) != 0) {
    free(state);
    return NULL;
  }
  state->mutex_init = 1;
  return state;
}

PTY2_EXPORT void pty2_dispose_main_state(void* ptr) {
  if (ptr == NULL) {
    return;
  }
  pty2_main_state_t* state = (pty2_main_state_t*)ptr;
  if (!state->mutex_init) {
    if (state->ptm >= 0) {
      close((int)state->ptm);
      state->ptm = -1;
    }
    if (state->status_fd >= 0) {
      close((int)state->status_fd);
      state->status_fd = -1;
    }
    free(state);
    return;
  }

  pid_t shim_to_wait = -1;
  pthread_mutex_lock(&state->lock);
  __atomic_store_n(&state->stop_flag, 1, __ATOMIC_RELEASE);
  int32_t ptm = __atomic_load_n(&state->ptm, __ATOMIC_RELAXED);
  if (ptm >= 0) {
    __atomic_store_n(&state->ptm, -1, __ATOMIC_RELEASE);
    close((int)ptm);
  }
  if (state->active_pollers == 0 && state->status_fd >= 0) {
    close((int)state->status_fd);
    state->status_fd = -1;
  }
  state->ref_count--;
  uint8_t should_free = (state->ref_count == 0);
  if (should_free && state->shim_pid > 0) {
    shim_to_wait = (pid_t)state->shim_pid;
    state->shim_pid = -1;
  }
  pthread_mutex_unlock(&state->lock);

  if (shim_to_wait > 0) {
    (void)waitpid(shim_to_wait, NULL, WNOHANG);
  }
  if (should_free) {
    pthread_mutex_destroy(&state->lock);
    free(state);
  }
}

PTY2_EXPORT void* pty2_main_state_write_buffer(void* ptr) {
  if (ptr == NULL) {
    return NULL;
  }
  return ((pty2_main_state_t*)ptr)->write_buf;
}

PTY2_EXPORT int32_t pty2_get_ptm(void* ptr) {
  if (ptr == NULL) {
    return -1;
  }
  pty2_main_state_t* state = (pty2_main_state_t*)ptr;
  return __atomic_load_n(&state->ptm, __ATOMIC_ACQUIRE);
}

PTY2_EXPORT void pty2_close_ptm(void* ptr) {
  if (ptr == NULL) {
    return;
  }
  pty2_main_state_t* state = (pty2_main_state_t*)ptr;
  pthread_mutex_lock(&state->lock);
  __atomic_store_n(&state->stop_flag, 1, __ATOMIC_RELEASE);
  int32_t ptm = __atomic_load_n(&state->ptm, __ATOMIC_RELAXED);
  if (ptm >= 0) {
    __atomic_store_n(&state->ptm, -1, __ATOMIC_RELEASE);
    close((int)ptm);
  }
  pthread_mutex_unlock(&state->lock);
}

PTY2_EXPORT uint8_t pty2_is_stopped(void* ptr) {
  if (ptr == NULL) {
    return 1;
  }
  pty2_main_state_t* state = (pty2_main_state_t*)ptr;
  return __atomic_load_n(&state->stop_flag, __ATOMIC_ACQUIRE);
}

// Caller MUST hold state->lock.
static void pty2_mark_reaped_locked(
    pty2_main_state_t* state,
    int32_t raw_status,
    uint8_t status_valid,
    pid_t* out_shim_to_wait) {
  state->reaped = 1;
  state->status_valid = status_valid;
  state->cached_status = status_valid ? raw_status : -1;
  if (state->active_pollers == 0 && state->status_fd >= 0) {
    close((int)state->status_fd);
    state->status_fd = -1;
  }
  if (state->shim_pid > 0) {
    *out_shim_to_wait = (pid_t)state->shim_pid;
    state->shim_pid = -1;
  }
}

// Caller MUST hold state->lock.
static int32_t pty2_try_reap_locked(
    pty2_main_state_t* state,
    pid_t* out_shim_to_wait) {
  *out_shim_to_wait = -1;
  if (state->reaped) {
    return state->status_valid ? 1 : -1;
  }

  int fd = state->status_fd;
  if (fd < 0) {
    pty2_mark_reaped_locked(state, -1, 0, out_shim_to_wait);
    return -1;
  }

  struct pollfd pfd;
  int pret;
  do {
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    pret = poll(&pfd, 1, 0);
  } while (pret < 0 && errno == EINTR);

  if (pret == 0) {
    return 0;
  }
  if (pret < 0) {
    pty2_mark_reaped_locked(state, -1, 0, out_shim_to_wait);
    return -1;
  }

  int32_t raw_status = 0;
  ssize_t n = pty2_read_exact(fd, &raw_status, sizeof(raw_status));
  uint8_t valid = (n == (ssize_t)sizeof(raw_status)) ? 1 : 0;
  pty2_mark_reaped_locked(state, raw_status, valid, out_shim_to_wait);
  return valid ? 1 : -1;
}

static int pty2_poll_status_unlocked(int fd) {
  struct pollfd pfd;
  int pret;
  do {
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    pret = poll(&pfd, 1, -1);
  } while (pret < 0 && errno == EINTR);
  return pret;
}

// Caller MUST hold state->lock.
static uint8_t pty2_release_poll_ref_locked(
    pty2_main_state_t* state,
    pid_t* out_shim_to_wait) {
  if (state->reaped && state->active_pollers == 0 && state->status_fd >= 0) {
    close((int)state->status_fd);
    state->status_fd = -1;
  }
  state->ref_count--;
  if (state->ref_count != 0) {
    return 0;
  }
  if (state->status_fd >= 0) {
    close((int)state->status_fd);
    state->status_fd = -1;
  }
  if (state->shim_pid > 0 && *out_shim_to_wait <= 0) {
    *out_shim_to_wait = (pid_t)state->shim_pid;
    state->shim_pid = -1;
  }
  return 1;
}

// Caller MUST hold state->lock.
static int32_t pty2_reap_blocking_locked(
    pty2_main_state_t* state,
    pid_t* out_shim_to_wait,
    uint8_t* out_should_free) {
  int32_t result = 0;
  state->ref_count++;
  for (;;) {
    int fd = state->status_fd;
    if (fd < 0 || state->ref_count == 1) {
      if (!state->reaped) {
        pty2_mark_reaped_locked(state, -1, 0, out_shim_to_wait);
      }
      result = -1;
      break;
    }
    state->active_pollers++;
    pthread_mutex_unlock(&state->lock);
    int pret = pty2_poll_status_unlocked(fd);
    pthread_mutex_lock(&state->lock);
    state->active_pollers--;
    if (pret < 0 && !state->reaped) {
      pty2_mark_reaped_locked(state, -1, 0, out_shim_to_wait);
      result = -1;
      break;
    }
    result = pty2_try_reap_locked(state, out_shim_to_wait);
    if (result != 0) {
      break;
    }
  }
  *out_should_free = pty2_release_poll_ref_locked(state, out_shim_to_wait);
  return result;
}

PTY2_EXPORT int32_t pty2_reap_status(
    void* main_state,
    int32_t blocking,
    int32_t* out_status) {
  if (out_status != NULL) {
    *out_status = 0;
  }
  if (main_state == NULL) {
    return -1;
  }
  pty2_main_state_t* state = (pty2_main_state_t*)main_state;
  pid_t shim_to_wait = -1;
  uint8_t should_free = 0;

  pthread_mutex_lock(&state->lock);
  int32_t result = pty2_try_reap_locked(state, &shim_to_wait);
  if (result == 0 && blocking) {
    result = pty2_reap_blocking_locked(state, &shim_to_wait, &should_free);
  }
  int32_t cached = state->cached_status;
  uint8_t valid = state->status_valid;
  pthread_mutex_unlock(&state->lock);

  if (should_free) {
    pthread_mutex_destroy(&state->lock);
    free(state);
  }
  pty2_wait_shim_pid(shim_to_wait);

  if (out_status != NULL) {
    *out_status = valid ? cached : -1;
  }
  return result;
}

PTY2_EXPORT int32_t pty2_kill_shell(void* main_state, int32_t sig) {
  if (main_state == NULL || sig <= 0) {
    return 0;
  }
  pty2_main_state_t* state = (pty2_main_state_t*)main_state;
  pid_t shim_to_wait = -1;
  int32_t delivered = 0;

  pthread_mutex_lock(&state->lock);
  int32_t reap_state = pty2_try_reap_locked(state, &shim_to_wait);
  if (reap_state == 0 && state->shell_pid > 1) {
    pid_t target = (pid_t)state->shell_pid;
    (void)kill(-target, (int)sig);
    delivered = (kill(target, (int)sig) == 0) ? 1 : 0;
  }
  pthread_mutex_unlock(&state->lock);

  pty2_wait_shim_pid(shim_to_wait);
  return delivered;
}
