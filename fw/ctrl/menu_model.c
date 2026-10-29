/* menu_model: what the OSD menus do, without drawing (menu_model.h).  The
 * floppy insert, GetDiskInfo and the CD-ROM messages moved here from menu.c
 * unchanged; the file selector's keys and the config file / Kickstart
 * sequences are the classic menu's, as functions both menus call. */
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "errors.h"
#include "fat.h"
#include "fdd.h"
#include "osd.h"
#include "fpga.h"
#include "config.h"
#include "cdrom.h"
#include "drivesounds.h"
#include "adv7511.h"
#include "menu.h"
#include "menu_model.h"
#include "hdd.h"

extern fileTYPE file;
extern DIRENTRY DirEntry[MAXDIRENTRIES];
extern unsigned char sort_table[MAXDIRENTRIES];
extern unsigned char nDirEntries;
extern unsigned char iSelectedEntry;
extern unsigned long iCurrentDirectory;
extern char DirEntryLFN[MAXDIRENTRIES][261];

char DiskInfo[5];                    // disk number info of selected entry

/******************************************************************/
/* CD-ROM messages (were menu.c's)                                */
/******************************************************************/

// A message in place of a CD line, for 4 s: "locked by the Amiga" (D5),
// or why an insert was refused (13.1: the cause, at most 23 characters).
static unsigned long cd_msg_timer;
char cd_msg_on;
const char *cd_msg_text;

void cd_show_msg(const char *text)
{
    cd_msg_text = text;
    cd_msg_on = 1;
    cd_msg_timer = GetTimer(CD_MSG_DELAY);
}

void cd_locked_msg(void)
{
    cd_show_msg("locked by the Amiga");
}

// The OSD's answer to CD_Insert: nothing when the disc went in.
void cd_insert_msg(int r)
{
    if (r == CD_LOCKED)
        cd_locked_msg();
    else if (r == CD_BADCUE)
        cd_show_msg(CD_Message());
    else if (r == CD_NOFILE)
        cd_show_msg("file not found");
}

// The message is over: redraw.
int cd_msg_expired(void)
{
    if (cd_msg_on && CheckTimer(cd_msg_timer))
    {
        cd_msg_on = 0;
        return 1;
    }
    return 0;
}

/******************************************************************/
/* the file selector's keys (were inline in menu.c MENU_FILE_SELECT2) */
/******************************************************************/

static unsigned long entry_cluster(const DIRENTRY *e)
{
    return e->StartCluster + (fat32 ? (e->HighCluster & 0x0FFF) << 16 : 0);
}

// Enter on the selected entry: open a directory, or take the file into
// `file` (name, long name without its extension, size, first cluster) and
// its disk number into DiskInfo.
int mm_fs_enter(char *ext, unsigned char opts)
{
    DIRENTRY *e = &DirEntry[sort_table[iSelectedEntry]];
    char *lfn = DirEntryLFN[sort_table[iSelectedEntry]];
    unsigned long len;

    if (e->Attributes & ATTR_DIRECTORY)
    {
        ChangeDirectory(entry_cluster(e));
        if (strncmp((char *)e->Name, "..", 2) == 0)
        { // parent dir selected
            if (ScanDirectory(SCAN_INIT_FIRST, ext, opts))
                ScanDirectory(SCAN_INIT_NEXT, ext, opts);
            else
                ScanDirectory(SCAN_INIT, ext, opts);
        }
        else
            ScanDirectory(SCAN_INIT, ext, opts);
        return MM_FS_DIR;
    }
    if (!nDirEntries)
        return MM_FS_EMPTY;

    len = strlen(lfn);
    if (len > 4)
        if (lfn[len - 4] == '.')
            len -= 4; // remove extension
    // the disk number, as the classic menu's directory page found it
    // (PrintDirectory: long names of files only)
    memset(DiskInfo, 0, sizeof(DiskInfo));
    if (lfn[0])
    {
        char *info = GetDiskInfo(lfn, len);
        if (info)
            memcpy(DiskInfo, info, sizeof(DiskInfo));
    }

    if (len > sizeof(file.long_name))
        len = sizeof(file.long_name);
    strncpy(file.name, (const char *)e->Name, sizeof(file.name));
    memset(file.long_name, 0, sizeof(file.long_name));
    strncpy(file.long_name, lfn, len);

    file.size = e->FileSize;
    file.attributes = e->Attributes;
    file.start_cluster = entry_cluster(e);
    file.cluster = file.start_cluster;
    file.sector = 0;
    return MM_FS_FILE;
}

// Backspace: after a fresh scan the first entry of a subdirectory is "..",
// the parent: open it and find the directory we came from.
int mm_fs_parent(char *ext, unsigned char opts)
{
    if (!iCurrentDirectory) // the root
        return 0;
    ScanDirectory(SCAN_INIT, ext, opts);
    ChangeDirectory(entry_cluster(&DirEntry[sort_table[iSelectedEntry]]));
    if (ScanDirectory(SCAN_INIT_FIRST, ext, opts))
        ScanDirectory(SCAN_INIT_NEXT, ext, opts);
    return 1;
}

// A letter: the next entry starting with it, files and directories in the
// order the listing has them.
void mm_fs_find(unsigned char i, char *ext, unsigned char opts)
{
    unsigned char first;
    if (!nDirEntries)
        return;
    first = DirEntry[sort_table[iSelectedEntry]].Name[0];
    if (DirEntry[sort_table[iSelectedEntry]].Attributes & ATTR_DIRECTORY)
    { // it's a directory
        if (i < first)
        {
            if (!ScanDirectory(i, ext, opts | FIND_FILE))
                ScanDirectory(i, ext, opts | FIND_DIR);
        }
        else if (i > first)
        {
            if (!ScanDirectory(i, ext, opts | FIND_DIR))
                ScanDirectory(i, ext, opts | FIND_FILE);
        }
        else
        {
            if (!ScanDirectory(i, ext, opts)) // find next
                if (!ScanDirectory(i, ext, opts | FIND_FILE))
                    ScanDirectory(i, ext, opts | FIND_DIR);
        }
    }
    else
    { // it's a file
        if (i < first)
        {
            if (!ScanDirectory(i, ext, opts | FIND_DIR))
                ScanDirectory(i, ext, opts | FIND_FILE);
        }
        else if (i > first)
        {
            if (!ScanDirectory(i, ext, opts | FIND_FILE))
                ScanDirectory(i, ext, opts | FIND_DIR);
        }
        else
        {
            if (!ScanDirectory(i, ext, opts)) // find next
                if (!ScanDirectory(i, ext, opts | FIND_DIR))
                    ScanDirectory(i, ext, opts | FIND_FILE);
        }
    }
}

/******************************************************************/
/* configuration files and the Kickstart                          */
/******************************************************************/

unsigned char mm_config_scan(void)
{
    unsigned char m = 0;
    int i;
    for (i = 0; i < MM_CONFIG_SLOTS; i++)
    {
        SetConfigurationFilename(i);
        if (ConfigurationExists(0))
            m |= 1 << i;
    }
    return m;
}

// the classic menu's MENU_LOADCONFIG_2
void mm_load_config(int slot)
{
    SetConfigurationFilename(slot);
    LoadConfiguration(NULL);
    ApplyConfiguration(1, 1);
    OsdDoReset(SPI_RST_USR | SPI_RST_CPU, 0);
}

void mm_save_config(int slot)
{
    SetConfigurationFilename(slot);
    SaveConfiguration(NULL);
}

// the classic menu's MENU_ROMFILE_SELECTED2
void mm_reload_kickstart(void)
{
    memcpy((void *)config.kickstart.name, (void *)file.name, sizeof(config.kickstart.name));
    memcpy((void *)config.kickstart.long_name, (void *)file.long_name, sizeof(config.kickstart.long_name));
    config.kickdir = CurrentDirectory();
    OsdDoReset(0, SPI_RST_CPU | SPI_CPU_HLT);
    ApplyConfiguration(1, 0);
    OsdDoReset(SPI_RST_USR | SPI_RST_CPU, 0);
}

/******************************************************************/
/* config fields                                                  */
/******************************************************************/

#define F_CHIPSET 1
#define F_MEMORY  2
#define F_CPU     3
#define F_JOY     4
#define F_FLOPPY  5
#define F_VIDEO   6
#define F_NONE    7

static const struct { unsigned char off, shift, bits, apply; } fields[MMF_FIELDS] = {
    [MMF_NTSC]        = { offsetof(configTYPE, chipset),     1, 1, F_CHIPSET },
    [MMF_CHIP]        = { offsetof(configTYPE, memory),      0, 2, F_MEMORY },
    [MMF_SLOW]        = { offsetof(configTYPE, memory),      2, 2, F_MEMORY },
    [MMF_FAST]        = { offsetof(configTYPE, memory),      4, 2, F_MEMORY },
    [MMF_HRTMON]      = { offsetof(configTYPE, memory),      6, 1, F_MEMORY },
    [MMF_BOARDS]      = { offsetof(configTYPE, memory),      7, 1, F_MEMORY },
    [MMF_CD32PAD]     = { offsetof(configTYPE, autofire),    2, 1, F_JOY },
    [MMF_AUTOFIRE]    = { offsetof(configTYPE, autofire),    0, 2, F_JOY },
    [MMF_TURBO]       = { offsetof(configTYPE, cpu),         2, 2, F_CPU },
    [MMF_CHIPSLOTS]   = { offsetof(configTYPE, cpu),         4, 1, F_CPU },
    [MMF_SCANLINES]   = { offsetof(configTYPE, scanlines),   0, 2, F_VIDEO },
    [MMF_MASK]        = { offsetof(configTYPE, crt_mask),    0, 2, F_VIDEO },
    [MMF_BEAM]        = { offsetof(configTYPE, crt_beam),    0, 2, F_VIDEO },
    [MMF_FLOPPYTURBO] = { offsetof(configTYPE, floppy.speed), 0, 1, F_FLOPPY },
    [MMF_IDE]         = { offsetof(configTYPE, enable_ide),  0, 1, F_NONE },
    [MMF_DRIVES]      = { offsetof(configTYPE, floppy.drives), 0, 2, F_FLOPPY },
    // the OSD menu's size and position (config.h CONFIG_OSD_*): ui_tabs.c
    // applies them (the window), nothing goes to the core
    [MMF_OSDSIZE]     = { offsetof(configTYPE, autofire),    3, 1, F_NONE },
    [MMF_OSDPOS]      = { offsetof(configTYPE, autofire),    4, 2, F_NONE },
};

unsigned char mm_get_field(unsigned char f)
{
    const unsigned char *b = (const unsigned char *)&config;
    return (b[fields[f].off] >> fields[f].shift) & ((1 << fields[f].bits) - 1);
}

void mm_set_field(unsigned char f, unsigned char v)
{
    unsigned char *b = (unsigned char *)&config + fields[f].off;
    unsigned char m = ((1 << fields[f].bits) - 1) << fields[f].shift;
    *b = (*b & ~m) | ((v << fields[f].shift) & m);
    switch (fields[f].apply)
    {
    case F_CHIPSET: ConfigChipset(config.chipset); break;
    case F_MEMORY:  ConfigMemory(config.memory); break;
    case F_CPU:     ConfigCPU(config.cpu); break;
    case F_JOY:     ConfigAutofire(config.autofire); break;
    case F_FLOPPY:  ConfigFloppy(config.floppy.drives, config.floppy.speed); break;
    case F_VIDEO:   ConfigVideo(config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam); break;
    }
}

// config.chipset bits 4:2: 0 OCS-A500, A1000, ECS, AGA | ECS (the classic
// menu's cycle); bits 1:0 (turbo, NTSC) kept
static const unsigned char chipset_bits[4] = { 0, CONFIG_A1000, CONFIG_ECS, CONFIG_AGA | CONFIG_ECS };

unsigned char mm_get_chipset(unsigned char arg)
{
    unsigned char i;
    (void)arg;
    for (i = 0; i < 4; i++)
        if ((config.chipset & 0x1c) == chipset_bits[i])
            return i;
    return 0;
}

void mm_set_chipset(unsigned char arg, unsigned char v)
{
    (void)arg;
    config.chipset = (config.chipset & 3) | chipset_bits[v & 3];
    ConfigChipset(config.chipset);
}

unsigned char mm_get_volume(unsigned char arg)
{
    (void)arg;
    if (config.audio.volume > 31) // as the classic Audio page
        config.audio.volume = 15;
    return config.audio.volume;
}

void mm_set_volume(unsigned char arg, unsigned char v)
{
    (void)arg;
    config.audio.volume = v > 31 ? 31 : v;
    ConfigAudio(config.audio.volume);
}

// config.cpu bits 1:0: 0 68000, 1 68010, 3 68020 (2 is not used)
unsigned char mm_get_cpu(unsigned char arg)
{
    unsigned char c = config.cpu & 3;
    (void)arg;
    return c == 3 ? 2 : c > 1 ? 0 : c;
}

unsigned char mm_get_scaling(unsigned char arg)
{
    (void)arg;
    return CONFIG_SCALING(config.scanlines);
}

unsigned char mm_get_bloom(unsigned char arg)
{
    (void)arg;
    return config.crt_bloom > 2 ? 0 : config.crt_bloom;
}

unsigned char mm_get_sound(unsigned char arg)
{
    return (config.drivesounds & arg) ? 1 : 0;
}

void mm_set_sound(unsigned char arg, unsigned char v)
{
    if (v)
    {
        config.drivesounds |= arg;
        drivesounds_enable(arg);
    }
    else
    {
        config.drivesounds &= ~arg;
        drivesounds_disable(arg);
    }
}

void mm_set_cpu(unsigned char arg, unsigned char v)
{
    static const unsigned char cpus[3] = { 0, 1, 3 };
    (void)arg;
    config.cpu = (config.cpu & ~3) | cpus[v > 2 ? 2 : v];
    ConfigCPU(config.cpu);
}

static void video(void)
{
    ConfigVideo(config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam);
}

void mm_set_scaling(unsigned char arg, unsigned char v)
{
    (void)arg;
    config.scanlines = (config.scanlines & ~SCALING_MASK) | ((v & 3) << SCALING_SHIFT);
    video();
}

void mm_set_bloom(unsigned char arg, unsigned char v)
{
    (void)arg;
    config.crt_bloom = v > 2 ? 2 : v;
    video();
}

unsigned char mm_bloom_avail(unsigned char arg)
{
    (void)arg;
    return (config.scanlines & 3) || (config.crt_beam & 3) || CONFIG_SCALING(config.scanlines) != SCALING_LINE;
}

unsigned char mm_get_ide(unsigned char arg)
{
    (void)arg;
    return mm_ide_on ? 1 : 0;
}

void mm_set_ide(unsigned char arg, unsigned char v)
{
    (void)arg;
    mm_ide_on = v ? 1 : 0;
}

void mm_step_pos(unsigned char vertical, int dir, unsigned char rtg)
{
    videoPosTYPE *p = rtg ? &config.videopos_rtg : &config.videopos;
    if (!vertical)
    {
        if (dir > 0 && (signed char)p->hpos < 0x78)
            p->hpos = p->hpos + 0x08;
        else if (dir < 0 && (signed char)p->hpos > -0x80)
            p->hpos = p->hpos - 0x08;
    }
    else
    {
        if (dir > 0 && (signed char)p->vpos < VPOS_MAX)
            p->vpos = p->vpos + VPOS_STEP;
        else if (dir < 0 && (signed char)p->vpos > -VPOS_MAX)
            p->vpos = p->vpos - VPOS_STEP;
    }
    ConfigVideoPos();
}

void mm_step_clkdelay(int dir)
{
    if (dir > 0 && adv_clkdelay < 7)
        adv7511_set_clkdelay(adv_clkdelay + 1);
    else if (dir < 0 && adv_clkdelay > 0)
        adv7511_set_clkdelay(adv_clkdelay - 1);
    config.hdmi_clkdelay = adv_clkdelay + 1;  // saved with the config
}

/******************************************************************/
/* value texts                                                    */
/******************************************************************/

static char buf[64];          // the longest: mm_text_hdmi_readback, 50

char *mm_utoa(char *p, unsigned v)
{
    char t[10];
    int n = 0;
    do
        t[n++] = (char)('0' + v % 10);
    while ((v /= 10) && n < 10);
    while (n)
        *p++ = t[--n];
    return p;
}

static char *bar(char *p, unsigned n)
{
    while (n--)
        *p++ = '#';
    return p;
}

const char *mm_text_volume_msg(void)
{
    char *p = buf;
    unsigned v = mm_get_volume(0);
    memcpy(p, "vol ", 4);
    p = mm_utoa(p + 4, v);
    *p++ = ' ';
    p = bar(p, (v + 1) >> 1);           // the classic VolumeBar: 16 cells
    *p = 0;
    return buf;
}

// a name of a config struct (8 + 16 characters, not terminated when full)
static const char *config_name(const char *name, const char *long_name, unsigned long_size)
{
    if (long_name[0])
    {
        memcpy(buf, long_name, long_size);
        buf[long_size] = 0;
    }
    else
    {
        memcpy(buf, name, 8);
        buf[8] = 0;
    }
    return buf;
}

const char *mm_text_kickstart(unsigned char arg)
{
    (void)arg;
    return config_name(config.kickstart.name, config.kickstart.long_name, sizeof(config.kickstart.long_name));
}

const char *mm_text_drives(unsigned char arg)
{
    (void)arg;
    buf[0] = (char)('1' + (config.floppy.drives & 3));
    buf[1] = 0;
    return buf;
}

const char *mm_text_hdf_type(unsigned char slot)
{
    static const char *const names[] = {
        "Disabled", "Hardfile (disk img)", "SD card", "SD partition 1", "SD partition 2",
        "SD partition 3", "SD partition 4", "CD-ROM (ISO)"
    };
    unsigned char e = mm_hdf[slot & 3].enabled;
    if (e == (HDF_FILE | HDF_SYNTHRDB))
        return "Hardfile (filesys)";
    if ((e & HDF_TYPEMASK) > HDF_CDROM)
        return "---";
    return names[e & HDF_TYPEMASK];
}

// as the classic Harddisks page's second line of a slot
const char *mm_text_hdf_file(unsigned char slot)
{
    hardfileTYPE *h = &mm_hdf[slot & 3];
    if ((h->enabled & HDF_TYPEMASK) != HDF_FILE && h->enabled != HDF_CDROM)
        return "";
    if (h->enabled == HDF_CDROM && cd_msg_on && mm_hdf_cd_live(slot & 3))
        return cd_msg_text;
    if (h->enabled == HDF_CDROM && !h->name[0])
        return "* no disc *";
    if (!h->present)
        return "** file not found **";
    return config_name(h->name, h->long_name, sizeof(h->long_name));
}

static const char *signed_text(int v)
{
    char *p = buf;
    if (v < 0)
    {
        *p++ = '-';
        v = -v;
    }
    else if (v > 0)
        *p++ = '+';
    p = mm_utoa(p, (unsigned)v);
    *p = 0;
    return buf;
}

const char *mm_text_pos(unsigned char vertical, unsigned char rtg)
{
    const videoPosTYPE *p = rtg ? &config.videopos_rtg : &config.videopos;
    signed_text((signed char)(vertical ? p->vpos : p->hpos));
    strcat(buf, vertical ? " lines" : " px");
    return buf;
}

static char *hex2(char *p, unsigned char v)
{
    static const char hex[] = "0123456789abcdef";
    *p++ = hex[v >> 4];
    *p++ = hex[v & 15];
    return p;
}

const char *mm_text_hdmi_readback(void)
{
    extern unsigned long adv_services;   // main.c
    extern unsigned char adv_int_now;
    char *p = buf;
    memcpy(p, "Chip 0xBA: ", 11);
    p = hex2(p + 11, adv7511_read_clkdelay());
    memcpy(p, "  set: ", 7);
    p = hex2(p + 7, (unsigned char)(adv_clkdelay << 5));
    memcpy(p, "  INT ", 6);
    p = mm_utoa(p + 6, adv_int_now);
    memcpy(p, "  serviced ", 11);
    p = mm_utoa(p + 11, (unsigned)adv_services);
    *p = 0;
    return buf;
}

const char *mm_text_clkdelay(unsigned char arg)
{
    static const char *const ns[] = { "-1.2 ns", "-0.8 ns", "-0.4 ns", " 0.0 ns",
                                      "+0.4 ns", "+0.8 ns", "+1.2 ns", "+1.6 ns" };
    (void)arg;
    return ns[adv_clkdelay & 7];
}

const char *mm_text_cpu(unsigned char arg)
{
    static const char *const cpus[] = { "68000", "68010", "68020" };
    if (CORE_CPU_FIXED_040())
    {
        strcpy(buf, "68040");
        if (core_caps & CORE_CAPS_FPU) strcat(buf, "/FPU");
        if (core_caps & CORE_CAPS_MMU) strcat(buf, "/MMU");
        return buf;
    }
    return cpus[mm_get_cpu(arg)];
}

/******************************************************************/
/* the floppy insert (was menu.c's)                               */
/******************************************************************/

char *GetDiskInfo(char *lfn, long len)
{
    // extracts disk number substring form file name
    // if file name contains "X of Y" substring where X and Y are one or two digit number
    // then the number substrings are extracted and put into the temporary buffer for further processing
    // comparision is case sensitive

    short i, k;
    static char info[] = "XX/XX";     // temporary buffer
    static char template[4] __attribute__((nonstring)) = " of "; // template substring to search for
    char *ptr1, *ptr2, c;
    unsigned char cmp;

    if (len > 20) // scan only names which can't be fully displayed
    {
        for (i = (unsigned short)len - 1 - sizeof(template); i > 0; i--) // scan through the file name starting from its end
        {
            ptr1 = &lfn[i]; // current start position
            ptr2 = template;
            cmp = 0;
            for (k = 0; (unsigned int)k < sizeof(template); k++) // scan through template
            {
                cmp |= *ptr1++ ^ *ptr2++; // compare substrings' characters one by one
                if (cmp)
                    break; // stop further comparing if difference already found
            }

            if (!cmp) // match found
            {
                k = i - 1; // no need to check if k is valid since i is greater than zero

                c = lfn[k];               // get the first character to the left of the matched template substring
                if (c >= '0' && c <= '9') // check if a digit
                {
                    info[1] = c;   // copy to buffer
                    info[0] = ' '; // clear previous character
                    k--;           // go to the preceding character
                    if (k >= 0)    // check if index is valid
                    {
                        c = lfn[k];
                        if (c >= '0' && c <= '9') // check if a digit
                            info[0] = c;          // copy to buffer
                    }

                    k = i + sizeof(template); // get first character to the right of the mached template substring
                    c = lfn[k];               // no need to check if index is valid
                    if (c >= '0' && c <= '9') // check if a digit
                    {
                        info[3] = c;   // copy to buffer
                        info[4] = ' '; // clear next char
                        k++;           // go to the followwing character
                        if (k < len)   // check if index is valid
                        {
                            c = lfn[k];
                            if (c >= '0' && c <= '9') // check if a digit
                                info[4] = c;          // copy to buffer
                        }
                        return info;
                    }
                }
            }
        }
    }
    return NULL;
}

void _strncpy(char *pStr1, const char *pStr2, size_t nCount)
{
    // customized strncpy() function to fill remaing destination string part with spaces

    while (*pStr2 && nCount)
    {
        *pStr1++ = *pStr2++; // copy strings
        nCount--;
    }

    while (nCount--)
        *pStr1++ = ' '; // fill remaining space with spaces
}

// insert floppy image pointed to to by global <file> into <drive>
void InsertFloppy(adfTYPE *drive)
{
    unsigned char i, j;
    unsigned long tracks;

    // calculate number of tracks in the ADF image file
    tracks = file.size / (512 * 11);
    if (tracks > MAX_TRACKS)
    {
        SetError(ERROR_FDD, "ADF has too many tracks!", tracks, 0);
        printf("UNSUPPORTED ADF SIZE!!! Too many tracks: %lu\r", tracks);
        tracks = MAX_TRACKS;
    }
    drive->tracks = (unsigned char)tracks;

    // fill index cache
    for (i = 0; i < tracks; i++) // for every track get its start position within image file
    {
        drive->cache[i] = file.cluster; // start of the track within image file
        for (j = 0; j < 11; j++)
            if (!FileNextSector(&file)) // advance by track length (11 sectors)
            {   // a FAT read failed: the index would be wrong (Task 10 fix round 1)
                SetError(ERROR_FDD, "ADF index read error", i, j);
                drive->status = 0;
                return;
            }
    }

    // copy image file name into drive struct
    if (file.long_name[0])                                          // file has long name
        _strncpy(drive->name, file.long_name, sizeof(drive->name)); // copy long name
    else
    {
        strncpy(drive->name, file.name, 8);                    // copy base name
        memset(&drive->name[8], ' ', sizeof(drive->name) - 8); // fill the rest of the name with spaces
    }

    if (DiskInfo[0]) // if selected file has valid disk number info then copy it to its name in drive struct
    {
        drive->name[16] = ' ';                                 // precede disk number info with space character
        strncpy(&drive->name[17], DiskInfo, sizeof(DiskInfo)); // copy disk number info
    }

    // initialize the rest of drive struct
    drive->status = DSK_INSERTED;
    if (!(file.attributes & ATTR_READONLY)) // read-only attribute
        drive->status |= DSK_WRITABLE;

    drive->cluster_offset = drive->cache[0];
    drive->sector_offset = 0;
    drive->track = 0;
    drive->track_prev = -1;

    // some debug info
    if (file.long_name[0])
        printf("Inserting floppy: \"%s\"\r", file.long_name);
    else
        printf("Inserting floppy: \"%.11s\"\r", file.name);

    printf("file attributes: 0x%02X\r", file.attributes);
    printf("file size: %lu (%lu KB)\r", file.size, file.size >> 10);
    printf("drive tracks: %u\r", drive->tracks);
    printf("drive status: 0x%02X\r", drive->status);
    drivesounds_queueevent(DRIVESOUND_INSERT);
}

/******************************************************************/
/* the IDE slots as edited (were menu.c's, MENU_SETTINGS_HARDFILE*) */
/******************************************************************/

hardfileTYPE mm_hdf[HDD_SLOTS];
unsigned long mm_hdfdir[HDD_SLOTS];
char mm_ide_on;

void mm_hdf_begin(void)
{
    int i;
    for (i = 0; i < HDD_SLOTS; i++)
    {
        mm_hdf[i] = *SlotConfig(i);
        mm_hdfdir[i] = config.hdfdir[i];
    }
    mm_ide_on = config.enable_ide;
}

unsigned char mm_hdf_type_after(int slot, unsigned char e)
{
    int i, cd_elsewhere = 0;
    for (i = 0; i < HDD_SLOTS; i++)
        if (i != slot && mm_hdf[i].enabled == HDF_CDROM)
            cd_elsewhere = 1;
    if (e == HDF_FILE)
        return HDF_FILE | HDF_SYNTHRDB;
    if (e == (HDF_FILE | HDF_SYNTHRDB))
        return HDF_CARD;
    if (e == HDF_CDROM)
        return HDF_DISABLED;
    e += 1;
    if (e >= HDF_CARDPART0 + partitioncount)
        e = (!cd_elsewhere && (core_caps & CORE_CAPS_IDE2)) ? HDF_CDROM : HDF_DISABLED;
    return e;
}

void mm_hdf_set_type(int slot, unsigned char e)
{
    hardfileTYPE *t = &mm_hdf[slot];
    if (e == HDF_CDROM)
    {   // a CD slot starts empty: an HDF name is not a disc
        memset(t->name, 0, sizeof(t->name));
        memset(t->long_name, 0, sizeof(t->long_name));
        t->present = 0;
    }
    t->enabled = e;
}

void mm_hdf_next_type(int slot)
{
    mm_hdf_set_type(slot, mm_hdf_type_after(slot, mm_hdf[slot].enabled));
}

int mm_hdf_cd_live(int slot)
{
    return slot == CD_SLOT() && SlotConfig(slot)->enabled == HDF_CDROM && mm_hdf[slot].enabled == HDF_CDROM;
}

int mm_hdf_needs_reset(void)
{
    int slot;
    if (mm_ide_on != config.enable_ide)
        return 1;
    for (slot = 0; slot < HDD_SLOTS; slot++)
    {
        hardfileTYPE *c = SlotConfig(slot);
        if (mm_hdf[slot].enabled != c->enabled)
            return 1;
        if (c->enabled != HDF_CDROM && memcmp(c, &mm_hdf[slot], sizeof(*c)) != 0)
            return 1;
    }
    return 0;
}

int mm_hdf_selected(int slot)
{
    hardfileTYPE *t = &mm_hdf[slot];
    if (t->enabled == HDF_CDROM)
    {
        if (mm_hdf_cd_live(slot))
        {   // a disc change in the live drive: now, no reset (refused while locked, D5)
            cd_insert_msg(CD_Insert(file.name, file.long_name[0] ? file.long_name : 0, CurrentDirectory()));
            *t = *SlotConfig(slot);
            mm_hdfdir[slot] = config.hdfdir[slot];
        }
        else
        {   // the disc for a CD slot that is not live yet
            memcpy((void *)t->name, (void *)file.name, sizeof(t->name));
            memcpy((void *)t->long_name, (void *)file.long_name, sizeof(t->long_name));
            t->present = CD_PRESENT(file.name); // ISO or CUE: the config's name has no extension
            mm_hdfdir[slot] = CurrentDirectory();
        }
        return MM_HDF_OK;
    }
    // Read RDB from selected drive and determine type...
    memcpy((void *)t->name, (void *)file.name, sizeof(t->name));
    memcpy((void *)t->long_name, (void *)file.long_name, sizeof(t->long_name));
    mm_hdfdir[slot] = CurrentDirectory();
    switch (GetHDFFileType(file.name))
    {
    case HDF_FILETYPE_RDB:
        t->enabled = HDF_FILE;
        t->present = 1;
        break;
    case HDF_FILETYPE_DOS:
        t->enabled = HDF_FILE | HDF_SYNTHRDB;
        t->present = 1;
        break;
    case HDF_FILETYPE_UNKNOWN:
        t->present = 1;
        // warn if we can't detect the type
        return t->enabled == HDF_FILE ? MM_HDF_NORDB : MM_HDF_NOFS;
    case HDF_FILETYPE_NOTFOUND:
    default:
        t->present = 0;
        break;
    }
    return MM_HDF_OK;
}

void mm_hdf_keep(void)
{
    int i;
    for (i = 0; i < HDD_SLOTS; i++)
        if (mm_hdf[i].enabled == HDF_CDROM && !mm_hdf_cd_live(i))
        {
            *SlotConfig(i) = mm_hdf[i];
            config.hdfdir[i] = mm_hdfdir[i];
        }
}

void mm_hdf_apply(void)
{
    unsigned char upd[HDD_SLOTS];
    int i;
    for (i = 0; i < HDD_SLOTS; i++)
    {
        hardfileTYPE *c = SlotConfig(i);
        upd[i] = (config.enable_ide != mm_ide_on && mm_hdf[i].enabled)
              || c->enabled != mm_hdf[i].enabled
              || strncmp(c->name, mm_hdf[i].name, sizeof(c->name)) != 0;
        *c = mm_hdf[i];                  // apply new configuration
        config.hdfdir[i] = mm_hdfdir[i];
    }
    config.enable_ide = mm_ide_on;       // Apply new IDE on/off

    // FIXME - waiting for user-confirmation increases the window of opportunity for file corruption!

    for (i = 0; i < HDD_SLOTS; i++)
        if (upd[i] && (i < 2 || (core_caps & CORE_CAPS_IDE2)))
            OpenHardfile(i);
    ApplyCDROM();       // the CD drive's slot and disc
    ConfigIDEPorts();
    OsdReset();
}
