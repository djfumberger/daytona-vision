#include "DaytonaCore.h"

#include "MetalRenderer.h"

#include "runtime/game_loop.h"
#include "runtime/raster.h"
#include "runtime/rom_import.h"
#include "runtime/video.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

void copy_message(const std::string &s, char *out, int len) {
    if (!out || len <= 0) return;
    std::snprintf(out, size_t(len), "%s", s.c_str());
}

template <typename C> void load_file(const std::string &path, C &into) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return;
    std::vector<uint8_t> v{std::istreambuf_iterator<char>(f), {}};
    if (v.size() == into.size()) std::copy(v.begin(), v.end(), into.begin());
}

template <typename C> void save_file(const std::string &path, const C &from) {
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    f.write(reinterpret_cast<const char *>(from.data()), std::streamsize(from.size()));
}

// Single producer (game thread), single consumer (one audio render callback).
class Ring {
public:
    static constexpr size_t kSize = 1 << 15; // ~0.68 s at 48 kHz

    size_t available() const {
        return w_.load(std::memory_order_acquire) - r_.load(std::memory_order_acquire);
    }

    void push(float v) {
        const size_t w = w_.load(std::memory_order_relaxed);
        if (w - r_.load(std::memory_order_acquire) >= kSize) return; // full: drop
        buf_[w & (kSize - 1)] = v;
        w_.store(w + 1, std::memory_order_release);
    }

    void read(float *out, int n) {
        size_t r = r_.load(std::memory_order_relaxed);
        const size_t w = w_.load(std::memory_order_acquire);
        int i = 0;
        for (; i < n && r != w; ++i, ++r) out[i] = buf_[r & (kSize - 1)];
        for (; i < n; ++i) out[i] = 0.f;
        r_.store(r, std::memory_order_release);
    }

    void skip(size_t n) {
        const size_t w = w_.load(std::memory_order_acquire);
        const size_t r = r_.load(std::memory_order_relaxed);
        r_.store(r + std::min(n, w - r), std::memory_order_release);
    }

private:
    std::array<float, kSize> buf_{};
    std::atomic<size_t> w_{0}, r_{0};
};

// Linear interpolation from one chip's rate to the output rate, keeping its
// position across calls. Input is interleaved stereo.
class Resampler {
public:
    void run(const std::vector<float> &in, double step, std::vector<float> &l, std::vector<float> &r) {
        const size_t n = in.size() / 2;
        if (n == 0) return;
        auto at = [&](size_t i, int ch) { return i == 0 ? prev_[ch] : in[(i - 1) * 2 + ch]; };

        while (pos_ < double(n)) {
            const size_t i = size_t(pos_);
            const float f = float(pos_ - double(i));
            l.push_back(at(i, 0) + (at(i + 1, 0) - at(i, 0)) * f);
            r.push_back(at(i, 1) + (at(i + 1, 1) - at(i, 1)) * f);
            pos_ += step;
        }

        pos_ -= double(n);
        prev_[0] = in[(n - 1) * 2];
        prev_[1] = in[(n - 1) * 2 + 1];
    }

private:
    double pos_ = 0;
    float prev_[2] = {0, 0};
};

} // namespace

// ---------------------------------------------------------------- stereo

// The 3D layer for two eyes. The geometrizer's polygons reach the rasterizer
// in view space, a vertex at screen x = centre + x / z; moving its x by
// s * z moves it s pixels on the screen. Each eye moves every vertex by half
// the parallax for its own depth: none at the convergence depth (a little
// in front of most of the scene, which so sits behind the screen), up to
// `depth` pixels far away, and a little the other way nearer. Rasterized
// with upstream's own CPU rasterizer, both eyes at once, then put over the
// game's composed frame: where the HUD's front layers covered the 3D they
// stay; elsewhere this eye's 3D replaces the game's, and where the 3D moved
// off, the nearest uncovered pixel of the row fills in.
class Stereo {
public:
    // The game's composed frame (w x H) in, both eyes stacked (left on top)
    // out.
    void make(rt::Video &video, const uint32_t *screen, int w, float depth, std::vector<uint32_t> &out) {
        constexpr int H = rt::GameLoop::kHeight;
        out.resize(size_t(w) * H * 2);
        const std::vector<rt::GeoPoly> &polys = video.gpu_polys();

        if (polys.empty()) { // no 3D: the same picture for both
            std::copy_n(screen, size_t(w) * H, out.data());
            std::copy_n(screen, size_t(w) * H, out.data() + size_t(w) * H);
            valid_ = false;
            return;
        }

        if (video.rendered_now() || !valid_ || depth != last_depth_) {
            render_eyes(video, polys, depth);
            valid_ = true;
            last_depth_ = depth;
        }

        const rt::Raster &mono = video.raster();
        for (int eye = 0; eye < 2; ++eye)
            compose(screen, w, mono.pixels(), mono.stride(), eye_[eye].pixels(), eye_[eye].stride(),
                    out.data() + size_t(eye) * size_t(w) * H);
    }

private:
    rt::Raster eye_[2];
    std::vector<rt::GeoPoly> polys_[2];
    std::vector<float> depths_;
    float convergence_ = 0;
    float last_depth_ = -1;
    bool valid_ = false;

    void render_eyes(rt::Video &video, const std::vector<rt::GeoPoly> &polys, float depth) {
        // Convergence: a quarter of the way into the scene's depths, eased.
        depths_.clear();
        for (const auto &p : polys)
            for (int i = 0; i < p.num_vertices; ++i)
                if (p.v[i].p[0] > 0) depths_.push_back(p.v[i].p[0]);
        if (!depths_.empty()) {
            auto q = depths_.begin() + long(depths_.size() / 4);
            std::nth_element(depths_.begin(), q, depths_.end());
            convergence_ = convergence_ > 0 ? convergence_ + (*q - convergence_) * 0.1f : *q;
        }

        // The race HUD's condition panel (overlay polygons) stays on the screen.
        const bool hud = eye_[0].find_race_hud(polys, video.crtc_x(), video.crtc_y());
        const uint16_t hud_z = eye_[0].hud_z();

        for (int eye = 0; eye < 2; ++eye) {
            const float side = eye == 0 ? -0.5f : 0.5f;
            auto &out = polys_[eye];
            out = polys;
            for (auto &p : out) {
                if (hud && p.z == hud_z) continue;
                for (int i = 0; i < p.num_vertices; ++i) {
                    rt::GeoVertex &v = p.v[i];
                    const float z = v.p[0];
                    if (z <= 0 || convergence_ <= 0) continue;
                    const float parallax = std::clamp(depth * (1.f - convergence_ / z), -0.5f * depth, depth);
                    v.x += side * parallax * z;
                }
            }
        }

        const rt::VideoMem &mem = video.gpu_mem();
        const int windows = video.gpu_windows();
        auto draw = [&](int eye) {
            eye_[eye].render(polys_[eye], windows, mem, video.crtc_x(), video.crtc_y(), video.render_x(),
                             video.render_y(), 0, rt::Video::W - 1, 0, rt::Video::H - 1);
        };

        std::thread right(draw, 1);
        draw(0);
        right.join();
    }

    static void compose(const uint32_t *screen, int w, const uint32_t *mono, int mono_stride, const uint32_t *eye,
                        int eye_stride, uint32_t *out) {
        constexpr int kSearch = 48; // how far along the row to look for what the 3D uncovered

        for (int y = 0; y < rt::GameLoop::kHeight; ++y) {
            const uint32_t *s = screen + size_t(y) * size_t(w);
            const uint32_t *m = mono + size_t(y) * size_t(mono_stride);
            const uint32_t *e = eye + size_t(y) * size_t(eye_stride);
            uint32_t *o = out + size_t(y) * size_t(w);
            for (int x = 0; x < w; ++x) {
                if (m[x] && s[x] != m[x]) o[x] = s[x]; // a front layer (the HUD) over the 3D
                else if (e[x]) o[x] = e[x];
                else if (m[x]) { // uncovered: what is beside the 3D on this row
                    uint32_t fill = s[x];
                    for (int d = 1; d <= kSearch; ++d) {
                        if (x - d >= 0 && !m[x - d]) { fill = s[x - d]; break; }
                        if (x + d < w && !m[x + d]) { fill = s[x + d]; break; }
                    }
                    o[x] = fill;
                } else o[x] = s[x];
            }
        }
    }
};

struct DTGame {
    std::unique_ptr<rt::GameLoop> loop;
    std::string save_dir;
    std::thread thread;
    std::atomic<bool> running{true}, paused{false};
    std::atomic<float> volume{1.f};

    std::mutex input_mu;
    DTInput input{0.f, 0.f, 0.f, 1, 0};

    std::mutex frame_mu;
    std::vector<uint32_t> frame;
    int frame_width = rt::GameLoop::kWidth;
    int frame_height = rt::GameLoop::kHeight;
    uint64_t frame_seq = 0;

    // Stereo (dt_set_stereo): the 3D drawn again for each eye.
    std::atomic<bool> stereo{false};
    std::atomic<float> stereo_depth{12.f};
    Stereo eyes;
    std::vector<uint32_t> stereo_frame;

    // Widescreen (dt_set_aspect): asked for, and what the game was last set to.
    std::atomic<float> aspect{0.f};
    float aspect_set = 0.f;

    // The GPU renderer (dt_set_renderer): 0 the CPU, 1-3 Metal at that scale.
    std::atomic<int> renderer_scale{0};
    std::unique_ptr<MetalRenderer> metal;
    bool metal_failed = false;

    // Its frames (under frame_mu), apart from the CPU's.
    MetalRenderer::Frame gpu_frame;
    uint64_t gpu_seq = 0;

    Ring ring[2];
    Resampler fm_rs, pcm_rs;
    std::vector<float> fm_l, fm_r, pcm_l, pcm_r; // resampled, waiting for the other stream

    std::atomic<double> fps{0};
    std::atomic<float> game_ms{0}, draw_ms{0}; // dt_frame_times

    std::mutex error_mu;
    std::string error;

    std::string path(const char *name) const { return save_dir + "/" + name; }

    void save() {
        if (save_dir.empty()) return;
        save_file(path("ioboard_eeprom.bin"), loop->board().io().eeprom);
        save_file(path("backup_ram.bin"), loop->board().backup_ram());
        loop->board().io().eeprom_dirty = false;
    }

    void run();
    void pump_audio();
    void publish_cpu_frame();
};

static rt::Inputs to_arcade(const DTInput &d) {
    rt::Inputs in;
    in.steer = uint8_t(std::lround(0x80 + std::clamp(d.steer, -1.f, 1.f) * 0x60));
    in.accel = uint8_t(std::lround(0x20 + std::clamp(d.accel, 0.f, 1.f) * 0xc0));
    in.brake = uint8_t(std::lround(0x20 + std::clamp(d.brake, 0.f, 1.f) * 0xc0));

    static const uint8_t gearvalue[5] = {0, 2, 1, 6, 5}; // MAME daytona_gearbox_r: neutral, 1-4
    const int gear = std::clamp(int(d.gear), 0, 4);
    in.in1 = uint8_t((in.in1 & ~0x70) | (gearvalue[gear] << 4));

    auto low = [&](uint8_t &port, uint8_t bit, uint32_t button) {
        if (d.buttons & button) port &= uint8_t(~bit);
    };
    low(in.in0, 0x01, DT_BTN_COIN);
    low(in.in0, 0x04, DT_BTN_TEST);
    low(in.in0, 0x08, DT_BTN_SERVICE);
    low(in.in0, 0x10, DT_BTN_START);
    low(in.in0, 0x20, DT_BTN_VIEW1);
    low(in.in0, 0x40, DT_BTN_VIEW2);
    low(in.in0, 0x80, DT_BTN_VIEW3);
    low(in.in1, 0x01, DT_BTN_VIEW4);

    return in;
}

void DTGame::pump_audio() {
    snd::SoundBoard *sb = loop->sound();
    if (!sb) return;
    const std::vector<float> fm = sb->take_fm(), pcm = sb->take_pcm();

    // Hold the queue near kTarget: the game thread's clock and the audio
    // device's drift apart slowly, so trim the resampling by at most 0.5%.
    constexpr double kTarget = 0.06 * DT_AUDIO_RATE;
    const double queued = double(std::min(ring[0].available(), ring[1].available()));
    if (queued > kTarget * 4) { // a stall: drop the backlog
        const size_t excess = size_t(queued - kTarget);
        ring[0].skip(excess);
        ring[1].skip(excess);
    }

    const double trim = 1.0 + 0.005 * std::clamp((queued - kTarget) / kTarget, -1.0, 1.0);
    fm_rs.run(fm, sb->fm_rate() / DT_AUDIO_RATE * trim, fm_l, fm_r);
    pcm_rs.run(pcm, sb->pcm_rate() / DT_AUDIO_RATE * trim, pcm_l, pcm_r);

    const size_t n = std::min(fm_l.size(), pcm_l.size());
    const float gain = volume.load(std::memory_order_relaxed);
    for (size_t i = 0; i < n; ++i) {
        ring[0].push((fm_l[i] + pcm_l[i]) * gain);
        ring[1].push((fm_r[i] + pcm_r[i]) * gain);
    }

    fm_l.erase(fm_l.begin(), fm_l.begin() + long(n));
    fm_r.erase(fm_r.begin(), fm_r.begin() + long(n));
    pcm_l.erase(pcm_l.begin(), pcm_l.begin() + long(n));
    pcm_r.erase(pcm_r.begin(), pcm_r.begin() + long(n));
}

void DTGame::run() {
    const auto period =
        std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(1.0 / rt::GameLoop::kFrameHz));
    auto next = Clock::now();
    auto fps_start = next;
    int fps_frames = 0;

    try {
        while (running.load()) {
            if (paused.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                next = Clock::now();
                continue;
            }

            DTInput d;
            {
                std::lock_guard<std::mutex> lock(input_mu);
                d = input;
            }
            // The renderer: the GPU if asked for and it works (the video then
            // hands its layers and polygons over instead of drawing them).
            int scale = renderer_scale.load();
            if (scale > 0 && !metal && !metal_failed) {
                metal = std::make_unique<MetalRenderer>();
                if (!metal->init()) {
                    std::lock_guard<std::mutex> lock(error_mu);
                    error = "GPU renderer: " + metal->error();
                    metal.reset();
                    metal_failed = true;
                }
            }
            if (!metal) scale = 0;
            loop->board().video().set_external_3d(scale > 0, true);

            // Between frames: the screen widened (or back to the original).
            if (const float a = aspect.load(); a != aspect_set) {
                loop->set_aspect(a);
                aspect_set = a;
            }

            const auto frame_start = Clock::now();
            loop->run_frame(to_arcade(d));
            pump_audio();
            const auto ran = Clock::now();

            if (scale > 0) {
                const auto drawn = metal->render(loop->board().video(), scale, stereo.load(), stereo_depth.load());
                std::lock_guard<std::mutex> lock(frame_mu);
                gpu_frame = drawn;
                ++gpu_seq;
            } else {
                publish_cpu_frame();
            }
            {
                auto smooth = [](std::atomic<float> &into, Clock::duration d) {
                    const float ms = std::chrono::duration<float, std::milli>(d).count();
                    into.store(into.load() * 0.95f + ms * 0.05f);
                };
                smooth(game_ms, ran - frame_start);
                smooth(draw_ms, Clock::now() - ran);
            }
            if (loop->board().io().eeprom_dirty) save();

            ++fps_frames;
            const auto now = Clock::now();
            if (now - fps_start >= std::chrono::seconds(1)) {
                fps.store(fps_frames / std::chrono::duration<double>(now - fps_start).count());
                fps_frames = 0;
                fps_start = now;
            }

            next += period;
            if (now > next + period * 6) next = now; // fell far behind: don't sprint to catch up
            std::this_thread::sleep_until(next);
        }
    } catch (const std::exception &e) {
        std::lock_guard<std::mutex> lock(error_mu);
        error = e.what();
    }
}

// The CPU-drawn frame (one picture, or both eyes in stereo) for dt_copy_frame.
void DTGame::publish_cpu_frame() {
    const bool stereo_now = stereo.load() && loop->screen_width() == rt::Video::W;
    if (stereo_now)
        eyes.make(loop->board().video(), loop->screen().data(), rt::Video::W, stereo_depth.load(),
                  stereo_frame);
    {
        std::lock_guard<std::mutex> lock(frame_mu);
        if (stereo_now) {
            frame.swap(stereo_frame);
            frame_height = rt::GameLoop::kHeight * 2;
        } else {
            const auto &s = loop->screen();
            frame.assign(s.begin(), s.end());
            frame_height = rt::GameLoop::kHeight;
        }
        frame_width = loop->screen_width();
        ++frame_seq;
    }
}

extern "C" {

const char *dt_rom_set_name(void) { return rt::rom_set_name(); }

bool dt_check_rom(const char *rom_path, char *message, int message_len) {
    try {
        for (const auto &c : rt::check_rom_set(rom_path))
            if (!c.ok) {
                copy_message(c.file + ": " + c.problem, message, message_len);
                return false;
            }
        copy_message("All files verified.", message, message_len);
        return true;
    } catch (const std::exception &e) {
        copy_message(e.what(), message, message_len);
        return false;
    }
}

DTGame *dt_create(const char *rom_path, const char *save_dir, char *error, int error_len) {
    try {
        auto g = std::make_unique<DTGame>();
        g->save_dir = save_dir ? save_dir : "";
        g->loop = std::make_unique<rt::GameLoop>(rt::import_rom_set(rom_path));
        if (!g->save_dir.empty()) {
            load_file(g->path("ioboard_eeprom.bin"), g->loop->board().io().eeprom);
            load_file(g->path("backup_ram.bin"), g->loop->board().backup_ram());
        }

        g->frame.assign(size_t(rt::GameLoop::kWidth) * rt::GameLoop::kHeight, 0xff000000u);
        DTGame *raw = g.get();
        g->thread = std::thread([raw] {
            pthread_setname_np("daytona.game");
            raw->run();
        });
        return g.release();
    } catch (const std::exception &e) {
        copy_message(e.what(), error, error_len);
        return nullptr;
    }
}

void dt_destroy(DTGame *game) {
    if (!game) return;
    game->running.store(false);
    if (game->thread.joinable()) game->thread.join();
    try {
        game->save();
    } catch (...) {
    }
    delete game;
}

void dt_set_paused(DTGame *game, bool paused) { game->paused.store(paused); }

void dt_set_input(DTGame *game, const DTInput *input) {
    std::lock_guard<std::mutex> lock(game->input_mu);
    game->input = *input;
}

void dt_set_volume(DTGame *game, float volume) { game->volume.store(std::clamp(volume, 0.f, 1.f)); }

void dt_set_aspect(DTGame *game, float aspect) { game->aspect.store(std::max(aspect, 0.f)); }

void dt_set_renderer(DTGame *game, int scale) { game->renderer_scale.store(std::clamp(scale, 0, 3)); }

bool dt_gpu_frame(DTGame *game, uint64_t *seq, void **buffer, int *width, int *height, int *pitch, int *scale) {
    std::lock_guard<std::mutex> lock(game->frame_mu);
    if (game->gpu_seq == 0 || game->gpu_seq == *seq || !game->gpu_frame.buffer) return false;

    *seq = game->gpu_seq;
    *buffer = game->gpu_frame.buffer;
    *width = game->gpu_frame.width;
    *height = game->gpu_frame.height;
    *pitch = game->gpu_frame.pitch;
    *scale = game->gpu_frame.scale;
    return true;
}

void dt_set_stereo(DTGame *game, bool on, float depth) {
    game->stereo.store(on);
    game->stereo_depth.store(std::clamp(depth, 0.f, 64.f));
}

bool dt_copy_frame(DTGame *game, void *dst, int dst_bytes, uint64_t *seq, int *width, int *height) {
    std::lock_guard<std::mutex> lock(game->frame_mu);
    if (game->frame_seq == *seq) return false;
    const size_t bytes = game->frame.size() * 4;
    if (size_t(dst_bytes) < bytes) return false;
    std::memcpy(dst, game->frame.data(), bytes);
    *seq = game->frame_seq;
    *width = game->frame_width;
    *height = game->frame_height;
    return true;
}

void dt_audio_read(DTGame *game, int channel, float *out, int frames) {
    game->ring[channel & 1].read(out, frames);
}

double dt_fps(DTGame *game) { return game->fps.load(); }

void dt_frame_times(DTGame *game, float *game_ms, float *draw_ms) {
    *game_ms = game->game_ms.load();
    *draw_ms = game->draw_ms.load();
}

bool dt_error(DTGame *game, char *error, int error_len) {
    std::lock_guard<std::mutex> lock(game->error_mu);
    if (game->error.empty()) return false;
    copy_message(game->error, error, error_len);
    return true;
}

} // extern "C"
