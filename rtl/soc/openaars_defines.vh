/* openaars_defines.v */
/* 2021, paul.honig@printf.nl */

// board type define
`define MINIMIG_OPENAARS
`define MINIMIG_XILINX
`define MINIMIG_ARTIX7
`define MINIMIG_VIDEO_FILTER
`define MINIMIG_PS2_KEYBOARD
`define MINIMIG_PS2_MOUSE
`define MINIMIG_VPOS // Video positon translation circuitry
`define MINIMIG_HOST_DIRECT // The host can access memory directly, so doesn't need to upload over SPI
`define MINIMIG_PARALLEL_AUDIO  // Use own sigma-delta for audio
`define MINIMIG_I2C_BUS // Bus to control preferals from host CPU
`define MINIMIG_RTC_BUS // SPI BUS TO RTC :w
