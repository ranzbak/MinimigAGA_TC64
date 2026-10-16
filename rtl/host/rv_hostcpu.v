`timescale 1ns / 1ps
// rv_hostcpu: VexRiscv OSD host CPU behind the EightThirtyTwo req/ack bus.
//
// Plain Verilog-2005 (no vendor primitives), Vivado and Quartus.
// doc/osd-riscv-plan.md 3.2; generated cores: rtl/host/vexriscv/README.md.
//
// Bus contract (832 req/ack): req, addr, q, sel, wr are registers and stay
// stable until the cycle in which ack = 1; d is sampled in that cycle; in the
// next cycle req is 0 or a new request.  One transaction in flight.
//
// Lane rule: sel[i] = byte A+i.  Memory (addr[23] = 0: boot ROM, SDRAM) is
// big endian (byte A+0 in bits 31:24), the core is little endian, so the four
// data bytes are swapped in both directions and sel is the core's byte mask
// unchanged.  The hw window (addr[23] = 1, cfide, 16-bit registers in bits
// 15:0) is passed through unswapped.
//
// iBus (IBusCachedPlugin, 32-byte lines): a command (size 5) becomes 8 word
// reads of the line in ascending order; each ack returns one rsp beat.  A
// line refill is never interrupted.
// dBus (DBusSimplePlugin): dBus_cmd_ready only while idle; a write is done
// for the core at the command, the next access waits for its ack; a read
// returns one dBus_rsp_ready beat.
// Arbitration only while idle, dBus before iBus.
// Responses (iBus_rsp_valid, dBus_rsp_ready, data) are registered: one cycle
// after the ack, so no path runs from the bus into the core's stall logic.
//
// EXTRA_WS (bench only, default 0 = no logic): idle cycles before every
// request (the "slower CPU" stress knob).
//
// DEBUG: 0 = VexOsd (no debug); 1 = VexOsd_DMT + rv_bscane2 (Artix only,
// Task 14 -- until then DEBUG = 1 fails elaboration on the missing module
// rv_hostcpu_DEBUG1_needs_rv_bscane2_Task14); 2 = VexOsd_DMJ, own TAP on
// the jtag_* ports.  Any other value fails elaboration likewise.
//
// Reset: reset_n is asserted asynchronously and released through a 2-FF
// synchroniser.  The core reset is a register: rst | ndmreset (the debug
// module's system reset request); debugReset = rst.  The bus state machine
// is reset by rst only, so an ndmreset in the middle of a transaction still
// finishes it on the bus (its responses are dropped).
//
// Simulation only (`ifdef RV_HOSTCPU_STATS): I$ refill and dBus counters,
// printed by the task stats_report (the bench calls it at the end).
module rv_hostcpu #(
  parameter DEBUG    = 0,  // 0 VexOsd, 1 VexOsd_DMT + rv_bscane2 (Task 14), 2 VexOsd_DMJ
  parameter EXTRA_WS = 0   // bench only: idle cycles before every request
) (
  input  wire        clk,
  input  wire        reset_n,    // async assert, released synchronously inside
  output reg  [31:2] addr,
  output reg  [31:0] q,          // write data, BE lanes when addr[23]=0
  output reg  [3:0]  sel,        // sel[i] = byte A+i
  output reg         wr,
  output reg         req,
  input  wire        ack,
  input  wire [31:0] d,          // read data, BE lanes when addr[23]=0
  input  wire        irq_ext,    // cfide interrupt, level
  input  wire        irq_timer,  // 0 until Phase 8
  input  wire        irq_soft,   // 0
  input  wire        jtag_tck, input wire jtag_tms, input wire jtag_tdi,
  output wire        jtag_tdo    // DEBUG=2 only; 0 otherwise
);

  function [31:0] swap32(input [31:0] w);
    swap32 = {w[7:0], w[15:8], w[23:16], w[31:24]};
  endfunction

  // ---------------------------------------------------------------- reset
  reg  [1:0] rst_sync;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) rst_sync <= 2'b00;
    else          rst_sync <= {rst_sync[0], 1'b1};
  wire rst = ~rst_sync[1];

  wire ndmreset;
  reg  core_rst;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) core_rst <= 1'b1;
    else          core_rst <= rst | ndmreset;

  // ----------------------------------------------------------- interrupts
  reg irq_ext_r;
  always @(posedge clk or posedge rst)
    if (rst) irq_ext_r <= 1'b0;
    else     irq_ext_r <= irq_ext;

  // ------------------------------------------------------------ core ports
  wire        iBus_cmd_valid;
  wire [31:0] iBus_cmd_payload_address;
  wire [2:0]  iBus_cmd_payload_size;
  wire        dBus_cmd_valid;
  wire        dBus_cmd_payload_wr;
  wire [3:0]  dBus_cmd_payload_mask;
  wire [31:0] dBus_cmd_payload_address;
  wire [31:0] dBus_cmd_payload_data;
  wire [1:0]  dBus_cmd_payload_size;

  reg         busy;          // a core command is being served on the bus
  reg         rsp_i;         // iBus_rsp_valid
  reg         rsp_d;         // dBus_rsp_ready
  reg  [31:0] rsp_data;

  wire dBus_cmd_ready = ~busy;
  wire iBus_cmd_ready = ~busy & ~dBus_cmd_valid;

  generate
    if (DEBUG == 0) begin : g_core
      VexOsd u_core (
        .timerInterrupt           (irq_timer),
        .externalInterrupt        (irq_ext_r),
        .softwareInterrupt        (irq_soft),
        .iBus_cmd_valid           (iBus_cmd_valid),
        .iBus_cmd_ready           (iBus_cmd_ready),
        .iBus_cmd_payload_address (iBus_cmd_payload_address),
        .iBus_cmd_payload_size    (iBus_cmd_payload_size),
        .iBus_rsp_valid           (rsp_i),
        .iBus_rsp_payload_data    (rsp_data),
        .iBus_rsp_payload_error   (1'b0),
        .dBus_cmd_valid           (dBus_cmd_valid),
        .dBus_cmd_ready           (dBus_cmd_ready),
        .dBus_cmd_payload_wr      (dBus_cmd_payload_wr),
        .dBus_cmd_payload_mask    (dBus_cmd_payload_mask),
        .dBus_cmd_payload_address (dBus_cmd_payload_address),
        .dBus_cmd_payload_data    (dBus_cmd_payload_data),
        .dBus_cmd_payload_size    (dBus_cmd_payload_size),
        .dBus_rsp_ready           (rsp_d),
        .dBus_rsp_error           (1'b0),
        .dBus_rsp_data            (rsp_data),
        .clk                      (clk),
        .reset                    (core_rst));
      assign ndmreset = 1'b0;
      assign jtag_tdo = 1'b0;
    end else if (DEBUG == 2) begin : g_core
      VexOsd_DMJ u_core (
        .timerInterrupt           (irq_timer),
        .externalInterrupt        (irq_ext_r),
        .softwareInterrupt        (irq_soft),
        .jtag_tms                 (jtag_tms),
        .jtag_tdi                 (jtag_tdi),
        .jtag_tdo                 (jtag_tdo),
        .jtag_tck                 (jtag_tck),
        .ndmreset                 (ndmreset),
        .iBus_cmd_valid           (iBus_cmd_valid),
        .iBus_cmd_ready           (iBus_cmd_ready),
        .iBus_cmd_payload_address (iBus_cmd_payload_address),
        .iBus_cmd_payload_size    (iBus_cmd_payload_size),
        .iBus_rsp_valid           (rsp_i),
        .iBus_rsp_payload_data    (rsp_data),
        .iBus_rsp_payload_error   (1'b0),
        .dBus_cmd_valid           (dBus_cmd_valid),
        .dBus_cmd_ready           (dBus_cmd_ready),
        .dBus_cmd_payload_wr      (dBus_cmd_payload_wr),
        .dBus_cmd_payload_mask    (dBus_cmd_payload_mask),
        .dBus_cmd_payload_address (dBus_cmd_payload_address),
        .dBus_cmd_payload_data    (dBus_cmd_payload_data),
        .dBus_cmd_payload_size    (dBus_cmd_payload_size),
        .dBus_rsp_ready           (rsp_d),
        .dBus_rsp_error           (1'b0),
        .dBus_rsp_data            (rsp_data),
        .reset                    (core_rst),
        .stoptime                 (),
        .clk                      (clk),
        .debugReset               (rst));
    end else if (DEBUG == 1) begin : g_core
      // Task 14 replaces this with VexOsd_DMT + rv_bscane2.  Until then the
      // missing module makes DEBUG = 1 fail elaboration with this name.
      rv_hostcpu_DEBUG1_needs_rv_bscane2_Task14 u_unsupported ();
    end else begin : g_core
      rv_hostcpu_DEBUG_must_be_0_1_or_2 u_unsupported ();
    end
  endgenerate

  // ------------------------------------------------------ bus state machine
  localparam WSW = (EXTRA_WS > 1) ? $clog2(EXTRA_WS) : 1;
  localparam [WSW-1:0] WS_LOAD = (EXTRA_WS > 0) ? EXTRA_WS - 1 : 0;

  reg           is_i;      // current transaction is an iBus line refill
  reg           is_hw;     // addr[23] of the current transaction: no swap
  reg           last;      // current request is the last of the transaction
  reg           pend;      // EXTRA_WS: request waiting for its idle cycles
  reg [WSW-1:0] wcnt;
  reg           drop;      // core was reset during the transaction

  wire d_fire = ~busy & dBus_cmd_valid;
  wire i_fire = ~busy & ~dBus_cmd_valid & iBus_cmd_valid;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      addr <= 30'h0; q <= 32'h0; sel <= 4'h0; wr <= 1'b0; req <= 1'b0;
      busy <= 1'b0; is_i <= 1'b0; is_hw <= 1'b0; last <= 1'b0;
      pend <= 1'b0; wcnt <= {WSW{1'b0}}; drop <= 1'b0;
      rsp_i <= 1'b0; rsp_d <= 1'b0; rsp_data <= 32'h0;
    end else begin
      rsp_i <= 1'b0;
      rsp_d <= 1'b0;

      if (core_rst && busy) drop <= 1'b1;

      if (d_fire || i_fire) begin
        busy <= 1'b1;
        drop <= 1'b0;
        if (EXTRA_WS == 0) req <= 1'b1;
        else begin pend <= 1'b1; wcnt <= WS_LOAD; end
      end

      if (d_fire) begin
        is_i  <= 1'b0;
        is_hw <= dBus_cmd_payload_address[23];
        last  <= 1'b1;
        addr  <= dBus_cmd_payload_address[31:2];
        wr    <= dBus_cmd_payload_wr;
        sel   <= dBus_cmd_payload_mask;
        q     <= dBus_cmd_payload_address[23] ? dBus_cmd_payload_data
                                              : swap32(dBus_cmd_payload_data);
      end else if (i_fire) begin
        is_i  <= 1'b1;
        is_hw <= iBus_cmd_payload_address[23];
        last  <= 1'b0;
        addr  <= {iBus_cmd_payload_address[31:5], 3'b000};
        wr    <= 1'b0;
        sel   <= 4'hF;
      end

      if (EXTRA_WS != 0 && pend) begin
        if (wcnt == {WSW{1'b0}}) begin pend <= 1'b0; req <= 1'b1; end
        else wcnt <= wcnt - 1'b1;
      end

      if (req && ack) begin
        rsp_data <= is_hw ? d : swap32(d);
        rsp_i    <= is_i & ~wr & ~drop & ~core_rst;
        rsp_d    <= ~is_i & ~wr & ~drop & ~core_rst;
        if (last) begin
          busy <= 1'b0;
          req  <= 1'b0;
        end else begin
          addr[4:2] <= addr[4:2] + 3'd1;
          last      <= (addr[4:2] == 3'd6);
          if (EXTRA_WS != 0) begin
            req  <= 1'b0;
            pend <= 1'b1;
            wcnt <= WS_LOAD;
          end
        end
      end
    end
  end

  // ------------------------------------------------------- simulation only
  // synthesis translate_off
  always @(posedge clk)
    if (!rst && i_fire && iBus_cmd_payload_size !== 3'd5)
      $display("=== BUS VIOLATION rv_hostcpu: iBus_cmd_payload_size = %0d (expected 5) at %t",
               iBus_cmd_payload_size, $time);

`ifdef RV_HOSTCPU_STATS
  integer st_irefill, st_dread, st_dwrite, st_busy;
  initial begin st_irefill = 0; st_dread = 0; st_dwrite = 0; st_busy = 0; end
  always @(posedge clk) if (!rst) begin
    if (i_fire)                          st_irefill = st_irefill + 1;
    if (d_fire && !dBus_cmd_payload_wr)  st_dread   = st_dread + 1;
    if (d_fire &&  dBus_cmd_payload_wr)  st_dwrite  = st_dwrite + 1;
    if (busy)                            st_busy    = st_busy + 1;
  end
  task stats_report;
    $display("=== STATS irefill %0d dread %0d dwrite %0d busy_cycles %0d",
             st_irefill, st_dread, st_dwrite, st_busy);
  endtask
`endif
  // synthesis translate_on

endmodule
