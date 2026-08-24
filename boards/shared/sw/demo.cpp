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

constexpr uint16_t kPixelsPerWord = 4u;
constexpr uint16_t kWordsPerRow = RISCC_FRAMEBUFFER_WIDTH / kPixelsPerWord;
constexpr uint16_t kBytesPerRow = RISCC_FRAMEBUFFER_WIDTH / 2u;
constexpr uint16_t kJuliaFirstRow = 10u;
constexpr uint16_t kJuliaEndRow = RISCC_FRAMEBUFFER_HEIGHT - 1u;
// Julia sets are symmetric under a 180-degree rotation.  Render the top half
// and rotate it into the bottom half.
constexpr int16_t kJuliaCenterX2 = RISCC_FRAMEBUFFER_WIDTH - 1u;
constexpr int16_t kJuliaCenterY =
    (kJuliaFirstRow + kJuliaEndRow - 1u) / 2u;
constexpr uint16_t kJuliaMirrorSumY =
    kJuliaFirstRow + kJuliaEndRow - 1u;
constexpr int16_t kViewStep = 48;
constexpr int16_t kParameterStep = 4;
constexpr int16_t kEscapeComponent = 8192;
constexpr uint16_t kEscapeRadiusSquared = 16384u;
constexpr uint16_t kMultiplySplitShift = 6u;
constexpr uint16_t kMultiplyLowMask = 0x003fu;
constexpr uint16_t kJuliaTileSize = 3u;
constexpr uint16_t kJuliaTileStep = kJuliaTileSize - 1u;
constexpr uint16_t kMaxIterations = 127u;
constexpr uint16_t kClockTicksPerSecond = RISCC_TICK_HZ;
constexpr uint16_t kTickerPixelsPerSecond = 30u;
constexpr uint16_t kGlyphWidth = 5u;
constexpr uint16_t kGlyphStride = kGlyphWidth + 1u;
constexpr uint16_t kGlyphTop = 2u;
constexpr uint16_t kGlyphBottom = kGlyphTop + 7u;

struct Point
{
    int16_t x;
    int16_t y;
};

struct TickerCursor
{
    uint16_t glyph;
    uint16_t column;
};

struct AxisStep
{
    int16_t whole;
    uint16_t remainder;
    uint16_t error;
    int8_t direction;
};

struct JuliaPathState
{
    Point parameter;
    uint16_t target;
    uint16_t step_count;
    uint16_t steps_left;
    AxisStep x;
    AxisStep y;
};

struct TickerState
{
    uint16_t offset;
    uint16_t tick_remainder;
    uint16_t last_tick;
};

volatile uint16_t *const framebuffer =
    reinterpret_cast<volatile uint16_t *>(RISCC_FRAMEBUFFER_BASE);
volatile uint8_t *const framebuffer_bytes =
    reinterpret_cast<volatile uint8_t *>(RISCC_FRAMEBUFFER_BASE);

const uint16_t kNibbleMasks[4] =
{
    0x000fu, 0x00f0u, 0x0f00u, 0xf000u
};
const uint8_t kBitMasks[5] =
{
    0x10u, 0x08u, 0x04u, 0x02u, 0x01u
};
// 2x2 Bayer screen for the four substeps between palette colors.
const uint8_t kDitherThresholds[4] =
{
    0u, 2u,
    3u, 1u
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

constexpr uint16_t kTickerGlyphCount =
    static_cast<uint16_t>(sizeof(kTickerText) / sizeof(kTickerText[0]));
constexpr uint16_t kTickerWidth = kTickerGlyphCount * kGlyphStride;

// Julia animation

// Q4.12 samples of c(t) = 0.55 + 0.20 cos(t) + 0.36i sin(t).  This path stays
// outside the main cardioid and produces uncluttered, disconnected Julia sets.
const Point kJuliaControlPoints[] =
{
    {1843, 1277}, {1674, 1043},  {1543, 737},   {1462, 382},
    {1434, 0},    {1462, -382},  {1543, -737},  {1674, -1043},
    {1843, -1277},{2041, -1424}, {2253, -1475}, {2465, -1424},
    {2662, -1277},{2832, -1043}, {2962, -737},  {3044, -382},
    {3072, 0},    {3044, 382},   {2962, 737},   {2832, 1043},
    {2662, 1277}, {2465, 1424},  {2253, 1475},  {2041, 1424},
};
constexpr uint16_t kJuliaPathCount =
    static_cast<uint16_t>(sizeof(kJuliaControlPoints) /
                          sizeof(kJuliaControlPoints[0]));

JuliaPathState julia_path;
TickerState ticker;
uint16_t next_julia_row;

// Adjacent 3x3 tiles share their edge samples.  The last row of this cache
// becomes the first row for the next strip.
uint8_t tile_iterations[kJuliaTileSize][RISCC_FRAMEBUFFER_WIDTH];

// Julia arithmetic

uint16_t magnitude16(int16_t value)
{
    const uint16_t bits = static_cast<uint16_t>(value);

    return value < 0 ? static_cast<uint16_t>(0u - bits) : bits;
}

// One Q4.12 iteration of z = z^2 + c.  Splitting each product into six-bit
// halves keeps the arithmetic cheap; the omitted low-low term is sub-LSB.
bool julia_step(int16_t &x, int16_t &y, int16_t cx, int16_t cy)
{
    const uint16_t abs_x = magnitude16(x);
    const uint16_t abs_y = magnitude16(y);

    if (abs_x >= static_cast<uint16_t>(kEscapeComponent) ||
        abs_y >= static_cast<uint16_t>(kEscapeComponent))
    {
        return true;
    }

    const uint16_t x_high = abs_x >> kMultiplySplitShift;
    const uint16_t x_low = abs_x & kMultiplyLowMask;
    const uint16_t y_high = abs_y >> kMultiplySplitShift;
    const uint16_t y_low = abs_y & kMultiplyLowMask;
    const uint16_t x_squared = static_cast<uint16_t>(
        x_high * x_high +
        ((x_high * x_low) >> (kMultiplySplitShift - 1u)));
    const uint16_t y_squared = static_cast<uint16_t>(
        y_high * y_high +
        ((y_high * y_low) >> (kMultiplySplitShift - 1u)));

    if (static_cast<uint16_t>(x_squared + y_squared) >=
        kEscapeRadiusSquared)
    {
        return true;
    }

    const uint16_t xy_high = static_cast<uint16_t>(x_high * y_high);
    const uint16_t xy_cross = static_cast<uint16_t>(
        x_high * y_low + x_low * y_high);
    const uint16_t xy = static_cast<uint16_t>(
        xy_high + (xy_cross >> kMultiplySplitShift));
    const int16_t signed_xy = (x < 0) != (y < 0)
        ? static_cast<int16_t>(0u - xy)
        : static_cast<int16_t>(xy);

    x = static_cast<int16_t>(
        static_cast<int16_t>(x_squared) - static_cast<int16_t>(y_squared) +
        cx);
    y = static_cast<int16_t>(signed_xy * 2 + cy);
    return false;
}

uint16_t escape_time(uint16_t x, uint16_t y)
{
    int16_t zx = static_cast<int16_t>(x * 2u - kJuliaCenterX2) *
        (kViewStep / 2);
    int16_t zy = static_cast<int16_t>(y - kJuliaCenterY) * kViewStep;
    uint16_t iteration = 0;

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

uint8_t julia_color(uint16_t iteration, uint16_t x, uint16_t y)
{
    if (x == 0u || x == RISCC_FRAMEBUFFER_WIDTH - 1u)
    {
        return 0x0fu;
    }
    if (iteration == kMaxIterations)
    {
        return 0u;
    }
    const uint16_t ramp = iteration & 0x003fu;
    const uint16_t base_color = ramp >> 2;
    const uint16_t fraction = ramp & 3u;
    const uint16_t dither_index = (x & 1u) | ((y & 1u) << 1u);
    const bool round_up = fraction > kDitherThresholds[dither_index];
    const uint16_t color = base_color + round_up;

    return color > 15u ? 15u : static_cast<uint8_t>(color);
}

// Frame and ticker

void draw_border()
{
    for (uint16_t word = 0; word < kWordsPerRow; ++word)
    {
        framebuffer[word] = 0xffffu;
        framebuffer[(RISCC_FRAMEBUFFER_HEIGHT - 1u) * kWordsPerRow + word] =
            0xffffu;
    }
    for (uint16_t y = 1; y < RISCC_FRAMEBUFFER_HEIGHT - 1u; ++y)
    {
        volatile uint16_t *const row = framebuffer + y * kWordsPerRow;
        row[0] = 0x000fu;
        row[kWordsPerRow - 1u] = 0xf000u;
    }
}

bool ticker_pixel(uint16_t y, const TickerCursor &cursor)
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

bool next_ticker_pixel(uint16_t y, TickerCursor &cursor)
{
    const bool set = ticker_pixel(y, cursor);

    advance_ticker_cursor(cursor);
    return set;
}

void draw_ticker()
{
    for (uint16_t y = 1; y < kJuliaFirstRow; ++y)
    {
        TickerCursor cursor = {0u, ticker.offset};
        volatile uint16_t *const row = framebuffer + y * kWordsPerRow;

        while (cursor.column >= kGlyphStride)
        {
            cursor.column -= kGlyphStride;
            ++cursor.glyph;
        }

        for (uint16_t word = 0; word < kWordsPerRow; ++word)
        {
            uint16_t packed = 0u;

            for (uint16_t lane = 0; lane < kPixelsPerWord; ++lane)
            {
                if (next_ticker_pixel(y, cursor))
                {
                    packed |= kNibbleMasks[lane];
                }
            }
            if (word == 0)
            {
                packed |= 0x000fu;
            }
            if (word == kWordsPerRow - 1u)
            {
                packed |= 0xf000u;
            }
            row[word] = packed;
        }
    }
}

// Julia animation path

void prepare_axis_step(AxisStep &axis, int16_t delta, uint16_t distance,
                       uint16_t step_count)
{
    axis.whole = static_cast<int16_t>(
        delta / static_cast<int16_t>(step_count));
    axis.remainder = static_cast<uint16_t>(distance % step_count);
    axis.error = 0u;
    axis.direction = delta < 0 ? -1 : 1;
}

void begin_path_segment()
{
    const Point target = kJuliaControlPoints[julia_path.target];
    const int16_t delta_x = static_cast<int16_t>(
        target.x - julia_path.parameter.x);
    const int16_t delta_y = static_cast<int16_t>(
        target.y - julia_path.parameter.y);
    const uint16_t distance_x = magnitude16(delta_x);
    const uint16_t distance_y = magnitude16(delta_y);
    const uint16_t distance = distance_x > distance_y ?
        distance_x : distance_y;

    julia_path.step_count = static_cast<uint16_t>(
        (distance + kParameterStep - 1u) / kParameterStep);
    julia_path.steps_left = julia_path.step_count;
    prepare_axis_step(julia_path.x, delta_x, distance_x,
                      julia_path.step_count);
    prepare_axis_step(julia_path.y, delta_y, distance_y,
                      julia_path.step_count);
}

void advance_axis(int16_t &value, AxisStep &axis, uint16_t step_count)
{
    value = static_cast<int16_t>(value + axis.whole);
    axis.error = static_cast<uint16_t>(axis.error + axis.remainder);
    if (axis.error >= step_count)
    {
        value = static_cast<int16_t>(value + axis.direction);
        axis.error = static_cast<uint16_t>(axis.error - step_count);
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

uint8_t pack_pixels(uint8_t left_iterations, uint8_t right_iterations,
                    uint16_t x, uint16_t y)
{
    return static_cast<uint8_t>(
        julia_color(left_iterations, x, y) |
        (julia_color(right_iterations, x + 1u, y) << 4));
}

void write_cached_rows(uint16_t top_y)
{
    for (uint16_t cache_row = 0; cache_row < kJuliaTileSize; ++cache_row)
    {
        const uint16_t y = top_y + cache_row;
        const uint16_t mirror_y = kJuliaMirrorSumY - y;
        volatile uint8_t *const output =
            framebuffer_bytes + y * kBytesPerRow;

        for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; x += 2u)
        {
            output[x / 2u] = pack_pixels(
                tile_iterations[cache_row][x],
                tile_iterations[cache_row][x + 1u], x, y);
        }

        if (mirror_y != y)
        {
            volatile uint8_t *const output_mirror =
                framebuffer_bytes + mirror_y * kBytesPerRow;

            for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; x += 2u)
            {
                const uint16_t mirror_x =
                    RISCC_FRAMEBUFFER_WIDTH - x - 2u;

                output_mirror[x / 2u] = pack_pixels(
                    tile_iterations[cache_row][mirror_x + 1u],
                    tile_iterations[cache_row][mirror_x], x, mirror_y);
            }
        }
    }
}

void sample_tile(uint16_t x, uint16_t y, uint16_t width)
{
    const uint16_t right = x + width - 1u;

    if (x == 0u)
    {
        for (uint16_t row = 1; row < kJuliaTileSize; ++row)
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
        for (uint16_t row = 1; row < kJuliaTileSize; ++row)
        {
            for (uint16_t column = 1; column < width; ++column)
            {
                tile_iterations[row][x + column] = top_left;
            }
        }
    }
    else
    {
        for (uint16_t row = 1; row < kJuliaTileSize - 1u; ++row)
        {
            for (uint16_t column = 1; column < width; ++column)
            {
                tile_iterations[row][x + column] = static_cast<uint8_t>(
                    escape_time(x + column, y + row));
            }
        }
        for (uint16_t column = 1; column + 1u < width; ++column)
        {
            tile_iterations[kJuliaTileSize - 1u][x + column] =
                static_cast<uint8_t>(escape_time(
                    x + column, y + kJuliaTileSize - 1u));
        }
    }
}

void draw_julia_strip(uint16_t y)
{
    if (y == kJuliaFirstRow)
    {
        for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; ++x)
        {
            tile_iterations[0][x] = static_cast<uint8_t>(escape_time(x, y));
        }
    }
    for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH;
         x += kJuliaTileStep)
    {
        const uint16_t width = RISCC_FRAMEBUFFER_WIDTH - x < kJuliaTileSize ?
            RISCC_FRAMEBUFFER_WIDTH - x : kJuliaTileSize;

        sample_tile(x, y, width);
    }
    write_cached_rows(y);
    if (y + kJuliaTileStep < kJuliaCenterY)
    {
        for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; ++x)
        {
            tile_iterations[0][x] =
                tile_iterations[kJuliaTileSize - 1u][x];
        }
    }
}

void update_ticker()
{
    const uint16_t now = static_cast<uint16_t>(clock());
    uint16_t elapsed = static_cast<uint16_t>(now - ticker.last_tick);
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
        next_julia_row = static_cast<uint16_t>(
            next_julia_row + kJuliaTileStep);
    }
}

}  // namespace

extern "C" int main()
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

    draw_border();
    draw_ticker();

    for (;;)
    {
        draw_next_strip();
    }
}
