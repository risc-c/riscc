// Animated Julia set and scrolling board name for the 320x180 demo display.

#include <stdint.h>
#include <stdio.h>
#include <time.h>

#include <riscc/platform.h>
#include <riscc/interrupt.h>

namespace
{

#if (defined(RISCC_ATUM_A3) + defined(RISCC_ICEPI_ZERO) + defined(RISCC_DE23_LITE)) != 1
#error "Board demo requires exactly one board macro"
#endif

constexpr uint32_t kPixelsPerWord = 4u;
constexpr uint32_t kWordsPerRow = RISCC_FRAMEBUFFER_WIDTH / kPixelsPerWord;
constexpr uint32_t kJuliaFirstRow = 10u;
constexpr uint32_t kJuliaEndRow = RISCC_FRAMEBUFFER_HEIGHT - 1u;
// Julia sets are symmetric under a 180-degree rotation.  Render the top half
// and rotate it into the bottom half.
constexpr int32_t kJuliaCenterX2 = RISCC_FRAMEBUFFER_WIDTH - 1u;
constexpr int32_t kJuliaCenterY =
    (kJuliaFirstRow + kJuliaEndRow - 1u) / 2u;
constexpr uint32_t kJuliaMirrorSumY =
    kJuliaFirstRow + kJuliaEndRow - 1u;
constexpr unsigned kFractionBits = 14;
constexpr int32_t kFixedOne = 1 << kFractionBits;
constexpr int32_t kViewStep = 192;
// Independent prime periods, measured in completed Julia frames.
constexpr uint32_t kPathPeriod = 2003u;
constexpr uint32_t kRotationPeriod = 3001u;
constexpr uint32_t kZoomPeriod = 4001u;
constexpr uint32_t kSineSize = 512u;
constexpr int32_t kEscapeComponent = 2 * kFixedOne;
constexpr int32_t kEscapeRadiusSquared = 4 * kFixedOne * kFixedOne;
constexpr uint32_t kJuliaTileSize = 3u;
constexpr uint32_t kJuliaTileStep = kJuliaTileSize - 1u;
constexpr uint32_t kMaxIterations = 254u;
constexpr uint32_t kClockTicksPerSecond = RISCC_TICK_HZ;
constexpr uint32_t kTickerPixelsPerSecond = 60u;
constexpr uint32_t kGlyphWidth = 5u;
constexpr uint32_t kGlyphStride = kGlyphWidth + 1u;
constexpr uint32_t kGlyphTop = 2u;
constexpr uint32_t kGlyphBottom = kGlyphTop + 7u;

struct Point
{
    int32_t x;
    int32_t y;
};

struct TickerState
{
    uint32_t offset;
    uint32_t tick_remainder;
    uint16_t last_tick;
};

volatile uint32_t *const framebuffer =
    reinterpret_cast<volatile uint32_t *>(RISCC_FRAMEBUFFER_BASE);

// Palette indices 0..126: black to blue; 127..253: blue to white.
// The iteration limit uses white (253); index 255 is white for text and borders.
uint32_t palette_color(uint32_t index)
{
    if (index < 127u)
        return (index * 255u + 63u) / 126u;
    if (index < kMaxIterations)
    {
        const uint32_t white = ((index - 127u) * 255u + 63u) / 126u;
        return (white << 16) | (white << 8) | 0xffu;
    }
    return index == 255u ? 0xffffffu : 0u;
}

void initialize_palette()
{
    for (uint32_t index = 0; index < 256u; ++index)
    {
        RISCC_MMIO32(RISCC_PALETTE_BASE + index * 4u) =
            palette_color(index);
    }
}

const uint8_t kBitMasks[5] =
{
    0x10u, 0x08u, 0x04u, 0x02u, 0x01u
};
// Font and ticker

enum Glyph : uint8_t
{
    kGlyphR,
    kGlyphI,
    kGlyphS,
    kGlyphC,
    kGlyphDash,
    kGlyphSpace,
    kGlyphA,
    kGlyphN,
    kGlyph3,
    kGlyphLowerA,
    kGlyphLowerM,
    kGlyphLowerN,
    kGlyphLowerO,
    kGlyphLowerT,
    kGlyphLowerU,
    kGlyphLowerC,
    kGlyphLowerE,
    kGlyphLowerP,
    kGlyphLowerI,
    kGlyphZ,
    kGlyphLowerR,
    kGlyphD,
    kGlyphE,
    kGlyph2,
    kGlyphL,
    kGlyphCount
};

const uint8_t kGlyphs[kGlyphCount][7] =
{
    {0x1eu, 0x11u, 0x11u, 0x1eu, 0x14u, 0x12u, 0x11u},  // R
    {0x1fu, 0x04u, 0x04u, 0x04u, 0x04u, 0x04u, 0x1fu},  // I
    {0x0fu, 0x10u, 0x10u, 0x0eu, 0x01u, 0x01u, 0x1eu},  // S
    {0x0eu, 0x11u, 0x10u, 0x10u, 0x10u, 0x11u, 0x0eu},  // C
    {0x00u, 0x00u, 0x00u, 0x1fu, 0x00u, 0x00u, 0x00u},  // -
    {0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x00u},  // space
    {0x0eu, 0x11u, 0x11u, 0x1fu, 0x11u, 0x11u, 0x11u},  // A
    {0x11u, 0x19u, 0x19u, 0x15u, 0x13u, 0x13u, 0x11u},  // N
    {0x0eu, 0x11u, 0x01u, 0x06u, 0x01u, 0x11u, 0x0eu},  // 3
    {0x00u, 0x00u, 0x0eu, 0x01u, 0x0fu, 0x11u, 0x0fu},  // a
    {0x00u, 0x00u, 0x1au, 0x15u, 0x15u, 0x15u, 0x15u},  // m
    {0x00u, 0x00u, 0x1eu, 0x11u, 0x11u, 0x11u, 0x11u},  // n
    {0x00u, 0x00u, 0x0eu, 0x11u, 0x11u, 0x11u, 0x0eu},  // o
    {0x04u, 0x04u, 0x1fu, 0x04u, 0x04u, 0x04u, 0x03u},  // t
    {0x00u, 0x00u, 0x11u, 0x11u, 0x11u, 0x13u, 0x0du},  // u
    {0x00u, 0x00u, 0x0eu, 0x10u, 0x10u, 0x10u, 0x0eu},  // c
    {0x00u, 0x00u, 0x0eu, 0x11u, 0x1fu, 0x10u, 0x0fu},  // e
    {0x00u, 0x00u, 0x1eu, 0x11u, 0x1eu, 0x10u, 0x10u},  // p
    {0x04u, 0x00u, 0x0cu, 0x04u, 0x04u, 0x04u, 0x0eu},  // i
    {0x1fu, 0x01u, 0x02u, 0x04u, 0x08u, 0x10u, 0x1fu},  // Z
    {0x00u, 0x00u, 0x16u, 0x19u, 0x10u, 0x10u, 0x10u},  // r
    {0x1eu, 0x11u, 0x11u, 0x11u, 0x11u, 0x11u, 0x1eu},  // D
    {0x1fu, 0x10u, 0x10u, 0x1eu, 0x10u, 0x10u, 0x1fu},  // E
    {0x0eu, 0x11u, 0x01u, 0x02u, 0x04u, 0x08u, 0x1fu},  // 2
    {0x10u, 0x10u, 0x10u, 0x10u, 0x10u, 0x10u, 0x1fu},  // L
};

#if defined(RISCC_ATUM_A3)
const uint8_t kTickerText[] =
{
    kGlyphR, kGlyphI, kGlyphS, kGlyphC, kGlyphDash, kGlyphC, kGlyphSpace,
    kGlyphLowerO, kGlyphLowerN, kGlyphSpace,
    kGlyphA, kGlyphLowerT, kGlyphLowerU, kGlyphLowerM, kGlyphSpace,
    kGlyphA, kGlyph3, kGlyphSpace, kGlyphN, kGlyphLowerA, kGlyphLowerN,
    kGlyphLowerO, kGlyphSpace, kGlyphSpace, kGlyphSpace, kGlyphSpace,
};
#elif defined(RISCC_DE23_LITE)
const uint8_t kTickerText[] =
{
    kGlyphR, kGlyphI, kGlyphS, kGlyphC, kGlyphDash, kGlyphC, kGlyphSpace,
    kGlyphLowerO, kGlyphLowerN, kGlyphSpace,
    kGlyphD, kGlyphE, kGlyph2, kGlyph3, kGlyphDash,
    kGlyphL, kGlyphLowerI, kGlyphLowerT, kGlyphLowerE,
    kGlyphSpace, kGlyphSpace, kGlyphSpace, kGlyphSpace,
};
#else
const uint8_t kTickerText[] =
{
    kGlyphR, kGlyphI, kGlyphS, kGlyphC, kGlyphDash, kGlyphC, kGlyphSpace,
    kGlyphLowerO, kGlyphLowerN, kGlyphSpace,
    kGlyphI, kGlyphLowerC, kGlyphLowerE, kGlyphLowerP, kGlyphLowerI,
    kGlyphSpace, kGlyphZ, kGlyphLowerE, kGlyphLowerR, kGlyphLowerO,
    kGlyphSpace, kGlyphSpace, kGlyphSpace, kGlyphSpace,
};
#endif

constexpr uint32_t kTickerGlyphCount =
    static_cast<uint32_t>(sizeof(kTickerText) / sizeof(kTickerText[0]));
constexpr uint32_t kTickerWidth = kTickerGlyphCount * kGlyphStride;

// Julia animation

// A tilted loop follows the region with varied intermediate escape counts.
Point julia_parameter;
uint32_t path_phase;
uint32_t rotation_phase;
uint32_t zoom_phase;
int16_t sine_table[kSineSize + 1u];
int32_t view_cos;
int32_t view_sin;
TickerState ticker;
uint32_t next_julia_row;

// Adjacent 3x3 tiles share their edge samples.  The last row of this cache
// becomes the first row for the next strip.
uint8_t tile_iterations[kJuliaTileSize][RISCC_FRAMEBUFFER_WIDTH];

// Julia arithmetic

// Keep 14 fractional bits so every product fits a native signed 32-bit MUL.
// Reject components outside (-2, 2) before squaring; even the sum of both
// squares then fits int32_t. No split products or 64-bit helpers are needed.
bool julia_step(int32_t &x, int32_t &y, int32_t cx, int32_t cy)
{
    if (x <= -kEscapeComponent || x >= kEscapeComponent ||
        y <= -kEscapeComponent || y >= kEscapeComponent)
    {
        return true;
    }

    const int32_t xx = x * x;
    const int32_t yy = y * y;
    if (xx + yy >= kEscapeRadiusSquared)
    {
        return true;
    }

    const int32_t xy = x * y;
    x = ((xx - yy) >> kFractionBits) + cx;
    y = (xy >> (kFractionBits - 1u)) + cy;
    return false;
}

uint32_t escape_time(uint32_t x, uint32_t y)
{
    int32_t zx = (static_cast<int32_t>(x) * 2 - kJuliaCenterX2) *
        (kViewStep / 2);
    int32_t zy = (static_cast<int32_t>(y) - kJuliaCenterY) * kViewStep;
    const int32_t rotated_x = (zx * view_cos - zy * view_sin) >> kFractionBits;
    zy = (zx * view_sin + zy * view_cos) >> kFractionBits;
    zx = rotated_x;
    uint32_t iteration = 0;

    while (iteration < kMaxIterations)
    {
        if (julia_step(zx, zy, julia_parameter.x,
                       julia_parameter.y))
        {
            break;
        }
        ++iteration;
    }

    return iteration;
}

uint8_t escape_colors[kMaxIterations];

void initialize_escape_colors()
{
    for (uint32_t iteration = 0; iteration < kMaxIterations; ++iteration)
    {
        if (iteration <= 4u)
        {
            escape_colors[iteration] = static_cast<uint8_t>(iteration);
            continue;
        }

        // 4 + 248*t*(1 + 4*t)/(1 + 4*t*t), t = (iteration - 4)/249.
        // Evaluate with integer rounding; all intermediates fit in 32 bits.
        const uint32_t d = iteration - 4u;
        const uint32_t denominator = 249u * 249u + 4u * d * d;
        const uint32_t numerator = 248u * d * (249u + 4u * d);
        const uint32_t color = 4u + (numerator + denominator / 2u) / denominator;
        // The curve ends at 252; only max-iteration interiors use full white.
        escape_colors[iteration] = static_cast<uint8_t>(color);
    }
}

uint8_t julia_color(uint32_t iteration, uint32_t x)
{
    if (x == 0u || x == RISCC_FRAMEBUFFER_WIDTH - 1u)
    {
        return 0xffu;
    }
    if (iteration == kMaxIterations)
    {
        return 253u;
    }
    return escape_colors[iteration];
}

// Frame and ticker

void draw_border()
{
    for (uint32_t word = 0; word < kWordsPerRow; ++word)
    {
        framebuffer[word] = 0xffffffffu;
        framebuffer[(RISCC_FRAMEBUFFER_HEIGHT - 1u) * kWordsPerRow + word] =
            0xffffffffu;
    }
    for (uint32_t y = 1; y < RISCC_FRAMEBUFFER_HEIGHT - 1u; ++y)
    {
        volatile uint32_t *const row = framebuffer + y * kWordsPerRow;
        row[0] = 0x000000ffu;
        row[kWordsPerRow - 1u] = 0xff000000u;
    }
}

// Three repeated pixels allow each four-byte load group to cross the wrap.
uint8_t ticker_pixels[kJuliaFirstRow - 1u][kTickerWidth + 3u];

void initialize_ticker()
{
    for (uint32_t y = 1; y < kJuliaFirstRow; ++y)
    {
        for (uint32_t x = 0; x < kTickerWidth + 3u; ++x)
        {
            const uint32_t position = x % kTickerWidth;
            const uint32_t column = position % kGlyphStride;
            const uint32_t glyph = position / kGlyphStride;
            const bool set = y >= kGlyphTop && y < kGlyphBottom &&
                column < kGlyphWidth &&
                (kGlyphs[kTickerText[glyph]][y - kGlyphTop] & kBitMasks[column]);
            ticker_pixels[y - 1u][x] = set ? 0xffu : 0u;
        }
    }
}

void draw_ticker(bool initialize = false)
{
    // Padding rows are static; only write them during initialization.
    const uint32_t first = initialize ? 1u : kGlyphTop;
    const uint32_t end = initialize ? kJuliaFirstRow : kGlyphBottom;
    for (uint32_t y = first; y < end; ++y)
    {
        uint32_t position = ticker.offset;
        const uint8_t *const pixels = ticker_pixels[y - 1u];
        volatile uint32_t *const row = framebuffer + y * kWordsPerRow;

        for (uint32_t word = 0; word < kWordsPerRow; ++word)
        {
            uint32_t packed = static_cast<uint32_t>(pixels[position]) |
                (static_cast<uint32_t>(pixels[position + 1u]) << 8) |
                (static_cast<uint32_t>(pixels[position + 2u]) << 16) |
                (static_cast<uint32_t>(pixels[position + 3u]) << 24);
            position += kPixelsPerWord;
            if (position >= kTickerWidth)
                position -= kTickerWidth;
            if (word == 0)
            {
                packed |= 0x000000ffu;
            }
            if (word == kWordsPerRow - 1u)
            {
                packed |= 0xff000000u;
            }
            row[word] = packed;
        }
    }
}

// Julia animation path

// Interpolate a periodic Q14 sine table without a discontinuity at wraparound.
int32_t animation_sine(uint32_t phase, uint32_t period, uint32_t quarter = 0u)
{
    const uint32_t position = phase * kSineSize;
    const uint32_t index = (position / period + quarter * (kSineSize / 4u)) % kSineSize;
    const int32_t fraction = static_cast<int32_t>(position % period);
    const int32_t a = sine_table[index];
    const int32_t b = sine_table[index + 1u];
    return a + (b - a) * fraction / static_cast<int32_t>(period);
}

void update_julia_motion()
{
    const int32_t along = animation_sine(path_phase, kPathPeriod);
    const int32_t across = animation_sine(path_phase, kPathPeriod, 1u);
    // c = 0.385 + 0.010*sin(t) + 0.001*cos(t) + i*(0.12 + 0.030*sin(t)).
    julia_parameter.x = 6308 + ((164 * along + 16 * across) >> kFractionBits);
    julia_parameter.y = 1966 + ((492 * along) >> kFractionBits);

    // Vary the view scale by +/-18%, independently of path and rotation.
    const int32_t scale = kFixedOne +
        ((2949 * animation_sine(zoom_phase, kZoomPeriod)) >> kFractionBits);
    view_cos = (scale * animation_sine(rotation_phase, kRotationPeriod, 1u)) >> kFractionBits;
    view_sin = (scale * animation_sine(rotation_phase, kRotationPeriod)) >> kFractionBits;
}

void initialize_julia_motion()
{
    for (uint32_t i = 0; i < kSineSize; ++i)
    {
        // Bhaskara's sine approximation on each half-cycle, using only
        // 32-bit integer arithmetic (maximum numerator is 2^30).
        const uint32_t half_phase = i % (kSineSize / 2u);
        const uint32_t product = half_phase * (kSineSize / 2u - half_phase);
        const uint32_t denominator = 5u * 16384u - product;
        const int32_t value = static_cast<int32_t>(
            (4u * product * kFixedOne + denominator / 2u) / denominator);
        sine_table[i] = static_cast<int16_t>(i < kSineSize / 2u ? value : -value);
    }
    sine_table[kSineSize] = sine_table[0];
    update_julia_motion();
}

void advance_julia_parameter()
{
    if (++path_phase == kPathPeriod)
        path_phase = 0u;
    if (++rotation_phase == kRotationPeriod)
        rotation_phase = 0u;
    if (++zoom_phase == kZoomPeriod)
        zoom_phase = 0u;
    update_julia_motion();
}

// Julia rendering

uint32_t pack_pixels(uint8_t p0, uint8_t p1, uint8_t p2, uint8_t p3,
                     uint32_t x)
{
    return static_cast<uint32_t>(julia_color(p0, x)) |
           (static_cast<uint32_t>(julia_color(p1, x + 1u)) << 8) |
           (static_cast<uint32_t>(julia_color(p2, x + 2u)) << 16) |
           (static_cast<uint32_t>(julia_color(p3, x + 3u)) << 24);
}

void write_cached_rows(uint32_t top_y)
{
    for (uint32_t cache_row = 0; cache_row < kJuliaTileSize; ++cache_row)
    {
        const uint32_t y = top_y + cache_row;
        const uint32_t mirror_y = kJuliaMirrorSumY - y;
        volatile uint32_t *const output =
            framebuffer + y * kWordsPerRow;

        for (uint32_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; x += 4u)
        {
            output[x / 4u] = pack_pixels(
                tile_iterations[cache_row][x],
                tile_iterations[cache_row][x + 1u],
                tile_iterations[cache_row][x + 2u],
                tile_iterations[cache_row][x + 3u], x);
        }

        if (mirror_y != y)
        {
            volatile uint32_t *const output_mirror =
                framebuffer + mirror_y * kWordsPerRow;

            for (uint32_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; x += 4u)
            {
                const uint32_t mirror_x =
                    RISCC_FRAMEBUFFER_WIDTH - x - 4u;

                output_mirror[x / 4u] = pack_pixels(
                    tile_iterations[cache_row][mirror_x + 3u],
                    tile_iterations[cache_row][mirror_x + 2u],
                    tile_iterations[cache_row][mirror_x + 1u],
                    tile_iterations[cache_row][mirror_x], x);
            }
        }
    }
}

void sample_tile(uint32_t x, uint32_t y, uint32_t width)
{
    const uint32_t right = x + width - 1u;

    if (x == 0u)
    {
        for (uint32_t row = 1; row < kJuliaTileSize; ++row)
        {
            tile_iterations[row][0] = static_cast<uint8_t>(
                escape_time(0u, y + row));
        }
    }
    const uint8_t top_left = tile_iterations[0][x];
    const uint8_t top_right = tile_iterations[0][right];
    const uint8_t bottom_left = tile_iterations[kJuliaTileSize - 1u][x];
    const uint8_t bottom_right = static_cast<uint8_t>(
        escape_time(right, y + kJuliaTileSize - 1u));

    tile_iterations[kJuliaTileSize - 1u][right] = bottom_right;
    const bool uniform = top_left == top_right && top_left == bottom_left &&
        top_left == bottom_right;

    // Flat tiles need no interior samples.  Shared edges are already cached.
    if (uniform)
    {
        for (uint32_t row = 1; row < kJuliaTileSize; ++row)
        {
            for (uint32_t column = 1; column < width; ++column)
            {
                tile_iterations[row][x + column] = top_left;
            }
        }
    }
    else
    {
        for (uint32_t row = 1; row < kJuliaTileSize - 1u; ++row)
        {
            for (uint32_t column = 1; column < width; ++column)
            {
                tile_iterations[row][x + column] = static_cast<uint8_t>(
                    escape_time(x + column, y + row));
            }
        }
        for (uint32_t column = 1; column + 1u < width; ++column)
        {
            tile_iterations[kJuliaTileSize - 1u][x + column] =
                static_cast<uint8_t>(escape_time(
                    x + column, y + kJuliaTileSize - 1u));
        }
    }
}

void draw_julia_strip(uint32_t y)
{
    if (y == kJuliaFirstRow)
    {
        for (uint32_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; ++x)
        {
            tile_iterations[0][x] = static_cast<uint8_t>(escape_time(x, y));
        }
    }
    for (uint32_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH;
         x += kJuliaTileStep)
    {
        const uint32_t width = RISCC_FRAMEBUFFER_WIDTH - x < kJuliaTileSize ?
            RISCC_FRAMEBUFFER_WIDTH - x : kJuliaTileSize;

        sample_tile(x, y, width);
    }
    write_cached_rows(y);
    if (y + kJuliaTileStep < kJuliaCenterY)
    {
        for (uint32_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; ++x)
        {
            tile_iterations[0][x] =
                tile_iterations[kJuliaTileSize - 1u][x];
        }
    }
}

void frame_interrupt()
{
    // Acknowledge before drawing. The runtime keeps interrupts masked until
    // return; the next vertical blank can then pend without being lost.
    riscc_timer_set_ticks(1u);
    const uint16_t now = static_cast<uint16_t>(clock());
    const uint16_t elapsed = static_cast<uint16_t>(now - ticker.last_tick);
    if (elapsed == 0u)
        return;

    // Advance once per display frame; compensate if an interrupt was delayed.
    ticker.last_tick = now;
    const uint32_t advance = ticker.tick_remainder +
        static_cast<uint32_t>(elapsed) * kTickerPixelsPerSecond;
    ticker.tick_remainder = advance % kClockTicksPerSecond;
    ticker.offset = (ticker.offset + advance / kClockTicksPerSecond) % kTickerWidth;
    draw_ticker();
}

void draw_next_strip()
{
    draw_julia_strip(next_julia_row);
    if (next_julia_row + kJuliaTileStep >= kJuliaCenterY)
    {
        next_julia_row = kJuliaFirstRow;
        advance_julia_parameter();
    }
    else
    {
        next_julia_row += kJuliaTileStep;
    }
}

}  // namespace

int main()
{
#ifdef RISCC_ATUM_A3
    puts("RISC-C on Atum A3 Nano");
#elif defined(RISCC_DE23_LITE)
    puts("RISC-C on DE23-Lite");
#else
    puts("RISC-C on Icepi Zero");
#endif
    initialize_julia_motion();
    next_julia_row = kJuliaFirstRow;

    initialize_escape_colors();
    initialize_palette();
    initialize_ticker();
    draw_border();
    draw_ticker(true);

    ticker.last_tick = static_cast<uint16_t>(clock());
    riscc_irq_set_handler(frame_interrupt);
    riscc_timer_set_ticks(1u);
    RISCC_MMIO_WORD(RISCC_IRQ_ENABLE) = RISCC_IRQ_TIMER;
    riscc_irq_enable();

    uint16_t t = static_cast<uint16_t>(clock());
    for (;;)
    {
        draw_next_strip();
        const uint16_t now = static_cast<uint16_t>(clock());
        if (static_cast<uint16_t>(now - t) >= RISCC_TICK_HZ)
        {
            t = now;
            putchar('.');
        }
    }
}
