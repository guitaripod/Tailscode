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
