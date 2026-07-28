// RISC-C board demo: incremental Julia renderer with a 30-pixel-per-second
// title scroll.  This uses only the freestanding C++ language subset; all
// runtime and peripheral services come from the regular C libc and demo BSP.

#include <stdint.h>
#include <stdio.h>
#include <time.h>

#include <riscc/platform.h>

namespace
{

constexpr uint16_t kPixelsPerWord = 4u;
constexpr uint16_t kWordsPerRow = RISCC_FRAMEBUFFER_WIDTH / kPixelsPerWord;
constexpr uint16_t kBytesPerRow = RISCC_FRAMEBUFFER_WIDTH / 2u;
constexpr uint16_t kJuliaFirstRow = 10u;
constexpr uint16_t kJuliaLastRow = RISCC_FRAMEBUFFER_HEIGHT - 1u;
// The Julia area has an even width and an odd height.  Its origin is between
// the middle two columns and on the middle row, so every pixel has an exact
// 180-degree-rotated partner within the area.
constexpr int16_t kJuliaDoubleCenterX = RISCC_FRAMEBUFFER_WIDTH - 1u;
constexpr int16_t kJuliaCenterY =
    (kJuliaFirstRow + kJuliaLastRow - 1u) / 2u;
constexpr uint16_t kJuliaMirrorY =
    kJuliaFirstRow + kJuliaLastRow - 1u;
// Both demo boards render the same 320x180 framebuffer, so they share one
// scale.  This is a 20% wider view than the prior 48-unit step.
constexpr int16_t kViewStep = 48;
// Advance c by at most four Q4.12 units after each completed image, giving
// the exterior path about 1,700 smoothly spaced positions per circuit.
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
// 2x2 ordered screen: the smallest useful halftone cell at this resolution.
const uint8_t kDitherThresholds[4] =
{
    0u, 2u,
    3u, 1u
};
// Palette corrections indexed by the two discarded iteration bits and the
// ordered-dither threshold.  This is ordinary ordered coverage: it never
// spans more than one palette step, and exact palette steps remain solid.
const int8_t kDitherCorrections[4][4] =
{
    {0, 0, 0, 0},
    {1, 0, 0, 0},
    {1, 1, 0, 0},
    {1, 1, 1, 0}
};

#if !defined(RISCC_ATUM_A3) && !defined(RISCC_ICEPI_ZERO)
#error "Board demo requires RISCC_ATUM_A3 or RISCC_ICEPI_ZERO"
#endif

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
#elif defined(RISCC_ICEPI_ZERO)
const uint8_t kTickerText[] =
{
    kGlyphR, kGlyphI, kGlyphS, kGlyphC, kGlyphDash, kGlyphC, kGlyphSpace,
    kGlyphLowerO, kGlyphLowerN, kGlyphSpace,
    kGlyphI, kGlyphLowerC, kGlyphLowerE, kGlyphLowerP, kGlyphLowerI,
    kGlyphSpace, kGlyphZ, kGlyphLowerE, kGlyphLowerR, kGlyphLowerO,
    kGlyphSpace, kGlyphSpace, kGlyphSpace, kGlyphSpace,
};
#else
#error "Board demo requires RISCC_ATUM_A3 or RISCC_ICEPI_ZERO"
#endif

constexpr uint16_t kTickerGlyphCount =
    static_cast<uint16_t>(sizeof(kTickerText) / sizeof(kTickerText[0]));
constexpr uint16_t kTickerWidth = kTickerGlyphCount * kGlyphStride;

// A modest exterior ellipse around the main-cardioid cusp:
// c(t) = 0.55 + 0.20 * cos(t) + 0.36i * sin(t).  Its control points remain
// outside the main cardioid and period-two bulb, giving simpler disconnected
// forms without the large filled interiors that overwhelm a 320x180 view.
const Point kJuliaControlPoints[] =
{
    {3072, 0},    {3044, 382},   {2962, 737},   {2832, 1043},
    {2662, 1277}, {2465, 1424},  {2253, 1475},  {2041, 1424},
    {1843, 1277}, {1674, 1043},  {1543, 737},   {1462, 382},
    {1434, 0},    {1462, -382},  {1543, -737},  {1674, -1043},
    {1843, -1277},{2041, -1424}, {2253, -1475}, {2465, -1424},
    {2662, -1277},{2832, -1043}, {2962, -737},  {3044, -382},
};
constexpr uint16_t kJuliaPathCount =
    static_cast<uint16_t>(sizeof(kJuliaControlPoints) /
                          sizeof(kJuliaControlPoints[0]));

uint16_t julia_row = kJuliaFirstRow;
uint16_t ticker_offset;
uint16_t ticker_tick_remainder;
uint16_t julia_target = 1u;
Point julia_c = {3072, 0};
Point julia_path_step;
uint16_t julia_path_step_count;
uint16_t julia_path_steps_remaining;
uint16_t julia_path_error_x;
uint16_t julia_path_error_y;
uint16_t julia_path_remainder_x;
uint16_t julia_path_remainder_y;
int8_t julia_path_sign_x;
int8_t julia_path_sign_y;
uint16_t ticker_last_tick;
// One full-width tile row holds one tile-height sample row.
uint8_t julia_tile_row_pixels[kJuliaTileSize][RISCC_FRAMEBUFFER_WIDTH];

uint16_t magnitude16(int16_t value)
{
    const uint16_t bits = static_cast<uint16_t>(value);

    return value < 0 ? static_cast<uint16_t>(0u - bits) : bits;
}

// Performs one Q4.12 z = z^2 + c iteration.  Its split products omit only
// low-by-low terms, each of which is below one Q12 output bit.
bool julia_step(int16_t &x, int16_t &y, int16_t cx, int16_t cy)
{
    const uint16_t mx = magnitude16(x);
    const uint16_t my = magnitude16(y);

    if (mx >= static_cast<uint16_t>(kEscapeComponent) ||
        my >= static_cast<uint16_t>(kEscapeComponent))
    {
        return true;
    }

    const uint16_t xh = mx >> kMultiplySplitShift;
    const uint16_t xl = mx & kMultiplyLowMask;
    const uint16_t yh = my >> kMultiplySplitShift;
    const uint16_t yl = my & kMultiplyLowMask;
    const uint16_t xh2 = static_cast<uint16_t>(xh * xh);
    const uint16_t yh2 = static_cast<uint16_t>(yh * yh);
    const uint16_t xhl = static_cast<uint16_t>(xh * xl);
    const uint16_t yhl = static_cast<uint16_t>(yh * yl);
    const uint16_t x2 = static_cast<uint16_t>(
        xh2 + (xhl >> (kMultiplySplitShift - 1u)));
    const uint16_t y2 = static_cast<uint16_t>(
        yh2 + (yhl >> (kMultiplySplitShift - 1u)));

    if (static_cast<uint16_t>(x2 + y2) >= kEscapeRadiusSquared)
    {
        return true;
    }

    const uint16_t xy_high = static_cast<uint16_t>(xh * yh);
    const uint16_t xy_cross = static_cast<uint16_t>(xh * yl + xl * yh);
    const uint16_t xy = static_cast<uint16_t>(
        xy_high + (xy_cross >> kMultiplySplitShift));
    const int16_t signed_xy = (x < 0) != (y < 0)
        ? static_cast<int16_t>(0u - xy)
        : static_cast<int16_t>(xy);

    x = static_cast<int16_t>(
        (static_cast<int16_t>(x2) - static_cast<int16_t>(y2)) + cx);
    y = static_cast<int16_t>(
        static_cast<int16_t>(signed_xy * 2) + cy);
    return false;
}

uint16_t julia_iterations(uint16_t x, uint16_t y)
{
    int16_t zx =
        static_cast<int16_t>(
            static_cast<int16_t>(x * 2u) - kJuliaDoubleCenterX) *
        (kViewStep / 2);
    int16_t zy =
        static_cast<int16_t>(static_cast<int16_t>(y) - kJuliaCenterY) *
        kViewStep;
    uint16_t iteration = 0;

    while (iteration < kMaxIterations)
    {
        if (julia_step(zx, zy, julia_c.x, julia_c.y))
        {
            break;
        }
        ++iteration;
    }

    return iteration;
}

uint8_t julia_output_color(uint16_t iteration, uint16_t x, uint16_t y)
{
    if (x == 0u || x == RISCC_FRAMEBUFFER_WIDTH - 1u)
    {
        return 0x0fu;
    }
    if (iteration == kMaxIterations)
    {
        return 0u;
    }
    // Repeat the 16-color, four-substep ramp every 64 escaped iterations.
    const uint16_t color_iteration = iteration & 0x003fu;
    const uint16_t base_color = color_iteration >> 2;
    const uint16_t fraction = color_iteration & 0x0003u;
    const uint16_t dither_index = (x & 1u) | ((y & 1u) << 1u);
    const uint16_t threshold = kDitherThresholds[dither_index];
    const int16_t dithered_color = static_cast<int16_t>(base_color) +
        kDitherCorrections[fraction][threshold];

    return dithered_color < 0 ? 0u :
        dithered_color > 15 ? 15u : static_cast<uint8_t>(dithered_color);
}

void draw_border()
{
    uint16_t word;

    for (word = 0; word < kWordsPerRow; ++word)
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

bool ticker_pixel(uint16_t row, const TickerCursor &cursor)
{
    if (row < kGlyphTop || row >= kGlyphBottom ||
        cursor.column >= kGlyphWidth)
    {
        return false;
    }
    return (kGlyphs[kTickerText[cursor.glyph]][row - kGlyphTop] &
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

uint16_t ticker_nibble(uint16_t row, TickerCursor &cursor, uint16_t lane)
{
    const bool set = ticker_pixel(row, cursor);

    advance_ticker_cursor(cursor);
    return set ? kNibbleMasks[lane] : 0;
}

void draw_ticker()
{
    for (uint16_t row_index = 1; row_index < kJuliaFirstRow; ++row_index)
    {
        TickerCursor cursor = {0, ticker_offset};
        volatile uint16_t *const row = framebuffer + row_index * kWordsPerRow;

        while (cursor.column >= kGlyphStride)
        {
            cursor.column -= kGlyphStride;
            ++cursor.glyph;
        }

        for (uint16_t word = 0; word < kWordsPerRow; ++word)
        {
            uint16_t packed = ticker_nibble(row_index, cursor, 0u);

            packed |= ticker_nibble(row_index, cursor, 1u);
            packed |= ticker_nibble(row_index, cursor, 2u);
            packed |= ticker_nibble(row_index, cursor, 3u);
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

void begin_julia_path_segment()
{
    const Point target = kJuliaControlPoints[julia_target];
    const int16_t delta_x = static_cast<int16_t>(target.x - julia_c.x);
    const int16_t delta_y = static_cast<int16_t>(target.y - julia_c.y);
    const uint16_t distance_x = magnitude16(delta_x);
    const uint16_t distance_y = magnitude16(delta_y);
    const uint16_t distance = distance_x > distance_y ?
        distance_x : distance_y;

    // Divide the segment into equal DDA steps.  The remainder accumulators
    // place the occasional extra unit so the endpoint is exact.
    julia_path_step_count = static_cast<uint16_t>(
        (distance + kParameterStep - 1u) / kParameterStep);
    julia_path_steps_remaining = julia_path_step_count;
    julia_path_step.x = static_cast<int16_t>(
        delta_x / static_cast<int16_t>(julia_path_step_count));
    julia_path_step.y = static_cast<int16_t>(
        delta_y / static_cast<int16_t>(julia_path_step_count));
    julia_path_remainder_x = static_cast<uint16_t>(
        distance_x % julia_path_step_count);
    julia_path_remainder_y = static_cast<uint16_t>(
        distance_y % julia_path_step_count);
    julia_path_error_x = 0u;
    julia_path_error_y = 0u;
    julia_path_sign_x = delta_x < 0 ? -1 : 1;
    julia_path_sign_y = delta_y < 0 ? -1 : 1;
}

void update_julia_parameter()
{
    if (julia_path_steps_remaining == 0u)
    {
        begin_julia_path_segment();
    }

    julia_c.x = static_cast<int16_t>(julia_c.x + julia_path_step.x);
    julia_c.y = static_cast<int16_t>(julia_c.y + julia_path_step.y);
    julia_path_error_x = static_cast<uint16_t>(
        julia_path_error_x + julia_path_remainder_x);
    julia_path_error_y = static_cast<uint16_t>(
        julia_path_error_y + julia_path_remainder_y);
    if (julia_path_error_x >= julia_path_step_count)
    {
        julia_c.x = static_cast<int16_t>(julia_c.x + julia_path_sign_x);
        julia_path_error_x = static_cast<uint16_t>(
            julia_path_error_x - julia_path_step_count);
    }
    if (julia_path_error_y >= julia_path_step_count)
    {
        julia_c.y = static_cast<int16_t>(julia_c.y + julia_path_sign_y);
        julia_path_error_y = static_cast<uint16_t>(
            julia_path_error_y - julia_path_step_count);
    }
    --julia_path_steps_remaining;
    if (julia_path_steps_remaining == 0u)
    {
        julia_c = kJuliaControlPoints[julia_target];
        ++julia_target;
        if (julia_target == kJuliaPathCount)
        {
            julia_target = 0u;
        }
    }
}

void store_julia_tile_row_pixel(uint16_t row, uint16_t x, uint8_t iteration)
{
    julia_tile_row_pixels[row][x] = iteration;
}

void write_julia_tile_row(uint16_t y)
{
    for (uint16_t row = 0; row < kJuliaTileSize; ++row)
    {
        const uint16_t source_y = y + row;
        const uint16_t mirror_y = kJuliaMirrorY - source_y;

        volatile uint8_t *const source =
            framebuffer_bytes + source_y * kBytesPerRow;

        for (uint16_t byte = 0; byte < kBytesPerRow; ++byte)
        {
            const uint16_t x = byte * 2u;

            source[byte] = static_cast<uint8_t>(
                julia_output_color(julia_tile_row_pixels[row][x], x, source_y) |
                (julia_output_color(julia_tile_row_pixels[row][x + 1u],
                                    x + 1u, source_y) << 4));
        }
        if (mirror_y != source_y)
        {
            volatile uint8_t *const mirror =
                framebuffer_bytes + mirror_y * kBytesPerRow;

            for (uint16_t byte = 0; byte < kBytesPerRow; ++byte)
            {
                const uint16_t source_x =
                    RISCC_FRAMEBUFFER_WIDTH - byte * 2u - 2u;
                const uint16_t x = byte * 2u;

                mirror[byte] = static_cast<uint8_t>(
                    julia_output_color(
                        julia_tile_row_pixels[row][source_x + 1u],
                        x, mirror_y) |
                    (julia_output_color(julia_tile_row_pixels[row][source_x],
                                        x + 1u, mirror_y) << 4));
            }
        }
    }
}

void draw_julia_tile(uint16_t x, uint16_t y, uint16_t width)
{
    const uint16_t right = x + width - 1u;

    if (x == 0)
    {
        for (uint16_t row = 1; row < kJuliaTileSize; ++row)
        {
            store_julia_tile_row_pixel(row, 0u, static_cast<uint8_t>(
                julia_iterations(0u, y + row)));
        }
    }
    const uint8_t top_left = julia_tile_row_pixels[0][x];
    const uint8_t top_right = julia_tile_row_pixels[0][right];
    const uint8_t bottom_left = julia_tile_row_pixels[kJuliaTileSize - 1u][x];
    const uint8_t bottom_right = static_cast<uint8_t>(
        julia_iterations(right, y + kJuliaTileSize - 1u));

    store_julia_tile_row_pixel(
        kJuliaTileSize - 1u, right, bottom_right);
    const bool uniform = top_left == top_right && top_left == bottom_left &&
        top_left == bottom_right;

    if (uniform)
    {
        for (uint16_t row = 1; row < kJuliaTileSize; ++row)
        {
            for (uint16_t column = 1; column < width; ++column)
            {
                store_julia_tile_row_pixel(row, x + column, top_left);
            }
        }
    }
    else
    {
        for (uint16_t row = 1; row < kJuliaTileSize - 1u; ++row)
        {
            for (uint16_t column = 1; column < width; ++column)
            {
                store_julia_tile_row_pixel(row, x + column,
                    static_cast<uint8_t>(julia_iterations(
                        x + column, y + row)));
            }
        }
        for (uint16_t column = 1; column + 1u < width; ++column)
        {
            store_julia_tile_row_pixel(kJuliaTileSize - 1u, x + column,
                static_cast<uint8_t>(julia_iterations(
                    x + column, y + kJuliaTileSize - 1u)));
        }
    }
}

void draw_julia_tile_row(uint16_t y)
{
    if (y == kJuliaFirstRow)
    {
        for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; ++x)
        {
            store_julia_tile_row_pixel(0u, x, static_cast<uint8_t>(
                julia_iterations(x, y)));
        }
    }
    for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH;
         x += kJuliaTileStep)
    {
        const uint16_t width = RISCC_FRAMEBUFFER_WIDTH - x < kJuliaTileSize ?
            RISCC_FRAMEBUFFER_WIDTH - x : kJuliaTileSize;

        draw_julia_tile(x, y, width);
    }
    write_julia_tile_row(y);
    if (y + kJuliaTileStep < kJuliaCenterY)
    {
        for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; ++x)
        {
            julia_tile_row_pixels[0][x] =
                julia_tile_row_pixels[kJuliaTileSize - 1u][x];
        }
    }
}

void advance_ticker()
{
    ++ticker_offset;
    if (ticker_offset == kTickerWidth)
    {
        ticker_offset = 0;
    }
}

void update_ticker()
{
    const uint16_t now = static_cast<uint16_t>(clock());
    uint16_t elapsed = static_cast<uint16_t>(now - ticker_last_tick);
    bool changed = false;

    ticker_last_tick = now;
    while (elapsed)
    {
        ticker_tick_remainder += kTickerPixelsPerSecond;
        if (ticker_tick_remainder >= kClockTicksPerSecond)
        {
            ticker_tick_remainder -= kClockTicksPerSecond;
            advance_ticker();
            changed = true;
        }
        --elapsed;
    }
    if (changed)
    {
        draw_ticker();
    }
}

void draw_next_row()
{
    update_ticker();
    draw_julia_tile_row(julia_row);
    if (julia_row + kJuliaTileStep >= kJuliaCenterY)
    {
        julia_row = kJuliaFirstRow;
        update_julia_parameter();
    }
    else
    {
        julia_row = static_cast<uint16_t>(julia_row + kJuliaTileStep);
    }
}

}  // namespace

extern "C" int main()
{
#ifdef RISCC_ATUM_A3
    puts("RISC-C on Atum A3 Nano");
#elif defined(RISCC_ICEPI_ZERO)
    puts("RISC-C on Icepi Zero");
#endif
    draw_border();
    draw_ticker();

    ticker_last_tick = static_cast<uint16_t>(clock());

    for (;;)
    {
        draw_next_row();
    }
}
