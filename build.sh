#!/usr/bin/env bash
# Cross-compile NetSurf (framebuffer) for Kindle from the official "netsurf-all" sources.
# Prerequisites: the koxtoolchain compiler in PATH and its tuple in TARGET_TUPLE.
set -euo pipefail

TARGET_TUPLE="${TARGET_TUPLE:?Set TARGET_TUPLE, e.g. arm-kindlehf-linux-gnueabihf}"
JOBS="${JOBS:-$(nproc)}"
VER="${NS_VERSION:-3.11}"
ROOT="$(pwd)"
PREFIX="$ROOT/ns-prefix"     # target libraries go here
HOSTPREFIX="$ROOT/ns-host"   # tools run on the build host (nsgenbind, buildsystem)
OUT="$ROOT/out"
export CROSS="${TARGET_TUPLE}-"

mkdir -p "$PREFIX" "$HOSTPREFIX" "$OUT"

TARBALL="netsurf-all-${VER}.tar.gz"
URL="https://download.netsurf-browser.org/netsurf/releases/source-full/${TARBALL}"

echo "==> downloading sources: $URL"
ok=0
for i in 1 2 3 4 5; do
  if curl -fSL --retry 3 -o "$TARBALL" "$URL"; then ok=1; break; fi
  echo "download #$i failed, retrying in 15 seconds..."; sleep 15
done
[ "$ok" = "1" ] || { echo "ERROR: failed to download the sources"; exit 1; }

echo "==> extracting"
tar xzf "$TARBALL"
SRC="$ROOT/netsurf-all-${VER}"
[ -d "$SRC" ] || { echo "ERROR: $SRC is missing after extracting the tarball"; exit 1; }

# netsurf-all contains exactly these components, with the same layout as the Git repositories
TARGET_LIBS="libwapcaplet libparserutils libhubbub libdom libcss libnsbmp libnsgif libnsutils libnspsl libutf8proc libnsfb"

# 1) buildsystem - required for both host and target
echo "==> buildsystem"
make -C "$SRC/buildsystem" PREFIX="$HOSTPREFIX" install
make -C "$SRC/buildsystem" PREFIX="$PREFIX" install
HOST_NSSHARED="$HOSTPREFIX/share/netsurf-buildsystem"
TGT_NSSHARED="$PREFIX/share/netsurf-buildsystem"

# 2) nsgenbind - runs on the BUILD host (JS bindings), built with the native compiler
echo "==> nsgenbind (host, native)"
make -C "$SRC/nsgenbind" PREFIX="$HOSTPREFIX" NSSHARED="$HOST_NSSHARED" install
# The netsurf Makefile calls nsgenbind by its bare name -> put it in PATH
export PATH="$HOSTPREFIX/bin:$PATH"

# 2b) expat - required for libdom XML bindings, cross-compiled into our prefix (static)
EXPAT_VER="${EXPAT_VER:-2.6.4}"
EXPAT_TAG="R_$(echo "$EXPAT_VER" | tr '.' '_')"
echo "==> expat ${EXPAT_VER} (target, static)"
ok=0
for i in 1 2 3; do
  if curl -fSL -o expat.tar.gz \
      "https://github.com/libexpat/libexpat/releases/download/${EXPAT_TAG}/expat-${EXPAT_VER}.tar.gz"; then ok=1; break; fi
  echo "expat download #$i failed, retrying in 10 seconds..."; sleep 10
done
[ "$ok" = "1" ] || { echo "ERROR: failed to download expat"; exit 1; }
tar xzf expat.tar.gz
( cd "expat-${EXPAT_VER}" && \
  ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
      --enable-static --disable-shared \
      --without-docbook --without-examples --without-tests \
      CC="${CROSS}gcc" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" && \
  make -j"$JOBS" && make install )

# The old NetSurf sources produce many warnings, which newer GCC turns into errors
# with -Werror. A compiler wrapper appends -Wno-error to the END of the command
# (overriding any earlier -Werror), so warnings are not fatal.
REALGCC="$(command -v "${CROSS}gcc")"
WRAP="$ROOT/ccwrap"
mkdir -p "$WRAP"
printf '#!/bin/sh\nexec "%s" "$@" -Wno-error\n' "$REALGCC" > "$WRAP/${CROSS}gcc"
chmod +x "$WRAP/${CROSS}gcc"
export PATH="$WRAP:$PATH"

export CFLAGS="-I$PREFIX/include -O2"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

tmake() {
  local dir="$1"; shift
  make -C "$SRC/$dir" -j"$JOBS" \
    CC="${CROSS}gcc" AR="${CROSS}ar" \
    PREFIX="$PREFIX" NSSHARED="$TGT_NSSHARED" \
    COMPONENT_TYPE=lib-static "$@"
}

echo "==> building target libraries"
for lib in $TARGET_LIBS; do
  echo "   -- $lib"
  if [ "$lib" = "libnsfb" ]; then
    # Package the palette API sources (for implementing the grayscale palette)
    mkdir -p "$OUT/libnsfb-src"
    cp "$SRC/$lib"/src/*.h "$OUT/libnsfb-src/" 2>/dev/null || true
    cp "$SRC/$lib"/src/palette.c "$SRC/$lib"/src/libnsfb.c "$OUT/libnsfb-src/" 2>/dev/null || true
    # --- Add a custom Kindle framebuffer surface to libnsfb ---
    echo "   >>> adding kindle framebuffer surface"
    cat > "$SRC/$lib/src/surface/kindlefb.c" <<'KFBEOF'
/* Kindle framebuffer surface for libnsfb.
 * NetSurf draws into a 32bpp (ABGR) RAM buffer; on update, the changed region is
 * converted to luminance (8bpp grayscale) and copied to /dev/fb0 (Y8, hwtcon_v2).
 * External fbink handles e-ink refreshes. Surface name: "kindle".
 * Touch input is read directly from the /dev/input/event* evdev device:
 *   - tap -> mouse click (MOUSE_1 down/up at the given position)
 *   - vertical drag -> scrolling (MOUSE_4/MOUSE_5)
 * Axis orientation can be adjusted through environment variables without recompiling:
 *   NETSURF_TOUCH_DEV, NETSURF_TOUCH_SWAP, NETSURF_TOUCH_INVX, NETSURF_TOUCH_INVY */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <poll.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <signal.h>

#include "libnsfb.h"
#include "libnsfb_plot.h"
#include "libnsfb_event.h"

#include "nsfb.h"
#include "surface.h"
#include "plot.h"

#define UNUSED(x) ((x) = (x))

#include <stdarg.h>
/* Diagnostic log to stderr (the launcher redirects it to netsurf.log) */
static void ktlog(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("KINDLETOUCH: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(ap);
    /* Persistent, append-only diagnostic log: NOT overwritten on restart,
     * so field-test traces survive even if the browser restarts. */
    {
        const char *fl = getenv("NETSURF_FIELD_LOG");
        if (fl != NULL && fl[0] != 0) {
            FILE *lf = fopen(fl, "a");
            if (lf != NULL) {
                va_list ap2;
                va_start(ap2, fmt);
                vfprintf(lf, fmt, ap2);
                va_end(ap2);
                fputc('\n', lf);
                fclose(lf);
            }
        }
    }
}

static int      kfb_fd = -1;
static uint8_t *kfb_mem = NULL;      /* mmap of the physical framebuffer (8bpp) */
static size_t   kfb_memlen = 0;
static int      kfb_linelen = 0;     /* framebuffer row length in bytes */
static int      kfb_bpp     = 8;     /* framebuffer bit depth (8 = grayscale Paperwhite, 32 = color Colorsoft) */
static int      kfb_bytespp = 1;     /* bytes/pixel = kfb_bpp/8 */
/* Byte indices of framebuffer R/G/B/A channels (default: BGRA / XRGB8888 little-endian) */
static int      ch_r = 2, ch_g = 1, ch_b = 0, ch_a = 3;

/* Write a color pixel (>=24bpp): actual R,G,B in framebuffer channel order. */
static inline void kfb_store_color(uint8_t *px, int r, int g, int b)
{
    px[ch_r] = (uint8_t)r; px[ch_g] = (uint8_t)g; px[ch_b] = (uint8_t)b;
    if (ch_a >= 0 && ch_a < kfb_bytespp) px[ch_a] = 0xFF;
}

/* Write a pixel to the physical framebuffer according to bit depth. v = 8-bit gray.
 * 8bpp: 1 byte; 16bpp: RGB565 gray; 32bpp: B,G,R,A (gray in all three channels). */
static inline void kfb_store(uint8_t *px, uint8_t v)
{
    switch (kfb_bytespp) {
    case 1:
        px[0] = v;
        break;
    case 2: {
        uint16_t p = (uint16_t)(((v >> 3) << 11) | ((v >> 2) << 5) | (v >> 3));
        px[0] = (uint8_t)(p & 0xFF);
        px[1] = (uint8_t)(p >> 8);
        break;
    }
    case 4:
        px[0] = v; px[1] = v; px[2] = v; px[3] = 0xFF;
        break;
    default:
        px[0] = v;
        break;
    }
}

/* ---- MTK (hwtcon) e-ink refresh: display the drawn region immediately ----
 * Source: FBInk/eink/mtk-kindle.h (PW5/PW6, hwtcon_v2). _IOW also encodes the
 * structure size, so it must be exact. */
struct mtk_rect { uint32_t top, left, width, height; };
struct mtk_alt_buffer { uint32_t phys_addr, width, height; struct mtk_rect region; };
struct mtk_swipe { uint32_t direction, steps; };
struct mtk_update_data {
    struct mtk_rect        update_region;
    uint32_t               waveform_mode;
    uint32_t               update_mode;
    uint32_t               update_marker;
    int32_t                temp;
    uint32_t               flags;
    int32_t                dither_mode;
    int32_t                quant_bit;
    struct mtk_alt_buffer  alt_buffer_data;
    struct mtk_swipe       swipe_data;
    uint32_t               hist_bw_waveform_mode;
    uint32_t               hist_gray_waveform_mode;
    uint32_t               ts_pxp;
    uint32_t               ts_epdc;
};
#define MTK_WAVEFORM_AUTO   257
#define MTK_WAVEFORM_GC16   2
#define MTK_WAVEFORM_GL16   3
#define MTK_UPDATE_PARTIAL  0
#define MTK_UPDATE_FULL     1
#define MTK_TEMP_AMBIENT    0x1000
#define MXCFB_SEND_UPDATE_MTK _IOW('F', 0x2E, struct mtk_update_data)

static int      mtk_ok = 1;          /* 0: ioctl unavailable, fall back to the fbink loop */
static uint32_t mtk_marker = 0;
static int      mtk_logged = 0;      /* log the first ioctl result */

/* ---- minimize (SIGSTOP) / resume (SIGCONT) ----
 * The browser is "frozen" in the background (KOReader regains the screen and
 * touch input). On resume, SIGCONT arrives; redraw the entire 32bpp RAM buffer
 * (nsfb->ptr), because KOReader has repainted the framebuffer in the meantime. */
static volatile sig_atomic_t g_resumed = 0;   /* 1: full redraw required after SIGCONT */
static void on_sigcont(int sig) { (void)sig; g_resumed = 1; }

/* ===================== CUSTOM TOOLBAR (KOReader-style top bar) ===================== */
/* DejaVuSansMono 26px, ASCII 32..126, 14x28 cell, uint16 per row (MSB=left) */
#define KFB_FONT_CW 14
#define KFB_FONT_CH 28
#define KFB_FONT_FIRST 32
static const unsigned short kfb_font[95][28] = {
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x0060,0x0060,0x0060,0x0060,0x0000,0x0000,0x0000,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0398,0x0398,0x0398,0x0398,0x0398,0x0398,0x0398,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00e3,0x00c7,0x00c6,0x00c6,0x01c6,0x1fff,0x1fff,0x018c,0x038c,0x0318,0x0318,0x3fff,0x3fff,0x0630,0x0630,0x0630,0x0c70,0x0c60,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0060,0x0060,0x0060,0x01fc,0x03fe,0x0766,0x0660,0x0e60,0x0e60,0x0760,0x07e0,0x03fc,0x007e,0x0067,0x0067,0x0063,0x0067,0x0c6f,0x0ffe,0x03f8,0x0060,0x0060,0x0060,0x0060},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0f80,0x1fc0,0x18c0,0x3060,0x3060,0x18c0,0x1fc3,0x0f8e,0x0038,0x00e0,0x0380,0x0e1e,0x183f,0x0071,0x0061,0x0061,0x0071,0x003f,0x001e,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f0,0x03f8,0x0708,0x0600,0x0600,0x0700,0x0300,0x0380,0x07c0,0x0ce1,0x1c61,0x1871,0x1839,0x181d,0x180f,0x1c0f,0x0e1f,0x07ff,0x03f3,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0018,0x0038,0x0030,0x0070,0x0060,0x00e0,0x00e0,0x00c0,0x00c0,0x00c0,0x01c0,0x01c0,0x01c0,0x00c0,0x00c0,0x00c0,0x00e0,0x00e0,0x0060,0x0070,0x0030,0x0038,0x0018,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0180,0x0180,0x00c0,0x00c0,0x00e0,0x0060,0x0070,0x0070,0x0070,0x0030,0x0030,0x0030,0x0030,0x0030,0x0070,0x0070,0x0070,0x0060,0x00e0,0x00c0,0x00c0,0x0180,0x0180,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0060,0x0060,0x0462,0x0e6e,0x03fc,0x00f0,0x00f0,0x03fc,0x0e6e,0x0462,0x0060,0x0060,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x1fff,0x1fff,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00f0,0x00f0,0x00f0,0x00e0,0x00e0,0x01c0,0x0180,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x03f8,0x03f8,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00e0,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0007,0x000e,0x000e,0x000c,0x001c,0x0018,0x0038,0x0030,0x0070,0x0060,0x00e0,0x00c0,0x01c0,0x0180,0x0380,0x0300,0x0700,0x0600,0x0e00,0x0c00,0x1c00,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f0,0x03fc,0x071c,0x060e,0x0e06,0x0e07,0x0e07,0x0c07,0x0c67,0x0cf7,0x0c67,0x0c07,0x0e07,0x0e07,0x0e06,0x060e,0x071c,0x03fc,0x01f0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f0,0x07f0,0x0770,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x07ff,0x07ff,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x03f0,0x0ffc,0x0e1e,0x080e,0x000e,0x0006,0x000e,0x000e,0x001c,0x001c,0x0038,0x0070,0x00e0,0x01c0,0x0380,0x0700,0x0e00,0x0fff,0x0fff,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x03f0,0x0ffc,0x0c1e,0x000e,0x0006,0x0006,0x000e,0x001c,0x01f8,0x01f8,0x001e,0x000e,0x0007,0x0007,0x0007,0x000e,0x0c1e,0x0ffc,0x07f0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x001c,0x003c,0x007c,0x007c,0x00dc,0x019c,0x019c,0x031c,0x071c,0x061c,0x0c1c,0x1c1c,0x1fff,0x1fff,0x001c,0x001c,0x001c,0x001c,0x001c,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x07fc,0x07fc,0x0600,0x0600,0x0600,0x0600,0x07f0,0x07fc,0x041c,0x000e,0x0006,0x0007,0x0007,0x0007,0x0006,0x000e,0x0c1c,0x0ffc,0x07f0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x00fc,0x03fe,0x0786,0x0700,0x0e00,0x0e00,0x0c00,0x0cf8,0x0dfc,0x0f0e,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0607,0x070e,0x03fc,0x01f8,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0fff,0x0fff,0x0006,0x000e,0x000c,0x001c,0x001c,0x0018,0x0038,0x0038,0x0070,0x0070,0x0060,0x00e0,0x00e0,0x00c0,0x01c0,0x01c0,0x0380,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f8,0x07fc,0x070e,0x0e06,0x0e07,0x0e06,0x0e06,0x070e,0x03f8,0x03fc,0x070e,0x0e07,0x0c07,0x0c07,0x0c07,0x0e07,0x0f0e,0x07fc,0x01f8,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f0,0x07fc,0x0f1c,0x0e0e,0x0c06,0x0c07,0x0c07,0x0c07,0x0e0f,0x0f1f,0x07ff,0x01f7,0x0007,0x0006,0x0006,0x000e,0x041c,0x07f8,0x03f0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00e0,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000,0x0000,0x00e0,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00e0,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000,0x0000,0x00f0,0x00f0,0x00f0,0x00e0,0x00e0,0x01c0,0x0180,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0001,0x0007,0x003f,0x00fc,0x07e0,0x1f80,0x1c00,0x1f80,0x07e0,0x00fc,0x003f,0x0007,0x0001,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x1fff,0x1fff,0x0000,0x0000,0x0000,0x1fff,0x1fff,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x1800,0x1e00,0x1f80,0x03f0,0x00fc,0x001f,0x0007,0x001f,0x007c,0x03f0,0x1f80,0x1e00,0x1800,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f8,0x03fc,0x071e,0x040e,0x0006,0x000e,0x000e,0x001c,0x0038,0x0070,0x00e0,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00fc,0x03fe,0x0787,0x0e03,0x0c01,0x1801,0x183d,0x18ff,0x38e3,0x31c1,0x3181,0x3181,0x31c1,0x38e3,0x18ff,0x183d,0x1c00,0x0c00,0x0600,0x0782,0x01fe,0x007e},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x00f0,0x00f0,0x01f0,0x01f8,0x01b8,0x0198,0x0398,0x031c,0x031c,0x070c,0x070e,0x060e,0x0ffe,0x0fff,0x0c07,0x1c07,0x1c03,0x1c03,0x1803,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0ff8,0x0ffc,0x0e0e,0x0e07,0x0e07,0x0e07,0x0e07,0x0e0e,0x0ffc,0x0ffc,0x0e0e,0x0e07,0x0e03,0x0e03,0x0e03,0x0e07,0x0e0f,0x0ffe,0x0ff8,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x00fc,0x01ff,0x0387,0x0701,0x0600,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0600,0x0701,0x0387,0x01ff,0x00fc,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0fe0,0x0ff8,0x0c3c,0x0c0e,0x0c0e,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c0e,0x0c0e,0x0c3c,0x0ff8,0x0fe0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0fff,0x0fff,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0ffe,0x0ffe,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0fff,0x0fff,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x07ff,0x07ff,0x0700,0x0700,0x0700,0x0700,0x0700,0x0700,0x07fe,0x07fe,0x0700,0x0700,0x0700,0x0700,0x0700,0x0700,0x0700,0x0700,0x0700,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x00fc,0x03fe,0x0786,0x0700,0x0e00,0x0e00,0x0c00,0x1c00,0x1c00,0x1c1f,0x1c1f,0x1c07,0x0c07,0x0e07,0x0e07,0x0707,0x0787,0x03ff,0x00fc,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0fff,0x0fff,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0c07,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0ffe,0x0ffe,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x0ffe,0x0ffe,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01fc,0x01fc,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x001c,0x001c,0x101c,0x1c3c,0x1ff8,0x07e0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0c03,0x0c07,0x0c0e,0x0c1c,0x0c38,0x0c70,0x0ce0,0x0dc0,0x0fe0,0x0fe0,0x0e70,0x0e38,0x0c38,0x0c1c,0x0c1e,0x0c0e,0x0c07,0x0c07,0x0c03,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x07ff,0x07ff,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x1e07,0x1e07,0x1e0f,0x1f0f,0x1f1b,0x1d1b,0x1d9b,0x1db3,0x1cf3,0x1cf3,0x1ce3,0x1c63,0x1c03,0x1c03,0x1c03,0x1c03,0x1c03,0x1c03,0x1c03,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0e07,0x0f07,0x0f07,0x0f87,0x0f87,0x0d87,0x0dc7,0x0cc7,0x0ce7,0x0c67,0x0c67,0x0c37,0x0c37,0x0c3f,0x0c1f,0x0c1f,0x0c0f,0x0c0f,0x0c0f,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f0,0x03fc,0x071e,0x0e0e,0x0e07,0x0e07,0x0c07,0x0c07,0x1c07,0x1c07,0x1c07,0x0c07,0x0c07,0x0e07,0x0e07,0x0e0e,0x071e,0x03fc,0x01f0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0ff8,0x0ffe,0x0e0f,0x0e07,0x0e03,0x0e03,0x0e03,0x0e07,0x0e0f,0x0ffe,0x0ff8,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f0,0x03fc,0x071e,0x0e0e,0x0e07,0x0e07,0x0c07,0x0c07,0x1c07,0x1c07,0x1c07,0x0c07,0x0c07,0x0e07,0x0e07,0x0e0e,0x071e,0x03fc,0x01f8,0x001c,0x000e,0x0004,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0ff0,0x0ffc,0x0c1e,0x0c0e,0x0c07,0x0c07,0x0c07,0x0c0e,0x0c1e,0x0ff8,0x0ff8,0x0c1c,0x0c0c,0x0c0e,0x0c06,0x0c07,0x0c03,0x0c03,0x0c01,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x01f8,0x07fe,0x070e,0x0e02,0x0c00,0x0c00,0x0e00,0x0f00,0x07e0,0x03fc,0x007e,0x000f,0x0007,0x0007,0x0007,0x0807,0x0e0e,0x0ffc,0x03f8,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x1fff,0x1fff,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e07,0x0e06,0x070e,0x07fc,0x01f8,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x1c03,0x1c03,0x1c03,0x0c07,0x0e07,0x0e06,0x060e,0x060e,0x070e,0x070c,0x031c,0x031c,0x0398,0x0198,0x01b8,0x01f0,0x01f0,0x00f0,0x00f0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x3801,0x3801,0x3801,0x3801,0x1801,0x18e3,0x18f3,0x18f3,0x1cf3,0x1db3,0x1db3,0x0d9b,0x0d9b,0x0d9f,0x0f1f,0x0f0e,0x0f0e,0x070e,0x060e,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x1c03,0x0e07,0x0606,0x070e,0x038c,0x039c,0x01f8,0x00f0,0x00f0,0x00f0,0x00f0,0x01f8,0x039c,0x031c,0x070e,0x0e06,0x0e07,0x1c03,0x3803,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x1c03,0x1c03,0x0e07,0x0e0e,0x070e,0x031c,0x0398,0x01b8,0x01f0,0x00f0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0fff,0x0fff,0x0007,0x0007,0x000e,0x001c,0x001c,0x0038,0x0070,0x0070,0x00e0,0x01c0,0x01c0,0x0380,0x0300,0x0700,0x0e00,0x0fff,0x0fff,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x00f8,0x00f8,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00f8,0x00f8,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x1c00,0x0c00,0x0e00,0x0600,0x0700,0x0300,0x0380,0x0180,0x01c0,0x00c0,0x00e0,0x0060,0x0070,0x0030,0x0038,0x0018,0x001c,0x000c,0x000e,0x000e,0x0007,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x03f0,0x03f0,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x0070,0x03f0,0x03f0,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x00e0,0x01f0,0x01b8,0x039c,0x070e,0x0e07,0x1c03,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0300,0x0180,0x00c0,0x00e0,0x0060,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x03f8,0x07fc,0x060e,0x0006,0x0006,0x03fe,0x07ff,0x0f07,0x0c07,0x0c07,0x0c0f,0x0e1f,0x07f7,0x03e7,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0ef8,0x0ffc,0x0f8e,0x0f07,0x0e07,0x0e07,0x0e03,0x0e03,0x0e07,0x0e07,0x0f07,0x0f8e,0x0ffc,0x0ef8,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00fc,0x01fe,0x0387,0x0700,0x0600,0x0600,0x0e00,0x0e00,0x0600,0x0600,0x0700,0x0387,0x01fe,0x00fc,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0006,0x0006,0x0006,0x0006,0x0006,0x0006,0x01e6,0x07fe,0x071e,0x0e0e,0x0c0e,0x0c06,0x0c06,0x0c06,0x0c06,0x0c0e,0x0e0e,0x071e,0x07fe,0x01e6,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01f8,0x03fc,0x070e,0x0e07,0x0e07,0x0c03,0x0fff,0x0fff,0x0c00,0x0c00,0x0e00,0x0703,0x03ff,0x01fc,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x003f,0x007f,0x0060,0x00e0,0x00e0,0x00e0,0x0fff,0x0fff,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01e6,0x07fe,0x071e,0x0e0e,0x0c0e,0x0c06,0x0c06,0x0c06,0x0c06,0x0c0e,0x0e0e,0x071e,0x07f6,0x01e6,0x0006,0x000e,0x061c,0x07fc},
  {0x0000,0x0000,0x0000,0x0000,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e00,0x0e78,0x0ffc,0x0f8e,0x0f06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0060,0x0060,0x0060,0x0000,0x0000,0x0000,0x07e0,0x07e0,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0fff,0x0fff,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000,0x03f0,0x03f0,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0070,0x0070,0x0070,0x0fe0},
  {0x0000,0x0000,0x0000,0x0000,0x0600,0x0600,0x0600,0x0600,0x0600,0x0600,0x0607,0x060e,0x061c,0x0638,0x0670,0x07e0,0x07f0,0x0730,0x0738,0x061c,0x060e,0x0606,0x0607,0x0603,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0fc0,0x0fc0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00e0,0x007e,0x003e,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x1fce,0x1fff,0x1cf3,0x1c63,0x1c63,0x1c63,0x1c63,0x1c63,0x1c63,0x1c63,0x1c63,0x1c63,0x1c63,0x1c63,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0e78,0x0ffc,0x0f8e,0x0f06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01f8,0x03fc,0x070e,0x0e06,0x0e07,0x0c07,0x0c07,0x0c07,0x0c07,0x0e07,0x0e06,0x070e,0x03fc,0x01f8,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0ef8,0x0ffc,0x0f8e,0x0f07,0x0e07,0x0e07,0x0e03,0x0e03,0x0e07,0x0e07,0x0f07,0x0f8e,0x0ffc,0x0ef8,0x0e00,0x0e00,0x0e00,0x0e00},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01e6,0x03fe,0x071e,0x0e0e,0x0e06,0x0c06,0x0c06,0x0c06,0x0c06,0x0e06,0x0e0e,0x071e,0x07fe,0x01e6,0x0006,0x0006,0x0006,0x0006},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x019f,0x01bf,0x01e0,0x01c0,0x0180,0x0180,0x0180,0x0180,0x0180,0x0180,0x0180,0x0180,0x0180,0x0180,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01f8,0x03fc,0x0704,0x0600,0x0600,0x0700,0x03f8,0x00fc,0x001e,0x0006,0x000e,0x060e,0x07fc,0x03f8,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01c0,0x01c0,0x01c0,0x01c0,0x0ffe,0x0ffe,0x01c0,0x01c0,0x01c0,0x01c0,0x01c0,0x01c0,0x01c0,0x01c0,0x01c0,0x00e0,0x00fe,0x007e,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x0e06,0x060e,0x071e,0x07f6,0x01e6,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x1c03,0x0c07,0x0e07,0x0e06,0x060e,0x070c,0x030c,0x031c,0x0398,0x0198,0x01b8,0x01f0,0x00f0,0x00f0,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x3001,0x3801,0x1801,0x1801,0x1863,0x1ce3,0x1cf3,0x0cf3,0x0db7,0x0d96,0x0f9e,0x071e,0x070e,0x070e,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0c07,0x060e,0x070c,0x039c,0x01b8,0x00f0,0x00e0,0x00f0,0x01f8,0x0398,0x031c,0x070e,0x0e07,0x1c03,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x1c03,0x0c03,0x0e07,0x0606,0x070e,0x030c,0x030c,0x039c,0x0198,0x01f8,0x00f0,0x00f0,0x00f0,0x0060,0x00e0,0x00e0,0x01c0,0x0f80},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x07fe,0x07fe,0x000e,0x001c,0x0018,0x0030,0x0070,0x00e0,0x01c0,0x0380,0x0300,0x0700,0x07fe,0x07fe,0x0000,0x0000,0x0000,0x0000},
  {0x0000,0x0000,0x0000,0x0000,0x003e,0x007e,0x0070,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x00e0,0x00e0,0x07c0,0x07c0,0x00e0,0x00e0,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0070,0x007e,0x003e},
  {0x0000,0x0000,0x0000,0x0000,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060},
  {0x0000,0x0000,0x0000,0x0000,0x0780,0x07c0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x0060,0x0060,0x0070,0x003e,0x003e,0x0070,0x0060,0x0060,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x00e0,0x07c0,0x0780},
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0780,0x1fe1,0x187f,0x101e,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000},
};

#define KFB_TBAR_H 72          /* custom toolbar height (physical) */
#define KFB_GUTTER 14          /* left content margin (retained when zooming) */
#define KFB_RGUT   64          /* right column: ▲ PageUp (top) / ▼ PageDown (bottom) */

static int kfb_scrw = 0, kfb_scrh = 0;   /* PHYSICAL display size (including toolbar and gutter) */

/* State shared with gui.c (NOT static, so the frontend can access it) */
char g_toolbar_url[1024] = "";
volatile sig_atomic_t g_toolbar_url_dirty = 1;     /* 1: URL needs redrawing */
volatile sig_atomic_t g_nav_request = 0;           /* 1=back 2=forward 3=reload 4=close (handled by the main loop) */
/* In-page input fields -> KOReader keyboard (NetSurf's own OSK is disabled) */
volatile sig_atomic_t g_field_click_pending = 0;   /* user just tapped a field (decremented by the main loop) */
volatile sig_atomic_t g_field_input_request = 0;   /* field focused -> KOReader keyboard needed */
volatile sig_atomic_t g_inject_request = 0;        /* inject entered text into the field after resuming */

/* Button identifiers */
enum { TB_NONE=0, TB_BACK, TB_FWD, TB_RELOAD, TB_READER, TB_MIN, TB_CLOSE, TB_URL };

/* ---- touch input (evdev) ---- */
#ifndef ABS_MT_POSITION_X
#define ABS_MT_POSITION_X 0x35
#endif
#ifndef ABS_MT_POSITION_Y
#define ABS_MT_POSITION_Y 0x36
#endif
#ifndef ABS_MT_TRACKING_ID
#define ABS_MT_TRACKING_ID 0x39
#endif

#define BITS_PER_LONG (sizeof(long) * 8)
#define NBITS(x) ((((x) - 1) / BITS_PER_LONG) + 1)
#define TEST_BIT(bit, arr) (((arr)[(bit) / BITS_PER_LONG] >> ((bit) % BITS_PER_LONG)) & 1)

static int   ts_fd = -1;
static int   ts_inited = 0;
static int   ts_min_x = 0, ts_max_x = 0, ts_min_y = 0, ts_max_y = 0;
static int   ts_swap = 0, ts_invx = 0, ts_invy = 0;

/* Raw touch state in the current frame */
static int   raw_x = 0, raw_y = 0;
static int   have_x = 0, have_y = 0;
static int   frame_down = -1;        /* -1: no change, 0: up, 1: down */

/* Gesture state */
static int   g_down = 0;
static int   g_start_x = 0, g_start_y = 0;
static int   g_last_x = 0,  g_last_y = 0;
static int   g_moved = 0;
static int   g_scrolling = 0;
static int   g_scroll_accum = 0;
static int   g_scroll_accx = 0;   /* horizontal scroll accumulator */
static int   g_min_fired = 0;     /* minimization already triggered during this gesture */

#define TAP_MAX_MOVE 18      /* movement below this threshold: tap */
#define SCROLL_STEP  80      /* drag distance in pixels per scroll step */
#define SCROLL_MAX_PER_FRAME 4
#define TOP_EDGE_PX      70  /* height of the strip treated as the top edge */
#define TOP_DRAG_TRIGGER 160 /* downward drag distance from the top edge to minimize */

/* Multitouch slots for PINCH-ZOOM (type B protocol, ABS_MT_SLOT) */
#ifndef ABS_MT_SLOT
#define ABS_MT_SLOT 0x2f
#endif
#define NSLOTS 2
static int   cur_slot = 0;
static int   sl_active[NSLOTS] = {0, 0};
static int   sl_x[NSLOTS] = {0, 0};
static int   sl_y[NSLOTS] = {0, 0};
static int   pinch_on = 0;
static int   pinch_last = 0;
#define PINCH_STEP 60        /* raw distance change per zoom step */

/* Small event queue, because the surface can return only one event per call
 * (enlarged to accommodate longer text injected into fields) */
#define EVQ_SIZE 1024
static nsfb_event_t evq[EVQ_SIZE];
static int evq_head = 0, evq_tail = 0;

static void evq_push_key(enum nsfb_event_type_e type, enum nsfb_key_code_e code)
{
    int nt = (evq_tail + 1) % EVQ_SIZE;
    if (nt == evq_head) return;            /* full: discard */
    evq[evq_tail].type = type;
    evq[evq_tail].value.keycode = code;
    evq_tail = nt;
}

static void evq_push_move(int x, int y)
{
    int nt = (evq_tail + 1) % EVQ_SIZE;
    if (nt == evq_head) return;
    evq[evq_tail].type = NSFB_EVENT_MOVE_ABSOLUTE;
    evq[evq_tail].value.vector.x = x;
    evq[evq_tail].value.vector.y = y;
    evq[evq_tail].value.vector.z = 0;
    evq_tail = nt;
}

static int evq_pop(nsfb_event_t *out)
{
    if (evq_head == evq_tail) return 0;
    *out = evq[evq_head];
    evq_head = (evq_head + 1) % EVQ_SIZE;
    return 1;
}

static int kindle_defaults(nsfb_t *nsfb)
{
    nsfb->width = 0;
    nsfb->height = 0;
    nsfb->format = NSFB_FMT_ABGR8888;
    select_plotters(nsfb);
    return 0;
}

static int kindle_initialise(nsfb_t *nsfb)
{
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    const char *dev = getenv("FRAMEBUFFER");
    if (dev == NULL) dev = "/dev/fb0";

    kfb_fd = open(dev, O_RDWR);
    if (kfb_fd == -1) return -1;
    if (ioctl(kfb_fd, FBIOGET_FSCREENINFO, &finfo) == -1) { close(kfb_fd); kfb_fd = -1; return -1; }
    if (ioctl(kfb_fd, FBIOGET_VSCREENINFO, &vinfo) == -1) { close(kfb_fd); kfb_fd = -1; return -1; }

    kfb_memlen = finfo.smem_len;
    kfb_linelen = finfo.line_length;
    kfb_mem = mmap(NULL, kfb_memlen, PROT_READ | PROT_WRITE, MAP_SHARED, kfb_fd, 0);
    if (kfb_mem == MAP_FAILED) { kfb_mem = NULL; close(kfb_fd); kfb_fd = -1; return -1; }

    /* PHYSICAL display size; NetSurf's content area is smaller:
     * custom toolbar at the top (KFB_TBAR_H), gutter on the left (KFB_GUTTER) */
    kfb_scrw = vinfo.xres;
    kfb_scrh = vinfo.yres;
    kfb_bpp     = (vinfo.bits_per_pixel > 0) ? (int)vinfo.bits_per_pixel : 8;
    kfb_bytespp = kfb_bpp / 8;
    if (kfb_bytespp < 1) kfb_bytespp = 1;
    ktlog("FB: xres=%u yres=%u bpp=%d bytespp=%d line_length=%d",
          vinfo.xres, vinfo.yres, kfb_bpp, kfb_bytespp, kfb_linelen);
    if (kfb_bytespp >= 3) {
        int r_ = (int)(vinfo.red.offset   / 8);
        int g_ = (int)(vinfo.green.offset / 8);
        int b_ = (int)(vinfo.blue.offset  / 8);
        int a_ = vinfo.transp.length ? (int)(vinfo.transp.offset / 8) : -1;
        if (r_ >= 0 && r_ < kfb_bytespp && g_ >= 0 && g_ < kfb_bytespp && b_ >= 0 && b_ < kfb_bytespp) {
            ch_r = r_; ch_g = g_; ch_b = b_; ch_a = a_;   /* order reported by the framebuffer */
        }
        ktlog("FB color: ch_r=%d ch_g=%d ch_b=%d ch_a=%d (red.off=%u green.off=%u blue.off=%u)",
              ch_r, ch_g, ch_b, ch_a, vinfo.red.offset, vinfo.green.offset, vinfo.blue.offset);
    }
    nsfb->width  = vinfo.xres - KFB_GUTTER - KFB_RGUT;   /* also leave room for the right paging column */
    nsfb->height = vinfo.yres - KFB_TBAR_H;
    nsfb->format = NSFB_FMT_ABGR8888;
    select_plotters(nsfb);               /* bpp = 32 */
    nsfb->linelen = nsfb->width * 4;
    nsfb->ptr = calloc((size_t)nsfb->width * nsfb->height, 4);
    if (nsfb->ptr == NULL) {
        munmap(kfb_mem, kfb_memlen); kfb_mem = NULL; close(kfb_fd); kfb_fd = -1;
        return -1;
    }

    /* SIGCONT handler: request a full redraw when resuming after minimization.
     * SA_RESTART allows interrupted poll/read calls to restart. */
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_sigcont;
        sa.sa_flags = SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGCONT, &sa, NULL);
    }
    return 0;
}

static int kindle_set_geometry(nsfb_t *nsfb, int width, int height, enum nsfb_format_e format)
{
    UNUSED(format);
    if (width > 0)  { kfb_scrw = width;  nsfb->width  = width  - KFB_GUTTER; }
    if (height > 0) { kfb_scrh = height; nsfb->height = height - KFB_TBAR_H; }
    nsfb->format = NSFB_FMT_ABGR8888;    /* always render at 32bpp */
    select_plotters(nsfb);
    return 0;
}

/* Convert the rendered (32bpp) region to grayscale and write it to the 8bpp framebuffer */
static int kindle_update(nsfb_t *nsfb, nsfb_bbox_t *box)
{
    int x, y, x0, y0, x1, y1;
    if (kfb_mem == NULL || nsfb->ptr == NULL) return 0;

    x0 = box->x0; y0 = box->y0; x1 = box->x1; y1 = box->y1;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > nsfb->width)  x1 = nsfb->width;
    if (y1 > nsfb->height) y1 = nsfb->height;

    if (x1 <= x0 || y1 <= y0) return 0;

    for (y = y0; y < y1; y++) {
        const uint32_t *src = (const uint32_t *)(nsfb->ptr + (size_t)y * nsfb->linelen);
        uint8_t *dst = kfb_mem + (size_t)(y + KFB_TBAR_H) * kfb_linelen; /* physical row (below the toolbar) */
        if (x0 == 0) { int gi; for (gi = 0; gi < KFB_GUTTER; gi++) kfb_store(dst + (size_t)gi * kfb_bytespp, 0xFF); } /* white left gutter */
        for (x = x0; x < x1; x++) {
            uint32_t p = src[x];
            int r =  p        & 0xFF;
            int g = (p >> 8)  & 0xFF;
            int b = (p >> 16) & 0xFF;
            uint8_t *d = dst + (size_t)(x + KFB_GUTTER) * kfb_bytespp;
            if (kfb_bytespp >= 3) {
                kfb_store_color(d, r, g, b);           /* color panel: actual RGB */
            } else {
                kfb_store(d, (uint8_t)((r * 77 + g * 151 + b * 28) >> 8)); /* grayscale */
            }
        }
    }

    /* Immediately refresh the rendered region on e-ink (no external polling loop) */
    if (mtk_ok) {
        struct mtk_update_data u;
        int big = ((x1 - x0) * (y1 - y0)) > (nsfb->width * nsfb->height / 2);
        memset(&u, 0, sizeof(u));
        u.update_region.left   = (uint32_t)((x0 == 0) ? 0 : (x0 + KFB_GUTTER));
        u.update_region.top    = (uint32_t)(y0 + KFB_TBAR_H);
        u.update_region.width  = (uint32_t)((x0 == 0) ? ((x1 - x0) + KFB_GUTTER) : (x1 - x0));
        u.update_region.height = (uint32_t)(y1 - y0);
        u.waveform_mode = MTK_WAVEFORM_AUTO;
        /* large area (page load) -> full, clean refresh; small -> fast partial refresh */
        u.update_mode   = big ? MTK_UPDATE_FULL : MTK_UPDATE_PARTIAL;
        u.update_marker = ++mtk_marker;
        u.temp          = MTK_TEMP_AMBIENT;
        if (ioctl(kfb_fd, MXCFB_SEND_UPDATE_MTK, &u) < 0) {
            if (!mtk_logged) { ktlog("MXCFB_SEND_UPDATE_MTK ERROR (errno=%d) -> falling back to the fbink loop", errno); mtk_logged = 1; }
            mtk_ok = 0;   /* unavailable: fall back to fbink */
        } else if (!mtk_logged) {
            ktlog("MXCFB_SEND_UPDATE_MTK OK (refresh-on-draw active)");
            mtk_logged = 1;
        }
    }
    return 0;
}


/* ---------- toolbar drawing (8bpp: white=0xFF, black=0x00) ---------- */
static void kfb_mtk_update(int x, int y, int w, int h, int full)
{
    struct mtk_update_data u;
    if (!mtk_ok) return;
    memset(&u, 0, sizeof(u));
    u.update_region.left = (uint32_t)x; u.update_region.top = (uint32_t)y;
    u.update_region.width = (uint32_t)w; u.update_region.height = (uint32_t)h;
    u.waveform_mode = full ? MTK_WAVEFORM_GC16 : MTK_WAVEFORM_AUTO;
    u.update_mode   = full ? MTK_UPDATE_FULL : MTK_UPDATE_PARTIAL;
    u.update_marker = ++mtk_marker; u.temp = MTK_TEMP_AMBIENT;
    if (ioctl(kfb_fd, MXCFB_SEND_UPDATE_MTK, &u) < 0) mtk_ok = 0;
}
static void kfb_px(int x, int y, uint8_t v)
{
    if (x < 0 || y < 0 || x >= kfb_scrw || y >= kfb_scrh) return;
    kfb_store(kfb_mem + (size_t)y * kfb_linelen + (size_t)x * kfb_bytespp, v);
}
static void kfb_fill(int x, int y, int w, int h, uint8_t v)
{
    int i, j; for (j = 0; j < h; j++) for (i = 0; i < w; i++) kfb_px(x + i, y + j, v);
}
static void kfb_line(int x0, int y0, int x1, int y1, uint8_t v, int th)
{
    int dx = (x1>x0)?(x1-x0):(x0-x1), dy = (y1>y0)?(y1-y0):(y0-y1);
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx - dy, e2, k, l;
    for (;;) {
        for (k = -th/2; k <= th/2; k++) for (l = -th/2; l <= th/2; l++) kfb_px(x0 + k, y0 + l, v);
        if (x0 == x1 && y0 == y1) break;
        e2 = 2 * err; if (e2 > -dy) { err -= dy; x0 += sx; } if (e2 < dx) { err += dx; y0 += sy; }
    }
}
static void kfb_tri_left(int cx, int cy, int s, uint8_t v)   /* ◀ filled triangle */
{
    int yy, x; for (yy = -s; yy <= s; yy++) { int ay = yy<0?-yy:yy; for (x = cx - s + ay; x <= cx + s; x++) kfb_px(x, cy + yy, v); }
}
static void kfb_tri_right(int cx, int cy, int s, uint8_t v)  /* ▶ filled triangle */
{
    int yy, x; for (yy = -s; yy <= s; yy++) { int ay = yy<0?-yy:yy; for (x = cx - s; x <= cx + s - ay; x++) kfb_px(x, cy + yy, v); }
}
static void kfb_reload(int cx, int cy, int r, uint8_t v)     /* ⟳ ring with a gap + arrowhead, without trigonometry */
{
    int yy, xx, r2 = r*r, rin = (r-3)*(r-3);
    for (yy = -r; yy <= r; yy++) for (xx = -r; xx <= r; xx++) {
        int d = xx*xx + yy*yy;
        if (d <= r2 && d >= rin) { if (!(xx > 0 && yy < 0 && (-yy) < xx)) kfb_px(cx + xx, cy + yy, v); }
    }
    kfb_line(cx + r - 1, cy - 1, cx + r - 9, cy - 4, v, 2);
    kfb_line(cx + r - 1, cy - 1, cx + r - 3, cy + 8, v, 2);
}
static void kfb_reader(int cx, int cy, uint8_t v)   /* reader: page + text lines */
{
    int w = 22, h = 28, x = cx - w/2, y = cy - h/2, i;
    kfb_fill(x, y, w, 2, v); kfb_fill(x, y + h - 2, w, 2, v);
    kfb_fill(x, y, 2, h, v); kfb_fill(x + w - 2, y, 2, h, v);
    for (i = 0; i < 3; i++) kfb_fill(x + 5, y + 8 + i * 7, w - 10, 2, v);
}
static void kfb_btnbox(int cx, int cy, int bw)
{
    int x = cx - bw/2, y = cy - bw/2;
    kfb_fill(x, y, bw, 1, 0xC8); kfb_fill(x, y + bw - 1, bw, 1, 0xC8);
    kfb_fill(x, y, 1, bw, 0xC8); kfb_fill(x + bw - 1, y, 1, bw, 0xC8);
}
static void kfb_text(int x, int y, const char *str, int xmax)
{
    const unsigned char *p = (const unsigned char *)str;
    for (; *p; p++) {
        int c = *p, idx, row;
        if (x + KFB_FONT_CW > xmax) break;
        if (c < KFB_FONT_FIRST || c > 126) c = '?';
        idx = c - KFB_FONT_FIRST;
        for (row = 0; row < KFB_FONT_CH; row++) {
            unsigned short bits = kfb_font[idx][row];
            int col; for (col = 0; col < KFB_FONT_CW; col++) if (bits & (1 << (KFB_FONT_CW - 1 - col))) kfb_px(x + col, y + row, 0x00);
        }
        x += KFB_FONT_CW;
    }
}
/* Button geometry (shared by hit testing and drawing) */
static int toolbar_hit(int px)
{
    int bw = 56, pad = 14, gap = 10;
    int xback = pad, xfwd = pad + (bw + gap), xrel = pad + 2*(bw + gap);
    int xclose = kfb_scrw - pad - bw;
    int xmin = kfb_scrw - pad - (bw + gap) - bw;
    int xread = kfb_scrw - pad - 2*(bw + gap) - bw;
    if (px >= xback && px < xback + bw) return TB_BACK;
    if (px >= xfwd  && px < xfwd  + bw) return TB_FWD;
    if (px >= xrel  && px < xrel  + bw) return TB_RELOAD;
    if (px >= xread && px < xread + bw) return TB_READER;
    if (px >= xmin  && px < xmin  + bw) return TB_MIN;
    if (px >= xclose&& px < xclose+ bw) return TB_CLOSE;
    return TB_URL;
}
static void draw_toolbar(nsfb_t *nsfb, int do_update)
{
    int bw = 56, pad = 14, gap = 10, cy = KFB_TBAR_H / 2;
    int xback = pad + bw/2, xfwd = pad + (bw+gap) + bw/2, xrel = pad + 2*(bw+gap) + bw/2;
    int xclose = kfb_scrw - pad - bw/2;
    int xmin = kfb_scrw - pad - (bw+gap) - bw/2;
    int xread = kfb_scrw - pad - 2*(bw+gap) - bw/2;
    int urlx0 = xrel + bw/2 + 18, urlx1 = xread - bw/2 - 18;
    UNUSED(nsfb);
    if (kfb_mem == NULL) return;
    kfb_fill(0, 0, kfb_scrw, KFB_TBAR_H, 0xFF);            /* white background */
    kfb_fill(0, KFB_TBAR_H - 2, kfb_scrw, 2, 0x40);        /* bottom border */
    kfb_btnbox(xback, cy, bw); kfb_btnbox(xfwd, cy, bw); kfb_btnbox(xrel, cy, bw);
    kfb_btnbox(xread, cy, bw);  kfb_btnbox(xmin, cy, bw);  kfb_btnbox(xclose, cy, bw);
    kfb_tri_left(xback, cy, 13, 0x00);
    kfb_tri_right(xfwd, cy, 13, 0x00);
    kfb_reload(xrel, cy, 14, 0x00);
    kfb_reader(xread, cy, 0x00);                           /* reader view */
    kfb_fill(xmin - 14, cy + 9, 28, 5, 0x00);              /* '_' minimizes */
    kfb_line(xclose - 13, cy - 13, xclose + 13, cy + 13, 0x00, 3);  /* ✕ closes */
    kfb_line(xclose + 13, cy - 13, xclose - 13, cy + 13, 0x00, 3);
    kfb_text(urlx0, (KFB_TBAR_H - KFB_FONT_CH) / 2, g_toolbar_url, urlx1);
    if (do_update) kfb_mtk_update(0, 0, kfb_scrw, KFB_TBAR_H, 0);
}

/* ---- right paging column: top ▲ (PageUp), bottom ▼ (PageDown) ---- */
static void draw_sidebar(nsfb_t *nsfb, int do_update)
{
    int x0   = kfb_scrw - KFB_RGUT;
    int top  = KFB_TBAR_H;
    int h    = kfb_scrh - top;
    int midy = top + h / 2;
    int cx   = x0 + KFB_RGUT / 2;
    int s    = 16;                 /* triangle size */
    int r;
    (void)nsfb;
    if (kfb_mem == NULL || KFB_RGUT <= 0) return;
    kfb_fill(x0, top, KFB_RGUT, h, 0xFF);        /* white background */
    kfb_fill(x0, top, 2, h, 0x40);               /* left separator line */
    kfb_fill(x0, midy - 1, KFB_RGUT, 2, 0x40);   /* horizontal divider between the two buttons */
    /* top button: ▲ (pointing up) */
    {
        int by = top + (midy - top) / 2 - s / 2;
        for (r = 0; r <= s; r++) kfb_fill(cx - r, by + r, 2 * r + 1, 1, 0x00);
    }
    /* bottom button: ▼ (pointing down) */
    {
        int by = midy + (kfb_scrh - midy) / 2 - s / 2;
        for (r = 0; r <= s; r++) kfb_fill(cx - (s - r), by + r, 2 * (s - r) + 1, 1, 0x00);
    }
    if (do_update) kfb_mtk_update(x0, top, KFB_RGUT, h, 1);
}

/* Redraw the entire rendered image (nsfb->ptr) + perform a full e-ink refresh.
 * Called on resume (SIGCONT), after KOReader has repainted the framebuffer. */
static void full_reblit(nsfb_t *nsfb)
{
    int x, y;
    if (kfb_mem == NULL || nsfb->ptr == NULL) return;
    for (y = 0; y < nsfb->height; y++) {
        const uint32_t *src = (const uint32_t *)(nsfb->ptr + (size_t)y * nsfb->linelen);
        uint8_t *dst = kfb_mem + (size_t)(y + KFB_TBAR_H) * kfb_linelen;
        int gi; for (gi = 0; gi < KFB_GUTTER; gi++) kfb_store(dst + (size_t)gi * kfb_bytespp, 0xFF);
        for (x = 0; x < nsfb->width; x++) {
            uint32_t p = src[x];
            int r =  p        & 0xFF;
            int g = (p >> 8)  & 0xFF;
            int b = (p >> 16) & 0xFF;
            uint8_t *d = dst + (size_t)(x + KFB_GUTTER) * kfb_bytespp;
            if (kfb_bytespp >= 3) {
                kfb_store_color(d, r, g, b);
            } else {
                kfb_store(d, (uint8_t)((r * 77 + g * 151 + b * 28) >> 8));
            }
        }
    }
    draw_toolbar(nsfb, 0);                       /* redraw the toolbar too */
    draw_sidebar(nsfb, 0);                       /* right paging column */
    kfb_mtk_update(0, 0, kfb_scrw, kfb_scrh, 1); /* single full, clean refresh */
}

static void minimize_self(nsfb_t *nsfb, int reason)
{
    const char *sig = getenv("NETSURF_SIGNAL_FILE");
    if (sig != NULL && sig[0] != 0) {
        FILE *f = fopen(sig, "w");
        if (f != NULL) { fputs(reason == 1 ? "menu" : reason == 2 ? "url" : reason == 3 ? "field" : reason == 5 ? "reader" : "min", f); fputc('\n', f); fclose(f); }
    }
    if (ts_fd >= 0) ioctl(ts_fd, EVIOCGRAB, (void *)0);   /* release the grab */
    g_down = 0; g_scrolling = 0; pinch_on = 0;
    frame_down = -1; have_x = have_y = 0;
    sl_active[0] = sl_active[1] = 0;
    ktlog("minimizing (reason=%d): SIGSTOP", reason);
    fflush(NULL);
    raise(SIGSTOP);                 /* --- freeze here; SIGCONT resumes from here --- */
    if (ts_fd >= 0) {
        struct input_event d;
        ioctl(ts_fd, EVIOCGRAB, (void *)1);
        while (read(ts_fd, &d, sizeof(d)) == (ssize_t)sizeof(d)) { }
    }
    full_reblit(nsfb);
    g_resumed = 0;
    /* FIELD INJECTION: send text entered in the KOReader dialog as REAL key
     * events (the same path as the keyboard). Use the accent patch's
     * "direct Unicode" range: 0x2000+codepoint. */
    if (reason == 3) {
        /* The gui.c main loop performs the actual input by calling
         * browser_window_key_press(bw, codepoint) directly (not through
         * synthetic key events). Only signal the request here. */
        g_inject_request = 1;
        ktlog("INJECT: g_inject_request=1 set (gui.c handles text input)");
    }
    ktlog("resuming: SIGCONT");
}

static int kindle_finalise(nsfb_t *nsfb)
{
    UNUSED(nsfb);
    if (nsfb->ptr != NULL) { free(nsfb->ptr); nsfb->ptr = NULL; }
    if (kfb_mem != NULL) { munmap(kfb_mem, kfb_memlen); kfb_mem = NULL; }
    if (kfb_fd != -1) { close(kfb_fd); kfb_fd = -1; }
    if (ts_fd != -1) { close(ts_fd); ts_fd = -1; }
    return 0;
}

/* Find a touch device: prefer multitouch (ABS_MT_POSITION_X),
 * then ABS_X. NETSURF_TOUCH_DEV overrides detection. */
static int ts_probe(const char *path, int *is_mt)
{
    int fd;
    unsigned long absbits[NBITS(ABS_MAX + 1)];
    char name[128];
    int mt = 0, plain = 0;

    fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    name[0] = 0;
    ioctl(fd, EVIOCGNAME(sizeof(name)), name);
    memset(absbits, 0, sizeof(absbits));
    if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) >= 0) {
        mt    = TEST_BIT(ABS_MT_POSITION_X, absbits) ? 1 : 0;
        plain = TEST_BIT(ABS_X, absbits) ? 1 : 0;
    }
    ktlog("probing %s: name='%s' MT=%d ABS_X=%d", path, name, mt, plain);
    if (mt || plain) { *is_mt = mt; return fd; }
    close(fd);
    return -1;
}

static int ts_open(void)
{
    const char *env = getenv("NETSURF_TOUCH_DEV");
    int i, fd, is_mt;
    int plain_fd = -1;
    char path[64];

    ts_swap = getenv("NETSURF_TOUCH_SWAP") ? 1 : 0;
    ts_invx = getenv("NETSURF_TOUCH_INVX") ? 1 : 0;
    ts_invy = getenv("NETSURF_TOUCH_INVY") ? 1 : 0;
    ktlog("orientation: swap=%d invx=%d invy=%d", ts_swap, ts_invx, ts_invy);

    if (env != NULL && env[0] != '\0') {
        fd = open(env, O_RDONLY | O_NONBLOCK);
        ktlog("NETSURF_TOUCH_DEV=%s -> fd=%d", env, fd);
        if (fd >= 0) return fd;
    }

    /* Pass 1: find a multitouch device; keep a plain ABS_X device as a fallback */
    for (i = 0; i < 32; i++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        is_mt = 0;
        fd = ts_probe(path, &is_mt);
        if (fd < 0) continue;
        if (is_mt) { ktlog("selected (MT): %s fd=%d", path, fd); return fd; }
        if (plain_fd < 0) plain_fd = fd; else close(fd);
    }
    if (plain_fd >= 0) ktlog("selected (plain ABS_X) fd=%d", plain_fd);
    else ktlog("NO touch device found");
    return plain_fd;
}

static void ts_read_range(int fd, int axis, int *mn, int *mx)
{
    struct input_absinfo ai;
    if (ioctl(fd, EVIOCGABS(axis), &ai) >= 0 && ai.maximum > ai.minimum) {
        *mn = ai.minimum; *mx = ai.maximum;
    }
}

static void ts_setup(nsfb_t *nsfb)
{
    int gr;
    ts_inited = 1;
    ts_fd = ts_open();
    if (ts_fd < 0) return;

    /* Try an exclusive grab; if KOReader already holds it, we get EBUSY */
    gr = ioctl(ts_fd, EVIOCGRAB, (void *)1);
    ktlog("EVIOCGRAB -> %d (0=success; -1 and EBUSY: held by another process)", gr);

    /* Ranges: prefer multitouch axes */
    ts_min_x = 0; ts_max_x = nsfb->width  - 1;
    ts_min_y = 0; ts_max_y = nsfb->height - 1;
    ts_read_range(ts_fd, ABS_MT_POSITION_X, &ts_min_x, &ts_max_x);
    if (ts_max_x == nsfb->width - 1)  ts_read_range(ts_fd, ABS_X, &ts_min_x, &ts_max_x);
    ts_read_range(ts_fd, ABS_MT_POSITION_Y, &ts_min_y, &ts_max_y);
    if (ts_max_y == nsfb->height - 1) ts_read_range(ts_fd, ABS_Y, &ts_min_y, &ts_max_y);
    ktlog("range X[%d..%d] Y[%d..%d] display %dx%d",
          ts_min_x, ts_max_x, ts_min_y, ts_max_y, nsfb->width, nsfb->height);
}

static int scale(int v, int mn, int mx, int screen)
{
    int s;
    if (mx <= mn) return v;
    s = (int)((long)(v - mn) * (screen - 1) / (mx - mn));
    if (s < 0) s = 0;
    if (s > screen - 1) s = screen - 1;
    return s;
}

/* Emit a zoom step to NetSurf (Ctrl + '+' zoom in / Ctrl + '-' zoom out) */
static void emit_zoom(int zin)
{
    enum nsfb_key_code_e k = zin ? NSFB_KEY_EQUALS : NSFB_KEY_MINUS;
    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_LCTRL);
    evq_push_key(NSFB_EVENT_KEY_DOWN, k);
    evq_push_key(NSFB_EVENT_KEY_UP, k);
    evq_push_key(NSFB_EVENT_KEY_UP, NSFB_KEY_LCTRL);
}

/* Process one SYN_REPORT: generate nsfb events from the raw state */
static void ts_process_frame(nsfb_t *nsfb)
{
    int sx, sy, tmp, dx, dy, nscroll, nsc2;
    int nact = sl_active[0] + sl_active[1];

    /* --- PINCH ZOOM: two fingers on the display --- */
    if (nact >= 2) {
        int px = sl_x[0] - sl_x[1]; if (px < 0) px = -px;
        int py = sl_y[0] - sl_y[1]; if (py < 0) py = -py;
        int d = px + py;
        if (!pinch_on) {
            pinch_on = 1;
            g_down = 0; g_scrolling = 0;
            pinch_last = d;
        } else {
            int delta = d - pinch_last;
            int steps = 0;
            while (delta >= PINCH_STEP && steps < 3) { emit_zoom(1); pinch_last += PINCH_STEP; delta -= PINCH_STEP; steps++; }
            while (delta <= -PINCH_STEP && steps < 3) { emit_zoom(0); pinch_last -= PINCH_STEP; delta += PINCH_STEP; steps++; }
        }
        frame_down = -1; have_x = have_y = 0;
        return;
    }
    if (pinch_on) {
        pinch_on = 0; g_down = 0;
        frame_down = -1; have_x = have_y = 0;
        return;
    }

    /* Scale to the PHYSICAL display */
    sx = scale(raw_x, ts_min_x, ts_max_x, kfb_scrw);
    sy = scale(raw_y, ts_min_y, ts_max_y, kfb_scrh);
    if (ts_swap) { tmp = sx; sx = sy; sy = tmp; }
    if (ts_invx) sx = kfb_scrw - 1 - sx;
    if (ts_invy) sy = kfb_scrh - 1 - sy;

    /* Touch press begins */
    if (frame_down == 1 && !g_down) {
        g_down = 1;
        g_start_x = sx; g_start_y = sy;
        g_last_x = sx;  g_last_y = sy;
        g_moved = 0; g_scrolling = 0; g_scroll_accum = 0; g_scroll_accx = 0;
        g_min_fired = 0;
    }

    /* Movement with a finger held down */
    if (g_down && (have_x || have_y)) {
        dx = sx - g_last_x;
        dy = sy - g_last_y;
        g_moved += (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);

        /* Drag down from the toolbar -> minimize (and open the KOReader menu) */
        if (!g_min_fired && g_start_y < KFB_TBAR_H) {
            int ddown = sy - g_start_y;
            int dhoriz = sx - g_start_x; if (dhoriz < 0) dhoriz = -dhoriz;
            if (ddown >= TOP_DRAG_TRIGGER && ddown > dhoriz) {
                g_min_fired = 1;
                minimize_self(nsfb, 1);
                frame_down = -1; have_x = have_y = 0;
                return;
            }
        }

        /* Scroll content ONLY if the gesture started in the content area (below the toolbar) */
        if (g_start_y >= KFB_TBAR_H) {
            if (!g_scrolling && g_moved > TAP_MAX_MOVE) {
                g_scrolling = 1; g_scroll_accum = 0; g_scroll_accx = 0;
            }
            if (g_scrolling) {
                g_scroll_accum += dy;
                nscroll = 0;
                while (g_scroll_accum <= -SCROLL_STEP && nscroll < SCROLL_MAX_PER_FRAME) {
                    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_5); g_scroll_accum += SCROLL_STEP; nscroll++;
                }
                while (g_scroll_accum >= SCROLL_STEP && nscroll < SCROLL_MAX_PER_FRAME) {
                    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_4); g_scroll_accum -= SCROLL_STEP; nscroll++;
                }
                g_scroll_accx += dx;
                nsc2 = 0;
                while (g_scroll_accx >= SCROLL_STEP && nsc2 < SCROLL_MAX_PER_FRAME) {
                    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_LEFT); g_scroll_accx -= SCROLL_STEP; nsc2++;
                }
                while (g_scroll_accx <= -SCROLL_STEP && nsc2 < SCROLL_MAX_PER_FRAME) {
                    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_RIGHT); g_scroll_accx += SCROLL_STEP; nsc2++;
                }
            }
        }
        g_last_x = sx; g_last_y = sy;
    }

    /* Release */
    if (frame_down == 0 && g_down) {
        if (g_start_y < KFB_TBAR_H) {
            /* Toolbar tap (not a drag): activate the corresponding button */
            if (!g_scrolling && !g_min_fired) {
                switch (toolbar_hit(g_start_x)) {
                    case TB_BACK:   g_nav_request = 1; break;
                    case TB_FWD:    g_nav_request = 2; break;
                    case TB_RELOAD: g_nav_request = 3; break;
                    case TB_READER: minimize_self(nsfb, 5); break;
                    case TB_MIN:    minimize_self(nsfb, 0); break;
                    case TB_CLOSE:  g_nav_request = 4; break;
                    case TB_URL:    minimize_self(nsfb, 2); break;
                    default: break;
                }
            }
        } else if (g_start_x >= kfb_scrw - KFB_RGUT) {
            /* Right paging column: upper half = PageUp, lower half = PageDown */
            if (!g_scrolling) {
                int midy = KFB_TBAR_H + (kfb_scrh - KFB_TBAR_H) / 2;
                if (g_start_y < midy) evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_PAGEUP);
                else                  evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_PAGEDOWN);
            }
        } else if (!g_scrolling) {
            /* Content tap -> click (offset by gutter/toolbar) */
            int cx = g_start_x - KFB_GUTTER, cy = g_start_y - KFB_TBAR_H;
            if (cx < 0) cx = 0;
            if (cx > nsfb->width - 1)  cx = nsfb->width - 1;
            if (cy < 0) cy = 0;
            if (cy > nsfb->height - 1) cy = nsfb->height - 1;
            /* If the tap hits an input field, this tells place_caret that it
             * was a user tap -> KOReader keyboard (not automatic focus) */
            g_field_click_pending = 4;
            ktlog("FIELD: content tap (%d,%d) -> g_field_click_pending=4", cx, cy);
            evq_push_move(cx, cy);
            evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_1);
            evq_push_key(NSFB_EVENT_KEY_UP, NSFB_KEY_MOUSE_1);
        }
        g_down = 0;
    }

    frame_down = -1;
    have_x = have_y = 0;
}

static bool kindle_input(nsfb_t *nsfb, nsfb_event_t *event, int timeout)
{
    struct input_event iev;
    struct pollfd pfd;
    ssize_t n;
    int pr;

    if (!ts_inited) ts_setup(nsfb);

    /* Resume after minimization: KOReader repainted the display, so redraw
     * the entire browser image before processing anything */
    if (g_resumed) {
        g_resumed = 0;
        full_reblit(nsfb);
    }

    /* Redraw the toolbar if the URL changed (or on the first call) */
    if (g_toolbar_url_dirty) {
        g_toolbar_url_dirty = 0;
        draw_toolbar(nsfb, 1);
    }

    /* Draw the right paging column once (content never overwrites it) */
    { static int sb_once = 0; if (!sb_once) { sb_once = 1; draw_sidebar(nsfb, 1); } }

    /* In-page field focused -> KOReader keyboard overlay (the browser stays
     * in the background, with the dialog drawn over it), then inject the entered text */
    if (g_field_input_request) {
        g_field_input_request = 0;
        minimize_self(nsfb, 3);
    }

    /* PERIODIC TOP-BAR REDRAW: the Kindle system clock (top left) / battery (top
     * right) occasionally draws over us; lipc cannot reliably stop this on MTK.
     * While idle, redraw our toolbar every ~2.5 seconds (a lightweight partial
     * refresh), so the clock disappears within a few seconds. This does not run
     * during active touch input (when poll returns an event), avoiding scroll flicker. */
    {
        static struct timespec s_last_tbar = { 0, 0 };
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (s_last_tbar.tv_sec == 0) {
            s_last_tbar = now;
        } else {
            long ms = (now.tv_sec - s_last_tbar.tv_sec) * 1000L
                    + (now.tv_nsec - s_last_tbar.tv_nsec) / 1000000L;
            if (ms >= 2500) { draw_toolbar(nsfb, 1); s_last_tbar = now; }
        }
    }

    /* Return a queued event first */
    if (evq_pop(event)) return true;

    if (ts_fd < 0) {
        /* No touch device: wait to keep NetSurf from busy-looping */
        if (timeout > 0) {
            struct timespec ts;
            ts.tv_sec = timeout / 1000;
            ts.tv_nsec = (long)(timeout % 1000) * 1000000L;
            nanosleep(&ts, NULL);
        }
        return false;
    }

    pfd.fd = ts_fd;
    pfd.events = POLLIN;
    /* Cap the timeout so we wake even when idle to periodically redraw the
     * top bar (see above) */
    if (timeout < 0 || timeout > 1500) timeout = 1500;
    pr = poll(&pfd, 1, timeout);
    if (pr <= 0) return false;      /* timeout or error */

    /* Read and process all available evdev records */
    while ((n = read(ts_fd, &iev, sizeof(iev))) == (ssize_t)sizeof(iev)) {
        switch (iev.type) {
        case EV_ABS:
            switch (iev.code) {
            case ABS_MT_SLOT:
                cur_slot = (iev.value >= 0 && iev.value < NSLOTS) ? iev.value : NSLOTS;
                break;
            case ABS_MT_POSITION_X:
                raw_x = iev.value; have_x = 1;
                if (cur_slot < NSLOTS) sl_x[cur_slot] = iev.value;
                break;
            case ABS_X:             raw_x = iev.value; have_x = 1; break;
            case ABS_MT_POSITION_Y:
                raw_y = iev.value; have_y = 1;
                if (cur_slot < NSLOTS) sl_y[cur_slot] = iev.value;
                break;
            case ABS_Y:             raw_y = iev.value; have_y = 1; break;
            case ABS_MT_TRACKING_ID:
                frame_down = (iev.value < 0) ? 0 : 1;
                if (cur_slot < NSLOTS) sl_active[cur_slot] = (iev.value < 0) ? 0 : 1;
                break;
            default: break;
            }
            break;
        case EV_KEY:
            if (iev.code == BTN_TOUCH) {
                frame_down = iev.value ? 1 : 0;
            }
            break;
        case EV_SYN:
            if (iev.code == SYN_REPORT) {
                ts_process_frame(nsfb);
            }
            break;
        default: break;
        }
    }

    if (evq_pop(event)) return true;
    return false;
}

const nsfb_surface_rtns_t kindle_rtns = {
    .defaults = kindle_defaults,
    .initialise = kindle_initialise,
    .finalise = kindle_finalise,
    .input = kindle_input,
    .update = kindle_update,
    .geometry = kindle_set_geometry,
};

NSFB_SURFACE_DEF(kindle, NSFB_SURFACE_LINUX, &kindle_rtns)

KFBEOF
    # Add it to the always-built handlers in surface/Makefile
    sed -i 's/^SURFACE_HANDLER_yes := surface.c ram.c/SURFACE_HANDLER_yes := surface.c ram.c kindlefb.c/' \
        "$SRC/$lib/src/surface/Makefile"
    echo "   >>> surface/Makefile SURFACE_HANDLER_yes:"; grep "SURFACE_HANDLER_yes :=" "$SRC/$lib/src/surface/Makefile"
    tmake "$lib"
    tmake "$lib" install
    echo "   >>> was kindlefb compiled?"; find "$SRC/$lib" -name 'kindlefb*.o' | head || echo "   (no)"
  else
    tmake "$lib"
    tmake "$lib" install
  fi
done

# 2c) Networking layer: zlib + openssl + libcurl (static, into our prefix)
fetch() {
  local out="$1" url="$2"
  for i in 1 2 3 4; do
    curl -fSL --retry 3 --retry-delay 5 -o "$out" "$url" && return 0
    echo "retrying download ($i): $url"; sleep 10
  done
  echo "ERROR: failed to download: $url"; exit 1
}

echo "==> zlib (target)"
ZLIB_VER=1.3.1
fetch zlib.tar.gz "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz"
tar xzf zlib.tar.gz
( cd "zlib-${ZLIB_VER}" && \
  CC="${CROSS}gcc" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" \
    ./configure --prefix="$PREFIX" --static && \
  make -j"$JOBS" && make install )

echo "==> openssl (target)"
OSSL_VER=3.0.15
fetch openssl.tar.gz "https://github.com/openssl/openssl/releases/download/openssl-${OSSL_VER}/openssl-${OSSL_VER}.tar.gz"
tar xzf openssl.tar.gz
( cd "openssl-${OSSL_VER}" && \
  CROSS_COMPILE="${CROSS}" ./Configure linux-armv4 \
    --prefix="$PREFIX" --openssldir="$PREFIX/ssl" \
    no-shared no-module no-legacy no-tests no-asm no-dso && \
  make -j"$JOBS" && make install_sw )

echo "==> libcurl (target)"
CURL_VER=8.11.0
CURL_TAG="curl-$(echo "$CURL_VER" | tr '.' '_')"
fetch curl.tar.gz "https://github.com/curl/curl/releases/download/${CURL_TAG}/curl-${CURL_VER}.tar.gz"
tar xzf curl.tar.gz
( cd "curl-${CURL_VER}" && \
  ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --with-openssl="$PREFIX" --with-zlib="$PREFIX" \
    --without-libpsl --without-libidn2 --without-brotli --without-zstd \
    --without-nghttp2 --without-ngtcp2 --disable-ldap --disable-ldaps \
    --disable-manual --disable-docs \
    CC="${CROSS}gcc" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" && \
  make -j"$JOBS" && make install )

# Add private dependencies to libcurl.pc for static linking,
# so -lssl -lcrypto -lz are available when linking NetSurf
if [ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ]; then
  sed -i 's/^Libs:.*/& -lssl -lcrypto -lz/' "$PREFIX/lib/pkgconfig/libcurl.pc"
fi

# 2e) FreeType - proper (TTF) fonts for Hungarian ő, Cyrillic, etc.,
#     with antialiased text (instead of the built-in bitmap font).
FT_VER="2.13.3"
echo "==> freetype ${FT_VER} (target, static)"
ok=0
for url in \
  "https://download.savannah.gnu.org/releases/freetype/freetype-${FT_VER}.tar.gz" \
  "https://downloads.sourceforge.net/freetype/freetype-${FT_VER}.tar.gz" \
  "https://downloads.sourceforge.net/project/freetype/freetype2/${FT_VER}/freetype-${FT_VER}.tar.gz" ; do
  echo "   freetype download: $url"
  if curl -fSL --retry 3 -o freetype.tar.gz "$url"; then ok=1; break; fi
  sleep 5
done
[ "$ok" = "1" ] || { echo "ERROR: failed to download freetype"; exit 1; }
tar xzf freetype.tar.gz
( cd "freetype-${FT_VER}" && \
  ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --without-zlib --without-bzip2 --without-png --without-harfbuzz --without-brotli && \
  make -j"$JOBS" && make install )
[ -f "$PREFIX/lib/pkgconfig/freetype2.pc" ] || { echo "ERROR: freetype2.pc is missing"; exit 1; }
echo "   freetype2.pc OK"

# 2f) libpng - PNG images (NetSurf finds it through pkg-config). Depends on zlib.
PNG_VER="1.6.44"
echo "==> libpng ${PNG_VER} (target, static)"
ok=0
for url in \
  "https://downloads.sourceforge.net/project/libpng/libpng16/${PNG_VER}/libpng-${PNG_VER}.tar.gz" \
  "https://downloads.sourceforge.net/libpng/libpng-${PNG_VER}.tar.gz" ; do
  echo "   libpng download: $url"
  if curl -fSL --retry 3 -o libpng.tar.gz "$url"; then ok=1; break; fi
  sleep 5
done
[ "$ok" = "1" ] || { echo "ERROR: failed to download libpng"; exit 1; }
tar xzf libpng.tar.gz
( cd "libpng-${PNG_VER}" && \
  ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
    --enable-static --disable-shared \
    CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" && \
  make -j"$JOBS" && make install )
[ -f "$PREFIX/lib/pkgconfig/libpng.pc" ] || { echo "ERROR: libpng.pc is missing"; exit 1; }
# Include zlib and -lm alongside png for static linking
sed -i 's/^Libs:.*/& -lz -lm/' "$PREFIX/lib/pkgconfig/libpng.pc"
echo "   libpng.pc OK"

# 2g) libjpeg (IJG) - JPEG images (e.g. book covers). Best-effort: on failure,
#     the build continues without JPEG (PNG remains available).
JPEG_OK=0
JPEG_VER="9f"
echo "==> libjpeg (IJG v${JPEG_VER}, target, static)"
ok=0
for url in \
  "https://www.ijg.org/files/jpegsrc.v${JPEG_VER}.tar.gz" \
  "http://www.ijg.org/files/jpegsrc.v${JPEG_VER}.tar.gz" ; do
  echo "   libjpeg download: $url"
  if curl -fSL --retry 3 -o jpeg.tar.gz "$url"; then ok=1; break; fi
  sleep 5
done
if [ "$ok" = "1" ] && tar xzf jpeg.tar.gz 2>/dev/null; then
  if ( cd "jpeg-${JPEG_VER}" && \
       ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
         --enable-static --disable-shared && \
       make -j"$JOBS" && make install ); then
    [ -f "$PREFIX/include/jpeglib.h" ] && JPEG_OK=1
  fi
fi
if [ "$JPEG_OK" = "1" ]; then echo "   libjpeg ready (JPEG enabled)"; else echo "   WARNING: libjpeg skipped (PNG only)"; fi

# 2h) libwebp - WebP images (e.g. Hungarian news sites). Best-effort.
WEBP_OK=0
WEBP_VER="1.4.0"
echo "==> libwebp ${WEBP_VER} (target, static)"
ok=0
for url in \
  "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VER}.tar.gz" \
  "https://github.com/webmproject/libwebp/releases/download/v${WEBP_VER}/libwebp-${WEBP_VER}.tar.gz" ; do
  echo "   libwebp download: $url"
  if curl -fSL --retry 3 -o webp.tar.gz "$url"; then ok=1; break; fi
  sleep 5
done
if [ "$ok" = "1" ] && tar xzf webp.tar.gz 2>/dev/null; then
  if ( cd "libwebp-${WEBP_VER}" && \
       ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
         --enable-static --disable-shared \
         --disable-gif --disable-tiff --disable-jpeg --disable-png --disable-wic \
         --disable-libwebpmux --disable-libwebpdemux && \
       make -j"$JOBS" && make install ); then
    [ -f "$PREFIX/lib/pkgconfig/libwebp.pc" ] && WEBP_OK=1
  fi
fi
if [ "$WEBP_OK" = "1" ]; then echo "   libwebp ready (WebP enabled)"; else echo "   WARNING: libwebp skipped"; fi

# NetSurf adds -ljpeg without pkg-config, so add our prefix to the compiler's
# search paths (pkg-config already finds png)
export CPATH="$PREFIX/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"

# 2d) MIME type fix: framebuffer fetch_filetype returns the wrong type for .css,
# causing stylesheets to fail with "UnacceptableType". Replace the function with
# a custom extension-based version (no external file dependency).
echo "==> replacing fetch_filetype in the sources"
cat > "$ROOT/patcher.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
def ensure_inc(s, inc):
    if ("#include " + inc) in s: return s
    m = re.search(r'^#include[^\n]*\n', s, re.M)
    return (s[:m.end()] + "#include " + inc + "\n" + s[m.end():]) if m else ("#include " + inc + "\n" + s)
for inc in ("<string.h>", "<strings.h>"):
    s = ensure_inc(s, inc)
lines = s.split('\n')
defidx = None
for i, l in enumerate(lines):
    if ('fetch_filetype' in l and '(' in l and ';' not in l
            and 'NSLOG' not in l and 'LOG(' not in l and 'define' not in l):
        defidx = i; break
if defidx is None:
    sys.stderr.write("PATCH-ERROR: fetch_filetype definition not found\n"); sys.exit(2)
startline = defidx; k = defidx - 1
while k >= 0:
    prev = lines[k].strip()
    if prev == "": k -= 1; continue
    if (prev.endswith('*') or prev in ('const char *','static const char *','char *')) \
            and ';' not in prev and '{' not in prev and '}' not in prev:
        startline = k; k -= 1; continue
    break
start = sum(len(lines[i]) + 1 for i in range(startline))
rest_off = sum(len(lines[i]) + 1 for i in range(defidx))
b = s.index('{', rest_off); depth = 0; j = b
while j < len(s):
    if s[j] == '{': depth += 1
    elif s[j] == '}':
        depth -= 1
        if depth == 0: break
    j += 1
end = j + 1
sys.stderr.write("ORIGINAL fetch_filetype:\n" + s[start:end] + "\n--- end ---\n")
newfn = (
'const char *fetch_filetype(const char *unix_path)\n'
'{\n'
'\tstatic const struct { const char *ext; const char *type; } nsmap[] = {\n'
'\t\t{".css","text/css"},{".html","text/html"},{".htm","text/html"},\n'
'\t\t{".js","text/javascript"},{".json","application/json"},\n'
'\t\t{".png","image/png"},{".gif","image/gif"},{".jpg","image/jpeg"},\n'
'\t\t{".jpeg","image/jpeg"},{".svg","image/svg+xml"},{".bmp","image/bmp"},\n'
'\t\t{".txt","text/plain"},{".xml","text/xml"},{0,0}\n'
'\t};\n'
'\tsize_t nl = strlen(unix_path); int ni;\n'
'\tfor (ni = 0; nsmap[ni].ext; ni++) {\n'
'\t\tsize_t el = strlen(nsmap[ni].ext);\n'
'\t\tif (nl >= el && strcasecmp(unix_path + nl - el, nsmap[ni].ext) == 0)\n'
'\t\t\treturn nsmap[ni].type;\n'
'\t}\n'
'\treturn "text/plain";\n'
'}'
)
open(p, 'w').write(s[:start] + newfn + s[end:])
sys.stderr.write("fetch_filetype REPLACED.\n")
PY
python3 "$ROOT/patcher.py" "$SRC/netsurf/frontends/framebuffer/fetch.c"
grep -q "nsmap" "$SRC/netsurf/frontends/framebuffer/fetch.c" \
  || { echo "ERROR: failed to replace fetch_filetype"; exit 1; }

# 2j) Change the on-screen keyboard (OSK) background from dark to white (e-ink) to avoid a black strip
sed -i 's/fbtk_get_height(root) - wh, 0, wh, 0xff202020/fbtk_get_height(root) - wh, 0, wh, 0xffffffff/' \
  "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" || true
echo "   OSK background set to white:"; grep -n "0xffffffff" "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" | head -1 || true

# 2k) Show the keyboard AUTOMATICALLY when tapping a text field (map_osk in text_input_click)
python3 - "$SRC/netsurf/frontends/framebuffer/fbtk/text.c" <<'PYOSK'
import re, sys
p = sys.argv[1]
s = open(p).read()
# Call map_osk() after redraw in text_input_click
anchor = "\tfbtk_request_redraw(widget);\n\n\treturn 0;\n}"
m = s.find("text_input_click")
if m != -1:
    i = s.find(anchor, m)
    if i != -1:
        s = s[:i] + "\tfbtk_request_redraw(widget);\n\n\tmap_osk();\n\n\treturn 0;\n}" + s[i+len(anchor):]
        open(p, "w").write(s)
        sys.stderr.write("map_osk inserted into text_input_click\n")
    else:
        sys.stderr.write("WARNING: text_input_click anchor not found (skipped)\n")
else:
    sys.stderr.write("WARNING: text_input_click not found (skipped)\n")
PYOSK
grep -q "map_osk();" "$SRC/netsurf/frontends/framebuffer/fbtk/text.c" && echo "   automatic keyboard patch OK" || echo "   (automatic keyboard patch skipped)"

# 2m) Keyboard: make shift STICKY (caps lock) - otherwise uppercase is unavailable
python3 - "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" <<'PYSHIFT'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''static int
osk_click(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
\tnsfb_event_t event;
\tstruct kbd_button_s *kbd_button = cbi->context;

\tevent.type = cbi->event->type;
\tevent.value.keycode = kbd_button->keycode;
\tfbtk_input(widget, &event);

\treturn 0;
}'''
new = '''static int osk_caps = 0;
static fbtk_widget_t *osk_keys[KEYCOUNT] = {0};
/* Visual feedback: letters switch case according to the caps lock state */
static void osk_update_caps(void)
{
\tint i;
\tfor (i = 0; i < KEYCOUNT; i++) {
\t\tconst char *t = kbdbase[i].t;
\t\tif (osk_keys[i] != NULL && t != NULL &&
\t\t    t[0] >= 'a' && t[0] <= 'z' && t[1] == 0) {
\t\t\tchar buf[2];
\t\t\tbuf[0] = (char)(osk_caps ? (t[0] - 32) : t[0]);
\t\t\tbuf[1] = 0;
\t\t\tfbtk_set_text(osk_keys[i], buf);
\t\t}
\t}
}
static int
osk_click(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
\tnsfb_event_t event;
\tstruct kbd_button_s *kbd_button = cbi->context;

\t/* Shift = sticky toggle (caps lock): hold the modifier until pressed again */
\tif (kbd_button->keycode == NSFB_KEY_LSHIFT ||
\t    kbd_button->keycode == NSFB_KEY_RSHIFT) {
\t\tif (cbi->event->type == NSFB_EVENT_KEY_DOWN) {
\t\t\tosk_caps = !osk_caps;
\t\t\tevent.type = osk_caps ? NSFB_EVENT_KEY_DOWN : NSFB_EVENT_KEY_UP;
\t\t\tevent.value.keycode = NSFB_KEY_LSHIFT;
\t\t\tfbtk_input(widget, &event);
\t\t\tosk_update_caps();
\t\t}
\t\treturn 0;
\t}

\tevent.type = cbi->event->type;
\tevent.value.keycode = kbd_button->keycode;
\tfbtk_input(widget, &event);

\treturn 0;
}'''
if old in s:
    s = s.replace(old, new)
    # Store key widgets in the creation loop (for updating labels)
    loop_old = "\t\tfbtk_set_text(widget, kbdbase[kloop].t);\n\t}"
    loop_new = "\t\tfbtk_set_text(widget, kbdbase[kloop].t);\n\t\tif (kloop < KEYCOUNT) osk_keys[kloop] = widget;\n\t}"
    if loop_old in s:
        s = s.replace(loop_old, loop_new, 1)
    else:
        sys.stderr.write("WARNING: OSK creation loop anchor not found (caps feedback skipped)\\n")
    open(p, "w").write(s)
    sys.stderr.write("OSK shift-toggle + caps feedback inserted\\n")
else:
    sys.stderr.write("WARNING: osk_click anchor not found (shift patch skipped)\\n")
PYSHIFT
grep -q "osk_update_caps" "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" && echo "   shift + caps feedback patch OK" || echo "   (shift patch skipped)"

# 2n) Broken on-screen keyboard keys: the "/" and "\" keycodes are swapped (only these
#     two keys are affected), and the apostrophe produces "l". Swap / fix them.
OSKC="$SRC/netsurf/frontends/framebuffer/fbtk/osk.c"
sed -i 's/NSFB_KEY_SLASH/__NSFBTMP__/g; s/NSFB_KEY_BACKSLASH/NSFB_KEY_SLASH/g; s/__NSFBTMP__/NSFB_KEY_BACKSLASH/g' "$OSKC"
sed -i "s/\"'\", NSFB_KEY_l/\"'\", NSFB_KEY_QUOTE/" "$OSKC"
echo "   OSK key fixes (slash/apostrophe):"; grep -nE 'NSFB_KEY_QUOTE|"/", NSFB_KEY_SLASH' "$OSKC" | head

# 2n2) HUNGARIAN ACCENTS on the on-screen keyboard. Keycodes normally pass through
#      the keymap table; introduce a "direct Unicode" range: codes above 0x2000
#      simply produce the Unicode character (code - 0x2000). This lets us add
#      accented OSK keys with arbitrary Unicode characters.
python3 - "$SRC/netsurf/frontends/framebuffer/fbtk/event.c" <<'PYACC'
import sys
p = sys.argv[1]; s = open(p).read()
anc = "fbtk_keycode_to_ucs4(int code, fbtk_modifier_type mods)\n{\n\tint ucs4 = -1;\n"
if anc not in s:
    sys.stderr.write("ACCENT-PATCH ERROR: fbtk_keycode_to_ucs4 anchor not found\n"); sys.exit(2)
s = s.replace(anc, anc + "\n\t/* Direct Unicode range for custom OSK keys (e.g. Hungarian accents) */\n\tif (code >= 0x2000) return code - 0x2000;\n", 1)
open(p, "w").write(s)
sys.stderr.write("event.c: direct-Unicode keycode handling inserted\n")
PYACC
grep -q "code >= 0x2000" "$SRC/netsurf/frontends/framebuffer/fbtk/event.c" \
  && echo "   accent (event.c) patch OK" || { echo "ERROR: accent event.c patch failed"; exit 1; }

python3 - "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" <<'PYACC2'
import sys
p = sys.argv[1]; s = open(p).read()
# KEYCOUNT 58 -> 67 (9 accented vowels)
if "#define KEYCOUNT 58" not in s:
    sys.stderr.write("ACCENT-PATCH ERROR: KEYCOUNT 58 not found\n"); sys.exit(2)
s = s.replace("#define KEYCOUNT 58", "#define KEYCOUNT 67", 1)
# Insert an accented key row at the end of kbdbase (after the down arrow, before '};')
anchor = '\t{ 250,  75,  20,  15, "\\xe2\\x96\\xbc", NSFB_KEY_DOWN},\n};'
if anchor not in s:
    sys.stderr.write("ACCENT-PATCH ERROR: end-of-kbdbase anchor not found\n"); sys.exit(2)
rows = (
    '\t{ 250,  75,  20,  15, "\\xe2\\x96\\xbc", NSFB_KEY_DOWN},\n'
    '\t{  60,  90,  20,  15, "\\xc3\\xa1", (enum nsfb_key_code_e)(0x2000 + 0x00E1)},\n'  # á
    '\t{  80,  90,  20,  15, "\\xc3\\xa9", (enum nsfb_key_code_e)(0x2000 + 0x00E9)},\n'  # é
    '\t{ 100,  90,  20,  15, "\\xc3\\xad", (enum nsfb_key_code_e)(0x2000 + 0x00ED)},\n'  # í
    '\t{ 120,  90,  20,  15, "\\xc3\\xb3", (enum nsfb_key_code_e)(0x2000 + 0x00F3)},\n'  # ó
    '\t{ 140,  90,  20,  15, "\\xc3\\xb6", (enum nsfb_key_code_e)(0x2000 + 0x00F6)},\n'  # ö
    '\t{ 160,  90,  20,  15, "\\xc5\\x91", (enum nsfb_key_code_e)(0x2000 + 0x0151)},\n'  # ő
    '\t{ 180,  90,  20,  15, "\\xc3\\xba", (enum nsfb_key_code_e)(0x2000 + 0x00FA)},\n'  # ú
    '\t{ 200,  90,  20,  15, "\\xc3\\xbc", (enum nsfb_key_code_e)(0x2000 + 0x00FC)},\n'  # ü
    '\t{ 220,  90,  20,  15, "\\xc5\\xb1", (enum nsfb_key_code_e)(0x2000 + 0x0171)},\n'  # ű
    '};'
)
s = s.replace(anchor, rows, 1)
open(p, "w").write(s)
sys.stderr.write("osk.c: 9 Hungarian accented keys added\n")
PYACC2
grep -q "0x2000 + 0x0151" "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" \
  && echo "   accented keys (osk.c) patch OK" || { echo "ERROR: accent osk.c patch failed"; exit 1; }

# 2o) Also show the keyboard when tapping an in-page (HTML) field (map_osk on caret placement;
#     map_osk() is declared in fbtk.h, which gui.c already includes)
python3 - "$SRC/netsurf/frontends/framebuffer/gui.c" <<'PYCARET'
import sys
p = sys.argv[1]
s = open(p).read()
anc = ("\tfb_queue_redraw(g->browser,\n"
       "\t\t\tx - bwidget->scrollx,\n"
       "\t\t\ty - bwidget->scrolly,\n"
       "\t\t\tx + 1 - bwidget->scrollx,\n"
       "\t\t\ty + height - bwidget->scrolly);\n"
       "}")
new = anc[:-1] + ("\n\tif (g_field_click_pending > 0) { g_field_copy_request = 1; g_field_click_pending = 0; nsk_flog(\"FIELD place_caret: user tap -> g_field_copy_request=1\"); }\n}")
if anc in s:
    s = s.replace(anc, new, 1)
    open(p, "w").write(s)
    sys.stderr.write("place_caret -> field trigger (KOReader overlay) inserted\n")
else:
    sys.stderr.write("WARNING: place_caret anchor not found\n")
PYCARET
grep -q "g_field_copy_request = 1" "$SRC/netsurf/frontends/framebuffer/gui.c" && echo "   field-focus (KOReader overlay) patch OK" || { echo "ERROR: field-focus patch failed"; exit 1; }

# 2k2) clipboard.c: export the static clipboard buffer so gui.c can read the
#      focused field's current contents (after SELECT_ALL + COPY).
python3 - "$SRC/netsurf/frontends/framebuffer/clipboard.c" <<'PYCLIP'
import sys
p = sys.argv[1]; s = open(p).read()
anc = "struct gui_clipboard_table *framebuffer_clipboard_table = &clipboard_table;"
if anc not in s:
    sys.stderr.write("CLIP-PATCH ERROR: anchor not found\n"); sys.exit(2)
add = anc + ("\n\n/* Kindle: read current clipboard text from gui.c (retrieve field contents) */\n"
             "const char *fb_clipboard_text(void) { return gui_clipboard.buffer ? gui_clipboard.buffer : \"\"; }\n"
             "void fb_clipboard_clear(void) { gui_clipboard.length = 0; if (gui_clipboard.buffer) gui_clipboard.buffer[0] = '\\0'; }\n")
s = s.replace(anc, add, 1)
open(p, "w").write(s)
sys.stderr.write("clipboard.c: fb_clipboard_text() exported\n")
PYCLIP
grep -q "fb_clipboard_text" "$SRC/netsurf/frontends/framebuffer/clipboard.c" && echo "   clipboard export OK" || { echo "ERROR: clipboard export failed"; exit 1; }

# 2l) DOWNLOAD HANDLER for the framebuffer frontend (which lacks one): save downloads
#     to NETSURF_DOWNLOAD_DIR and append their paths to NETSURF_DL_LIST.
python3 - "$SRC/netsurf/frontends/framebuffer/gui.c" <<'PYDL'
import sys
p = sys.argv[1]
s = open(p).read()
block = r'''
/* ===== Kindle: download to file (missing from the fb frontend) ===== */
#include "netsurf/download.h"
#include "desktop/download.h"
struct gui_download_window { FILE *kf; char kpath[1024]; download_context *kctx; };
static struct gui_download_window *
fb_kindle_download_create(download_context *ctx, struct gui_window *parent)
{
	const char *dir = getenv("NETSURF_DOWNLOAD_DIR");
	const char *fn = download_context_get_filename(ctx);
	struct gui_download_window *dw;
	char name[512];
	char cmd[1200];
	char *p;
	(void) parent;
	if (dir == NULL || dir[0] == 0) dir = "/mnt/us/koreader/documents";
	if (fn != NULL && fn[0] != 0) { strncpy(name, fn, sizeof(name) - 1); name[sizeof(name) - 1] = 0; }
	else { snprintf(name, sizeof(name), "download-%ld", (long) time(NULL)); }
	for (p = name; *p != 0; p++) { if (*p == '/' || *p == '\\') *p = '_'; }
	dw = calloc(1, sizeof(*dw));
	if (dw == NULL) return NULL;
	dw->kctx = ctx;
	snprintf(cmd, sizeof(cmd), "mkdir -p \"%s\" 2>/dev/null", dir);
	if (system(cmd) == -1) { /* ignore */ }
	snprintf(dw->kpath, sizeof(dw->kpath), "%s/%s", dir, name);
	dw->kf = fopen(dw->kpath, "wb");
	if (dw->kf == NULL) { free(dw); return NULL; }
	NSLOG(netsurf, INFO, "Kindle download -> %s", dw->kpath);
	return dw;
}
static nserror
fb_kindle_download_data(struct gui_download_window *dw, const char *data, unsigned int size)
{
	if (dw != NULL && dw->kf != NULL && size > 0) {
		if (fwrite(data, 1, size, dw->kf) != size) return NSERROR_SAVE_FAILED;
	}
	return NSERROR_OK;
}
static void
fb_kindle_download_error(struct gui_download_window *dw, const char *error_msg)
{
	NSLOG(netsurf, INFO, "Kindle download error: %s", error_msg ? error_msg : "?");
	if (dw != NULL) { if (dw->kf != NULL) fclose(dw->kf); download_context_destroy(dw->kctx); free(dw); }
}
static void
fb_kindle_download_done(struct gui_download_window *dw)
{
	const char *listf;
	if (dw == NULL) return;
	if (dw->kf != NULL) fclose(dw->kf);
	NSLOG(netsurf, INFO, "Kindle download done: %s", dw->kpath);
	listf = getenv("NETSURF_DL_LIST");
	if (listf != NULL && listf[0] != 0) {
		FILE *lf = fopen(listf, "a");
		if (lf != NULL) { fputs(dw->kpath, lf); fputc('\n', lf); fclose(lf); }
	}
	download_context_destroy(dw->kctx);
	free(dw);
}
static struct gui_download_table framebuffer_download_table = {
	.create = fb_kindle_download_create,
	.data = fb_kindle_download_data,
	.error = fb_kindle_download_error,
	.done = fb_kindle_download_done,
};
/* ===== End of Kindle download handling ===== */

'''
anchor = "\t.quit = gui_quit,\n};\n"
i = s.find(anchor)
if i == -1:
    sys.stderr.write("DL-PATCH ERROR: misc_table anchor not found\n"); sys.exit(2)
i += len(anchor)
s = s[:i] + block + s[i:]
# Register download handling in the table
tbl = "\t\t.fetch = framebuffer_fetch_table,\n"
j = s.find(tbl)
if j == -1:
    sys.stderr.write("DL-PATCH ERROR: framebuffer_table anchor not found\n"); sys.exit(2)
j += len(tbl)
s = s[:j] + "\t\t.download = &framebuffer_download_table,\n" + s[j:]
open(p, "w").write(s)
sys.stderr.write("Download handler inserted into the fb frontend\n")
PYDL
grep -q "framebuffer_download_table" "$SRC/netsurf/frontends/framebuffer/gui.c" \
  && echo "   download handler patch OK" || { echo "ERROR: download handler patch failed"; exit 1; }

# 2p) CUSTOM TOOLBAR: the surface (kindlefb.c) draws the top bar and sets the
#     g_nav_request / g_toolbar_url flags. gui.c must do three things:
#      - declare the shared flags as extern,
#      - handle back/forward/reload/close requests in the main loop,
#      - copy the address for the custom bar when the URL changes (with NULL checks,
#        because the native toolbar is disabled, so g->url may be NULL).
python3 - "$SRC/netsurf/frontends/framebuffer/gui.c" <<'PYTB'
import sys
p = sys.argv[1]; s = open(p).read()

a1 = "static bool fb_complete = false;\n"
if a1 not in s:
    sys.stderr.write("TB-PATCH ERROR: fb_complete anchor not found\n"); sys.exit(2)
add1 = a1 + ('#include <signal.h>\n'
             '#include <stdarg.h>\n'
             'extern char g_toolbar_url[1024];\n'
             'extern volatile sig_atomic_t g_toolbar_url_dirty;\n'
             'extern volatile sig_atomic_t g_nav_request;\n'
             'extern volatile sig_atomic_t g_field_click_pending;\n'
             'extern volatile sig_atomic_t g_field_input_request;\n'
             'extern volatile sig_atomic_t g_inject_request;\n'
             'static volatile sig_atomic_t g_field_copy_request = 0;\n'
             'extern const char *fb_clipboard_text(void);\n'
             'extern void fb_clipboard_clear(void);\n'
             'static void nsk_flog(const char *fmt, ...) {\n'
             '\tconst char *fl = getenv("NETSURF_FIELD_LOG");\n'
             '\tif (fl == NULL || fl[0] == 0) return;\n'
             '\tFILE *lf = fopen(fl, "a"); if (lf == NULL) return;\n'
             '\tva_list ap; va_start(ap, fmt); vfprintf(lf, fmt, ap); va_end(ap);\n'
             '\tfputc(\'\\n\', lf); fclose(lf);\n'
             '}\n')
s = s.replace(a1, add1, 1)

a2 = "\twhile (fb_complete != true) {\n"
if a2 not in s:
    sys.stderr.write("TB-PATCH ERROR: main loop anchor not found\n"); sys.exit(2)
h2 = ("\t\tif (g_nav_request != 0) {\n"
      "\t\t\tint _r = g_nav_request; g_nav_request = 0;\n"
      "\t\t\tif (window_list != NULL && window_list->bw != NULL) {\n"
      "\t\t\t\tif (_r == 1) browser_window_history_back(window_list->bw, false);\n"
      "\t\t\t\telse if (_r == 2) browser_window_history_forward(window_list->bw, false);\n"
      "\t\t\t\telse if (_r == 3) browser_window_reload(window_list->bw, true);\n"
      "\t\t\t\telse if (_r == 4) fb_complete = true;\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t\tif (g_field_click_pending > 0) g_field_click_pending--;\n"
      "\t\tif (g_field_copy_request != 0) {\n"
      "\t\t\tg_field_copy_request = 0;\n"
      "\t\t\tif (window_list != NULL && window_list->bw != NULL) {\n"
      "\t\t\t\tfb_clipboard_clear(); /* do not retain the previous field's text */\n"
      "\t\t\t\tbrowser_window_key_press(window_list->bw, 1); /* NS_KEY_SELECT_ALL */\n"
      "\t\t\t\tbrowser_window_key_press(window_list->bw, 3); /* NS_KEY_COPY_SELECTION */\n"
      "\t\t\t\t{ const char *_ct = fb_clipboard_text();\n"
      "\t\t\t\t  const char *_ftf = getenv(\"NETSURF_FIELD_TEXT\");\n"
      "\t\t\t\t  if (_ftf != NULL && _ftf[0] != 0) {\n"
      "\t\t\t\t    FILE *_tf = fopen(_ftf, \"wb\");\n"
      "\t\t\t\t    if (_tf != NULL) { if (_ct != NULL && _ct[0] != 0) fputs(_ct, _tf); fclose(_tf); }\n"
      "\t\t\t\t  }\n"
      "\t\t\t\t  nsk_flog(\"GUI FIELD-TEXT read: %u bytes\", (unsigned)(_ct ? strlen(_ct) : 0)); }\n"
      "\t\t\t\tbrowser_window_key_press(window_list->bw, 26); /* NS_KEY_CLEAR_SELECTION */\n"
      "\t\t\t}\n"
      "\t\t\tg_field_input_request = 1;\n"
      "\t\t}\n"
      "\t\tif (g_inject_request != 0) {\n"
      "\t\t\tg_inject_request = 0;\n"
      "\t\t\tnsk_flog(\"GUI INJECT: processing g_inject_request; window_list=%p bw=%p\", (void*)window_list, (void*)(window_list?window_list->bw:NULL));\n"
      "\t\t\tif (window_list != NULL && window_list->bw != NULL) {\n"
      "\t\t\t\tconst char *_if = getenv(\"NETSURF_INJECT_FILE\");\n"
      "\t\t\t\tnsk_flog(\"GUI INJECT: injection file=%s\", _if ? _if : \"(none)\");\n"
      "\t\t\t\tif (_if != NULL && _if[0] != 0) {\n"
      "\t\t\t\t\tFILE *_f = fopen(_if, \"rb\");\n"
      "\t\t\t\t\tnsk_flog(\"GUI INJECT: file opened=%d\", _f ? 1 : 0);\n"
      "\t\t\t\t\tif (_f != NULL) {\n"
      "\t\t\t\t\t\tint _ch; uint32_t _cp = 0; int _need = 0; int _np = 0;\n"
      "\t\t\t\t\t\tbrowser_window_key_press(window_list->bw, 1); /* NS_KEY_SELECT_ALL: the first character replaces the existing content */\n"
      "\t\t\t\t\t\twhile ((_ch = fgetc(_f)) != EOF) {\n"
      "\t\t\t\t\t\t\tunsigned char _b = (unsigned char)_ch;\n"
      "\t\t\t\t\t\t\tif (_need == 0) {\n"
      "\t\t\t\t\t\t\t\tif (_b == '\\n' || _b == '\\r') continue;\n"
      "\t\t\t\t\t\t\t\tif (_b < 0x80) { bool _r = browser_window_key_press(window_list->bw, _b); nsk_flog(\"GUI INJECT key cp=%u -> key_press=%d\", (unsigned)_b, (int)_r); _np++; }\n"
      "\t\t\t\t\t\t\t\telse if ((_b & 0xE0) == 0xC0) { _cp = _b & 0x1F; _need = 1; }\n"
      "\t\t\t\t\t\t\t\telse if ((_b & 0xF0) == 0xE0) { _cp = _b & 0x0F; _need = 2; }\n"
      "\t\t\t\t\t\t\t\telse if ((_b & 0xF8) == 0xF0) { _cp = _b & 0x07; _need = 3; }\n"
      "\t\t\t\t\t\t\t\telse { _need = 0; }\n"
      "\t\t\t\t\t\t\t} else {\n"
      "\t\t\t\t\t\t\t\tif ((_b & 0xC0) == 0x80) { _cp = (_cp << 6) | (_b & 0x3F); _need--; if (_need == 0) { bool _r = browser_window_key_press(window_list->bw, _cp); nsk_flog(\"GUI INJECT key cp=%u -> key_press=%d\", (unsigned)_cp, (int)_r); _np++; } }\n"
      "\t\t\t\t\t\t\t\telse { _need = 0; }\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\tif (_np == 0) browser_window_key_press(window_list->bw, 8); /* empty new text: NS_KEY_DELETE_LEFT deletes the selection */\n"
      "\t\t\t\t\t\tfclose(_f); remove(_if);\n"
      "\t\t\t\t\t\tnsk_flog(\"GUI INJECT: done, %d keys sent\", _np);\n"
      "\t\t\t\t\t}\n"
      "\t\t\t\t}\n"
      "\t\t\t}\n"
      "\t\t}\n")
s = s.replace(a2, a2 + h2, 1)

a3 = "\tfbtk_set_text(g->url, nsurl_access(url));\n"
if a3 not in s:
    sys.stderr.write("TB-PATCH ERROR: set_url anchor not found\n"); sys.exit(2)
h3 = ("\t{ const char *_u = nsurl_access(url);\n"
      "\t  strncpy(g_toolbar_url, _u ? _u : \"\", sizeof(g_toolbar_url) - 1);\n"
      "\t  g_toolbar_url[sizeof(g_toolbar_url) - 1] = 0; g_toolbar_url_dirty = 1;\n"
      "\t  { const char *_hf = getenv(\"NETSURF_HISTORY_FILE\");\n"
      "\t    if (_hf != NULL && _hf[0] != 0 && _u != NULL && _u[0] != 0 && strncmp(_u, \"about:\", 6) != 0) {\n"
      "\t      FILE *_h = fopen(_hf, \"a\"); if (_h != NULL) { fputs(_u, _h); fputc('\\n', _h); fclose(_h); } } } }\n"
      "\tif (g->url != NULL) fbtk_set_text(g->url, nsurl_access(url));\n")
s = s.replace(a3, h3, 1)

open(p, "w").write(s)
sys.stderr.write("Custom toolbar patch inserted into gui.c\n")
PYTB
grep -q "g_nav_request" "$SRC/netsurf/frontends/framebuffer/gui.c" \
  && echo "   custom toolbar (gui.c) patch OK" || { echo "ERROR: custom toolbar patch failed"; exit 1; }

# 2p) Override User-Agent through an environment variable (NETSURF_USER_AGENT), so it
#     can be changed in plugin settings (e.g. Firefox/Chrome UA for better site compatibility).
python3 - "$SRC/netsurf/utils/useragent.c" <<'PYUA'
import sys
p = sys.argv[1]; s = open(p).read()
anc = "        char *ua_string;\n        int len;\n"
if anc not in s:
    sys.stderr.write("UA-PATCH ERROR: anchor not found\n"); sys.exit(2)
add = anc + ("\n        {\n"
             "                const char *_envua = getenv(\"NETSURF_USER_AGENT\");\n"
             "                if (_envua != NULL && _envua[0] != 0) {\n"
             "                        core_user_agent_string = strdup(_envua);\n"
             "                        if (core_user_agent_string != NULL) {\n"
             "                                NSLOG(netsurf, INFO, \"User agent from env: %s\", core_user_agent_string);\n"
             "                                return;\n"
             "                        }\n"
             "                }\n"
             "        }\n")
s = s.replace(anc, add, 1)
# getenv/strdup -> stdlib.h/string.h; add them if missing
if '#include <stdlib.h>' not in s:
    s = s.replace('#include "utils/useragent.h"', '#include <stdlib.h>\n#include "utils/useragent.h"', 1)
open(p, "w").write(s)
sys.stderr.write("useragent.c: NETSURF_USER_AGENT env override inserted\n")
PYUA
grep -q "NETSURF_USER_AGENT" "$SRC/netsurf/utils/useragent.c" && echo "   UA env-override OK" || { echo "ERROR: UA patch failed"; exit 1; }

# 2q) Paging with overlap: PageUp/PageDown should always scroll by the viewport height
#     minus a fixed overlap (so no lines are missed), consistently for all content.
python3 - "$SRC/netsurf/frontends/framebuffer/gui.c" <<'PYPAGE'
import sys
p = sys.argv[1]; s = open(p).read()
old = ("\t\tcase NSFB_KEY_PAGEUP:\n"
       "\t\t\tif (browser_window_key_press(gw->bw,\n"
       "\t\t\t\t\tNS_KEY_PAGE_UP) == false)\n"
       "\t\t\t\twidget_scroll_y(gw, -fbtk_get_height(\n"
       "\t\t\t\t\t\tgw->browser), false);\n"
       "\t\t\tbreak;\n"
       "\n"
       "\t\tcase NSFB_KEY_PAGEDOWN:\n"
       "\t\t\tif (browser_window_key_press(gw->bw,\n"
       "\t\t\t\t\tNS_KEY_PAGE_DOWN) == false)\n"
       "\t\t\t\twidget_scroll_y(gw, fbtk_get_height(\n"
       "\t\t\t\t\t\tgw->browser), false);\n"
       "\t\t\tbreak;\n")
new = ("\t\tcase NSFB_KEY_PAGEUP:\n"
       "\t\t\twidget_scroll_y(gw, -(fbtk_get_height(gw->browser) - 56), false);\n"
       "\t\t\tbreak;\n"
       "\n"
       "\t\tcase NSFB_KEY_PAGEDOWN:\n"
       "\t\t\twidget_scroll_y(gw, (fbtk_get_height(gw->browser) - 56), false);\n"
       "\t\t\tbreak;\n")
if old not in s:
    sys.stderr.write("PAGE-PATCH WARNING: PageUp/Down anchor does not match exactly; skipped\n")
else:
    s = s.replace(old, new, 1)
    open(p, "w").write(s)
    sys.stderr.write("gui.c: paging with overlap (56px) inserted\n")
PYPAGE

# 3) NetSurf, framebuffer frontend, linux surface (/dev/fb + /dev/input), JS (duktape)
echo "==> netsurf (framebuffer)"
make -C "$SRC/netsurf" -j"$JOBS" \
  CC="${CROSS}gcc" AR="${CROSS}ar" HOST="$TARGET_TUPLE" \
  PREFIX="$PREFIX" NSSHARED="$TGT_NSSHARED" \
  NSGENBIND="$HOSTPREFIX/bin/nsgenbind" \
  TARGET=framebuffer \
  NETSURF_FB_FRONTEND=linux \
  NETSURF_FB_FONTLIB=freetype \
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  NETSURF_USE_DUKTAPE=YES \
  NETSURF_USE_JPEG=$([ "$JPEG_OK" = "1" ] && echo YES || echo NO) \
  NETSURF_USE_PNG=YES NETSURF_USE_WEBP=$([ "$WEBP_OK" = "1" ] && echo YES || echo NO) \
  NETSURF_USE_ROSPRITE=NO NETSURF_USE_NSSVG=NO NETSURF_USE_VIDEO=NO \
  NETSURF_USE_HARU_PDF=NO NETSURF_USE_CURL=YES NETSURF_USE_OPENSSL=YES

# 4) FBInk - Kindle e-ink refresh (MTK EPDC). After drawing, force the display
#    to show what NetSurf wrote to the framebuffer.
echo "==> FBInk (Kindle e-ink)"
if [ ! -d "$ROOT/FBInk" ]; then
  git clone --depth 1 --recursive https://github.com/NiLuJe/FBInk.git "$ROOT/FBInk" || true
fi
if [ -d "$ROOT/FBInk" ]; then
  ( cd "$ROOT/FBInk" && \
    export CROSS_TC="$TARGET_TUPLE" && \
    export PATH="$(dirname "$REALGCC"):$PATH" && \
    make clean >/dev/null 2>&1 || true; \
    make kindle -j"$JOBS" ) && \
  FBINK_BIN="$(find "$ROOT/FBInk" -name fbink -type f -perm -u+x | head -n1 || true)" && \
  [ -n "$FBINK_BIN" ] && cp "$FBINK_BIN" "$OUT/fbink" && "${CROSS}strip" "$OUT/fbink" 2>/dev/null || true
fi
[ -f "$OUT/fbink" ] && echo "   fbink ready: $(file "$OUT/fbink" | cut -c1-50)" || echo "   WARNING: fbink was not built (NetSurf is still ready)"

# 5) libmobi + mobitool - on-device azw3/mobi/KF8 -> EPUB conversion (no external
#    dependencies: built-in miniz + xmlwriter). Best-effort: failure does not affect the rest.
echo "==> libmobi (mobitool, azw3->epub)"
if [ ! -d "$ROOT/libmobi" ]; then
  git clone --depth 1 https://github.com/bfabiszewski/libmobi "$ROOT/libmobi" || true
fi
if [ -d "$ROOT/libmobi" ]; then
  # Save all libmobi build output to the log (also included in the artifact)
  ( cd "$ROOT/libmobi" && \
    ./autogen.sh && \
    ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
      --enable-static --disable-shared --enable-tools \
      --with-zlib=no --with-libxml2=no \
      LDFLAGS="-Wl,--allow-multiple-definition" && \
    make -j"$JOBS" ) > "$OUT/libmobi-build.log" 2>&1 || echo "   WARNING: libmobi build failed (see libmobi-build.log)"
  # libtool places the ACTUAL ELF binary under .libs/; search there first
  MOBITOOL_BIN="$(find "$ROOT/libmobi" -path '*/.libs/mobitool' -type f 2>/dev/null | head -n1 || true)"
  [ -n "$MOBITOOL_BIN" ] || MOBITOOL_BIN="$(find "$ROOT/libmobi" -name mobitool -type f 2>/dev/null | head -n1 || true)"
  if [ -n "$MOBITOOL_BIN" ] && head -c4 "$MOBITOOL_BIN" | grep -q "ELF"; then
    cp "$MOBITOOL_BIN" "$OUT/mobitool" && "${CROSS}strip" "$OUT/mobitool" 2>/dev/null || true
  else
    echo "   (mobitool binary is not ELF or is missing: $MOBITOOL_BIN)"
  fi
fi
[ -f "$OUT/mobitool" ] && echo "   mobitool ready: $(file "$OUT/mobitool" | cut -c1-50)" || echo "   WARNING: mobitool was not built (conversion unavailable)"

echo "==> assembling output"
BIN="$(find "$SRC/netsurf" -maxdepth 2 -name 'nsfb' -type f | head -n1 || true)"
[ -n "$BIN" ] || BIN="$(find "$SRC/netsurf" -maxdepth 2 -name 'netsurf' -type f -perm -u+x | head -n1 || true)"
[ -n "$BIN" ] || { echo "ERROR: compiled binary not found"; exit 1; }

cp "$BIN" "$OUT/netsurf"
# IMPORTANT: use -L so framebuffer res symlinks (default.css, quirks.css,
# internal.css, welcome.html, etc. -> shared resources) are copied as ACTUAL files.
rm -rf "$OUT/res"
if [ -d "$SRC/netsurf/frontends/framebuffer/res" ]; then
  cp -rL "$SRC/netsurf/frontends/framebuffer/res" "$OUT/res"
elif [ -d "$SRC/netsurf/resources" ]; then
  cp -rL "$SRC/netsurf/resources" "$OUT/res"
fi
# DejaVu TTF fonts under res/fonts (loaded by the freetype backend: Hungarian ő, Cyrillic, Greek)
echo "==> downloading DejaVu fonts"
DEJAVU_VER="2.37"
ok=0
for url in \
  "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-${DEJAVU_VER}.tar.bz2" \
  "https://downloads.sourceforge.net/project/dejavu/dejavu/${DEJAVU_VER}/dejavu-fonts-ttf-${DEJAVU_VER}.tar.bz2" ; do
  echo "   DejaVu download: $url"
  if curl -fSL --retry 3 -o dejavu.tar.bz2 "$url"; then ok=1; break; fi
  sleep 5
done
[ "$ok" = "1" ] || { echo "ERROR: failed to download DejaVu"; exit 1; }
tar xjf dejavu.tar.bz2
DEJAVU_DIR="$(find "$ROOT" -maxdepth 2 -type d -name 'dejavu-fonts-ttf-*' | head -n1)/ttf"
mkdir -p "$OUT/res/fonts"
for f in DejaVuSans.ttf DejaVuSans-Bold.ttf DejaVuSans-Oblique.ttf \
         DejaVuSans-BoldOblique.ttf DejaVuSerif.ttf DejaVuSerif-Bold.ttf \
         DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf ; do
  cp -f "$DEJAVU_DIR/$f" "$OUT/res/fonts/$f" || { echo "ERROR: $f is missing"; exit 1; }
done
echo "   DejaVu fonts under res/fonts:"; ls -1 "$OUT/res/fonts"

# Custom mime.types in res (read by fetch.c as patched during the build)
cat > "$OUT/res/mime.types" <<'MIME'
text/css			css
text/html			html htm
text/plain			txt text
text/javascript			js
application/json		json
image/png			png
image/jpeg			jpg jpeg jpe
image/gif			gif
image/svg+xml			svg
image/bmp			bmp
application/octet-stream	bin
MIME
echo "==> checking res contents (must include .css, welcome.html, mime.types):"
ls -1 "$OUT/res" | grep -E '\.css$|welcome|mime\.types' || echo "WARNING: something is missing from res!"
"${CROSS}strip" "$OUT/netsurf" 2>/dev/null || true
file "$OUT/netsurf" || true
echo "==> DONE: $OUT/netsurf"
