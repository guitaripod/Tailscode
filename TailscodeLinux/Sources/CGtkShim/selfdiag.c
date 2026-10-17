#define _GNU_SOURCE
#include "selfdiag.h"
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <execinfo.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static pid_t sampled_tid = 0;
static int sampling_signal = 0;
static void *captured[TAILSCODE_STACK_DEPTH + 2];
static atomic_int captured_depth = 0;
static atomic_uint sequence = 0;
static atomic_int armed = 0;

/// Runs on the sampled thread. Everything it touches is preallocated: `backtrace` has been
/// primed, so it no longer loads the unwinder, and the buffer is written under a sequence number
/// the asking thread checks, so a late signal from an earlier request cannot hand it a torn stack.
static void answer_sample(int signal_number) {
    (void)signal_number;
    int saved = errno;
    if (atomic_load_explicit(&armed, memory_order_acquire)) {
        unsigned start = atomic_load_explicit(&sequence, memory_order_relaxed);
        atomic_store_explicit(&sequence, start + 1, memory_order_release);
        int depth = backtrace(captured, TAILSCODE_STACK_DEPTH + 2);
        atomic_store_explicit(&captured_depth, depth, memory_order_relaxed);
        atomic_store_explicit(&sequence, start + 2, memory_order_release);
    }
    errno = saved;
}

static void unblock_sampling_signal(int number) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, number);
    pthread_sigmask(SIG_UNBLOCK, &set, NULL);
}

int tailscode_stack_sampler_install(void) {
    if (sampling_signal != 0) {
        unblock_sampling_signal(sampling_signal);
        sampled_tid = (pid_t)syscall(SYS_gettid);
        return 1;
    }
    void *warm[4];
    backtrace(warm, 4);
    int number = SIGRTMAX - 3;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = answer_sample;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    if (sigaction(number, &action, NULL) != 0) return 0;
    unblock_sampling_signal(number);
    sampled_tid = (pid_t)syscall(SYS_gettid);
    sampling_signal = number;
    return 1;
}

static void pause_one_millisecond(void) {
    struct timespec nap = {0, 1000000};
    nanosleep(&nap, NULL);
}

int tailscode_stack_sample_main(int timeout_ms, uintptr_t *out, int capacity) {
    if (sampling_signal == 0 || out == NULL || capacity <= 0) return -1;
    unsigned before = atomic_load_explicit(&sequence, memory_order_acquire);
    atomic_store_explicit(&armed, 1, memory_order_release);
    if (syscall(SYS_tgkill, (pid_t)getpid(), sampled_tid, sampling_signal) != 0) {
        atomic_store_explicit(&armed, 0, memory_order_release);
        return -1;
    }
    int result = -1;
    for (int waited = 0; waited <= timeout_ms; waited++) {
        unsigned now = atomic_load_explicit(&sequence, memory_order_acquire);
        if (now != before && (now & 1u) == 0) {
            int depth = atomic_load_explicit(&captured_depth, memory_order_relaxed);
            if (depth > TAILSCODE_STACK_DEPTH + 2) depth = TAILSCODE_STACK_DEPTH + 2;
            int skip = depth > 2 ? 2 : 0;
            int count = depth - skip < capacity ? depth - skip : capacity;
            for (int index = 0; index < count; index++) out[index] = (uintptr_t)captured[skip + index];
            if (atomic_load_explicit(&sequence, memory_order_acquire) == now) {
                result = count;
                break;
            }
        }
        pause_one_millisecond();
    }
    atomic_store_explicit(&armed, 0, memory_order_release);
    return result;
}

int tailscode_stack_resolve(uintptr_t address, char *module, size_t capacity, uint64_t *offset) {
    Dl_info info;
    if (capacity == 0) return 0;
    if (address != 0 && dladdr((void *)address, &info) != 0 && info.dli_fname != NULL
        && info.dli_fbase != NULL) {
        const char *slash = strrchr(info.dli_fname, '/');
        const char *name = slash ? slash + 1 : info.dli_fname;
        if (*name == '\0') name = "?";
        strncpy(module, name, capacity - 1);
        module[capacity - 1] = '\0';
        *offset = (uint64_t)(address - (uintptr_t)info.dli_fbase);
        return 1;
    }
    strncpy(module, "?", capacity - 1);
    module[capacity - 1] = '\0';
    *offset = (uint64_t)address;
    return 0;
}

static char crash_log_path[512];
static char crash_build[32];
static void *crash_frames[TAILSCODE_STACK_DEPTH + 4];
static volatile sig_atomic_t crash_entered = 0;
static char crash_alt_stack[65536];

static size_t crash_append(char *buffer, size_t used, size_t capacity, const char *text) {
    size_t length = strlen(text);
    if (used + length >= capacity) length = capacity - used - 1;
    memcpy(buffer + used, text, length);
    return used + length;
}

static size_t crash_append_hex(char *buffer, size_t used, size_t capacity, uintptr_t value) {
    char digits[2 + 16 + 1];
    size_t count = 0;
    digits[count++] = '0';
    digits[count++] = 'x';
    int started = 0;
    for (int shift = 60; shift >= 0; shift -= 4) {
        int nibble = (int)((value >> shift) & 0xf);
        if (nibble != 0 || started || shift == 0) {
            started = 1;
            digits[count++] = (char)(nibble < 10 ? '0' + nibble : 'a' + nibble - 10);
        }
    }
    digits[count] = '\0';
    return crash_append(buffer, used, capacity, digits);
}

static size_t crash_append_number(char *buffer, size_t used, size_t capacity, long value) {
    char digits[24];
    size_t count = 0;
    if (value == 0) digits[count++] = '0';
    while (value > 0 && count < sizeof(digits) - 1) {
        digits[count++] = (char)('0' + value % 10);
        value /= 10;
    }
    char text[24];
    for (size_t index = 0; index < count; index++) text[index] = digits[count - 1 - index];
    text[count] = '\0';
    return crash_append(buffer, used, capacity, text);
}

static void crash_write(int descriptor, const char *text, size_t length) {
    while (length > 0) {
        ssize_t written = write(descriptor, text, length);
        if (written <= 0) return;
        text += written;
        length -= (size_t)written;
    }
}

/// Runs on the faulting thread, on its own stack, and must be quick: the runtime's own crash
/// reporter suspends every other thread to print their stacks and, with a dozen of them parked in
/// the toolkit's pollers, retried for fifteen seconds while the window sat frozen. This writes one
/// line a person can read, the frames in the form `tailscode --stacks` resolves, then lets the
/// signal take its default action so the kernel still writes the core file. An alarm bounds the
/// one call that is not async-signal-safe (`dladdr`, which takes the loader's lock).
static void crash_handler(int signal_number, siginfo_t *info, void *context) {
    (void)context;
    if (crash_entered++ != 0) {
        signal(signal_number, SIG_DFL);
        raise(signal_number);
        return;
    }
    alarm(2);
    int depth = backtrace(crash_frames, TAILSCODE_STACK_DEPTH + 4);
    char line[4096];
    size_t used = 0;
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    struct tm parts;
    gmtime_r(&now.tv_sec, &parts);
    char stamp[48];
    snprintf(stamp, sizeof(stamp), "%04d-%02d-%02dT%02d:%02d:%02d.%03ldZ", parts.tm_year + 1900,
             parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec,
             now.tv_nsec / 1000000);
    used = crash_append(line, used, sizeof(line), stamp);
    used = crash_append(line, used, sizeof(line), " [lifecycle] watchdog: crash signal ");
    used = crash_append_number(line, used, sizeof(line), signal_number);
    used = crash_append(line, used, sizeof(line), " at ");
    used = crash_append_hex(line, used, sizeof(line), (uintptr_t)(info ? info->si_addr : 0));
    used = crash_append(line, used, sizeof(line), " · build ");
    used = crash_append(line, used, sizeof(line), crash_build);
    used = crash_append(line, used, sizeof(line), "\n");
    used = crash_append(line, used, sizeof(line), stamp);
    used = crash_append(line, used, sizeof(line), " [lifecycle] watchdog: stack 1/1 · main: ");
    int first = depth > 2 ? 2 : 0;
    for (int index = first; index < depth && index < first + TAILSCODE_STACK_DEPTH; index++) {
        Dl_info where;
        if (dladdr(crash_frames[index], &where) != 0 && where.dli_fname != NULL
            && where.dli_fbase != NULL) {
            const char *slash = strrchr(where.dli_fname, '/');
            used = crash_append(line, used, sizeof(line), slash ? slash + 1 : where.dli_fname);
            used = crash_append(line, used, sizeof(line), "+");
            used = crash_append_hex(line, used, sizeof(line),
                                    (uintptr_t)crash_frames[index] - (uintptr_t)where.dli_fbase);
        } else {
            used = crash_append(line, used, sizeof(line), "?+");
            used = crash_append_hex(line, used, sizeof(line), (uintptr_t)crash_frames[index]);
        }
        used = crash_append(line, used, sizeof(line), " ");
    }
    used = crash_append(line, used, sizeof(line), "\n");
    crash_write(2, line, used);
    int descriptor = crash_log_path[0] != '\0'
        ? open(crash_log_path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644) : -1;
    if (descriptor >= 0) {
        crash_write(descriptor, line, used);
        close(descriptor);
    }
    alarm(0);
    signal(signal_number, SIG_DFL);
    raise(signal_number);
}

int tailscode_crash_logger_install(const char *log_path, const char *build) {
    void *warm[4];
    backtrace(warm, 4);
    snprintf(crash_log_path, sizeof(crash_log_path), "%s", log_path ? log_path : "");
    snprintf(crash_build, sizeof(crash_build), "%s", build ? build : "?");
    stack_t alternate;
    alternate.ss_sp = crash_alt_stack;
    alternate.ss_size = sizeof(crash_alt_stack);
    alternate.ss_flags = 0;
    sigaltstack(&alternate, NULL);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = crash_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    int installed = 0;
    const int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP};
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
        if (sigaction(signals[index], &action, NULL) == 0) installed++;
    }
    return installed;
}
