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
#include "config.h"
#include "hdd.h"

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

/* ---- the IDE slots as edited (the classic Harddisks pages, the new
   Storage tab; were menu.c's t_hardfile, t_hdfdir, t_enable_ide) ----
   The four slots (slot = port << 1 | slave) and the IDE on/off as changed,
   applied when leaving: a change of type or hardfile needs a reset (the
   Amiga probes the bus again), a new disc in a CD slot does not (a media
   change, applied at once in the live drive). */
extern hardfileTYPE mm_hdf[HDD_SLOTS];
extern unsigned long mm_hdfdir[HDD_SLOTS];
extern char mm_ide_on;
/* the copy from config (entering the pages / the tab) */
void mm_hdf_begin(void);
/* the type cycle: Disabled, Hardfile (disk img), Hardfile (filesys), SD
   card, its partitions, CD-ROM (ISO), Disabled.  CD-ROM only on a core with
   two IDE ports, and not while another slot is the CD drive (one drive, D3).
   mm_hdf_type_after: the type after e (nothing changed); mm_hdf_set_type: a
   CD slot starts empty (an HDF name is not a disc); mm_hdf_next_type: both */
unsigned char mm_hdf_type_after(int slot, unsigned char e);
void mm_hdf_set_type(int slot, unsigned char e);
void mm_hdf_next_type(int slot);
/* the CD slot is the live drive: same slot, same type as in use */
int mm_hdf_cd_live(int slot);
/* does leaving need a reset? */
int mm_hdf_needs_reset(void);
/* the file in `file` (just chosen) for slot: a disc (a live CD drive takes
   it now, refused while locked), or a hardfile, its type from its first
   blocks.  MM_HDF_OK, or the warning to show: no partition table (a
   Hardfile (disk img) slot), no filesystem (a Hardfile (filesys) slot) */
#define MM_HDF_OK    0
#define MM_HDF_NORDB 1
#define MM_HDF_NOFS  2
int mm_hdf_selected(int slot);
/* leaving without a reset: the discs of CD slots that are not live yet */
void mm_hdf_keep(void);
/* leaving with the reset (its dialog's Yes): the slots and IDE on/off into
   config, the changed hardfiles opened, the CD drive, the ports, OsdReset */
void mm_hdf_apply(void);

/* ---- config fields: value index get / set (the set applies it) ----
   The `arg` of the new menu's items (ui_tabs.c). */
enum {
	MMF_NTSC, MMF_CHIP, MMF_SLOW, MMF_FAST, MMF_HRTMON, MMF_BOARDS,
	MMF_CD32PAD, MMF_AUTOFIRE, MMF_TURBO, MMF_CHIPSLOTS, MMF_SCANLINES,
	MMF_MASK, MMF_BEAM, MMF_FLOPPYTURBO, MMF_IDE, MMF_DRIVES,
	MMF_OSDSIZE, MMF_OSDPOS,
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
/* arg = DRIVESOUNDS_FLOPPY / DRIVESOUNDS_HDD: off, on (the set switches
   the drive's sounds on or off at once, as the classic pages) */
unsigned char mm_get_sound(unsigned char arg);
void mm_set_sound(unsigned char arg, unsigned char v);
/* the set: 68000, 68010, 68020 (config.cpu 0, 1, 3; Turbo and Chip slots kept) */
void mm_set_cpu(unsigned char arg, unsigned char v);
/* SCALING_*: 0 sharp, 1 area, 2 line rate (the classic cycle line rate ->
   sharp -> area is the index + 1) */
void mm_set_scaling(unsigned char arg, unsigned char v);
void mm_set_bloom(unsigned char arg, unsigned char v);
/* Bloom shows only where there is a gap between the lines to fill:
   Scanlines on, Beam width on, or Scaling sharp / area (crt_post.v f_en,
   crt_beamh.v); otherwise it does nothing and the item is greyed */
unsigned char mm_bloom_avail(unsigned char arg);
/* the IDE on/off being edited (mm_ide_on): off, on */
unsigned char mm_get_ide(unsigned char arg);
void mm_set_ide(unsigned char arg, unsigned char v);
/* Video Pos, one step (dir +1 / -1) of the PAL/NTSC picture's pair (rtg 0)
   or the RTG screen's (rtg 1): horizontal +-8 HD pixels within -128..120,
   vertical +-VPOS_STEP lines within +-VPOS_MAX (the classic Video Pos page),
   then both pairs to the core (ConfigVideoPos) */
void mm_step_pos(unsigned char vertical, int dir, unsigned char rtg);
/* the ADV7511's clock delay, one step within 0..7, saved with the config
   (the classic HDMI page) */
void mm_step_clkdelay(int dir);

/* value texts, in one shared static buffer (valid until the next call) */
const char *mm_text_kickstart(unsigned char arg);
const char *mm_text_drives(unsigned char arg);     /* "1".."4" */
/* the IDE slots as being edited (mm_hdf): the type, the file (the CD
   drive's message in a live CD slot; "* no disc *", "** file not found **") */
const char *mm_text_hdf_type(unsigned char slot);
const char *mm_text_hdf_file(unsigned char slot);
/* a Video Pos value, signed with its unit: "-8 px", "+4 lines" */
const char *mm_text_pos(unsigned char vertical, unsigned char rtg);
const char *mm_text_clkdelay(unsigned char arg);   /* "+0.4 ns" */
const char *mm_text_cpu(unsigned char arg);        /* with a fixed 68040: "68040/FPU/MMU" */
/* the HDMI page's readback: "Chip 0xBA: 80  set: 80  INT 0  serviced 12"
   (0xBA as the chip holds it, ff = no answer; as written) */
const char *mm_text_hdmi_readback(void);
/* the volume bar of the shortcut's message: "vol 23 ################" */
const char *mm_text_volume_msg(void);

/* decimal digits of v into p (no terminator); returns the end */
char *mm_utoa(char *p, unsigned v);

#endif
