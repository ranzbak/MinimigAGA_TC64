#ifndef MENU_MODEL_H
#define MENU_MODEL_H

/*
 * menu_model: what the OSD menus DO, without drawing anything
 * (findings/osd-redesign/plan.md 5).  Both engines use it while the
 * classic menu (menu.c HandleUI_legacy) and the new one on the 720p text
 * layer (ui.c) live side by side: the floppy insert, the CD-ROM messages,
 * the file selector's Enter / Backspace / letter keys, configuration files,
 * the Kickstart reload, and the config fields the new menu's items show and
 * change (their Config* calls).
 */

#include "fat.h"
#include "fdd.h"

/* ---- floppies ---- */
/* the disk number ("XX/XX") of a long file name of more than 20 characters
   that holds "<n> of <m>", or NULL; a static buffer */
char *GetDiskInfo(char *lfn, long len);
/* the disk number of the file taken last (mm_fs_enter), for InsertFloppy */
extern char DiskInfo[5];
/* (InsertFloppy(adfTYPE *) is declared in menu.h) */

/* ---- CD-ROM messages: one in place of the CD line for CD_MSG_DELAY ---- */
#define CD_MSG_DELAY 4000
extern char cd_msg_on;
extern const char *cd_msg_text;
void cd_show_msg(const char *text);
void cd_locked_msg(void);
/* the answer to CD_Insert: nothing when the disc went in */
void cd_insert_msg(int r);
/* 1 once, when the message ran out (redraw) */
int cd_msg_expired(void);

/* ---- the file selector (the directory table of fat.c) ---- */
#define MM_FS_DIR   0   /* a directory was opened: the table is new */
#define MM_FS_FILE  1   /* the selected file is in `file` (and DiskInfo) */
#define MM_FS_EMPTY 2   /* the directory has no entries */
int mm_fs_enter(char *ext, unsigned char opts);
/* Backspace: the parent directory; 0 in the root (nothing done) */
int mm_fs_parent(char *ext, unsigned char opts);
/* a letter or digit: the next entry that starts with it */
void mm_fs_find(unsigned char ch, char *ext, unsigned char opts);

/* ---- configuration files (slot 0 = Default, 1-4) ---- */
#define MM_CONFIG_SLOTS 5
/* bit n set: slot n's file exists (reads the card) */
unsigned char mm_config_scan(void);
/* load and apply slot, then reset the Amiga (the OSD should be closed) */
void mm_load_config(int slot);
void mm_save_config(int slot);
/* the ROM in `file` (just chosen) becomes the Kickstart: halt, upload,
   reset (the OSD should be closed) */
void mm_reload_kickstart(void);

/* ---- config fields: value index get / set (the set applies it) ----
   The `arg` of the new menu's items (ui_tabs.c). */
enum {
	MMF_NTSC, MMF_CHIP, MMF_SLOW, MMF_FAST, MMF_HRTMON, MMF_BOARDS,
	MMF_CD32PAD, MMF_AUTOFIRE, MMF_TURBO, MMF_CHIPSLOTS, MMF_SCANLINES,
	MMF_MASK, MMF_BEAM, MMF_FLOPPYTURBO, MMF_IDE,
	MMF_FIELDS
};
unsigned char mm_get_field(unsigned char f);
void mm_set_field(unsigned char f, unsigned char v);
/* OCS-A500, OCS-A1000, ECS, AGA */
unsigned char mm_get_chipset(unsigned char arg);
void mm_set_chipset(unsigned char arg, unsigned char v);
/* 0..31 */
unsigned char mm_get_volume(unsigned char arg);
void mm_set_volume(unsigned char arg, unsigned char v);
/* 68000, 68010, 68020 */
unsigned char mm_get_cpu(unsigned char arg);
unsigned char mm_get_scaling(unsigned char arg);
unsigned char mm_get_bloom(unsigned char arg);
/* arg = DRIVESOUNDS_FLOPPY / DRIVESOUNDS_HDD: off, on */
unsigned char mm_get_sound(unsigned char arg);

/* value texts, in one shared static buffer (valid until the next call) */
const char *mm_text_volume(unsigned char arg);     /* "23 ##########" */
const char *mm_text_kickstart(unsigned char arg);
const char *mm_text_drives(unsigned char arg);     /* "1".."4" */
const char *mm_text_hdf_type(unsigned char slot);
const char *mm_text_hdf_file(unsigned char slot);
const char *mm_text_pos(unsigned char vertical);   /* signed: "-8" */
const char *mm_text_clkdelay(unsigned char arg);   /* "+0.4 ns" */
const char *mm_text_cpu(unsigned char arg);        /* with a fixed 68040: "68040/FPU/MMU" */
/* the volume bar of the shortcut's message: "vol 23 ################" */
const char *mm_text_volume_msg(void);

/* decimal digits of v into p (no terminator); returns the end */
char *mm_utoa(char *p, unsigned v);

#endif
