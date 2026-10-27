/* dispatch_test: menu.c's HandleUI(), cut out of menu.c (handleui.inc; menu.c
 * holds the whole classic menu), on stubs: which menu runs a main-loop pass.
 *   - a core without the text layer (osd2_caps 0): the classic menu, every
 *     pass, whatever ui_legacy_active says, its file selector at 8 entries;
 *   - a core with it: the new menu (ui_handle), until it hands over to the
 *     classic one (ui_legacy_active); that one runs until it closes
 *     (menustate MENU_NONE2), then the new one again.
 *   make -C fw/ctrl/test run-dispatch_test
 */
#include <stdio.h>

#include "menu.h"

unsigned char osd2_caps, ui_legacy_active, fat_dir_window = 16;
unsigned char menustate = MENU_NONE1;
static int n_new, n_old;
static unsigned char next_state = MENU_NONE2, window_seen;

void ui_handle(void) { n_new++; }
static void HandleUI_legacy(void)
{
	n_old++;
	window_seen = fat_dir_window;
	menustate = next_state;
}

#include "handleui.inc"

static int fails, cases;
static void check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		printf("FAIL %s: got %ld, want %ld\n", what, got, want);
		fails++;
	} else
		printf("ok   %s = %ld\n", what, got);
}

int main(void)
{
	/* no text layer: the classic menu only */
	osd2_caps = 0;
	HandleUI();
	HandleUI();
	check("no layer: the classic menu each pass", n_old, 2);
	check("no layer: never the new one", n_new, 0);
	check("no layer: the file selector at 8 entries", window_seen, 8);
	ui_legacy_active = 1;
	next_state = MENU_MAIN2;
	HandleUI();
	check("no layer, classic open: the classic menu", n_old, 3);
	check("no layer: ui_legacy_active not cleared while open", ui_legacy_active, 1);
	ui_legacy_active = 0;

	/* the layer: the new menu */
	n_old = n_new = 0;
	osd2_caps = 1;
	HandleUI();
	HandleUI();
	check("layer: the new menu", n_new, 2);
	check("layer: not the classic one", n_old, 0);

	/* handed over: the classic menu until it closes */
	ui_legacy_active = 1;
	next_state = MENU_MAIN2;
	HandleUI();
	HandleUI();
	check("handed over: the classic menu", n_old, 2);
	check("handed over: still active while it is open", ui_legacy_active, 1);
	next_state = MENU_NONE2;
	HandleUI();
	check("the classic menu closed: ui_legacy_active cleared", ui_legacy_active, 0);
	HandleUI();
	check("then the new menu again", n_new, 3);

	printf("%s: %d cases, %d failed\n", fails ? "FAIL dispatch_test" : "dispatch_test passed", cases, fails);
	return fails ? 1 : 0;
}
