#ifdef __APPLE__

#include "feral_core_audio.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <vector>

namespace {

/// Where one device channel lives: which buffer of the list, and which channel inside it.
struct Slot {
    float *data = nullptr;
    int stride = 0; // channels in that buffer: 1 for a mono (non-interleaved) buffer
};

/// Finds every device channel in a buffer list. Returns the number of frames, or -1 when a buffer
/// is not a whole number of float frames or the buffers disagree.
int mapChannels(const AudioBufferList *list, Slot *slots, int &channels) {
    channels = 0;
    int frames = 0;
    if (!list) return 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer &buffer = list->mBuffers[b];
        const int n = static_cast<int>(buffer.mNumberChannels);
        if (n == 0) continue;
        const size_t frameBytes = sizeof(float) * static_cast<size_t>(n);
        if (buffer.mDataByteSize % frameBytes != 0) return -1;
        const int f = static_cast<int>(buffer.mDataByteSize / frameBytes);
        if (frames == 0) frames = f;
        else if (f != frames) return -1;
        for (int c = 0; c < n && channels < FERAL_IO_MAX_DEVICE_CHANNELS; ++c, ++channels) {
            slots[channels].data = buffer.mData ? static_cast<float *>(buffer.mData) + c : nullptr;
            slots[channels].stride = n;
        }
    }
    return frames;
}

}

struct feral_io {
    feral_core *core;
    std::vector<int> inputMap, outputMap;
    // Everything below is sized here, before the device starts, so the IOProc never allocates.
    std::vector<Slot> inputSlots, outputSlots;
    std::vector<float> inputScratch, outputScratch; // one FERAL_IO_MAX_FRAMES block per engine channel
    std::vector<const float *> inputs;
    std::vector<float *> outputs;
    std::atomic<uint64_t> skipped{0};
};

extern "C" {

feral_io *feral_io_create(feral_core *core, const int *input_map, int num_inputs,
                          const int *output_map, int num_outputs) {
    auto *io = new feral_io;
    io->core = core;
    io->inputMap.assign(input_map, input_map + std::max(num_inputs, 0));
    io->outputMap.assign(output_map, output_map + std::max(num_outputs, 0));
    io->inputSlots.resize(FERAL_IO_MAX_DEVICE_CHANNELS);
    io->outputSlots.resize(FERAL_IO_MAX_DEVICE_CHANNELS);
    io->inputScratch.assign(static_cast<size_t>(io->inputMap.size()) * FERAL_IO_MAX_FRAMES, 0.0f);
    io->outputScratch.assign(static_cast<size_t>(io->outputMap.size()) * FERAL_IO_MAX_FRAMES, 0.0f);
    io->inputs.resize(io->inputMap.size());
    io->outputs.resize(io->outputMap.size());
    return io;
}

void feral_io_destroy(feral_io *io) { delete io; }

uint64_t feral_io_skipped_buffers(const feral_io *io) { return io->skipped.load(std::memory_order_relaxed); }

OSStatus feral_io_proc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *input_data,
                       const AudioTimeStamp *, AudioBufferList *output_data, const AudioTimeStamp *,
                       void *client_data) {
    auto *io = static_cast<feral_io *>(client_data);

    // Every device output starts silent, so outputs the engine does not use stay quiet.
    if (output_data) {
        for (UInt32 b = 0; b < output_data->mNumberBuffers; ++b)
            if (output_data->mBuffers[b].mData)
                std::memset(output_data->mBuffers[b].mData, 0, output_data->mBuffers[b].mDataByteSize);
    }

    int deviceInputs = 0, deviceOutputs = 0;
    const int inFrames = mapChannels(input_data, io->inputSlots.data(), deviceInputs);
    const int outFrames = mapChannels(output_data, io->outputSlots.data(), deviceOutputs);
    const int frames = outFrames > 0 ? outFrames : inFrames;
    if (inFrames < 0 || outFrames < 0 || frames > FERAL_IO_MAX_FRAMES || (inFrames > 0 && inFrames != frames)) {
        io->skipped.fetch_add(1, std::memory_order_relaxed);
        return noErr;
    }
    if (frames == 0) return noErr;

    // Inputs: point straight at mono buffers, copy channels out of interleaved ones.
    for (size_t k = 0; k < io->inputMap.size(); ++k) {
        const int c = io->inputMap[k];
        io->inputs[k] = nullptr;
        if (c < 0 || c >= deviceInputs || !io->inputSlots[c].data) continue;
        const Slot &s = io->inputSlots[c];
        if (s.stride == 1) {
            io->inputs[k] = s.data;
        } else {
            float *dst = io->inputScratch.data() + k * FERAL_IO_MAX_FRAMES;
            for (int n = 0; n < frames; ++n) dst[n] = s.data[n * s.stride];
            io->inputs[k] = dst;
        }
    }

    // Outputs: render straight into mono buffers, through scratch into interleaved ones.
    for (size_t k = 0; k < io->outputMap.size(); ++k) {
        const int c = io->outputMap[k];
        const bool direct = c >= 0 && c < deviceOutputs && io->outputSlots[c].data && io->outputSlots[c].stride == 1;
        io->outputs[k] = direct ? io->outputSlots[c].data : io->outputScratch.data() + k * FERAL_IO_MAX_FRAMES;
    }

    feral_core_render(io->core, io->inputs.data(), static_cast<int>(io->inputs.size()),
                      io->outputs.data(), static_cast<int>(io->outputs.size()), frames);

    for (size_t k = 0; k < io->outputMap.size(); ++k) {
        const int c = io->outputMap[k];
        if (c < 0 || c >= deviceOutputs || !io->outputSlots[c].data) continue;
        const Slot &s = io->outputSlots[c];
        if (s.stride == 1) continue;
        const float *src = io->outputs[k];
        for (int n = 0; n < frames; ++n) s.data[n * s.stride] = src[n];
    }
    return noErr;
}

AudioDeviceIOProc feral_io_proc_pointer(void) { return feral_io_proc; }

}

#endif
