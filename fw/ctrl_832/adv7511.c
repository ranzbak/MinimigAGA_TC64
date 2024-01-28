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
    0x96, 0x00, // Clear HPD interrupt flag
    0xFA, 0x00, // Nbr of times to search for good phase
    // Set the video clock delay
    0xBA, 0x00, // Configure clock delay -1.2ns
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
void adv7511_init(void)
{
    i2c_set_divider(0x0020);

    // Configure Main registers
    adv_send_config(ADV_CTRL_ADDR, adv7511_init_main_vals);
    // Configure Packet memory
    adv_send_config(ADV_PACKET_ADDR, adv7511_init_packet_vals);

    // Done
    return;
}