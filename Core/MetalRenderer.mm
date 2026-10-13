// The Metal port of upstream's hardware renderer (src/app/gpu/gpu_renderer.cpp):
// the same polygon and tilemap preparation, drawn with Metal instead of
// SDL_GPU, plus stereo. See MetalRenderer.h.
//
// The ported parts: Copyright (c) 2026, Ben Templeman and contributors.
// BSD-3-Clause, see upstream/LICENSE. The rest: GPL-3.0-or-later, as this
// project (LICENSE).
#import <Metal/Metal.h>

#include "MetalRenderer.h"

#include "app/gpu/shaders_gen.h"
#include "runtime/raster.h"
#include "runtime/video.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <vector>

namespace {

inline uint16_t le16(const uint8_t *base, uint32_t index) { return uint16_t(base[index * 2] | base[index * 2 + 1] << 8); }

constexpr uint32_t kSheetWords = 0x80000;             // one texture sheet (VideoMem tex0, tex1)
constexpr uint32_t kTexramBytes = kSheetWords * 4 * 2; // both sheets
constexpr uint32_t kLumaBytes = 0x20000;              // luma RAM (one entry per dword)
constexpr uint32_t kXlatEntries = 0x6000;             // colour translation (0xc000 bytes of u16)
constexpr uint32_t kTilePixBytes = 4 * 512 * 512 * 2; // the four tilemap pixmaps, a u16 per pixel
constexpr uint32_t kTileHeader = 16;                  // m2.hlsl tiledata: header, pens, tile words
constexpr uint32_t kTileDataWords = kTileHeader + rt::Video::kGpuPens + rt::Video::kGpuTileWords / 2;

constexpr int kW = rt::Video::W, kH = rt::Video::H;
constexpr int kTargets = 3; // frames in turn: one being drawn, the others being shown

// Vertex buffers sit after the shaders' uniforms (buffer 0).
constexpr NSUInteger kVertexBufferIndex = 1;

struct PolyVertex {
    float x, y, depth;
    float ooz, uoz, voz; // render_one's p[0..2]: 1/z, u/z, v/z
    float r, g, b, a;
    uint32_t info[4], more[2]; // texture state (m2.hlsl PolyIn)
};

struct QuadVertex {
    float x, y, u, v;
};

struct Batch { // consecutive polygons sharing one clip rectangle
    uint32_t first, count;
    MTLScissorRect clip;
};

} // namespace

struct MetalRenderer::Impl {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> polyPipe, backPipe, frontPipe;
    id<MTLDepthStencilState> depthOrder, depthOff;

    // texture RAM, luma RAM, colour translation; tilemap pixmaps, header + pens + tile words
    id<MTLBuffer> texram, luma, xlat, tilepix, tiledata;
    id<MTLBuffer> vertices;
    id<MTLTexture> depth;

    id<MTLBuffer> targets[kTargets];
    int next = 0;

    // For each target: its eyes as textures, for the size (in pixels) they were made at.
    id<MTLTexture> eyeTextures[kTargets][2];
    NSUInteger eyeTexturesWidth[kTargets] = {}, eyeTexturesHeight[kTargets] = {};

    uint64_t texramGeneration = ~0ull;
    uint64_t tileInstance = 0, tileGeneration = 0;
    uint8_t gamma[256];

    std::vector<PolyVertex> verts;
    std::vector<bool> shifts; // per vertex: moved for the eyes (not the race HUD's overlay)
    std::vector<Batch> batches;
    std::vector<size_t> order;
    std::vector<uint32_t> xlatTable;
    std::vector<float> depths;
    rt::Raster hudFinder; // finds the race HUD's overlay polygons, as the CPU rasterizer does
    float convergence = 0;

    std::string error;

    id<MTLFunction> function(const char *msl) {
        NSError *err = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@(msl) options:nil error:&err];
        if (!library) {
            error = std::string("Metal shader: ") + err.localizedDescription.UTF8String;
            return nil;
        }
        return [library newFunctionWithName:@"main0"];
    }

    id<MTLRenderPipelineState> pipeline(id<MTLFunction> vs, id<MTLFunction> fs, MTLVertexDescriptor *layout) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = vs;
        d.fragmentFunction = fs;
        d.vertexDescriptor = layout;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; // the frames' 0xAARRGGBB words
        d.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;

        NSError *err = nil;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!state) error = std::string("Metal pipeline: ") + err.localizedDescription.UTF8String;
        return state;
    }

    bool init();
    void build(const rt::Video &video, int scale, int w);
    void moveForEye(int first, int count, float side, float maxParallax);
    void upload(const rt::Video &video, int scale);
    id<MTLTexture> eyeTexture(int target, int eye, NSUInteger w, NSUInteger h);
    void draw(id<MTLCommandBuffer> commands, id<MTLTexture> target, int scale, int w, uint32_t vertexBase,
              const std::vector<Batch> &batches);
};

bool MetalRenderer::Impl::init() {
    device = MTLCreateSystemDefaultDevice();
    if (!device) {
        error = "no Metal device";
        return false;
    }
    queue = [device newCommandQueue];

    for (int i = 0; i < 256; i++) // the rasterizer's gamma (MAME video_start)
        gamma[i] = uint8_t(std::max((double(i) - 64.0) * 255.0 / 191.0, 0.0));

    id<MTLFunction> vsPoly = function(k_vs_poly_msl), psPoly = function(k_ps_poly_msl);
    id<MTLFunction> vsQuad = function(k_vs_quad_msl);
    id<MTLFunction> psBack = function(k_ps_tiles_back_msl), psFront = function(k_ps_tiles_front_msl);
    if (!vsPoly || !psPoly || !vsQuad || !psBack || !psFront) return false;

    // Polygons: position, depth (draw order), 1/z u/z v/z, colour, texture state.
    MTLVertexDescriptor *polyLayout = [MTLVertexDescriptor new];
    const struct { MTLVertexFormat format; size_t offset; } polyAttributes[6] = {
        {MTLVertexFormatFloat2, offsetof(PolyVertex, x)},     {MTLVertexFormatFloat, offsetof(PolyVertex, depth)},
        {MTLVertexFormatFloat3, offsetof(PolyVertex, ooz)},   {MTLVertexFormatFloat4, offsetof(PolyVertex, r)},
        {MTLVertexFormatUInt4, offsetof(PolyVertex, info)},   {MTLVertexFormatUInt2, offsetof(PolyVertex, more)},
    };
    for (int i = 0; i < 6; i++) {
        polyLayout.attributes[i].format = polyAttributes[i].format;
        polyLayout.attributes[i].offset = polyAttributes[i].offset;
        polyLayout.attributes[i].bufferIndex = kVertexBufferIndex;
    }
    polyLayout.layouts[kVertexBufferIndex].stride = sizeof(PolyVertex);

    // Layers: a full-screen quad, composed per pixel.
    MTLVertexDescriptor *quadLayout = [MTLVertexDescriptor new];
    for (int i = 0; i < 2; i++) {
        quadLayout.attributes[i].format = MTLVertexFormatFloat2;
        quadLayout.attributes[i].offset = i == 0 ? offsetof(QuadVertex, x) : offsetof(QuadVertex, u);
        quadLayout.attributes[i].bufferIndex = kVertexBufferIndex;
    }
    quadLayout.layouts[kVertexBufferIndex].stride = sizeof(QuadVertex);

    polyPipe = pipeline(vsPoly, psPoly, polyLayout);
    backPipe = pipeline(vsQuad, psBack, quadLayout);
    frontPipe = pipeline(vsQuad, psFront, quadLayout);
    if (!polyPipe || !backPipe || !frontPipe) return false;

    // The depth test stands in for the rasterizer's "first polygon to fill a
    // pixel wins": earlier in the order is nearer. The layers ignore it.
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled = YES;
    depthOrder = [device newDepthStencilStateWithDescriptor:dd];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = NO;
    depthOff = [device newDepthStencilStateWithDescriptor:dd];

    const MTLResourceOptions shared = MTLResourceStorageModeShared;
    texram = [device newBufferWithLength:kTexramBytes options:shared];
    luma = [device newBufferWithLength:kLumaBytes options:shared];
    xlat = [device newBufferWithLength:kXlatEntries * 4 options:shared];
    tilepix = [device newBufferWithLength:kTilePixBytes options:shared];
    tiledata = [device newBufferWithLength:kTileDataWords * 4 options:shared];

    if (!queue || !texram || !luma || !xlat || !tilepix || !tiledata) {
        error = "Metal buffers";
        return false;
    }
    return true;
}

// The polygons as triangles, in the rasterizer's order, batched by clip
// rectangle (upstream's GpuRenderer::build, without moving the HUD to the
// widescreen edges). `w`: the screen's width, the original's or wider.
void MetalRenderer::Impl::build(const rt::Video &video, int scale, int w) {
    verts.clear();
    shifts.clear();
    batches.clear();

    const std::vector<rt::GeoPoly> &polys = video.gpu_polys();
    const rt::VideoMem &mem = video.gpu_mem();
    const int windows = video.gpu_windows();
    // widescreen: the screen is `margin` wider on each side; x shifts by it
    const int margin = (w - kW) / 2;
    const int crtc_x = video.crtc_x() + margin, crtc_y = video.crtc_y();
    const int render_x = video.render_x() + margin, render_y = video.render_y();
    if (polys.empty() || !mem.palram || !mem.colorxlat) return;

    // The race HUD's condition panel (overlay polygons) stays on the screen in stereo.
    const bool hud = hudFinder.find_race_hud(polys, video.crtc_x(), crtc_y);
    const uint16_t hud_z = hudFinder.hud_z();

    // internal resolution: the mip level the rasterizer picks from z, less
    // log2(scale) (its levels are 128 units of fast_log2)
    const int lod_bias = int(std::lround(128.0 * std::log2(double(scale))));

    // Raster::render: windows from the last down to 0, low z first, newest first within z.
    order.resize(polys.size());
    std::iota(order.begin(), order.end(), size_t(0));
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        if (polys[a].window != polys[b].window) return polys[a].window > polys[b].window;
        if (polys[a].z != polys[b].z) return polys[a].z < polys[b].z;
        return a > b;
    });

    const float depth_step = 1.0f / float(order.size() + 2);
    uint32_t drawn = 0;
    for (size_t i : order) {
        const rt::GeoPoly &poly = polys[i];
        if (poly.window > windows || poly.num_vertices < 3) continue;
        const int renderer = (poly.texheader[0] >> 13) & 3;
        if (renderer == 1) continue; // translucent solid: the rasterizer draws nothing

        // clip rectangle (Raster::render_one), in the renderer's offsets, within the screen;
        // a viewport spanning the screen extends into the widescreen margins
        const int wide = margin && poly.viewport[0] <= 0 && poly.viewport[2] >= kW - 1 ? margin : 0;
        const int x0 = std::max(poly.viewport[0] - wide + render_x, 0);
        const int x1 = std::min(poly.viewport[2] + wide + render_x, w - 1);
        const int y0 = std::max((384 - poly.viewport[3]) + render_y, 0);
        const int y1 = std::min((384 - poly.viewport[1]) + render_y, kH - 1);
        if (x0 > x1 || y0 > y1) continue;

        const MTLScissorRect clip{NSUInteger(x0), NSUInteger(y0), NSUInteger(x1 - x0 + 1), NSUInteger(y1 - y0 + 1)};
        if (batches.empty() || std::memcmp(&batches.back().clip, &clip, sizeof clip) != 0)
            batches.push_back({uint32_t(verts.size()), 0, clip});

        // colour: the solid renderer's (palette entry, luma translation, gamma)
        const uint32_t colorbase = (poly.texheader[3] >> 6) & 0x3ff;
        const uint32_t luma_index = poly.luma >> 2;
        const uint32_t color = le16(mem.palram, colorbase + 0x1000);
        const float r = gamma[le16(mem.colorxlat, 0x0000 / 2 + (((color >> 0) & 0x1f) << 8) + luma_index) & 0xff] / 255.0f;
        const float g = gamma[le16(mem.colorxlat, 0x4000 / 2 + (((color >> 5) & 0x1f) << 8) + luma_index) & 0xff] / 255.0f;
        const float b = gamma[le16(mem.colorxlat, 0x8000 / 2 + (((color >> 10) & 0x1f) << 8) + luma_index) & 0xff] / 255.0f;
        const float depth_value = float(++drawn) * depth_step;

        // texture state, decoded as render_one (m2.hlsl PolyIn)
        const uint32_t th0 = poly.texheader[0], th1 = poly.texheader[1], th2 = poly.texheader[2];
        const uint32_t mirx = (th0 >> 8) & 1, miry = (th0 >> 9) & 1;
        const uint32_t wlog = th0 & 7, hlog = (th0 >> 3) & 7;
        // the rasterizer's 30 - countl_zero(min(width, height)): log2(min) - 1, width = 32 << wlog
        const uint32_t max_level = 4 + std::min(wlog, hlog);
        uint32_t info[4], more[2];
        info[0] = uint32_t(renderer) | ((th0 >> 15) & 1) << 2 | (((th0 >> 6) & 1) & ~mirx) << 3 |
                  (((th0 >> 7) & 1) & ~miry) << 4 | mirx << 5 | miry << 6 | ((th0 >> 12) & 1) << 7 |
                  ((th0 >> 10) & 3) << 8 | ((th2 >> 12) & 1) << 10 | max_level << 12 | wlog << 17 | hlog << 20;
        info[1] = (32u * (th2 & 0x3f)) | (32u * ((th2 >> 6) & 0x1f)) << 16;
        info[2] = (((th2 >> 13) & 1) * 128) | (((th2 >> 14) & 3) * 128) << 16;
        info[3] = ((th1 & 0xff) << 7) | uint32_t(poly.luma) << 16;
        more[0] = uint32_t(poly.texlod + lod_bias);
        more[1] = le16(mem.palram, colorbase + 0x1000) & 0x7fff;

        // model2_3d_project, then a fan from vertex 0 (the polygon is convex)
        PolyVertex v[8];
        for (int k = 0; k < poly.num_vertices; k++) {
            const rt::GeoVertex &g0 = poly.v[k];
            const float z = g0.p[0] + std::numeric_limits<float>::min();
            const float ooz = 1.0f / z; // render_one, textured: p[0] = 1/z, p[1..2] scaled by it / 8
            v[k] = {float(crtc_x + poly.center[0]) + g0.x / z, float((384 - poly.center[1]) + crtc_y) - g0.y / z,
                    depth_value, ooz, g0.p[1] * ooz * (1.0f / 8.0f), g0.p[2] * ooz * (1.0f / 8.0f),
                    r, g, b, 1.0f, {info[0], info[1], info[2], info[3]}, {more[0], more[1]}};
        }

        const bool shift = !(hud && poly.z == hud_z);
        for (int k = 1; k + 1 < poly.num_vertices; k++) {
            verts.push_back(v[0]);
            verts.push_back(v[k]);
            verts.push_back(v[k + 1]);
            shifts.insert(shifts.end(), 3, shift);
        }
        batches.back().count = uint32_t(verts.size()) - batches.back().first;
    }
}

// One eye's copy of the polygons (verts[first, first + count)): each vertex
// moved sideways by half the parallax for its depth. None at the convergence
// depth (a quarter of the way into the scene, eased), up to maxParallax far
// away, a little the other way nearer.
void MetalRenderer::Impl::moveForEye(int first, int count, float side, float maxParallax) {
    for (int i = first; i < first + count; i++) {
        if (!shifts[size_t(i - first)]) continue;
        PolyVertex &v = verts[size_t(i)];
        const float parallax = std::clamp(maxParallax * (1.f - convergence * v.ooz), -0.5f * maxParallax, maxParallax);
        v.x += side * parallax;
    }
}

// The frame's data into the shared buffers: luma RAM and the gamma'd colour
// translation every frame, texture RAM and tilemap rows when they changed.
// (Safe to write: the previous frame's drawing has completed.)
void MetalRenderer::Impl::upload(const rt::Video &video, int scale) {
    const rt::VideoMem &mem = video.gpu_mem();
    if (mem.lumaram && mem.colorxlat && mem.tex0 && mem.tex1) {
        std::memcpy(luma.contents, mem.lumaram, kLumaBytes);

        auto *table = static_cast<uint32_t *>(xlat.contents);
        for (uint32_t i = 0; i < kXlatEntries; i++) table[i] = gamma[le16(mem.colorxlat, i) & 0xff];

        if (mem.tex_generation != texramGeneration) { // the board counts texture RAM writes
            texramGeneration = mem.tex_generation;
            auto *sheets = static_cast<uint8_t *>(texram.contents);
            std::memcpy(sheets, mem.tex0, kSheetWords * 4);
            std::memcpy(sheets + kSheetWords * 4, mem.tex1, kSheetWords * 4);
        }
    }

    // The tilemap pixmaps' rows changed since tilepix was filled (all, for a
    // new Video), packed as m2.hlsl reads them (pen, category in bit 15).
    const uint64_t generation = video.system24_texture_generation();
    const bool all = video.instance() != tileInstance || generation < tileGeneration;
    auto *pix = static_cast<uint16_t *>(tilepix.contents);
    for (int l = 0; l < 4; l++) {
        int first = 64, last = -1;
        for (unsigned row = 0; row < 64; row++) {
            bool changed = all;
            for (unsigned t = row * 64; !changed && t < row * 64 + 64; t++)
                changed = video.system24_tile_generation(l, t) > tileGeneration;
            if (changed) first = std::min(first, int(row)), last = int(row);
        }
        if (last < 0) continue;

        const size_t start = size_t(first) * 8 * 512, count = size_t(last - first + 1) * 8 * 512;
        const uint16_t *pixels = video.system24_pixels(l) + start;
        const uint8_t *flags = video.system24_flags(l) + start;
        uint16_t *dst = pix + size_t(l) * 512 * 512 + start;
        for (size_t i = 0; i < count; i++) dst[i] = uint16_t(pixels[i] | (flags[i] & 1) << 15);
    }
    tileInstance = video.instance();
    tileGeneration = generation;

    // the header (widescreen margin and its fill, the scale), pens, tile words
    auto *words = static_cast<uint32_t *>(tiledata.contents);
    std::memset(words, 0, kTileHeader * 4);
    words[0] = uint32_t(video.margin());
    words[1] = uint32_t(video.backdrop()); // Edges 0, Sky 1, Stretch 2, as m2.hlsl
    words[2] = uint32_t(scale);
    std::memcpy(words + kTileHeader, video.gpu_pens(), rt::Video::kGpuPens * 4);
    std::memcpy(words + kTileHeader + rt::Video::kGpuPens, video.gpu_tile_words(), rt::Video::kGpuTileWords * 2);
}

// An eye of a target, w x h pixels (w: the frame's pitch), as a texture over its part of the buffer.
id<MTLTexture> MetalRenderer::Impl::eyeTexture(int target, int eye, NSUInteger w, NSUInteger h) {
    if (eyeTexturesWidth[target] != w || eyeTexturesHeight[target] != h) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        for (int e = 0; e < 2; e++)
            eyeTextures[target][e] = [targets[target] newTextureWithDescriptor:d offset:NSUInteger(e) * w * h * 4
                                                                  bytesPerRow:w * 4];
        eyeTexturesWidth[target] = w;
        eyeTexturesHeight[target] = h;
    }
    return eyeTextures[target][eye];
}

// One picture: the back tilemap layers, the polygons, the front layers.
void MetalRenderer::Impl::draw(id<MTLCommandBuffer> commands, id<MTLTexture> target, int scale, int w,
                               uint32_t vertexBase, const std::vector<Batch> &frameBatches) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;

    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];
    // the target may be wider than the picture (its rows padded): draw to the picture's part
    [enc setViewport:{0, 0, double(w * scale), double(kH * scale), 0, 1}];
    // positions are in original pixels (the shaders' screen size), the target scale times that
    const float fw = float(w), fh = float(kH);
    const float screen[4] = {fw, fh, 0, 0};
    const MTLScissorRect full{0, 0, NSUInteger(w * scale), NSUInteger(kH * scale)};
    const QuadVertex corners[6] = {{0, 0, 0, 0}, {fw, 0, 1, 0}, {0, fh, 0, 1}, {fw, 0, 1, 0}, {fw, fh, 1, 1}, {0, fh, 0, 1}};

    auto layers = [&](id<MTLRenderPipelineState> pipe) {
        [enc setRenderPipelineState:pipe];
        [enc setDepthStencilState:depthOff];
        [enc setScissorRect:full];
        [enc setVertexBytes:screen length:sizeof screen atIndex:0];
        [enc setVertexBytes:corners length:sizeof corners atIndex:kVertexBufferIndex];
        [enc setFragmentBuffer:tilepix offset:0 atIndex:0];
        [enc setFragmentBuffer:tiledata offset:0 atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    };

    layers(backPipe);
    if (!frameBatches.empty()) {
        [enc setRenderPipelineState:polyPipe];
        [enc setDepthStencilState:depthOrder];
        [enc setVertexBytes:screen length:sizeof screen atIndex:0];
        [enc setVertexBuffer:vertices offset:0 atIndex:kVertexBufferIndex];
        [enc setFragmentBuffer:texram offset:0 atIndex:0];
        [enc setFragmentBuffer:luma offset:0 atIndex:1];
        [enc setFragmentBuffer:xlat offset:0 atIndex:2];
        for (const Batch &b : frameBatches) {
            if (!b.count) continue;
            [enc setScissorRect:{b.clip.x * NSUInteger(scale), b.clip.y * NSUInteger(scale),
                                 b.clip.width * NSUInteger(scale), b.clip.height * NSUInteger(scale)}];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:vertexBase + b.first vertexCount:b.count];
        }
    }
    layers(frontPipe);
    [enc endEncoding];
}

MetalRenderer::MetalRenderer() : impl_(std::make_unique<Impl>()) {}
MetalRenderer::~MetalRenderer() = default;

bool MetalRenderer::init() { return impl_->init(); }

const std::string &MetalRenderer::error() const { return impl_->error; }

MetalRenderer::Frame MetalRenderer::render(const rt::Video &video, int scale, bool stereo, float depth) {
    Impl &m = *impl_;
    scale = std::clamp(scale, 1, 3);
    const int sw = video.width(); // the screen, the original's width or wider
    @autoreleasepool {
        m.build(video, scale, sw);
        m.upload(video, scale);

        // Stereo: a second copy of the polygons for the right eye, both moved.
        const int count = int(m.verts.size());
        if (stereo && count) {
            m.depths.clear();
            for (const PolyVertex &v : m.verts)
                if (v.ooz > 0) m.depths.push_back(1.f / v.ooz);
            auto q = m.depths.begin() + long(m.depths.size() / 4);
            std::nth_element(m.depths.begin(), q, m.depths.end());
            m.convergence = m.convergence > 0 ? m.convergence + (*q - m.convergence) * 0.1f : *q;

            m.verts.resize(size_t(count) * 2);
            std::copy_n(m.verts.begin(), count, m.verts.begin() + count);
            m.moveForEye(0, count, -0.5f, depth);
            m.moveForEye(count, count, 0.5f, depth);
        }

        // Buffers and textures big enough for this frame.
        const size_t vertexBytes = m.verts.size() * sizeof(PolyVertex);
        if (vertexBytes && (!m.vertices || m.vertices.length < vertexBytes))
            m.vertices = [m.device newBufferWithLength:std::max<size_t>(vertexBytes * 2, 1 << 20)
                                               options:MTLResourceStorageModeShared];
        if (vertexBytes) std::memcpy(m.vertices.contents, m.verts.data(), vertexBytes);

        const NSUInteger w = NSUInteger(sw * scale), h = NSUInteger(kH * scale);
        // A texture over a buffer needs its rows aligned (a widescreen width may not be).
        const NSUInteger align = [m.device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
        const NSUInteger pitch = (w * 4 + align - 1) / align * align / 4;
        if (!m.depth || m.depth.width != pitch || m.depth.height != h) { // as big as the targets
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm
                                                                                        width:pitch height:h mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget;
            d.storageMode = MTLStorageModePrivate;
            m.depth = [m.device newTextureWithDescriptor:d];
        }

        const int target = m.next;
        m.next = (m.next + 1) % kTargets;
        const size_t frameBytes = pitch * h * 4 * 2; // room for both eyes
        if (!m.targets[target] || m.targets[target].length < frameBytes) {
            m.targets[target] = [m.device newBufferWithLength:frameBytes options:MTLResourceStorageModeShared];
            m.eyeTexturesWidth[target] = 0;
        }

        id<MTLCommandBuffer> commands = [m.queue commandBuffer];
        m.draw(commands, m.eyeTexture(target, 0, pitch, h), scale, sw, 0, m.batches);
        if (stereo) m.draw(commands, m.eyeTexture(target, 1, pitch, h), scale, sw, uint32_t(count), m.batches);
        [commands commit];
        [commands waitUntilCompleted];

        Frame frame;
        frame.buffer = (__bridge void *)m.targets[target];
        frame.width = int(w);
        frame.pitch = int(pitch);
        frame.height = int(h) * (stereo ? 2 : 1);
        frame.scale = scale;
        frame.stereo = stereo;
        return frame;
    }
}
