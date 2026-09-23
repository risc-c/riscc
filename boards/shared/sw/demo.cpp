// Animated Julia set and scrolling board name for the 320x180 demo display.

#include <stdint.h>
#include <stdio.h>
#include <time.h>

#include <riscc/platform.h>

namespace
{

#if defined(RISCC_ATUM_A3) == defined(RISCC_ICEPI_ZERO)
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
constexpr int32_t kParameterStep = 16;
constexpr int32_t kEscapeComponent = 2 * kFixedOne;
constexpr int32_t kEscapeRadiusSquared = 4 * kFixedOne * kFixedOne;
constexpr uint32_t kJuliaTileSize = 3u;
constexpr uint32_t kJuliaTileStep = kJuliaTileSize - 1u;
constexpr uint32_t kMaxIterations = 254u;
constexpr uint32_t kClockTicksPerSecond = RISCC_TICK_HZ;
constexpr uint32_t kTickerPixelsPerSecond = 30u;
constexpr uint32_t kGlyphWidth = 5u;
constexpr uint32_t kGlyphStride = kGlyphWidth + 1u;
constexpr uint32_t kGlyphTop = 2u;
constexpr uint32_t kGlyphBottom = kGlyphTop + 7u;

struct Point
{
    int32_t x;
    int32_t y;
};

struct TickerCursor
{
    uint32_t glyph;
    uint32_t column;
};

struct AxisStep
{
    int32_t whole;
    uint32_t remainder;
    uint32_t error;
    int32_t direction;
};

struct JuliaPathState
{
    Point parameter;
    uint32_t target;
    uint32_t step_count;
    uint32_t steps_left;
    AxisStep x;
    AxisStep y;
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
// The iteration limit is black; index 255 is reserved for text and borders.
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

// Samples of c(t) = 0.55 + 0.20 cos(t) + 0.36i sin(t), with 14 fractional
// bits. This path stays outside the main cardioid and produces disconnected
// Julia sets.
const Point kJuliaControlPoints[] =
{
    {7372, 5108},   {6696, 4172},   {6172, 2948},   {5848, 1528},
    {5736, 0},      {5848, -1528},  {6172, -2948},  {6696, -4172},
    {7372, -5108},  {8164, -5696},  {9012, -5900},  {9860, -5696},
    {10648, -5108}, {11328, -4172}, {11848, -2948}, {12176, -1528},
    {12288, 0},     {12176, 1528},  {11848, 2948},  {11328, 4172},
    {10648, 5108},  {9860, 5696},   {9012, 5900},   {8164, 5696},
};
constexpr uint32_t kJuliaPathCount =
    static_cast<uint32_t>(sizeof(kJuliaControlPoints) /
                          sizeof(kJuliaControlPoints[0]));

JuliaPathState julia_path;
TickerState ticker;
uint32_t next_julia_row;

// Adjacent 3x3 tiles share their edge samples.  The last row of this cache
// becomes the first row for the next strip.
uint8_t tile_iterations[kJuliaTileSize][RISCC_FRAMEBUFFER_WIDTH];

// Julia arithmetic

uint32_t magnitude(int32_t value)
{
    const uint32_t bits = static_cast<uint32_t>(value);

    return value < 0 ? 0u - bits : bits;
}

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
    uint32_t iteration = 0;

    while (iteration < kMaxIterations)
    {
        if (julia_step(zx, zy, julia_path.parameter.x,
                       julia_path.parameter.y))
        {
            break;
        }
        ++iteration;
    }

    return iteration;
}

// round(253 * sqrt(iteration / 253)); brighten early escapes without dithering.
const uint8_t kEscapeColors[kMaxIterations] =
{
    0u, 16u, 22u, 28u, 32u, 36u, 39u, 42u, 45u, 48u, 50u, 53u, 55u, 57u, 60u, 62u,
    64u, 66u, 67u, 69u, 71u, 73u, 75u, 76u, 78u, 80u, 81u, 83u, 84u, 86u, 87u, 89u,
    90u, 91u, 93u, 94u, 95u, 97u, 98u, 99u, 101u, 102u, 103u, 104u, 106u, 107u, 108u, 109u,
    110u, 111u, 112u, 114u, 115u, 116u, 117u, 118u, 119u, 120u, 121u, 122u, 123u, 124u, 125u, 126u,
    127u, 128u, 129u, 130u, 131u, 132u, 133u, 134u, 135u, 136u, 137u, 138u, 139u, 140u, 140u, 141u,
    142u, 143u, 144u, 145u, 146u, 147u, 148u, 148u, 149u, 150u, 151u, 152u, 153u, 153u, 154u, 155u,
    156u, 157u, 157u, 158u, 159u, 160u, 161u, 161u, 162u, 163u, 164u, 165u, 165u, 166u, 167u, 168u,
    168u, 169u, 170u, 171u, 171u, 172u, 173u, 174u, 174u, 175u, 176u, 176u, 177u, 178u, 179u, 179u,
    180u, 181u, 181u, 182u, 183u, 183u, 184u, 185u, 185u, 186u, 187u, 188u, 188u, 189u, 190u, 190u,
    191u, 192u, 192u, 193u, 194u, 194u, 195u, 195u, 196u, 197u, 197u, 198u, 199u, 199u, 200u, 201u,
    201u, 202u, 202u, 203u, 204u, 204u, 205u, 206u, 206u, 207u, 207u, 208u, 209u, 209u, 210u, 210u,
    211u, 212u, 212u, 213u, 213u, 214u, 215u, 215u, 216u, 216u, 217u, 218u, 218u, 219u, 219u, 220u,
    220u, 221u, 222u, 222u, 223u, 223u, 224u, 224u, 225u, 226u, 226u, 227u, 227u, 228u, 228u, 229u,
    229u, 230u, 230u, 231u, 232u, 232u, 233u, 233u, 234u, 234u, 235u, 235u, 236u, 236u, 237u, 238u,
    238u, 239u, 239u, 240u, 240u, 241u, 241u, 242u, 242u, 243u, 243u, 244u, 244u, 245u, 245u, 246u,
    246u, 247u, 247u, 248u, 248u, 249u, 249u, 250u, 250u, 251u, 251u, 252u, 252u, 253u,
};

uint8_t julia_color(uint32_t iteration, uint32_t x)
{
    if (x == 0u || x == RISCC_FRAMEBUFFER_WIDTH - 1u)
    {
        return 0xffu;
    }
    if (iteration == kMaxIterations)
    {
        return 0u;
    }
    return kEscapeColors[iteration];
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

bool ticker_pixel(uint32_t y, const TickerCursor &cursor)
{
    if (y < kGlyphTop || y >= kGlyphBottom ||
        cursor.column >= kGlyphWidth)
    {
        return false;
    }
    return (kGlyphs[kTickerText[cursor.glyph]][y - kGlyphTop] &
            kBitMasks[cursor.column]) != 0;
}

void advance_ticker_cursor(TickerCursor &cursor)
{
    ++cursor.column;
    if (cursor.column == kGlyphStride)
    {
        cursor.column = 0;
        ++cursor.glyph;
        if (cursor.glyph == kTickerGlyphCount)
        {
            cursor.glyph = 0;
        }
    }
}

bool next_ticker_pixel(uint32_t y, TickerCursor &cursor)
{
    const bool set = ticker_pixel(y, cursor);

    advance_ticker_cursor(cursor);
    return set;
}

void draw_ticker()
{
    for (uint32_t y = 1; y < kJuliaFirstRow; ++y)
    {
        TickerCursor cursor = {0u, ticker.offset};
        volatile uint32_t *const row = framebuffer + y * kWordsPerRow;

        while (cursor.column >= kGlyphStride)
        {
            cursor.column -= kGlyphStride;
            ++cursor.glyph;
        }

        for (uint32_t word = 0; word < kWordsPerRow; ++word)
        {
            uint32_t packed = 0u;

            for (uint32_t lane = 0; lane < kPixelsPerWord; ++lane)
            {
                if (next_ticker_pixel(y, cursor))
                {
                    packed |= 0xffu << (lane * 8u);
                }
            }
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

void prepare_axis_step(AxisStep &axis, int32_t delta, uint32_t distance,
                       uint32_t step_count)
{
    axis.whole = delta / static_cast<int32_t>(step_count);
    axis.remainder = distance % step_count;
    axis.error = 0u;
    axis.direction = delta < 0 ? -1 : 1;
}

void begin_path_segment()
{
    const Point target = kJuliaControlPoints[julia_path.target];
    const int32_t delta_x = target.x - julia_path.parameter.x;
    const int32_t delta_y = target.y - julia_path.parameter.y;
    const uint32_t distance_x = magnitude(delta_x);
    const uint32_t distance_y = magnitude(delta_y);
    const uint32_t distance = distance_x > distance_y ?
        distance_x : distance_y;

    julia_path.step_count = (distance + kParameterStep - 1u) / kParameterStep;
    julia_path.steps_left = julia_path.step_count;
    prepare_axis_step(julia_path.x, delta_x, distance_x,
                      julia_path.step_count);
    prepare_axis_step(julia_path.y, delta_y, distance_y,
                      julia_path.step_count);
}

void advance_axis(int32_t &value, AxisStep &axis, uint32_t step_count)
{
    value += axis.whole;
    axis.error += axis.remainder;
    if (axis.error >= step_count)
    {
        value += axis.direction;
        axis.error -= step_count;
    }
}

void advance_julia_parameter()
{
    if (julia_path.steps_left == 0u)
    {
        begin_path_segment();
    }

    advance_axis(julia_path.parameter.x, julia_path.x,
                 julia_path.step_count);
    advance_axis(julia_path.parameter.y, julia_path.y,
                 julia_path.step_count);

    --julia_path.steps_left;
    if (julia_path.steps_left != 0u)
    {
        return;
    }

    julia_path.parameter = kJuliaControlPoints[julia_path.target];
    ++julia_path.target;
    if (julia_path.target == kJuliaPathCount)
    {
        julia_path.target = 0u;
    }
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

void update_ticker()
{
    const uint16_t now = static_cast<uint16_t>(clock());
    uint32_t elapsed = static_cast<uint16_t>(now - ticker.last_tick);
    bool moved = false;

    ticker.last_tick = now;
    while (elapsed != 0u)
    {
        --elapsed;
        ticker.tick_remainder += kTickerPixelsPerSecond;
        if (ticker.tick_remainder < kClockTicksPerSecond)
        {
            continue;
        }

        ticker.tick_remainder -= kClockTicksPerSecond;
        if (++ticker.offset == kTickerWidth)
        {
            ticker.offset = 0u;
        }
        moved = true;
    }
    if (moved)
    {
        draw_ticker();
    }
}

void draw_next_strip()
{
    update_ticker();
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
#else
    puts("RISC-C on Icepi Zero");
#endif
    julia_path.parameter = kJuliaControlPoints[0];
    julia_path.target = 1u;
    next_julia_row = kJuliaFirstRow;
    ticker.last_tick = static_cast<uint16_t>(clock());

    initialize_palette();
    draw_border();
    draw_ticker();

    time_t t = clock();
    for (;;)
    {
        draw_next_strip();
        if (clock() != t)
        {
            t = clock();
            putchar('.');
        }
    }
}
