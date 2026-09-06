// -----------------------------------------------------------------------------
// autoconfig_tb.sv -- what does the Minimig autoconfig block actually offer the
// Amiga OS?
//
// The bench instantiates rtl/minimig/minimig_autoconfig.v (with its nibble ROM)
// twice, once with Z3RAM3 = 0 (the DDR3 fast-RAM build) and once with
// Z3RAM3 = 1 (SDRAM builds); see minimig_virtual_top.v:
//   minimig ... .Z3RAM3(haveddr3 ? 1'b0 : 1'b1)
// and then plays expansion.library at it:
//
//   * read the AUTOCONFIG ROM one nibble at a time: the high nibble of register
//     N at offset N, the low nibble at offset N+2 (Zorro II style mapping --
//     Minimig only decodes the $00E8xxxx configuration block, which per the
//     Zorro III spec 8.1 "always look[s] like Zorro II cycles").
//   * complement every register except register 00 (spec 8.1: "all read
//     registers except for the 00 register are physically complemented").
//   * decode er_Type / er_Product / er_Flags / er_Manufacturer / er_SerialNumber
//     exactly as chapter 8.2 says, including the size extension bit
//     (er_Flags bit 5) and the sub-size (logical size) nibble er_Flags[3:0].
//   * allocate a base address the way the OS would and write it to the board;
//     stop when the chain reports "no board".
//
// Address allocation model (assumptions, all documented in the report):
//   Zorro II  memory board (ERTF_MEMLIST)  -> $00200000 upward (Z2 RAM space)
//   Zorro II  I/O board                    -> $00E90000 upward (Z2 I/O space)
//   Zorro III board >= 16 MB               -> $40000000 upward.  This is what
//        real Kickstarts hand the Minimig ZIII RAM board and what TG68K.vhd
//        decodes (sel_z3ram = cpuaddr(31:30)="01" and cpuaddr(26:24)="000").
//   Zorro III board <  16 MB               -> $08000000 upward, the A3000
//        "32-Bit Memory Expansion Space" of figure 1-1 of the Zorro III spec
//        ($08000000-$0FFFFFFF), where small Zorro III boards commonly land.
//        Nothing in the Minimig wrapper decodes there.
//
// Two OS write orderings are exercised, because the ordering decides whether a
// trailing base-address write lands on the *next* device in the chain:
//   WRPOL=0 ("44,48"): spec 8.2 ordering for a Zorro III PIC in the Zorro II
//        configuration block -- register 44 (A31-A24) first, then register 48
//        (A23-A16); "writing to register 48 actually configures the board".
//   WRPOL=1 ("48,44"): register 48 first, register 44 last (the ordering the
//        spec gives for a Zorro III PIC in the Zorro III configuration block).
// The RTL acts on 44 for Zorro III boards and on 48 for Zorro II boards, so
// under WRPOL=0 the trailing 48 write is seen by whatever device the chain has
// already advanced to.
//
// On top of the sweep the bench runs two extra checks:
//
//   * ec_Shutup (spec 8.2, register 4C): a run in which the OS shuts the Zorro II
//     RAM board up instead of configuring it.  That board leaves NOSHUTUP clear
//     (its er_Flags nibble is the ROM default $F, so er_Flags reads $0x), so the
//     OS is allowed to do it, and the chain must still walk on to the Zorro III
//     board and reach the NULL terminator.
//
//   * gary.v's Toccata decode.  gary.v itself is not in this bench (it needs the
//     whole chip bus), so the single line that matters is modelled here and
//     checked against the state of the block after every configuration:
//        assign sel_toccata = (cpu_address_in[23:16] == toccata_base_addr_reg)
//                          && (autoconfig_configured_reg[4] == 1'b1)
//                          && (autoconfig_shutup_reg[4] == 1'b0)
//                          && (autoconfig_done_reg   == 1'b1);
//     The board_configured[4] term is the new one: autoconfig_done alone only
//     says the chain reached the NULL device, which also happens when the
//     Toccata was never offered -- and then base register 4 still holds its
//     reset value $00, so the card decoded $000000-$00FFFF on top of chip RAM.
//
// Run:  ./run.sh            (compact table)
//       ./run.sh -v         (full per-board register dump)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module autoconfig_tb;

  // ---------------------------------------------------------------- clock/bus
  logic        clk = 1'b0;
  logic        clk7_en = 1'b0;
  logic        reset = 1'b1;
  logic        rd = 1'b0, hwr = 1'b0, lwr = 1'b0;
  logic  [8:1] address = 8'h00;
  logic [15:0] data_in = 16'h0000;
  logic  [1:0] fastram_config = 2'b00;
  logic  [1:0] slowram_config = 2'b00;
  logic        m68020 = 1'b0;
  logic        ram_64meg = 1'b0;

  logic        sel_r = 1'b0;      // bus select, steered to one of the two DUTs
  // 0 -> Z3RAM3=0, 1 -> Z3RAM3=1 (leftover SDRAM board), 2 -> Z3RAM3=1 with
  // Z3RAM3_DDR3=1 (that board is the 16 MB DDR3 fast RAM board instead).
  logic  [1:0] dsel  = 2'd0;

  always #5 clk = ~clk;

  logic [1:0] ckdiv = 2'b00;
  always @(posedge clk) begin
    ckdiv   <= ckdiv + 2'd1;
    clk7_en <= (ckdiv == 2'b10);  // one enable in four, as minimig.v does
  end

  // ------------------------------------------------------------------- DUTs
  wire [15:0] dout0, dout1, dout2;
  wire  [4:0] bcfg0, bcfg1, bcfg2, bshut0, bshut1, bshut2;
  wire  [7:0] tocc0, tocc1, tocc2;
  wire  [7:0] z3b0, z3b1, z3b2;
  wire        done0, done1, done2;
  wire        sel0 = sel_r & (dsel == 2'd0);
  wire        sel1 = sel_r & (dsel == 2'd1);
  wire        sel2 = sel_r & (dsel == 2'd2);

  minimig_autoconfig #(.TOCCATA_SND(1'b1), .Z3RAM3(1'b0)) dut_z3ram3_0 (
    .clk(clk), .clk7_en(clk7_en), .reset(reset),
    .address_in(address), .data_out(dout0), .data_in(data_in),
    .rd(rd), .hwr(hwr), .lwr(lwr), .sel(sel0),
    .slowram_config(slowram_config), .fastram_config(fastram_config),
    .m68020(m68020), .ram_64meg(ram_64meg),
    .board_configured(bcfg0), .board_shutup(bshut0),
    .toccata_base_addr(tocc0), .z3ram3_base(z3b0), .autoconfig_done(done0));

  minimig_autoconfig #(.TOCCATA_SND(1'b1), .Z3RAM3(1'b1)) dut_z3ram3_1 (
    .clk(clk), .clk7_en(clk7_en), .reset(reset),
    .address_in(address), .data_out(dout1), .data_in(data_in),
    .rd(rd), .hwr(hwr), .lwr(lwr), .sel(sel1),
    .slowram_config(slowram_config), .fastram_config(fastram_config),
    .m68020(m68020), .ram_64meg(ram_64meg),
    .board_configured(bcfg1), .board_shutup(bshut1),
    .toccata_base_addr(tocc1), .z3ram3_base(z3b1), .autoconfig_done(done1));

  // The third ZIII board is the DDR3 fast RAM board: 16 MB, and the size
  // nibble is not rewritten by the first ZIII board's handler.
  minimig_autoconfig #(.TOCCATA_SND(1'b1), .Z3RAM3(1'b1), .Z3RAM3_DDR3(1'b1)) dut_z3ram3_ddr3 (
    .clk(clk), .clk7_en(clk7_en), .reset(reset),
    .address_in(address), .data_out(dout2), .data_in(data_in),
    .rd(rd), .hwr(hwr), .lwr(lwr), .sel(sel2),
    .slowram_config(slowram_config), .fastram_config(fastram_config),
    .m68020(m68020), .ram_64meg(ram_64meg),
    .board_configured(bcfg2), .board_shutup(bshut2),
    .toccata_base_addr(tocc2), .z3ram3_base(z3b2), .autoconfig_done(done2));

  wire [15:0] dout  = (dsel == 2'd2) ? dout2  : dsel ? dout1  : dout0;
  wire  [4:0] bcfg  = (dsel == 2'd2) ? bcfg2  : dsel ? bcfg1  : bcfg0;
  wire  [4:0] bshut = (dsel == 2'd2) ? bshut2 : dsel ? bshut1 : bshut0;
  // Read the Toccata base out of the DUT array directly: Icarus does not
  // re-evaluate the continuous assign "toccata_base_addr = board_base_addr[4]"
  // when the array is written through the variable-index reset loop, so the
  // port itself stays X in simulation even though the register is cleared.
  function automatic [7:0] tocc_base();
    begin
      tocc_base = (dsel == 2'd2) ? dut_z3ram3_ddr3.board_base_addr[4]
                : dsel           ? dut_z3ram3_1.board_base_addr[4]
                                 : dut_z3ram3_0.board_base_addr[4];
    end
  endfunction
  // Same story for the third ZIII board's latched base (board_base_addr[3]):
  // read the register, not the port.  This is A31-A24 of whatever the OS
  // assigned, and is what TG68K.vhd decodes that board against.
  function automatic [7:0] z3ram3_base_val();
    begin
      z3ram3_base_val = (dsel == 2'd2) ? dut_z3ram3_ddr3.board_base_addr[3]
                      : dsel           ? dut_z3ram3_1.board_base_addr[3]
                                       : dut_z3ram3_0.board_base_addr[3];
    end
  endfunction
  wire        done  = (dsel == 2'd2) ? done2 : dsel ? done1  : done0;

  // ------------------------------------------------------------- bus helpers
  task automatic wait_clk7();
    begin
      do @(posedge clk); while (clk7_en !== 1'b1);
    end
  endtask

  // Read one AUTOCONFIG nibble.  data_out = sel ? {rom_q,12'hfff} : 0 and the
  // nibble ROM has two clocks of read latency, so hold the address a while.
  task automatic ac_nib(input integer off, output logic [3:0] n);
    begin
      @(negedge clk);
      address = off[8:1];
      sel_r   = 1'b1;
      rd      = 1'b1;
      repeat (5) @(posedge clk);
      n = dout[15:12];
      @(negedge clk);
      rd    = 1'b0;
      sel_r = 1'b0;
    end
  endtask

  // Read a logical 8 bit register (high nibble at off, low nibble at off+2) and
  // undo the hardware complement for every register except register 00.
  task automatic ac_reg(input integer off, output logic [7:0] b);
    logic [3:0] hi, lo;
    begin
      ac_nib(off,   hi);
      ac_nib(off+2, lo);
      b = {hi, lo};
      if (off != 0) b = ~b;
    end
  endtask

  // One write bus cycle containing exactly one clk7_en pulse, so the block sees
  // the write once (it latches on clk7_en && sel && (lwr|hwr)).  A 68000/68020
  // byte write replicates the byte on both halves of the data bus, which is why
  // the RTL may take data_in[7:0] for a byte write to the even address $48.
  task automatic ac_write(input integer off, input [7:0] val);
    begin
      wait_clk7();                     // land just after an enable
      @(negedge clk);
      address = off[8:1];
      data_in = {val, val};
      sel_r   = 1'b1;
      hwr     = 1'b1;
      lwr     = 1'b1;
      wait_clk7();                     // the single enable that latches it
      @(negedge clk);
      hwr     = 1'b0;
      lwr     = 1'b0;
      sel_r   = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic do_reset();
    begin
      @(negedge clk);
      reset = 1'b1; sel_r = 1'b0; rd = 1'b0; hwr = 1'b0; lwr = 1'b0;
      address = 8'h00; data_in = 16'h0000;
      repeat (8) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      repeat (16) @(posedge clk);      // let the init state write the ZII size
    end
  endtask

  // ---------------------------------------------------------- size decoding
  // Zorro III spec 8.2, register 00 bits 2-0, with the register 08 bit 5
  // ("size extension") interpretation.
  function automatic longint unsigned phys_size(input [2:0] code, input bit ext);
    begin
      if (!ext) begin
        case (code)
          3'b000: phys_size = 64'h800000;   // 8 MB
          3'b001: phys_size = 64'h10000;    // 64 KB
          3'b010: phys_size = 64'h20000;    // 128 KB
          3'b011: phys_size = 64'h40000;    // 256 KB
          3'b100: phys_size = 64'h80000;    // 512 KB
          3'b101: phys_size = 64'h100000;   // 1 MB
          3'b110: phys_size = 64'h200000;   // 2 MB
          3'b111: phys_size = 64'h400000;   // 4 MB
        endcase
      end else begin
        case (code)
          3'b000: phys_size = 64'h1000000;  // 16 MB
          3'b001: phys_size = 64'h2000000;  // 32 MB
          3'b010: phys_size = 64'h4000000;  // 64 MB
          3'b011: phys_size = 64'h8000000;  // 128 MB
          3'b100: phys_size = 64'h10000000; // 256 MB
          3'b101: phys_size = 64'h20000000; // 512 MB
          3'b110: phys_size = 64'h40000000; // 1 GB
          3'b111: phys_size = 64'h0;        // RESERVED
        endcase
      end
    end
  endfunction

  // Register 08 bits 3-0, the sub-size (logical size) table.
  // 0 = same as physical, 1 = sized by the OS, 2 = 64 KB .. 13 = 14 MB.
  function automatic longint unsigned sub_size(input [3:0] code);
    begin
      case (code)
        4'h0: sub_size = 64'h0;          // "matches physical"
        4'h1: sub_size = 64'h0;          // "auto sized by the OS"
        4'h2: sub_size = 64'h10000;
        4'h3: sub_size = 64'h20000;
        4'h4: sub_size = 64'h40000;
        4'h5: sub_size = 64'h80000;
        4'h6: sub_size = 64'h100000;
        4'h7: sub_size = 64'h200000;
        4'h8: sub_size = 64'h400000;
        4'h9: sub_size = 64'h600000;
        4'hA: sub_size = 64'h800000;
        4'hB: sub_size = 64'hA00000;
        4'hC: sub_size = 64'hC00000;
        4'hD: sub_size = 64'hE00000;
        default: sub_size = 64'h0;       // reserved
      endcase
    end
  endfunction

  function automatic string hsize(input longint unsigned s);
    begin
      if (s == 0)                  hsize = "-";
      else if (s >= 64'h100000)    hsize = $sformatf("%0dM", s / 64'h100000);
      else                         hsize = $sformatf("%0dK", s / 64'h400);
    end
  endfunction

  // ------------------------------------------------------- OS allocator state
  longint unsigned z2mem_next, z2io_next, z3big_next, z3small_next;

  task automatic alloc_pool(input integer pool, input longint unsigned size,
                            output longint unsigned base);
    longint unsigned al, p, b;
    begin
      al = (size == 0) ? 64'h10000 : size;
      case (pool)
        0: begin p = z2mem_next;   b = 64'h00200000; end
        1: begin p = z2io_next;    b = 64'h00E90000; end
        2: begin p = z3big_next;   b = 64'h40000000; end
        default: begin p = z3small_next; b = 64'h08000000; end
      endcase
      // align inside the region, not in absolute terms: an 8 MB Zorro II board
      // has to fit the 8 MB Zorro II space that starts at $00200000.
      p    = b + ((p - b + al - 1) & ~(al - 1));
      base = p;
      p    = p + al;
      case (pool)
        0: z2mem_next   = p;
        1: z2io_next    = p;
        2: z3big_next   = p;
        default: z3small_next = p;
      endcase
    end
  endtask

  // ----------------------------------------------------------------- the OS
  integer verbose = 0;
  integer WRPOL   = 0;                    // 0 = write 44 then 48, 1 = 48 then 44
  integer SHUTUP_IDX = -1;                // chain position the OS shuts up, -1 = none
  string  summary;
  integer nboards;
  // Where the OS put the third ZIII RAM board in the run just done, and how
  // big it said it was; see the capture in config_chain.
  bit              z3ram3_seen;
  longint unsigned z3ram3_alloc_base;
  longint unsigned z3ram3_alloc_size;
  longint unsigned z3ram3_alloc_lsize;
  longint unsigned fast_linked;
  string  notes;
  string  s_order, s_boards, s_ml;

  task automatic config_chain();
    logic [7:0] er_type, er_prod, er_flags, er_man_hi, er_man_lo;
    logic [7:0] s0, s1, s2, s3;
    logic [15:0] manuf;
    logic [31:0] serial;
    bit    memlist, romvec, chained, memspace, noshutup, extended;
    logic [2:0] szcode;
    logic [3:0] subcode;
    longint unsigned psize, lsize, base;
    string kind;
    integer idx, pool;
    bit    do_shutup;
    begin : body
      z2mem_next   = 64'h00200000;
      z2io_next    = 64'h00E90000;
      z3big_next   = 64'h40000000;
      z3small_next = 64'h08000000;
      nboards = 0; fast_linked = 0;
      summary = "";
      notes   = "";
      z3ram3_seen = 1'b0; z3ram3_alloc_base = 0;
      z3ram3_alloc_size = 0; z3ram3_alloc_lsize = 0;

      for (idx = 0; idx < 8; idx = idx + 1) begin
        ac_reg('h00, er_type);
        ac_reg('h04, er_prod);
        ac_reg('h08, er_flags);
        ac_reg('h10, er_man_hi);
        ac_reg('h14, er_man_lo);
        ac_reg('h18, s0); ac_reg('h1c, s1); ac_reg('h20, s2); ac_reg('h24, s3);
        manuf  = {er_man_hi, er_man_lo};
        serial = {s0, s1, s2, s3};

        // End of chain.  An empty Zorro slot floats high, so er_Type reads $FF
        // and er_Manufacturer reads $0000 after complementing; the Minimig NULL
        // device (acdevice 3'b111, every nibble 1111) mimics exactly that.
        if (er_type[7:6] == 2'b00 || er_type[7:6] == 2'b01 ||
            manuf == 16'h0000 || manuf == 16'hFFFF) begin
          if (verbose)
            $display("      -- end of chain (er_Type=%02x er_Manufacturer=%04x)",
                     er_type, manuf);
          disable body;
        end

        memlist  = er_type[5];
        romvec   = er_type[4];
        chained  = er_type[3];
        szcode   = er_type[2:0];
        memspace = er_flags[7];
        noshutup = er_flags[6];
        extended = er_flags[5];
        subcode  = er_flags[3:0];

        if (er_type[7:6] == 2'b10) begin
          kind  = "Z3";
          psize = phys_size(szcode, extended);
          lsize = (sub_size(subcode) != 0) ? sub_size(subcode) : psize;
        end else begin
          kind  = "Z2";
          psize = phys_size(szcode, 1'b0);   // no size extension on Zorro II
          lsize = psize;
        end

        // ---- the OS either configures this board or shuts it up
        do_shutup = (idx == SHUTUP_IDX);

        if (do_shutup) begin
          // ec_Shutup, Zorro III spec 8.2: writing register 4C tells a board
          // that is not going to be used to stop answering in the
          // configuration space.  Legal for any board that leaves NOSHUTUP
          // (er_Flags bit 6) clear.  No address is allocated for it.
          if (verbose) begin
            $display("   board %0d: %s  er_Type=$%02x  er_Flags=$%02x (noshutup=%0d)",
                     nboards, kind, er_type, er_flags, noshutup);
            $display("            OS writes ec_Shutup (register 4C)%s",
                     noshutup ? "   -- but the board advertises NOSHUTUP!" : "");
          end
          summary = $sformatf("%s | %s %s SHUT-UP", summary, kind, hsize(lsize));
          if (noshutup) notes = " [shut-up asked of a NOSHUTUP board!]";
          ac_write('h4c, 8'h00);
        end else begin
          // ---- allocate as expansion.library would
          if (er_type[7:6] == 2'b10) pool = (psize >= 64'h1000000) ? 2 : 3;
          else                       pool = memlist ? 0 : 1;
          alloc_pool(pool, psize, base);

          // Remember where the OS put the third ZIII RAM board.  It carries
          // serial 3 (the second ZIII board carries 4), so this identifies it
          // whether or not ram_64meg put that second board in the chain.
          // TG68K.vhd has to decode the board here, so the base the OS chose
          // and the base the hardware latched must agree.
          if (er_type[7:6] == 2'b10 && memlist && serial == 32'd3) begin
            z3ram3_alloc_base  = base;
            z3ram3_alloc_size  = psize;   // what the board occupies
            z3ram3_alloc_lsize = lsize;   // what the OS adds to the free list
            z3ram3_seen        = 1'b1;
          end

          if (verbose) begin
            $display("   board %0d: %s  er_Type=$%02x  (memlist=%0d, rom=%0d, chained=%0d, size code %03b)",
                     nboards, kind, er_type, memlist, romvec, chained, szcode);
            $display("            er_Product=$%02x  er_Flags=$%02x (memspace=%0d noshutup=%0d extended=%0d subsize=%04b)",
                     er_prod, er_flags, memspace, noshutup, extended, subcode);
            $display("            er_Manufacturer=$%04x  er_SerialNumber=$%08x", manuf, serial);
            $display("            physical %s, linked %s -> assigned base $%08x   [board_configured=%05b]",
                     hsize(psize), hsize(lsize), base[31:0], bcfg);
          end

          if (memlist) s_ml = ""; else s_ml = "io";
          summary = $sformatf("%s | %s %s%s@$%08x", summary, kind, hsize(lsize),
                              s_ml, base[31:0]);
          if (memlist) fast_linked = fast_linked + lsize;

          // ---- hand the board its base address
          if (er_type[7:6] == 2'b10) begin
            if (WRPOL == 0) begin
              ac_write('h44, base[31:24]);   // A31-A24
              ac_write('h48, base[23:16]);   // A23-A16, "writing 48 configures"
            end else begin
              ac_write('h48, base[23:16]);
              ac_write('h44, base[31:24]);
            end
          end else begin
            ac_write('h4a, base[19:16]);     // nibble register, ignored by the RTL
            ac_write('h48, base[23:16]);     // this configures a Zorro II board
          end
        end
        nboards = nboards + 1;
      end
      notes = " [chain still offering boards after 8!]";
    end
  endtask

  // -------------------------------------------- gary.v sel_toccata gate model
  // gary.v is not instantiated here (it needs the whole chip bus), so the one
  // decode line that consumes this block's outputs is modelled instead.  New
  // condition, rtl/minimig/gary.v:
  //   assign sel_toccata = (cpu_address_in[23:16] == toccata_base_addr_reg)
  //                     && (autoconfig_configured_reg[4] == 1'b1)   <-- new
  //                     && (autoconfig_shutup_reg[4]     == 1'b0)
  //                     && (autoconfig_done_reg          == 1'b1);
  // gary registers all three autoconfig inputs one clock before using them, so
  // comparing against the settled end-of-chain state is exactly what it sees.
  function automatic bit gary_sel_toccata(input [7:0] a2316);
    begin
      gary_sel_toccata = (a2316 === tocc_base()) && (bcfg[4] === 1'b1)
                          && (bshut[4] === 1'b0) && (done === 1'b1);
    end
  endfunction

  // The old line, without the board_configured[4] term, for contrast.
  function automatic bit gary_sel_toccata_old(input [7:0] a2316);
    begin
      gary_sel_toccata_old = (a2316 === tocc_base())
                          && (bshut[4] === 1'b0) && (done === 1'b1);
    end
  endfunction

  integer tocc_checked = 0;   // configurations examined
  integer tocc_bad_new = 0;   // ... where the new decode opens a bogus window
  integer tocc_bad_old = 0;   // ... where the old decode did

  // After a chain has been walked: if the Toccata was never configured, no CPU
  // address may select it.  Sweep every possible A23-A16.
  task automatic check_toccata_gate(input string what);
    integer a;
    bit hit_new, hit_old;
    begin
      hit_new = 1'b0;
      hit_old = 1'b0;
      for (a = 0; a < 256; a = a + 1) begin
        if (bcfg[4] !== 1'b1) begin
          if (gary_sel_toccata(a[7:0]))     hit_new = 1'b1;
          if (gary_sel_toccata_old(a[7:0])) hit_old = 1'b1;
        end
      end
      tocc_checked = tocc_checked + 1;
      if (hit_new) begin
        tocc_bad_new = tocc_bad_new + 1;
        $display("   FAIL: sel_toccata can assert at $%02xxxxx with board_configured[4]=0  (%s)",
                 tocc_base(), what);
      end
      if (hit_old) tocc_bad_old = tocc_bad_old + 1;
    end
  endtask

  // ------------------------------------------------------- ec_Shutup runs
  // Walk the chain but write register 4C ("shut up", spec 8.2) instead of a
  // base address for the board at chain position SIDX, then check that the
  // chain still moves on and terminates.
  task automatic shutup_run(input integer z3, input integer f, input integer mm,
                            input integer sr, input integer pol, input integer sidx,
                            input [4:0] exp_cfg, input [4:0] exp_shut);
    string tag;
    begin
      dsel           = z3[0];
      fastram_config = f[1:0];
      slowram_config = sr[1:0];
      m68020         = mm[0];
      ram_64meg      = 1'b0;
      WRPOL          = pol;
      SHUTUP_IDX     = sidx;
      do_reset();
      if (pol) s_order = " 48,44 "; else s_order = " 44,48 ";
      tag = $sformatf("Z3RAM3=%0d fast=%02b 020=%0d order%s shut board %0d",
                      z3, f[1:0], mm, s_order, sidx);
      if (verbose)
        $display("--- %s ---", tag);
      config_chain();
      $display("   %0d     %02b   %0d   %02b  %s   %0d  |%s",
               z3, f[1:0], mm, sr[1:0], s_order, sidx, summary);
      $display("                                        |   boards=%0d linked-fast=%s configured=%05b shutup=%05b toccata_base=$%02x done=%0d%s",
               nboards, hsize(fast_linked), bcfg, bshut, tocc_base(), done, notes);
      check_toccata_gate(tag);
      if ((bshut & exp_shut) !== exp_shut)
        $display("   FAIL: board_shutup=%05b, expected at least %05b", bshut, exp_shut);
      else if ((bcfg & exp_cfg) !== exp_cfg)
        $display("   FAIL: board_configured=%05b, expected at least %05b -- the chain stalled on the shut-up board",
                 bcfg, exp_cfg);
      else if (done !== 1'b1)
        $display("   FAIL: autoconfig_done=0, the chain never reached the NULL terminator");
      else
        $display("   OK: shut-up board dropped, chain reached configured=%05b and the NULL terminator",
                 bcfg);
      SHUTUP_IDX = -1;
    end
  endtask

  // ------------------------------------------------- raw device image dump
  // acdevice is only ever changed by a configuration write, so after reset and
  // init we can poke it and read out the ROM image of every device -- including
  // the ones the state machine can no longer select.
  task automatic dump_device(input [2:0] dev);
    logic [7:0] er_type, er_prod, er_flags, mh, ml, s0, s1, s2, s3;
    logic [3:0] n;
    integer o;
    string names[8];
    string img;
    begin
      names[0] = "z2base   (ZII fast RAM)";
      names[1] = "z3base   (ZIII fast RAM)";
      names[2] = "z3base2  (ZIII RAM 2, 64 meg platforms)";
      names[3] = "z3base3  (ZIII RAM 3, leftover SDRAM)";
      names[4] = "ethbase  (Ethernet placeholder)";
      names[5] = "sndbase  (Toccata sound card)";
      names[6] = "unused   (all ones)";
      names[7] = "NULL     (chain terminator)";
      dut_z3ram3_0.acdevice = dev;
      img = "";
      for (o = 0; o <= 'h26; o = o + 2) begin
        ac_nib(o, n);
        img = $sformatf("%s%04b ", img, n);
      end
      ac_reg('h00, er_type); ac_reg('h04, er_prod); ac_reg('h08, er_flags);
      ac_reg('h10, mh); ac_reg('h14, ml);
      ac_reg('h18, s0); ac_reg('h1c, s1); ac_reg('h20, s2); ac_reg('h24, s3);
      $display(" acdevice %03b  %s", dev, names[dev]);
      $display("   raw nibbles $00..$26 : %s", img);
      $display("   er_Type=$%02x er_Product=$%02x er_Flags=$%02x er_Manufacturer=$%04x er_Serial=$%08x",
               er_type, er_prod, er_flags, {mh, ml}, {s0, s1, s2, s3});
      if (er_type[7:6] == 2'b00 || {mh, ml} == 16'h0000)
        $display("   -> no board (chain terminator)");
      else
        $display("   -> %s, %s, physical %s, linked %s, %s",
                 (er_type[7:6] == 2'b10) ? "Zorro III" : "Zorro II",
                 er_type[5] ? "memory (linked into the free pool)" : "I/O (not linked)",
                 hsize((er_type[7:6] == 2'b10) ? phys_size(er_type[2:0], er_flags[5])
                                               : phys_size(er_type[2:0], 1'b0)),
                 hsize((sub_size(er_flags[3:0]) != 0 && er_type[7:6] == 2'b10)
                        ? sub_size(er_flags[3:0])
                        : ((er_type[7:6] == 2'b10) ? phys_size(er_type[2:0], er_flags[5])
                                                   : phys_size(er_type[2:0], 1'b0))),
                 er_flags[7] ? "memory space" : "I/O space");
    end
  endtask

  // ---------------------------------------------------------------- the sweep
  integer f, mm, sr, z3, pol, dv, r64;
  integer z3b_checked = 0, z3b_bad = 0;
  longint unsigned exp_size, exp_lsize;
  string  s_verdict, s_third;

  initial begin
    if ($test$plusargs("verbose")) verbose = 1;

    $display("");
    $display("=== minimig_autoconfig: boards offered to AmigaOS  (ram_64meg=0, TOCCATA_SND=1) ===");
    $display("");
    $display(" Z3RAM3 fast 020 slow wrorder | boards as the OS sees them (linked size @ assigned base)");
    $display(" ------ ---- --- ---- ------- | -------------------------------------------------------");

    for (z3 = 1; z3 >= 0; z3 = z3 - 1) begin
      for (f = 0; f <= 3; f = f + 1) begin
        for (mm = 0; mm <= 1; mm = mm + 1) begin
          for (sr = 0; sr <= 1; sr = sr + 1) begin
            for (pol = 0; pol <= 1; pol = pol + 1) begin
              dsel           = z3[0];
              fastram_config = f[1:0];
              slowram_config = sr[1:0];
              m68020         = mm[0];
              ram_64meg      = 1'b0;
              WRPOL          = pol;
              do_reset();
              if (pol) s_order = " 48,44 "; else s_order = " 44,48 ";
              if (verbose)
                $display("--- Z3RAM3=%0d fastram_config=%02b m68020=%0d slowram_config=%02b write order %s ---",
                         z3, f[1:0], mm, sr[1:0], s_order);
              config_chain();
              if (nboards == 0) s_boards = "  (no board offered)";
              else              s_boards = summary;
              $display("   %0d     %02b   %0d   %02b  %s |%s",
                       z3, f[1:0], mm, sr[1:0], s_order, s_boards);
              $display("                                 |   boards=%0d linked-fast=%s configured=%05b shutup=%05b toccata_base=$%02x done=%0d%s",
                       nboards, hsize(fast_linked), bcfg, bshut, tocc_base(), done, notes);
              check_toccata_gate($sformatf("Z3RAM3=%0d fast=%02b 020=%0d slow=%02b order%s",
                                           z3, f[1:0], mm, sr[1:0], s_order));
            end
          end
        end
      end
    end

    // ---- every device image in the ROM, reachable or not
    $display("");
    $display("=== raw AUTOCONFIG ROM images, one per acdevice value ===");
    $display("    (fastram_config=11 so acdevice 000 carries the 8 MB size nibble)");
    $display("");
    dsel = 1'b0; fastram_config = 2'b11; slowram_config = 2'b00;
    m68020 = 1'b1; ram_64meg = 1'b0;
    do_reset();
    for (dv = 0; dv <= 7; dv = dv + 1) begin
      dump_device(dv[2:0]);
      $display("");
    end

    // ---- the OS shuts a board up instead of configuring it (spec 8.2, reg 4C)
    // Runs last: every 44 write rewrites the ZIII RAM 3 size nibble in the
    // shared ROM, so the raw dump above has to be taken before these.
    $display("");
    $display("=== ec_Shutup: the OS silences a board and the chain must walk on ===");
    $display("    (fast=11, 020=1, so the ZII RAM board is followed by the ZIII board)");
    $display("");
    $display(" Z3RAM3 fast 020 slow wrorder shut | boards as the OS sees them");
    $display(" ------ ---- --- ---- ------- ---- | -------------------------------------------------------");
    // board 0 is the ZII RAM board (er_Flags NOSHUTUP clear -> the OS may do this)
    shutup_run(1, 3, 1, 0, 0, 0, 5'b11010, 5'b00001);  // SDRAM build, 44 then 48
    shutup_run(1, 3, 1, 0, 1, 0, 5'b11010, 5'b00001);  // SDRAM build, 48 then 44
    shutup_run(0, 3, 1, 0, 0, 0, 5'b10010, 5'b00001);  // DDR3 build,  44 then 48
    shutup_run(0, 3, 1, 0, 1, 0, 5'b10010, 5'b00001);  // DDR3 build,  48 then 44
    // board 2 is the Toccata card in the DDR3 build (ZII RAM, ZIII RAM, Toccata)
    shutup_run(0, 3, 1, 0, 0, 2, 5'b00011, 5'b10000);
    shutup_run(0, 3, 1, 0, 1, 2, 5'b00011, 5'b10000);

    // ---- what gary.v would decode for the Toccata in all of the above
    $display("");
    $display("=== gary.v sel_toccata gating ===");
    $display(" %0d configurations checked.", tocc_checked);
    $display(" with board_configured[4] required : %0d open a window while the Toccata is unconfigured",
             tocc_bad_new);
    $display(" on autoconfig_done alone (old)    : %0d did -- a 64 KB window at $%02xxxxx, i.e. over chip RAM",
             tocc_bad_old, 8'h00);
    if (tocc_bad_new != 0)
      $display(" *** sel_toccata is still reachable without board_configured[4] ***");

    // ---- the third ZIII board, as the leftover SDRAM board and as the DDR3 one
    // Two things are checked.  The size the board advertises, which decides
    // how much memory the OS adds and therefore has to be 16 MB for the DDR3
    // board rather than the 2/4 MB the leftover board offers.  And the base:
    // the OS allocates it from its own free list, and minimig_autoconfig.v has
    // to latch exactly that value, because TG68K.vhd decodes the board against
    // it.  Assuming the base is what broke this board before -- the hardware
    // looked at $41000000 while the OS had placed it at $08000000.
    // Both write orderings matter: under 44,48 the trailing 48 write lands on
    // whatever device the chain has already moved to, so a base latched on the
    // 44 write must survive it.
    $display("");
    $display("=== the third ZIII board: size offered, and the base the OS assigns ===");
    $display("    fast=11, 020=1.  DDR3=1 is Z3RAM3_DDR3, i.e. the DDR3 fast RAM board.");
    $display("");
    $display(" DDR3 64meg slow wrorder | third ZIII board            | latched base | verdict");
    $display(" ---- ----- ---- ------- | --------------------------- | ------------ | -------");
    for (z3 = 0; z3 <= 1; z3 = z3 + 1) begin
      for (r64 = 0; r64 <= 1; r64 = r64 + 1) begin
        for (sr = 0; sr <= 1; sr = sr + 1) begin
          for (pol = 0; pol <= 1; pol = pol + 1) begin
            dsel           = z3 ? 2'd2 : 2'd1;
            fastram_config = 2'b11;
            slowram_config = sr[1:0];
            m68020         = 1'b1;
            ram_64meg      = r64[0];
            WRPOL          = pol;
            SHUTUP_IDX     = -1;
            do_reset();
            if (pol) s_order = " 48,44 "; else s_order = " 44,48 ";
            config_chain();

            // The DDR3 board is 16 MB and its linked size matches, so the OS
            // adds all of it.  The leftover board always occupies 4 MB (fixed
            // in the ROM) but links only the SDRAM actually spare, which is
            // what slowram_config decides and what the first ZIII board's
            // handler writes into the size nibble.
            if (z3) begin
              exp_size  = 64'h1000000;
              exp_lsize = 64'h1000000;
            end else begin
              exp_size  = 64'h400000;
              exp_lsize = (sr != 0) ? 64'h200000 : 64'h400000;
            end

            z3b_checked = z3b_checked + 1;
            if (!z3ram3_seen) begin
              s_verdict = "FAIL: board never offered";
              z3b_bad = z3b_bad + 1;
            end else if (z3ram3_alloc_size != exp_size) begin
              s_verdict = $sformatf("FAIL: size %s, expected %s",
                                    hsize(z3ram3_alloc_size), hsize(exp_size));
              z3b_bad = z3b_bad + 1;
            end else if (z3ram3_alloc_lsize != exp_lsize) begin
              s_verdict = $sformatf("FAIL: linked %s, expected %s",
                                    hsize(z3ram3_alloc_lsize), hsize(exp_lsize));
              z3b_bad = z3b_bad + 1;
            end else if (z3ram3_alloc_base[23:0] != 24'd0) begin
              // z3ram3_base carries A31-A24 only, so TG68K.vhd can only
              // compare on a 16 MB boundary.  Every ZIII base the OS hands
              // out is 16 MB aligned, which is what makes that enough -- but
              // it is an assumption about the OS's allocator, and assuming
              // where the OS puts this board is the bug this whole change
              // exists to fix.  So check it rather than trust it: if this
              // ever fires, the decode needs A23-A16 latched from the
              // register-48 write as well.
              s_verdict = $sformatf("FAIL: base $%08x is not 16 MB aligned",
                                    z3ram3_alloc_base[31:0]);
              z3b_bad = z3b_bad + 1;
            end else if (z3ram3_base_val() !== z3ram3_alloc_base[31:24]) begin
              s_verdict = $sformatf("FAIL: latched $%02x, OS used $%02x",
                                    z3ram3_base_val(), z3ram3_alloc_base[31:24]);
              z3b_bad = z3b_bad + 1;
            end else begin
              s_verdict = "OK";
            end

            if (z3ram3_seen)
              s_third = $sformatf("%3s phys, %3s linked @ $%08x",
                                  hsize(z3ram3_alloc_size), hsize(z3ram3_alloc_lsize),
                                  z3ram3_alloc_base[31:0]);
            else
              s_third = "        (never offered)     ";
            $display("   %0d     %0d    %02b  %s | %s |     $%02x      | %s",
                     z3, r64, sr[1:0], s_order, s_third, z3ram3_base_val(), s_verdict);
          end
        end
      end
    end
    $display("");
    $display(" %0d configurations checked, %0d bad.", z3b_checked, z3b_bad);
    if (z3b_bad != 0)
      $display(" *** the third ZIII board is not decodable from what the hardware latched ***");

    $finish;
  end

endmodule
