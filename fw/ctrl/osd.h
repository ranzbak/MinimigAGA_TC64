#ifndef OSD_H_INCLUDED
#define OSD_H_INCLUDED

// ---- new Minimig v2 constants -------
#define OSD_CMD_READ 0x00
#define OSD_CMD_RST 0x08
// OSD control {K: the keyboard and joystick 2 to the OSD, not the Amiga;
// bit 0 was the bitmap OSD's enable (gone, Phase 6): 0}
#define OSD_CMD_OSD 0x28
#define OSD_CMD_CHIP 0x04
#define OSD_CMD_CPU 0x14
#define OSD_CMD_MEM 0x24
#define OSD_CMD_VID 0x34
#define OSD_CMD_FLP 0x44
#define OSD_CMD_HDD 0x54
#define OSD_CMD_HDD1 0x58   // IDE port 2 (userio_osd.v SPI_HARDDISK1_CFG_ADR)
#define OSD_CMD_JOY 0x64
#define OSD_CMD_VERSION 0x88
// Drain the core's key-event queue.  Data byte 0 is {overflow,3'b000,count},
// every later byte pops one event, oldest first.  Only present when
// CORE_CAPS_KEYQ is set; see userio_osd.v.
#define OSD_CMD_KEYQ 0x98

#define DISABLE_KEYBOARD 0x02 // disable keyboard while OSD is active

#define REPEATDELAY 100 // repeat delay in audio ticks
#define REPEATRATE 25   // repeat rate in audio ticks
#define BUTTONDELAY 20  // repeat rate in audio ticks

#define KEY_UPSTROKE 0x80 // These codes are from the Amiga key map (not PC)
#define KEY_MENU 0x69
#define KEY_PGUP 0x6C
#define KEY_PGDN 0x6D
#define KEY_HOME 0x6A
#define KEY_ESC 0x45
#define KEY_KPENTER 0x43
#define KEY_ENTER 0x44
#define KEY_BACK 0x41
#define KEY_SPACE 0x40
#define KEY_UP 0x4C
#define KEY_DOWN 0x4D
#define KEY_LEFT 0x4F
#define KEY_RIGHT 0x4E
#define KEY_F1 0x50
#define KEY_F2 0x51
#define KEY_F3 0x52
#define KEY_F4 0x53
#define KEY_F5 0x54
#define KEY_F6 0x55
#define KEY_F7 0x56
#define KEY_F8 0x57
#define KEY_F9 0x58
#define KEY_F10 0x59
#define KEY_CTRL 0x63
#define KEY_LALT 0x64
#define KEY_LSHIFT 0x60
#define KEY_RSHIFT 0x61
#define KEY_KPPLUS 0x5E
#define KEY_KPMINUS 0x4A
#define KEY_KPDOT 0x3C
#define KEY_KPRETURN 0x0D
#define KEY_KP0 0x0F

#define CONFIG_TURBO 1
// config.cpu bit 4: Chip slots Fast (cpu_config[4] in userio_osd.v).  Old
// configs have it clear, which is Standard -- the behaviour they were saved with.
#define CONFIG_CPU_FASTCHIP 0x10
#define CONFIG_NTSC 2
#define CONFIG_A1000 4
#define CONFIG_ECS 8
#define CONFIG_AGA 16

#define CONFIG_FLOPPY1X 0
#define CONFIG_FLOPPY2X 1

#include <sys/types.h>

/*functions*/
// the keyboard (and joystick 2) back to the Amiga (OSD control, K = 0)
void OsdHide(void);
void OsdReset();
void ConfigVideo(unsigned char scanlines, unsigned char crt_mask, unsigned char crt_bloom, unsigned char crt_beam);
// config.videopos and config.videopos_rtg to the core (osd.c)
void ConfigVideoPos(void);
void ConfigAudio(unsigned char volume);
void ConfigMemory(unsigned char memory);
void ConfigCPU(unsigned char cpu);
void ConfigChipset(unsigned char chipset);
void ConfigFloppy(unsigned char drives, unsigned char speed);
void ConfigIDE(unsigned char port, unsigned char on, unsigned char master, unsigned char slave, unsigned char atapi);
void ConfigAutofire(unsigned char autofire);
unsigned char OsdGetCtrl(void);
// The key the core is holding right now, not an event: for "was F1 held at
// boot", where the answer is a state and not a change.
unsigned char OsdGetKeyLevel(void);
// Set when the core's key queue overflowed and events were lost.  ui_handle
// clears it and keeps the modifiers (ui.c says why).
extern unsigned char osd_keyq_lost;
unsigned char GetASCIIKey(unsigned char c);
void OsdDoReset(int enter, int leave);

#endif
