#include "audio.h"
#include "hardware.h"
#include "i2c.h"


int audio_busy(int buffer)
{
	return((AUDIO&1)==buffer);
}


void audio_start()
{
	AUDIO=AUDIOF_ENA;
}


void audio_stop()
{
	AUDIO=AUDIOF_CLEAR;
}

void audio_clear()
{
	unsigned char *p=AUDIO_BUFFER;
	int i;
	AUDIO=AUDIOF_CLEAR;
	for(i=0;i<AUDIO_BUFFER_SIZE*2;++i)
	{
		p[i]=0;
	}
	AUDIO=AUDIOF_ENA;
	i=TIMER;
	while(TIMER==i)
		;
	AUDIO=AUDIOF_CLEAR;
}

// Values from 0 to 31 are valid
void audio_volume(unsigned char volume)
{
  // Sanity check
  if (volume < 32) {
	i2c_set_divider(0x0020);

    // Set the address of the audio chip (0x20)
    i2c_set_address(0x20);

    // Setup the message to be sent
    i2c_write(MAX_VOL_REG); // Start implicit
    i2c_write(vol_to_reg(volume));
    i2c_stop();
  }
}
