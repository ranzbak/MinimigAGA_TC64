#include "adv7511.h"
#include "hardware.h"
#include "i2c.h"

// Setup registers for the ADV7511, to output MDMI
unsigned char adv7511_init_main_vals[] = {
    // Power cycle
    0x41, 0x40, //  7 Power Down
    0x41, 0x10, //  7 Power Up
    0xD6, 0x10, //  Force HPD high (Power on), TMDS soft turn on
    // Setup mandatory registers
    0x98, 0x03, // ADI required Write
    0x99, 0x02, // ADI required Write
    0x9A, 0xE0, // ADI required Write
    0x9C, 0x30, // ADI required Write
    0x9D, 0x01, // ADI required Write
    0xA2, 0xA4, // ADI required Write
    0xA3, 0xA4, // ADI required Write
    0xE0, 0xD0, // ADI required Write
    0xF9, 0x00, // ADI required Write
    0xD0, 0x3E, // ADI required Write
    // Setup video input mode
    0x48, 0x20, // DDR alignment [35:24]
    0x15, 0x25, // Input 444 (RGB or YCrCb) with Separate Syncs DDR, 48kHz audio
    0x16, 0x38, // 8 bit, style 1, falling edge
    0x17, 0x02, // 12 bit, style 1, falling edge, 16:9
    0x18, 0x00, // CSC disabled
    0x55, 0x00, // 0 default
    0x56, 0x18, // 16:9, active same as aspect ratio
    // Set output mode
    0xAF, 0x04, // 04 for DVI, 06 for HDMI
    0x40, 0x80, // GC and SPD Package Enable
    0x4A, 0x80, // Auto Checksum Enable
    // Tell the display the resolution
    0x3C, 0x04, // VIC to 720p @ 60Hz
    0xD1, 0xFF, // Nbr of times to search for good phase
    0xDE, 0x9C, // ADI required write
    0xE4, 0x9C, // ADI required write
    0x94, 0xC0, // Enable HDP interrupt
    // Writing a 1 CLEARS an interrupt flag (Programming Guide 4.11); 0x00
    // cleared nothing and left the interrupt pin stuck active.  0xC0 clears
    // both HPD (bit 7) and Monitor Sense (bit 6).
    0x96, 0xC0, // Clear HPD + Monitor Sense interrupt flags
    0xFA, 0x00, // Nbr of times to search for good phase
    // Set the video clock delay
    0xBA, 0x00, // Clock delay -1.2 ns: the only glitch-free value with the IOB-packed, centre-aligned adv_ddr.v (OSD slider, 2026-09-25); the OSD HDMI page overrides it
    // Audio I2S
    0x01, 0x00, // N = 6144
    0x02, 0x18, // N and CTS for 48kHz @ 74.25 MHz pixel clock
    0x03, 0x00, // CTS is calculated
    0x0A, 0x00, //
    0x0C, 0x3C, // s0-s3 channel I2S
    0x14, 0x02, // 16bit samples
    0x44, 0x3A, // audio packet enable, AVI infroframe, audio info frame
    0x73, 0x01, //
    // Terminate transmission
    0x00, 0x00};

unsigned char adv7511_init_packet_vals[] = {
    // Set Source Product Description Infoframe (SPD)
    0x1f, 0x80, // Allow config of new packet, while sending previous data
    0x00, 0x83, // Packet type 3
    0x01, 0x01, // Version 1
    0x02, 0x19, // Length 0x19 (25)
    0x03, 0x40, //
    0x04, 0x41, //
    0x05, 0x42, //
    0x04, 0x43, //
    0x07, 0x44, //
    0x08, 0x45, //
    0x09, 0x00, //
    0x0a, 0x00, //
    0x0b, 0x30, // Product description start
    0x0c, 0x31, //
    0x0d, 0x32, //
    0x0e, 0x33, //
    0x0f, 0x34, //
    0x10, 0x00, //
    0x11, 0x00, //
    0x12, 0x00, //
    0x1c, 0x08, // Game Mode
    0x1f, 0x00, // send new information, latch current data to buffer

    0x40, 0xc0, // SPD Package Enable

    // Terminate transmission
    0x00, 0x00};

/**
 * The function sends configuration data over I2C by writing register addresses and values.
 *
 * @param i2c_addr The I2C address of the device to which the configuration is being sent.
 * @param cfg_buf A pointer to a buffer containing the configuration data to be sent over I2C.
 */
void adv_send_config(unsigned char i2c_addr, char *cfg_buf)
{

    while (1 == 1)
    {
        char adv_addr = *cfg_buf++;
        char adv_val = *cfg_buf++;
        // If 0x00 && 0x00 we reached the end of the configuration
        if (adv_addr == 0x00 && adv_val == 0x00)
        {
            break;
        }
        // Set the address of the ADV7511 device on the bus
        i2c_set_address(i2c_addr);

        // Write the registers addr first
        i2c_write(adv_addr);
        i2c_write(adv_val);
        i2c_stop();

        // Wait for the TX buffer to be empty
        i2c_wait_not_busy();
    }
}

/**
 * The function initializes the ADV7511 device by setting its address and writing configuration values
 * to its registers using I2C communication.
 */
// THE DISPLAY COMING BACK.  Switching a monitor off, or unplugging HDMI, takes
// Hot Plug Detect low; switching it on again takes it high, and the part must
// be configured again -- until now by hand, with LSHIFT + keypad '.'.
//
// Polled rather than interrupt-driven: the interrupt pin does reach the FPGA
// (dv_int, and rtl/openaars/adv7511/i2c_sender.vhd re-sends its table on a
// change), but that path does not recover the display on this board, and the
// firmware has to read 0x42 anyway -- an edge alone does not say whether the
// monitor arrived or left (Programming Guide 4.11.2: the interrupt fires on
// both transitions).
//
//   0x42[6] HPD state, 0x42[5] Monitor Sense state   (read only)
//   0x96[7] HPD interrupt, 0x96[6] Monitor Sense interrupt -- WRITE 1 TO CLEAR
//
// Call it a few times a second from the main loop.  It re-initialises only on
// a low->high transition of HPD, so a monitor that is simply absent costs one
// I2C read per call and nothing else.
static unsigned char adv_hpd_was = 0;

unsigned char adv7511_status(void)
{
    return i2c_read_reg(ADV_CTRL_ADDR, 0x42);
}

unsigned char adv7511_int_flags(void)
{
    return i2c_read_reg(ADV_CTRL_ADDR, 0x96);
}

// The last status byte the poll read, purely so the OSD can show it.  Costs no
// extra I2C traffic: the poll has already fetched it.  This exists to settle
// one question -- when the display is off, does the part stop answering (0xff)
// or does it answer with HPD still set?  Those need different fixes and the
// symptom is identical.
unsigned char adv_last_status = 0;

// The last four status bytes that DIFFERED from the one before, newest in the
// low byte.  A plain "last value" readout cannot answer the question that
// matters, because the reading wanted is the one taken while the display is
// off -- and the OSD cannot be read with the display off.  Keeping the changes
// means the sequence can be read afterwards, with the display back on.
unsigned long adv_status_hist = 0;

int adv7511_poll(void)
{
    unsigned char st  = adv7511_status();

    if (st != adv_last_status)
        adv_status_hist = (adv_status_hist << 8) | st;
    adv_last_status = st;
    unsigned char hpd;
    int reinit = 0;

    // 0xff is i2c_read_reg's "no answer": the device did not respond, or the
    // bus is held by the RTL's own master on the same pins.  Do nothing --
    // never re-initialise on a failed read, and never touch the bus again this
    // pass.  (0xff is not a plausible value here either: 0x42 has six reserved
    // bits that read 0.)
    if (st == 0xff)
    {
        // Treat "no answer" as the sink being gone, and SAY SO in adv_hpd_was.
        // Returning without touching it was a latent trap: if the part stops
        // answering while the display is off -- and HPD low resets most of its
        // registers, so that is entirely possible -- then adv_hpd_was stays at
        // 1 from when the display was on.  The display comes back, hpd reads 1,
        // and there is no rising edge to trigger on.  The re-init then never
        // happens again, which is exactly the fault Paul reported.
        //
        // Still no re-initialising on a failed read: we only record that there
        // is nothing there.  The worst this can cause is one extra re-init
        // after a transient read failure, which is harmless.
        adv_hpd_was = 0;
        return 0;
    }

    hpd = (st & 0x40) ? 1 : 0;

    if (hpd && !adv_hpd_was)
    {
        // the sink is back: configure the part again
        adv7511_init();
        reinit = 1;
    }
    adv_hpd_was = hpd;

    // clear both interrupt flags so the pin re-arms (writing 1 clears)
    i2c_set_address(ADV_CTRL_ADDR);
    i2c_write(0x96);
    i2c_write(0xC0);
    i2c_stop();
    i2c_wait_not_busy();

    return reinit;
}

unsigned char adv_clkdelay = ADV_CLKDELAY_DEFAULT;

static void adv_write_clkdelay(void)
{
    i2c_set_address(ADV_CTRL_ADDR);
    i2c_write(0xBA);
    i2c_write(adv_clkdelay << 5);
    i2c_stop();
    i2c_wait_not_busy();
}

void adv7511_set_clkdelay(unsigned char step)
{
    adv_clkdelay = step & 7;
    adv_write_clkdelay();
}

unsigned char adv7511_read_clkdelay(void)
{
    return i2c_read_reg(ADV_CTRL_ADDR, 0xBA);
}

void adv7511_init(void)
{
    i2c_set_divider(0x0020);

    // Configure Main registers
    adv_send_config(ADV_CTRL_ADDR, adv7511_init_main_vals);
    // The table's 0xBA entry is the default; the OSD setting overrides it
    adv_write_clkdelay();
    // Configure Packet memory
    adv_send_config(ADV_PACKET_ADDR, adv7511_init_packet_vals);

    // Done
    return;
}