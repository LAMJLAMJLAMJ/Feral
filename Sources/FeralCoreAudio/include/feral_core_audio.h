// The Core Audio IOProc. It runs on the device's real-time thread, maps the device's buffers to the
// engine's channels and calls feral_core_render. macOS only: elsewhere this header declares nothing.
#ifndef FERAL_CORE_AUDIO_H
#define FERAL_CORE_AUDIO_H

#ifdef __APPLE__

#include <CoreAudio/CoreAudio.h>
#include "feral_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/// The largest buffer the IOProc handles, in frames. Live use runs 32 to 256.
#define FERAL_IO_MAX_FRAMES 4096
/// The most channels a device may have on one side for the channel maps.
#define FERAL_IO_MAX_DEVICE_CHANNELS 1024

typedef struct feral_io feral_io;

/// Creates the IOProc's context. input_map[k] is the device input channel (from 0) that feeds
/// engine input k, output_map[k] the device output channel that engine output k plays on; -1 leaves
/// that engine channel unconnected. Device channels count across all of the device's streams, in
/// order. Device outputs no engine output plays on are silent. Allocates; call before starting.
feral_io *feral_io_create(feral_core *core, const int *input_map, int num_inputs,
                          const int *output_map, int num_outputs);
void feral_io_destroy(feral_io *io);

/// Buffers skipped because they were larger than FERAL_IO_MAX_FRAMES or not 32-bit float.
uint64_t feral_io_skipped_buffers(const feral_io *io);

/// The IOProc to register with AudioDeviceCreateIOProcID, with a feral_io as its client data.
OSStatus feral_io_proc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input_data,
                       const AudioTimeStamp *input_time, AudioBufferList *output_data,
                       const AudioTimeStamp *output_time, void *client_data);

/// feral_io_proc as the AudioDeviceIOProc type, so Swift can pass it without converting.
AudioDeviceIOProc feral_io_proc_pointer(void);

#ifdef __cplusplus
}
#endif

#endif
#endif
