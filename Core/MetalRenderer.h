// The game's picture drawn on the GPU (Metal) instead of upstream's CPU
// rasterizer and tilemap drawing: a port of upstream's desktop hardware
// renderer (src/app/gpu/gpu_renderer.cpp, SDL_GPU) to Metal, with its shaders
// (m2.hlsl, as upstream's build turns it into MSL in shaders_gen.h).
//
// The video must be in external-3D desktop mode (Video::set_external_3d(true,
// true)), so it hands over the polygons, tilemap pixmaps and registers instead
// of drawing them. Frames are drawn at the screen's size (the original 496 x
// 384, or wider in widescreen) times `scale` (the internal resolution), and in
// stereo twice, one picture per eye, stacked (left on top), into shared
// buffers of 0xAARRGGBB words.
#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace rt {
class Video;
}

class MetalRenderer {
public:
    MetalRenderer();
    ~MetalRenderer();

    // False, with error(), if Metal or the shaders are not usable.
    bool init();
    const std::string &error() const;

    struct Frame {
        void *buffer = nullptr; // id<MTLBuffer>, owned by the renderer (one of a few, reused in turn)
        int width = 0, height = 0; // in pixels: the screen's width * scale, 384 * scale (twice that in stereo) high
        int pitch = 0;             // pixels from one row to the next (width, padded to Metal's alignment)
        int scale = 1;
        bool stereo = false;
    };

    // Draws the frame `video` holds. Stereo: each eye's 3D moved by its
    // depth, `depth` pixels (of the original screen) at most apart.
    // Returns the finished frame (the GPU has completed it).
    Frame render(const rt::Video &video, int scale, bool stereo, float depth);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
