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
constexpr int16_t kJuliaCenterX = RISCC_FRAMEBUFFER_WIDTH / 2u;
constexpr int16_t kJuliaCenterY = RISCC_FRAMEBUFFER_HEIGHT / 2u;
constexpr int16_t kViewStep = 20;
constexpr int16_t kParameterStep = 8;
constexpr uint16_t kEscapeRadiusSquared = 4096u;
constexpr uint16_t kMaxIterations = 31u;
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

#ifdef RISCC_ATUM_A3
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
};

const uint8_t kTickerText[] =
{
    kGlyphR, kGlyphI, kGlyphS, kGlyphC, kGlyphDash, kGlyphC, kGlyphSpace,
    kGlyphLowerO, kGlyphLowerN, kGlyphSpace,
    kGlyphA, kGlyphLowerT, kGlyphLowerU, kGlyphLowerM, kGlyphSpace,
    kGlyphA, kGlyph3, kGlyphSpace, kGlyphN, kGlyphLowerA, kGlyphLowerN,
    kGlyphLowerO, kGlyphSpace, kGlyphSpace, kGlyphSpace, kGlyphSpace,
};
#else
enum Glyph : uint8_t
{
    kGlyphR,
    kGlyphI,
    kGlyphS,
    kGlyphC,
    kGlyphDash,
    kGlyphSpace,
    kGlyphJ,
    kGlyphU,
    kGlyphL,
    kGlyphA,
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
    {0x07u, 0x02u, 0x02u, 0x02u, 0x12u, 0x12u, 0x0cu},  // J
    {0x11u, 0x11u, 0x11u, 0x11u, 0x11u, 0x11u, 0x0eu},  // U
    {0x10u, 0x10u, 0x10u, 0x10u, 0x10u, 0x10u, 0x1fu},  // L
    {0x0eu, 0x11u, 0x11u, 0x1fu, 0x11u, 0x11u, 0x11u},  // A
};

const uint8_t kTickerText[] =
{
    kGlyphR, kGlyphI, kGlyphS, kGlyphC, kGlyphDash, kGlyphC, kGlyphSpace,
    kGlyphJ, kGlyphU, kGlyphL, kGlyphI, kGlyphA, kGlyphSpace, kGlyphSpace,
    kGlyphSpace, kGlyphSpace,
};
#endif

constexpr uint16_t kTickerGlyphCount =
    static_cast<uint16_t>(sizeof(kTickerText) / sizeof(kTickerText[0]));
constexpr uint16_t kTickerWidth = kTickerGlyphCount * kGlyphStride;

const Point kJuliaPath[] =
{
    {-571, 571},  {-746, 309},  {-807, 0},    {-746, -309},
    {-571, -571}, {-309, -746}, {0, -807},    {309, -746},
    {571, -571},  {746, -309},  {807, 0},     {746, 309},
    {571, 571},   {309, 746},   {0, 807},     {-309, 746},
};
constexpr uint16_t kJuliaPathCount =
    static_cast<uint16_t>(sizeof(kJuliaPath) / sizeof(kJuliaPath[0]));

uint16_t julia_row = kJuliaFirstRow;
uint16_t ticker_offset;
uint16_t ticker_tick_remainder;
uint16_t julia_target = 1u;
Point julia_c = {-571, 571};
uint16_t ticker_last_tick;

// Equivalent to (left * right) >> 10 without a 32-bit multiply.  Inputs in
// this demo are well inside the signed-16 range, including after negation.
int16_t q10_multiply(int16_t left, int16_t right)
{
    uint16_t negative = 0;
    uint16_t a = static_cast<uint16_t>(left);
    uint16_t b = static_cast<uint16_t>(right);

    if (left < 0)
    {
        a = static_cast<uint16_t>(0u - a);
        negative = 1;
    }
    if (right < 0)
    {
        b = static_cast<uint16_t>(0u - b);
        negative ^= 1u;
    }

    const uint16_t al = a & 0x00ffu;
    const uint16_t ah = a >> 8;
    const uint16_t bl = b & 0x00ffu;
    const uint16_t bh = b >> 8;
    uint16_t result = static_cast<uint16_t>((al * bl) >> 10);

    result = static_cast<uint16_t>(
        result + static_cast<uint16_t>(((ah * bl) + (al * bh)) >> 2));
    result = static_cast<uint16_t>(
        result + static_cast<uint16_t>((ah * bh) << 6));
    if (negative)
    {
        return static_cast<int16_t>(0u - result);
    }
    return static_cast<int16_t>(result);
}

uint16_t julia_pixel(uint16_t x, uint16_t y)
{
    int16_t zx =
        static_cast<int16_t>(static_cast<int16_t>(x) - kJuliaCenterX) *
        kViewStep;
    int16_t zy =
        static_cast<int16_t>(static_cast<int16_t>(y) - kJuliaCenterY) *
        kViewStep;
    uint16_t iteration = 0;

    while (iteration < kMaxIterations)
    {
        const int16_t zx2 = q10_multiply(zx, zx);
        const int16_t zy2 = q10_multiply(zy, zy);

        if (static_cast<uint16_t>(zx2 + zy2) >= kEscapeRadiusSquared)
        {
            break;
        }

        const int16_t next_zy = static_cast<int16_t>(
            static_cast<int16_t>(q10_multiply(zx, zy) * 2) + julia_c.y);
        zx = static_cast<int16_t>(zx2 - zy2 + julia_c.x);
        zy = next_zy;
        ++iteration;
    }

    if (iteration == kMaxIterations)
    {
        return 0;
    }
    return iteration & 0x0fu;
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
        row[0] |= 0x000fu;
        row[kWordsPerRow - 1u] |= 0xf000u;
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

int16_t move_towards(int16_t current, int16_t target)
{
    if (current < target)
    {
        current = static_cast<int16_t>(current + kParameterStep);
        if (current > target)
        {
            current = target;
        }
    }
    else if (current > target)
    {
        current = static_cast<int16_t>(current - kParameterStep);
        if (current < target)
        {
            current = target;
        }
    }
    return current;
}

void update_julia_parameter()
{
    const Point target = kJuliaPath[julia_target];

    julia_c.x = move_towards(julia_c.x, target.x);
    julia_c.y = move_towards(julia_c.y, target.y);
    if (julia_c.x == target.x && julia_c.y == target.y)
    {
        ++julia_target;
        if (julia_target == kJuliaPathCount)
        {
            julia_target = 0;
        }
    }
}

void draw_julia_row(uint16_t y)
{
    volatile uint8_t *pixel = framebuffer_bytes + y * kBytesPerRow;

    for (uint16_t x = 0; x < RISCC_FRAMEBUFFER_WIDTH; x += 2u)
    {
        uint8_t packed = static_cast<uint8_t>(julia_pixel(x, y));

        packed |= static_cast<uint8_t>(julia_pixel(x + 1u, y) << 4);
        if (x == 0)
        {
            packed |= 0x0fu;
        }
        if (x == RISCC_FRAMEBUFFER_WIDTH - 2u)
        {
            packed |= 0xf0u;
        }
        *pixel++ = packed;
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
    draw_julia_row(julia_row);
    ++julia_row;
    if (julia_row == kJuliaLastRow)
    {
        julia_row = kJuliaFirstRow;
        update_julia_parameter();
    }
}

}  // namespace

extern "C" int main()
{
#ifdef RISCC_ATUM_A3
    puts("RISC-C on Atum A3 Nano: C++ Julia");
#else
    puts("RISC-C on icepi-zero: C++ Julia");
#endif
    draw_border();
    draw_ticker();

    ticker_last_tick = static_cast<uint16_t>(clock());

    for (;;)
    {
        draw_next_row();
    }
}
