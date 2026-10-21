-- Black boxes for the GHDL conversion (run.sh SIM=verilator): VHDL entity
-- declarations of the Verilog modules that the VHDL instantiates as
-- "entity work.X" (a component declaration needs no stub: ghdl --synth
-- leaves an unbound component as an instance of that name).  They are
-- analysed into the conversion's work library only, so that cfide.vhd
-- analyses unchanged.  ghdl --synth turns each into an empty module; run.sh
-- deletes that module from its output, and Verilator links the real Verilog.
-- Ports as the Verilog, names and widths (connections are by name).
--
--   i2c_master_mmio   rtl/host/i2c_master_mmio.sv, cfide's havei2c branch
--                     (not elaborated in this bench: havei2c = false)
library ieee;
use ieee.std_logic_1164.all;

entity i2c_master_mmio is
  port (
    clk              : in  std_logic;
    rst              : in  std_logic;
    d                : in  std_logic_vector(15 downto 0);
    q                : out std_logic_vector(15 downto 0);
    interrupt        : out std_logic;
    addr             : in  std_logic_vector(31 downto 2);
    i2c_select       : in  std_logic;
    interrupt_select : in  std_logic;
    req              : in  std_logic;
    wr               : in  std_logic;
    scl_i            : in  std_logic;
    scl_o            : out std_logic;
    scl_t            : out std_logic;
    sda_i            : in  std_logic;
    sda_o            : out std_logic;
    sda_t            : out std_logic;
    ext_int          : in  std_logic
  );
end entity;

architecture blackbox of i2c_master_mmio is
begin
end architecture;
