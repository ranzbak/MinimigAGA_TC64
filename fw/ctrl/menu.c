/*
Copyright 2005, 2006, 2007 Dennis van Weeren
Copyright 2008, 2009 Jakub Bednarski

This file is part of Minimig

Minimig is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

Minimig is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// The OSD's entry points for main.c: HandleUI() once per main-loop pass,
// ShowError() for an error, the debug messages and their page (Ctrl-Alt-F12)
// on the 720p text layer.  The menu itself is ui.c on the layer (osd2.h,
// findings/osd-redesign/plan.md).  The classic menu on the bitmap OSD
// (HandleUI_legacy and its MENU_* pages, the 8-line file selector) was
// deleted with the bitmap OSD in OSD redesign Phase 6; the last commit with
// it is osd-int bc677a44.

#include "stdio.h"
#include "string.h"
#include "errors.h"
#include "fpga.h"
#include "menu.h"
#include "osd2.h"
#include "ui.h"

extern char s[40];

// the file selector's file kind (ui.c): another one starts at the root
char *fs_pFileExt = NULL;

static char debuglines[8 * 32 + 1];
static char debugptr = 0;

// The debug page on the OSD text layer (osd2.h; OSD redesign Phase 2): the
// eight lines in a 64 x 20 window at scale 2, centred on the 720p raster
// (x0 16, y0 5 in 8-pixel units), the newest line highlighted, and one cell
// per palette entry (entry 7 is transparent).  Drawn into the shadow
// every pass; osd2_flush() sends only what changed.
#define DBG2_X0   16
#define DBG2_Y0   5
#define DBG2_COLS 64
#define DBG2_ROWS 20
#define DBG2_PANEL OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLACK)
static unsigned char debug2_open;

static void debug2_draw(void)
{
    int i;
    osd2_fill(0, 0, DBG2_COLS, ' ', DBG2_PANEL);
    osd2_put(0, 1, " Debug ", OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLUE));
    osd2_put(0, 44, "Ctrl-Alt-F12 closes", OSD2_ATTR(OSD2_C_DKBLUE, OSD2_C_BLACK));
    osd2_fill(1, 0, DBG2_COLS, OSD2_BOX_H, OSD2_ATTR(OSD2_C_DKBLUE, OSD2_C_BLACK));
    for (i = 0; i < 8; ++i)
    {
        int j = (debugptr + i) & 7;
        unsigned char a = (i == 7) ? OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLUE) : DBG2_PANEL;
        debuglines[j * 32 + 31] = 0;
        osd2_fill(2 + i, 0, DBG2_COLS, ' ', a);
        osd2_putn(2 + i, 2, 31, &debuglines[j * 32], a);
    }
    osd2_clear_rows(10, 17, ' ', DBG2_PANEL);
    osd2_put(11, 2, "OSD text layer: 720p, 64 x 20 cells, scale 2",
             OSD2_ATTR(OSD2_C_BLUE, OSD2_C_BLACK));
    osd2_put(13, 2, "Palette:", DBG2_PANEL);
    for (i = 0; i < 16; ++i)
    {
        osd2_fill(14, 2 + i * 3, 2, ' ', OSD2_ATTR(OSD2_C_WHITE, i));
        osd2_fill(15, 2 + i * 3, 2, (unsigned char)(i < 10 ? '0' + i : 'A' + i - 10), DBG2_PANEL);
    }
    osd2_fill(18, 0, DBG2_COLS, OSD2_BOX_H, OSD2_ATTR(OSD2_C_DKBLUE, OSD2_C_BLACK));
    osd2_fill(19, 0, DBG2_COLS, ' ', OSD2_ATTR(OSD2_C_WHITE, OSD2_C_DKBLUE));
    osd2_put(19, 1, "Minimig AGA OSD", OSD2_ATTR(OSD2_C_WHITE, OSD2_C_DKBLUE));
    osd2_flush();
}

// the debug page on the text layer, on (1) or off (0); also the new menu's
// (ui.c) when it closes, or a toast ends, in debug mode
void debug2_show(int on)
{
    if (on)
    {
        debug2_draw();
        osd2_pal_default();
        osd2_commit(1, 2, DBG2_X0, DBG2_Y0, DBG2_COLS, DBG2_ROWS);
    }
    else if (debug2_open)
        osd2_disable();
    debug2_open = (unsigned char)on;
}

void _showdebugmessages()
{
    if (osd2_caps)
        debug2_draw();
}

// The OSD menu, once per main-loop pass: the new one on the 720p text
// layer (ui.c).  A core without the layer (osd2_caps 0) has no menu: the
// boot ROM does not start this firmware there (the lock-step trailer's
// OSD2_REQUIRED), so only a firmware loaded another way (a debugger, a
// bench) gets here; fpga_init() says so on the UART, and the main loop
// goes on serving the disks without a menu.
void HandleUI(void)
{
    if (osd2_caps)
        ui_handle();
}

// The error page of the new menu, at the first category of ErrorMask
void ShowError(void)
{
    int t = ErrorMask >> 1;
    int page = 0;
    while (t)
    {
        t >>= 1;
        ++page;
    }
    if (osd2_caps)
        ui_error_show(page);
}

static int shiftcheck(int in)
{
    return (in >> 1);
}

static int mulcheck(int in)
{
    return (in * 0x88888888);
}

static int addcheck(int in)
{
    return (in + 0xa5a5a5a5);
}

void SanityCheck()
{
    snprintf(s, 32, "%X", shiftcheck(0xabcdef01));
    DebugMessage(s);
    snprintf(s, 32, "%X", shiftcheck(0x23456789));
    DebugMessage(s);
    snprintf(s, 32, "%X", mulcheck(0xabcdef01));
    DebugMessage(s);
    snprintf(s, 32, "%X", mulcheck(0x23456789));
    DebugMessage(s);
    snprintf(s, 32, "%X", addcheck(0xabcdef01));
    DebugMessage(s);
    snprintf(s, 32, "%X", addcheck(0x23456789));
    DebugMessage(s);
    snprintf(s, 32, "%X", checksum_pre);
    DebugMessage(s);
}

void DebugMessage(char *message)
{
    strncpy(&debuglines[debugptr * 32], message, 31);
    debuglines[debugptr * 32 + 31] = 0;
    debugptr = (debugptr + 1) & 7;
}
