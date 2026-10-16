// DaytonaCore: a small C API over the upstream recompiled game
// (rt::GameLoop), for the visionOS app. The game runs on its own thread at
// the arcade's frame rate; the host sets inputs, copies the latest frame and
// pulls audio from whichever thread it likes.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DTGame DTGame;

// Arcade buttons (DTInput.buttons).
enum {
    DT_BTN_COIN = 1u << 0,
    DT_BTN_START = 1u << 1,
    DT_BTN_TEST = 1u << 2,
    DT_BTN_SERVICE = 1u << 3,
    DT_BTN_VIEW1 = 1u << 4, // red
    DT_BTN_VIEW2 = 1u << 5, // blue
    DT_BTN_VIEW3 = 1u << 6, // yellow
    DT_BTN_VIEW4 = 1u << 7, // green
};

typedef struct {
    float steer;      // -1 (full left) .. +1 (full right)
    float accel;      // 0..1
    float brake;      // 0..1
    int32_t gear;     // 1..4 (0: neutral)
    uint32_t buttons; // DT_BTN_*
} DTInput;

enum { DT_SCREEN_HEIGHT = 384, DT_SCREEN_MAX_WIDTH = 1024 };
enum { DT_AUDIO_RATE = 48000 };

// The MAME set this build was recompiled from ("daytona" or "daytona93").
const char *dt_rom_set_name(void);

// Checks every file of the ROM set. Returns true when all are present and
// correct; otherwise `message` names the first problem.
bool dt_check_rom(const char *rom_path, char *message, int message_len);

// Loads the ROM set and starts the game thread. save_dir keeps the settings
// EEPROM and backup RAM. NULL on failure, with `error` filled in.
DTGame *dt_create(const char *rom_path, const char *save_dir, char *error, int error_len);

// Stops the game, saves, and frees it.
void dt_destroy(DTGame *game);

void dt_set_paused(DTGame *game, bool paused);
void dt_set_input(DTGame *game, const DTInput *input);
void dt_set_volume(DTGame *game, float volume); // 0..1

// Stereo 3D: the 3D drawn for each eye, the frame then both stacked (left on
// top, *height twice DT_SCREEN_HEIGHT). depth: the most the eyes' pictures
// differ, in screen pixels (about 12 is gentle).
void dt_set_stereo(DTGame *game, bool on, float depth);

// Widescreen (the flat screen window): the picture widened to `aspect`
// (width / height, square pixels) by showing more of the scene at the sides;
// 0, or anything at most 496:384, is the original screen. Frames are then
// wider (dt_copy_frame, dt_gpu_frame); the race HUD stays where it was.
void dt_set_aspect(DTGame *game, float aspect);

// Who draws the picture: 0 the CPU (upstream's reference rasterizer), 1-3
// the GPU (Metal) at that multiple of the original 496 x 384.
void dt_set_renderer(DTGame *game, int scale);

// The latest frame the GPU drew, when it draws them: an id<MTLBuffer> of
// 0xAARRGGBB words, width x height (both eyes stacked in stereo), at `scale`
// times the original; *pitch pixels from one row to the next (at least the
// width). Valid until a few frames later (the renderer reuses
// its buffers in turn). True when there is one newer than *seq.
bool dt_gpu_frame(DTGame *game, uint64_t *seq, void **buffer, int *width, int *height, int *pitch, int *scale);

// The latest composed frame (0xAARRGGBB words, i.e. BGRA8 bytes), copied
// into dst when its sequence number differs from *seq. Returns true and
// updates *seq, *width and *height when a new frame was copied.
bool dt_copy_frame(DTGame *game, void *dst, int dst_bytes, uint64_t *seq, int *width, int *height);

// Pulls up to `frames` samples of one channel (0 left, 1 right) at
// DT_AUDIO_RATE. Missing samples are written as silence. Real-time safe.
void dt_audio_read(DTGame *game, int channel, float *out, int frames);

// Frames per second the game thread achieved over the last second.
double dt_fps(DTGame *game);

// Where a frame's time goes on the game thread, in milliseconds (smoothed):
// running the game (the CPU's 3D included, with the CPU renderer), and
// drawing it (the GPU renderer's frame, or publishing the CPU's).
void dt_frame_times(DTGame *game, float *game_ms, float *draw_ms);

// The cabinet's lamps as the game last set them: the I/O board's output port
// (dual-port RAM byte 0x0F, MAME's Daytona layout), read after each frame.
enum {
    DT_COIN_COUNTER1 = 1u << 0, DT_COIN_COUNTER2 = 1u << 1,
    DT_LAMP_START = 1u << 2,
    DT_LAMP_VIEW1 = 1u << 3, DT_LAMP_VIEW2 = 1u << 4, DT_LAMP_VIEW3 = 1u << 5, DT_LAMP_VIEW4 = 1u << 6,
    DT_LAMP_LEADER = 1u << 7,
};
uint32_t dt_lamps(DTGame *game);

// Non-empty when the game thread stopped on an error.
bool dt_error(DTGame *game, char *error, int error_len);

#ifdef __cplusplus
}
#endif
