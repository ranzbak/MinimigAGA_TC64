// Checks the host bridge's req/ack bus contract every cycle (Global Constraints):
//   - the master holds req, addr, q, sel, wr stable until it samples ack = 1
//     ("req dropped before ack", "signal change while req")
//   - ack only while req is high ("ack without req"), one cycle per
//     transaction ("ack held")
//   - no X on a request, on write data, or on read data in the ack cycle
//   - sel != 0 on every request
// Each violation prints "=== BUS VIOLATION <what> ..." and sets violation;
// the bench then ends the run as a failure.
module bus_checker (
  input  wire        clk,
  input  wire        rst,
  input  wire        req,
  input  wire        ack,
  input  wire        wr,
  input  wire [31:2] addr,
  input  wire [31:0] q,
  input  wire [3:0]  sel,
  input  wire [31:0] d,
  output reg         violation
);
  reg        p_req, p_ack, p_wr;
  reg [31:2] p_addr;
  reg [31:0] p_q;
  reg [3:0]  p_sel;
  reg [63:0] cycle;
  integer    nreq;

  task viol(input [8*40-1:0] what);
    begin
      $display("=== BUS VIOLATION %0s cycle %0d: req=%b ack=%b wr=%b addr=%08x q=%08x sel=%b (prev req=%b ack=%b wr=%b addr=%08x q=%08x sel=%b)",
               what, cycle, req, ack, wr, {addr, 2'b00}, q, sel,
               p_req, p_ack, p_wr, {p_addr, 2'b00}, p_q, p_sel);
      violation <= 1'b1;
    end
  endtask

  always @(posedge clk) begin
    if (rst) begin
      p_req <= 1'b0; p_ack <= 1'b0; p_wr <= 1'b0; p_addr <= 30'h0;
      p_q <= 32'h0; p_sel <= 4'h0; violation <= 1'b0; cycle <= 64'd0;
      nreq <= 0;
    end else begin
      cycle <= cycle + 64'd1;
      if (req === 1'bx || ack === 1'bx)               viol("X on req/ack");
      if (ack && !req)                                viol("ack without req");
      if (ack && p_ack)                               viol("ack held");
      if (p_req && !p_ack && !req)                    viol("req dropped before ack");
      if (p_req && !p_ack && req &&
          (addr !== p_addr || q !== p_q || sel !== p_sel || wr !== p_wr))
                                                      viol("signal change while req");
      if (req && ^{addr, sel, wr} === 1'bx)           viol("X on request");
      if (req && wr && ^q === 1'bx)                   viol("X on write data");
      if (req && sel == 4'h0)                         viol("sel = 0");
      if (ack && !wr && ^d === 1'bx)                  viol("X on read data");
      if (req && (!p_req || p_ack)) nreq <= nreq + 1;
      p_req <= req; p_ack <= ack; p_wr <= wr; p_addr <= addr; p_q <= q; p_sel <= sel;
    end
  end
endmodule
