#include "CSherpa.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vendor/sherpa-onnx-c-api.h"

static void *library;
static __typeof__(&SherpaOnnxCreateOnlineRecognizer) create_recognizer;
static __typeof__(&SherpaOnnxDestroyOnlineRecognizer) destroy_recognizer;
static __typeof__(&SherpaOnnxCreateOnlineStream) create_stream;
static __typeof__(&SherpaOnnxDestroyOnlineStream) destroy_stream;
static __typeof__(&SherpaOnnxOnlineStreamAcceptWaveform) accept_waveform;
static __typeof__(&SherpaOnnxIsOnlineStreamReady) is_ready;
static __typeof__(&SherpaOnnxDecodeOnlineStream) decode_stream;
static __typeof__(&SherpaOnnxGetOnlineStreamResult) get_result;
static __typeof__(&SherpaOnnxDestroyOnlineRecognizerResult) destroy_result;
static __typeof__(&SherpaOnnxOnlineStreamReset) reset_stream;
static __typeof__(&SherpaOnnxOnlineStreamIsEndpoint) is_endpoint;
static __typeof__(&SherpaOnnxOnlineStreamInputFinished) input_finished;

static int find(void **slot, const char *name, char *error, int error_size) {
    *slot = dlsym(library, name);
    if (*slot) return 1;
    snprintf(error, (size_t)error_size, "missing %s", name);
    return 0;
}

int tailscode_sherpa_load(const char *library_path, char *error, int error_size) {
    if (library) return 1;
    void *opened = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!opened) {
        const char *reason = dlerror();
        snprintf(error, (size_t)error_size, "%s", reason ? reason : "dlopen failed");
        return 0;
    }
    library = opened;
    int ok = find((void **)&create_recognizer, "SherpaOnnxCreateOnlineRecognizer", error, error_size)
        && find((void **)&destroy_recognizer, "SherpaOnnxDestroyOnlineRecognizer", error, error_size)
        && find((void **)&create_stream, "SherpaOnnxCreateOnlineStream", error, error_size)
        && find((void **)&destroy_stream, "SherpaOnnxDestroyOnlineStream", error, error_size)
        && find((void **)&accept_waveform, "SherpaOnnxOnlineStreamAcceptWaveform", error, error_size)
        && find((void **)&is_ready, "SherpaOnnxIsOnlineStreamReady", error, error_size)
        && find((void **)&decode_stream, "SherpaOnnxDecodeOnlineStream", error, error_size)
        && find((void **)&get_result, "SherpaOnnxGetOnlineStreamResult", error, error_size)
        && find((void **)&destroy_result, "SherpaOnnxDestroyOnlineRecognizerResult", error, error_size)
        && find((void **)&reset_stream, "SherpaOnnxOnlineStreamReset", error, error_size)
        && find((void **)&is_endpoint, "SherpaOnnxOnlineStreamIsEndpoint", error, error_size)
        && find((void **)&input_finished, "SherpaOnnxOnlineStreamInputFinished", error, error_size);
    if (!ok) {
        dlclose(library);
        library = NULL;
    }
    return ok;
}

void *tailscode_sherpa_recognizer(
    const char *encoder, const char *decoder, const char *joiner, const char *tokens, int threads,
    float trailing_silence) {
    if (!library) return NULL;
    SherpaOnnxOnlineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = encoder;
    config.model_config.transducer.decoder = decoder;
    config.model_config.transducer.joiner = joiner;
    config.model_config.tokens = tokens;
    config.model_config.num_threads = threads;
    config.model_config.provider = "cpu";
    config.decoding_method = "greedy_search";
    config.enable_endpoint = 1;
    config.rule1_min_trailing_silence = 2.4f;
    config.rule2_min_trailing_silence = trailing_silence;
    config.rule3_min_utterance_length = 30.0f;
    return (void *)create_recognizer(&config);
}

void tailscode_sherpa_free_recognizer(void *recognizer) {
    if (library && recognizer) destroy_recognizer(recognizer);
}

void *tailscode_sherpa_stream(void *recognizer) {
    if (!library || !recognizer) return NULL;
    return (void *)create_stream(recognizer);
}

void tailscode_sherpa_free_stream(void *stream) {
    if (library && stream) destroy_stream(stream);
}

static void copy_text(void *recognizer, void *stream, char *out, int out_size) {
    const SherpaOnnxOnlineRecognizerResult *result = get_result(recognizer, stream);
    if (!result) {
        out[0] = 0;
        return;
    }
    snprintf(out, (size_t)out_size, "%s", result->text ? result->text : "");
    destroy_result(result);
}

int tailscode_sherpa_feed(
    void *recognizer, void *stream, int sample_rate, const float *samples, int count, char *out,
    int out_size) {
    if (!library || !recognizer || !stream) {
        out[0] = 0;
        return 0;
    }
    if (count > 0) accept_waveform(stream, sample_rate, samples, count);
    while (is_ready(recognizer, stream)) decode_stream(recognizer, stream);
    copy_text(recognizer, stream, out, out_size);
    if (!is_endpoint(recognizer, stream)) return 0;
    reset_stream(recognizer, stream);
    return 1;
}

void tailscode_sherpa_finish(void *recognizer, void *stream, int sample_rate, char *out, int out_size) {
    if (!library || !recognizer || !stream) {
        out[0] = 0;
        return;
    }
    int padding = sample_rate / 2;
    float *silence = calloc((size_t)padding, sizeof(float));
    if (silence) {
        accept_waveform(stream, sample_rate, silence, padding);
        free(silence);
    }
    input_finished(stream);
    while (is_ready(recognizer, stream)) decode_stream(recognizer, stream);
    copy_text(recognizer, stream, out, out_size);
}
