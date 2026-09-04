localparam CMD_W = 4;
typedef enum logic [3:0] {
  CMD_LOAD_MODE = 4'b0000,
  CMD_REFRESH   = 4'b0001,
  CMD_PRECHARGE = 4'b0010,
  CMD_ACTIVE    = 4'b0011,
  CMD_WRITE     = 4'b0100,
  CMD_READ      = 4'b0101,
  CMD_ZQCL      = 4'b0110,
  CMD_NOP       = 4'b0111
} cmd_t;

// SM states
typedef enum {
  STATE_INIT,
  STATE_DELAY,
  STATE_IDLE,
  STATE_ACTIVATE,
  STATE_READ,
  STATE_WRITE,
  STATE_PRECHARGE,
  STATE_REFRESH
} state_t;
