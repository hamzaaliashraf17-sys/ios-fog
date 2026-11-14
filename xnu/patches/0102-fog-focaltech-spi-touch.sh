#!/bin/bash
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0

python3 - <<'PY'
from pathlib import Path
p = Path("bsd/dev/sweet_touch.c")
t = p.read_text()
assert "NVT_PAGE_COUNT" in t, "0101 not applied?"
if "touch_fog_fts_probe" in t:
    print("0102 already applied, skipping")
    raise SystemExit(0)

# Firmware: copy the .h next to sweet_touch.c so #include works
import shutil
shutil.copyfile("xnu/patches/focaltech_fw_xinli.h", "bsd/dev/focaltech_fw_xinli.h")

fts = r'''
/* FocalTech fog (220333QAG): FT8006S Xinli, ID 0x8006. No flash - FW must be
 * loaded to PRAM on every boot from focaltech_ts_fw_xinli.bin (128K).
 * Chip ID: reg 0xA3 = 0x80, reg 0x9F = 0x06. Touch data: reg 0x00. */
#include "focaltech_fw_xinli.h"
#define FTS_REG_ID1           0xA3u
#define FTS_REG_ID2           0x9Fu
#define FTS_ID1               0x80u
#define FTS_ID2               0x06u
#define FTS_REG_TOUCH        0x00u
#define FTS_REG_BOOT         0xFCu
#define FTS_FW_LEN           131072u
static bool fog_is_fts;

/* FocalTech SPI: 1 addr byte, then data. No dummy byte like Novatek (+1, not +2). */
static int
touch_fog_fts_read(uint8_t reg, uint8_t *buf, unsigned n)
{
        uint8_t tx[256], rx[256];
        int err;
        if (n == 0 || n + 1u > 256u) return EINVAL;
        memset(tx, 0, sizeof(tx));
        tx[0] = reg;
        err = touch_spi_run(SPI_TX_RX, 0, tx, n + 1u, rx, n + 1u);
        if (!err) { memcpy(buf, rx + 1, n); return 0; }
        if (st.dead) return err;
        if ((err = touch_spi_run(SPI_TX_ONLY, SPI_FRAGMENT, &reg, 1, NULL, 0)) != 0) return err;
        if ((err = touch_spi_run(SPI_RX_ONLY, 0, NULL, 0, rx, n + 1u)) != 0) return err;
        memcpy(buf, rx + 1, n);
        return 0;
}

static int
touch_fog_fts_write(uint8_t reg, const uint8_t *buf, unsigned n)
{
        uint8_t tx[256];
        if (n + 1u > 256u) return EINVAL;
        tx[0] = reg;
        if (n) memcpy(tx + 1, buf, n);
        return touch_spi_run(SPI_TX_ONLY, 0, tx, n + 1u, NULL, 0);
}

/* FT8006S FW load: enter bootloader (0x55 0xAA to 0xFC), stream 128K PRAM
 * in 128B chunks, then reset to run it. Logs every step so we can debug. */
static bool
touch_fog_fts_load_fw(void)
{
        uint8_t enter[2] = { 0x55, 0xAA };
        uint8_t id1 = 0, id2 = 0;
        if (touch_fog_fts_write(FTS_REG_BOOT, enter, 2)) {
                printf("SWEET TOUCH: fts fw enter-boot failed\n");
                return false;
        }
        printf("SWEET TOUCH: fts fw loading %u bytes\n", FTS_FW_LEN);
        for (unsigned off = 0; off < FTS_FW_LEN; off += 128u) {
                unsigned chunk = FTS_FW_LEN - off;
                if (chunk > 128u) chunk = 128u;
                /* PRAM write: addr = off, payload = fw[off..] via reg 0x00 window */
                uint8_t hdr[3] = { (uint8_t)(off >> 16), (uint8_t)(off >> 8), (uint8_t)off };
                if (touch_fog_fts_write(FTS_REG_TOUCH, hdr, 3)) return false;
                if (touch_fog_fts_write(FTS_REG_TOUCH, firmware_focaltech_ts_fw_xinli_bin + off, chunk)) {
                        printf("SWEET TOUCH: fts fw write failed off=%u\n", off);
                        return false;
                }
                if ((off & 0x3FFFu) == 0) printf("SWEET TOUCH: fts fw off=%u/131072\n", off);
        }
        printf("SWEET TOUCH: fts fw loaded, resetting to run\n");
        return true;
}

static bool
touch_fog_fts_probe(void)
{
        uint8_t id1 = 0, id2 = 0;
        if (touch_fog_fts_read(FTS_REG_ID1, &id1, 1)) return false;
        if (touch_fog_fts_read(FTS_REG_ID2, &id2, 1)) return false;
        printf("SWEET TOUCH: fog fts id=%02x %02x expect 80 06\n", id1, id2);
        if (id1 != FTS_ID1 || id2 != FTS_ID2) return false;
        fog_is_fts = true;
        printf("SWEET TOUCH: fog focaltech FT8006S detected, loading FW\n");
        if (!touch_fog_fts_load_fw()) printf("SWEET TOUCH: fts fw load failed, will still try report\n");
        return true;
}

/* FocalTech report: byte0=gesture, byte1=finger count (low nibble),
 * then 6 bytes per finger at +3: [event<<6 | x_hi, x_lo, id<<4 | y_hi, y_lo, pressure, area] */
static int
touch_fog_fts_report(void)
{
        uint8_t buf[34];
        int x[TOUCH_MAX] = {0}, y[TOUCH_MAX] = {0};
        uint32_t mask = 0;
        int err = touch_fog_fts_read(FTS_REG_TOUCH, buf, sizeof(buf));
        if (err) return err;
        if (!st.s_frames || buf[0] || buf[1]) memcpy(st.s_raw, buf, sizeof(st.s_raw));
        st.s_frames++;
        unsigned cnt = buf[1] & 0x0fu;
        if (cnt > TOUCH_MAX) cnt = TOUCH_MAX;
        for (unsigned i = 0; i < cnt; ++i) {
                const uint8_t *p = buf + 3u + 6u * i;
                unsigned ev = p[0] >> 6, id = (p[2] >> 4) & 0x0fu;
                unsigned px = ((unsigned)(p[0] & 0x0fu) << 8) | p[1];
                unsigned py = ((unsigned)(p[2] & 0x0fu) << 8) | p[3];
                if (ev == 1u) continue;
                if (id >= TOUCH_MAX) continue;
                if (px >= FOG_PANEL_W) px = FOG_PANEL_W - 1u;
                if (py >= FOG_PANEL_H) py = FOG_PANEL_H - 1u;
                mask |= 1u << id;
                x[id] = (int)px; y[id] = (int)py;
        }
        unsigned n = (unsigned)__builtin_popcount(mask);
        if (n > st.s_maxn) st.s_maxn = n;
        touch_report(mask, x, y);
        return 0;
}
'''

needle = "#define NVT_PAGE_COUNT"
idx = t.find(needle)
assert idx != -1
eol = t.find("\n", idx)
t = t[:eol+1] + fts + t[eol+1:]

old_fw = "touch_fog_fwinfo(void)\n{\n"
assert old_fw in t
t = t.replace(old_fw, old_fw + "\tif (touch_fog_fts_probe()) return true;\n", 1)

old_rep = "touch_fog_report(void)\n{\n"
assert old_rep in t
t = t.replace(old_rep, old_rep + "\tif (fog_is_fts) return touch_fog_fts_report();\n", 1)

p.write_text(t)
print("0102 .sh applied OK - FT8006S")
PY
