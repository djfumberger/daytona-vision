// The cab's CRT look, applied to the game's frame on its way into the screen
// texture: a little horizontal blur (the video amplifier's bandwidth and the
// beam's spot), then each scanline drawn as a Gaussian beam whose width grows
// with its brightness, per colour channel. Bright lines bloom and fill the
// gaps between them; dark lines stay thin, so their scanlines show. Each line's
// energy is preserved (the beam profile is integrated over every output
// pixel), so the picture's average brightness does not change. A soft bloom
// of the brightest parts (glow in the glass and phosphor) is added on top.
//
// An old tube's faults, all measured from the middle of the picture (of each
// eye's, in stereo): focus going soft towards the edges, the red and blue
// beams landing beside the green (a fixed offset, and more towards the edges),
// and patches of colour where the shadow mask needs degaussing.
#include <metal_stdlib>
using namespace metal;

struct CRTParams {
    uint srcWidth;
    uint srcHeight;
    float scanlines;      // 0: flat picture, 1: full scanlines
    float blur;           // horizontal Gaussian sigma, in source pixels
    float minBeam;        // beam sigma at black, in scanline heights
    float maxBeam;        // beam sigma at full brightness
    float brightness;     // overall gain
    float bloom;          // bloom amount added
    float bloomThreshold; // linear brightness where bloom starts
    float bloomRadius;    // bloom sigma, in source pixels
    uint eyeRows;         // source rows per picture (two pictures stacked in stereo)
    float edgeBlur;       // extra softness at the corners: blur and beam width grow by up to this factor
    float convergence;    // red and blue beams' fixed offset from green, in source pixels (opposite ways)
    float misconvergence; // more of it towards the edges, in source pixels at the corners
    float purity;         // strength of the degauss stains
};

static float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

// The source in linear light, once per frame, for the kernels below: they
// read each source pixel many times over (the CRT kernel each one hundreds of
// times), and converting it every time was most of their cost.
kernel void linearKernel(device const uint *src [[buffer(0)]],
                         constant CRTParams &p [[buffer(1)]],
                         texture2d<half, access::write> out [[texture(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcWidth || gid.y >= p.srcHeight) return;
    const uint v = src[gid.y * p.srcWidth + gid.x];
    out.write(half4(half3(srgbToLinear(float3((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff) / 255.0)), 1.0h), gid);
}

typedef texture2d<half, access::read> Linear;

// One source pixel in linear light (linearKernel's), clamped at the edges.
static float3 texel(Linear src, constant CRTParams &p, int x, int y) {
    x = clamp(x, 0, int(p.srcWidth) - 1);
    y = clamp(y, 0, int(p.srcHeight) - 1);
    return float3(src.read(uint2(x, y)).rgb);
}

// A scanline at horizontal source position sx, blurred by sigma.
static float3 line(Linear src, constant CRTParams &p, float sx, int y, float blur) {
    if (blur < 0.05) return texel(src, p, int(floor(sx + 0.5)), y);
    const int x0 = int(floor(sx));
    float3 sum = 0;
    float total = 0;
    for (int k = -2; k <= 3; ++k) {
        const float d = sx - float(x0 + k);
        const float w = exp(-0.5 * d * d / (blur * blur));
        sum += texel(src, p, x0 + k, y) * w;
        total += w;
    }
    return sum / total;
}

static float3 erfApprox(float3 x) { // |error| < 2e-4
    const float a = 0.147;
    const float3 x2 = x * x;
    return sign(x) * sqrt(1.0 - exp(-x2 * (4.0 / M_PI_F + a * x2) / (1.0 + a * x2)));
}

// Bloom (as vision-emulator's): the bright part of the picture, softly
// thresholded on a half-size grid, then a separable Gaussian blur across and
// down it. crtKernel adds it, sampled bilinearly. The blur's taps are spaced
// so its sigma is bloomRadius source pixels.
kernel void bloomThresholdKernel(constant CRTParams &p [[buffer(1)]],
                                 texture2d<half, access::write> out [[texture(0)]],
                                 texture2d<half, access::sample> src [[texture(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    // the middle of each texel's 2x2 source pixels: the bilinear sample is their average
    const float3 c = float3(src.sample(linear, (float2(gid) + 0.5) / float2(out.get_width(), out.get_height())).rgb);
    const float l = max(c.r, max(c.g, c.b));
    const float k = smoothstep(p.bloomThreshold, p.bloomThreshold + 0.2, l);
    out.write(half4(half3(c * k), 1.0h), gid);
}

struct BloomBlur {
    float2 direction; // (1, 0) across, (0, 1) down
};

kernel void bloomBlurKernel(constant CRTParams &p [[buffer(1)]],
                            constant BloomBlur &b [[buffer(3)]],
                            texture2d<half, access::write> out [[texture(0)]],
                            texture2d<half, access::sample> src [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const float2 size = float2(out.get_width(), out.get_height());
    if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) return;
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    // 9 taps, sigma about 2 taps; a tap every bloomRadius / 4 texels (two source pixels each)
    const float w[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
    const float2 uv = (float2(gid) + 0.5) / size;
    const float2 step = b.direction * max(p.bloomRadius, 0.5) / 4.0 / size;
    float3 sum = float3(src.sample(linear, uv).rgb) * w[0];
    for (int i = 1; i < 5; ++i) {
        sum += float3(src.sample(linear, uv + step * float(i)).rgb) * w[i];
        sum += float3(src.sample(linear, uv - step * float(i)).rgb) * w[i];
    }
    out.write(half4(half3(sum), 1.0h), gid);
}

// Where each scanline's centre sits within its row of the source, in line
// heights. Not 0.5: the output has 4 texels per line and the mip below it 2,
// made by averaging pairs. Centred on 0.5, each line's bright middle straddles
// two pairs and the mip comes out flat, with no scanlines at all. At 0.25 one
// pair holds the line and the next its gap, so the mip keeps them.
constant float kLineCentre = 0.25;

// The beams at source position (sx, sy): each scanline near sy, blurred, as a
// Gaussian across it (see the top). soft: how much wider than set, at this spot.
static float3 beams(Linear src, constant CRTParams &p, float sx, float sy, float halfPixel, float soft) {
    const int nearest = int(floor(sy));
    const float blur = p.blur * soft;
    float3 flat = 0; // the nearest line, without scanlines (from the loop)
    float3 sum = 0;
    for (int k = -2; k <= 2; ++k) {
        const int y = nearest + k;
        const float3 c = line(src, p, sx, y, blur);
        if (k == 0) flat = c;
        const float d = sy - (float(y) + kLineCentre); // from this line's centre
        const float3 w = mix(float3(p.minBeam), float3(p.maxBeam), sqrt(saturate(c))) * soft * M_SQRT2_F;
        // Mean of the beam's normalised profile over the output pixel.
        const float3 coverage = 0.5 * (erfApprox((d + halfPixel) / w) - erfApprox((d - halfPixel) / w))
                                / (2.0 * halfPixel);
        sum += c * coverage;
    }
    return mix(flat, sum, p.scanlines);
}

// The degauss stains' tint at a spot (uv 0..1 over one picture): smooth
// patches leaning magenta or green, out of the middle and strongest in the
// corners. A fixed pattern, as a magnetised mask's is.
static float3 purityTint(float2 uv, float strength) {
    const float2 c = uv * 2.0 - 1.0;
    const float edge = smoothstep(0.35, 1.25, length(c * float2(1.0, 0.85)));
    const float wave = sin(c.x * 2.3 + 0.7) * sin(c.y * 1.9 - 0.4) + 0.6 * sin(c.x * 4.1 - c.y * 3.3 + 1.9);
    const float k = strength * edge * clamp(wave, -1.0, 1.0);
    // Magenta (more red and blue) one way, green the other.
    return 1.0 + k * float3(0.35, -0.3, 0.3);
}

kernel void crtKernel(constant CRTParams &p [[buffer(1)]],
                      texture2d<half, access::write> out [[texture(0)]],
                      texture2d<half, access::sample> bloom [[texture(1)]],
                      Linear src [[texture(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
    const uint W = out.get_width(), H = out.get_height();
    if (gid.x >= W || gid.y >= H) return;

    // Source coordinates of this output pixel's centre (pixel centres at .5).
    const float sx = (float(gid.x) + 0.5) * float(p.srcWidth) / float(W) - 0.5;
    const float sy = (float(gid.y) + 0.5) * float(p.srcHeight) / float(H);
    const float halfPixel = 0.5 * float(p.srcHeight) / float(H); // in scanline heights

    // Where this is within its own picture (each eye's, in stereo), -1..1.
    const float eyeY = fmod(sy, float(p.eyeRows));
    const float2 uv = float2((sx + 0.5) / float(p.srcWidth), eyeY / float(p.eyeRows));
    const float2 c = uv * 2.0 - 1.0;
    const float r2 = saturate(dot(c, c) * 0.5); // 0 in the middle, 1 in the corners

    const float soft = 1.0 + p.edgeBlur * r2;
    float3 colour;
    if (p.convergence + p.misconvergence * r2 > 0.01) {
        // Red and blue land either side of green: outwards from the middle
        // (and right and left for the fixed part).
        const float2 apart = normalize(c + float2(1e-4, 0)) * p.misconvergence * r2 + float2(p.convergence, 0);
        const float3 red = beams(src, p, sx + apart.x, sy + apart.y, halfPixel, soft);
        const float3 green = beams(src, p, sx, sy, halfPixel, soft);
        const float3 blue = beams(src, p, sx - apart.x, sy - apart.y, halfPixel, soft);
        colour = float3(red.r, green.g, blue.b);
    } else {
        colour = beams(src, p, sx, sy, halfPixel, soft);
    }
    colour *= p.brightness;
    if (p.purity > 0) colour *= purityTint(uv, p.purity);
    if (p.bloom > 0) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        const float2 bloomUV = (float2(gid) + 0.5) / float2(W, H);
        colour += float3(bloom.sample(linear, bloomUV).rgb) * p.bloom;
    }
    out.write(half4(half3(colour), 1.0h), gid);
}

// A GPU-drawn frame (MetalRenderer: `scale` times the original, one or two
// pictures stacked) into the original's size for the kernels above: each
// pixel the average of its scale x scale block, in linear light (so the extra
// resolution becomes anti-aliasing). A one-picture frame for a stereo screen
// fills both; a stereo frame for a one-picture screen gives its left eye.
struct GatherParams {
    uint srcWidth;  // pixels from one source row to the next (its width, or padded)
    uint scale;
    uint srcEyes;   // pictures in the source
    uint eyeRows;   // rows of one picture at the original size
};

static float3 unpack(uint v) {
    return srgbToLinear(float3((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff) / 255.0);
}

static uint pack(float3 c) {
    const float3 s = select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    const uint3 b = uint3(clamp(s, 0.0, 1.0) * 255.0 + 0.5);
    return 0xff000000u | b.r << 16 | b.g << 8 | b.b;
}

kernel void gatherKernel(device const uint *src [[buffer(0)]],
                         constant GatherParams &p [[buffer(1)]],
                         device uint *dst [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 size [[threads_per_grid]]) {
    const uint eye = min(gid.y / p.eyeRows, p.srcEyes - 1);
    const uint row = gid.y % p.eyeRows;
    const uint sy0 = (eye * p.eyeRows + row) * p.scale, sx0 = gid.x * p.scale;
    float3 sum = 0;
    for (uint j = 0; j < p.scale; ++j)
        for (uint i = 0; i < p.scale; ++i)
            sum += unpack(src[(sy0 + j) * p.srcWidth + sx0 + i]);
    dst[gid.y * size.x + gid.x] = pack(sum / float(p.scale * p.scale));
}
