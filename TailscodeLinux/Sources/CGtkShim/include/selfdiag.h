#ifndef TAILSCODE_SELFDIAG_H
#define TAILSCODE_SELFDIAG_H

#include <stdint.h>
#include <stddef.h>

/// The most return addresses one sample of the main thread keeps.
#define TAILSCODE_STACK_DEPTH 48

/// Primes the unwinder and installs the handler for the sampling signal. Call once, on the thread
/// to be sampled (the main thread), before any sample is asked for; a later call from another
/// thread makes that thread the one sampled. Returns 1 when sampling is available.
int tailscode_stack_sampler_install(void);

/// Asks the thread that installed the sampler for its own stack and waits up to `timeout_ms` for
/// the answer. Safe from any single other thread at a time. Writes up to `capacity` addresses to
/// `out`, innermost first, the first being the instruction the thread was executing and the rest
/// return addresses. Returns the count, or -1 when the thread did not answer in time (it is
/// blocked in the kernel, or the sampler is not installed).
int tailscode_stack_sample_main(int timeout_ms, uintptr_t *out, int capacity);

/// Names the module an address lies in and its offset from the module's load base, which is what
/// `addr2line -e <module> <offset>` takes. The module is the file's base name, copied to `module`
/// (`capacity` bytes). Returns 1 when the address belongs to a loaded module, 0 otherwise, in
/// which case `module` is "?" and the offset is the address itself.
int tailscode_stack_resolve(uintptr_t address, char *module, size_t capacity, uint64_t *offset);

/// Replaces the runtime's crash reporter with one that writes the faulting thread's frames to the
/// app log (and stderr) at once and lets the default action write the core. Call once, on the main
/// thread, early; `build` is the version the frames resolve against. Returns how many signals it
/// took over.
int tailscode_crash_logger_install(const char *log_path, const char *build);

#endif
