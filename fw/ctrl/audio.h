#ifndef AUDIO_H
#define AUDIO_H

int audio_busy(int buffer);
void audio_start();
void audio_stop();
void audio_clear();

void audio_volume(unsigned char volume);

// Volume table  
//
// 0x19 -29.5  default

// value   pos   dB

#define MAX_VOL_REG 0x02                      // MAX9850 register for volume control

#define vol_to_reg(x) (0x68-(unsigned char)x) // 0x68 volume with slew rate control, 0x28 without
//  0x28, // 0     Mute
//  0x27, // 1     -73.5
//  0x26, // 2     -69.5
//  0x25, // 3     -65.5
//  0x24, // 4     -61.5
//
//  0x23, // 5     -57.5
//  0x22, // 6     -53.5
//  0x21, // 7     -49.5
//  0x20, // 8     -45.5
//  0x1f, // 9     -41.5
//
//  0x1e, // 10    -39.5
//  0x1d, // 11    -37.5
//  0x1c, // 12    -35.5
//  0x1b, // 13    -33.5
//  0x1a, // 14    -31.5
//
//  0x19, // 15    -29.5 default
//  0x18, // 16    -27.5
//  0x17, // 17    -25.5
//  0x16, // 18    -23.5
//  0x15, // 19    -21.5
//
//  0x14, // 20    -19.5
//  0x13, // 21    -17.5
//  0x12, // 22    -15.5
//  0x11, // 23    -13.5
//  0x10, // 24    -11.5
//
//  0x0f, // 25    -9.5
//  0x0e, // 26    -7.5
//  0x0d, // 27    -5.5
//  0x0c, // 28    -3.5
//  0x0b, // 29    -1.5
//
//  0x0a, // 30    -0.5
//  0x09, // 31    +0.5

#endif

