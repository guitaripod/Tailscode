#ifndef TAILSCODE_CSHERPA_H
#define TAILSCODE_CSHERPA_H

/// The speech engine Linux dictation listens with, reached at run time. sherpa-onnx's shared
/// library is downloaded on the first press, never linked, so this is a small door onto it: the
/// library is opened with dlopen, its streaming recognizer is driven through the struct layouts of
/// its own vendored header, and nothing of it is visible to Swift but opaque handles and text.

/// Opens the library at `library_path` and finds every function the recognizer needs. Returns 1
/// when it is usable; otherwise 0 with the loader's own words in `error`.
int tailscode_sherpa_load(const char *library_path, char *error, int error_size);

/// A streaming transducer recognizer over the four model files, decoding greedily with endpoints
/// on. `trailing_silence` is how long a pause after speech closes a segment. NULL on failure.
void *tailscode_sherpa_recognizer(
    const char *encoder, const char *decoder, const char *joiner, const char *tokens, int threads,
    float trailing_silence);

void tailscode_sherpa_free_recognizer(void *recognizer);

void *tailscode_sherpa_stream(void *recognizer);

void tailscode_sherpa_free_stream(void *stream);

/// Hands over `count` samples at `sample_rate` (the library resamples), decodes what is ready and
/// copies the segment's text so far into `out`. Returns 1 when the segment just ended — the text is
/// final and the stream starts a new segment — and 0 while it is still being heard.
int tailscode_sherpa_feed(
    void *recognizer, void *stream, int sample_rate, const float *samples, int count, char *out,
    int out_size);

/// Ends the input with a moment of silence, decodes what is left and copies the last segment's
/// text into `out`.
void tailscode_sherpa_finish(void *recognizer, void *stream, int sample_rate, char *out, int out_size);

#endif
