//============================================================================
//  Super Slams -- VS9209 (4L01F1429) 80-pin QFP I/O
//
//  Eight ports, each with a data latch and a direction register.  Direction 1
//  is OUTPUT, 0 is input; a read returns live inputs on the input bits ORed
//  with the latch on the output bits.  Port H is only four bits wide.
//
//  From references/upstream/mame/src/mame/vsystem/vs9209.cpp, which is
//  BSD-3-Clause.  Its header notes that the game programs always write zero to
//  the first direction register "except for Super Slams which doesn't write to
//  it at all" -- and that is confirmed here by measurement, not taken on
//  trust: over 900 frames offset 8 is never written.
//
//  Mapped at 0xFFF000-0xFFF01F with umask16(0x00FF), so the device sees only
//  the ODD byte of each word.  A decode that ignores that and writes on a word
//  access will write a port every time the game polls an input.
//
//  ---- what this board actually uses (MEASURED, docs/HARDWARE.md) ---------
//
//      A (0)   P1              read 879 times in 900 frames -- once a frame
//      B (1)   P2              read 879
//      C (2)   SYSTEM          read 879
//      D (3)   DSW1            read ONCE, at boot
//      E (4)   DSW2            read ONCE, at boot
//      G (6)   written 0x00 once a frame.  MAME connects no callback.
//              Coin counter?  Watchdog?  UNKNOWN -- HARDWARE H3.
//      H (7)   spr_ctrl.  NEVER WRITTEN in 900 frames, and MAME could not act
//              on it if it were, because the output callback only fires when
//              the direction register is non-zero and the one write to
//              offset F happens while the latch is still 0.  So the sprite/FG
//              layer order is fixed.  HARDWARE section 4.
//
//  THE DIPS ARE READ ONCE, AT BOOT.  Changing a DIP on the OSD therefore does
//  nothing until the core is reset.  That is the board's behaviour, not a
//  limitation of this module.
//
//  Writing a direction register also drives the port from its latch, if the
//  direction changed towards output -- vs9209.cpp:127.  That is how spr_ctrl
//  gets its initial 0 and it is reproduced here.
//============================================================================
`default_nettype none

module ss_io (
    input  wire        clk,
    input  wire        rst,

    // --- CPU, byte-wide on the ODD lane -----------------------------------
    input  wire        cs,
    input  wire        we,
    input  wire [3:0]  a,               // offset 0..15
    input  wire [7:0]  din,
    output wire [7:0]  dout,

    // --- inputs, all ACTIVE LOW -------------------------------------------
    input  wire [7:0]  p1,
    input  wire [7:0]  p2,
    input  wire [7:0]  system,
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2,

    // --- outputs ----------------------------------------------------------
    output wire [3:0]  port_h,          // spr_ctrl; bit 3 swaps sprites/FG
    output wire [7:0]  port_g,          // UNKNOWN -- HARDWARE H3
    output wire [7:0]  port_f
);

  reg [7:0] latch [0:7];
  reg [7:0] dir   [0:7];

  wire [2:0] port = a[2:0];
  wire       is_dir = a[3];

  // Port H is four bits wide; the device masks writes above that and logs
  // them.  We mask silently -- there is nowhere to log to.
  wire [7:0] wmask = (port == 3'd7) ? 8'h0F : 8'hFF;

  reg [7:0] live;
  always @(*) begin
    case (port)
      3'd0: live = p1;
      3'd1: live = p2;
      3'd2: live = system;
      3'd3: live = dsw1;
      3'd4: live = dsw2;
      // Ports F, G, H have no input source on this board.  vs9209.cpp returns
      // 0xFF from an unset input callback, and an undefined port reads as
      // input-high because it is pulled up.
      default: live = 8'hFF;
    endcase
  end

  // vs9209.cpp:78-92: live inputs on the bits configured as input, latched
  // data on the bits configured as output.  Port H reads only four bits.
  wire [7:0] in_mask = ~dir[port] & ((port == 3'd7) ? 8'h0F : 8'hFF);
  assign dout = is_dir ? 8'hFF                       // write-only: unmapped
                       : ((live & in_mask) | (latch[port] & dir[port]));

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      // device_reset clears the DIRECTIONS only; the latches are cleared once
      // at device_start.  Both are cleared here, which is the same thing from
      // power-on and differs only on a warm reset the board cannot do.
      for (i = 0; i < 8; i = i + 1) begin
        dir[i]   <= 8'h00;
        latch[i] <= 8'h00;
      end
    end else if (cs && we) begin
      if (is_dir) dir[port]   <= din & wmask;
      else        latch[port] <= din & wmask;
    end
  end

  assign port_h = latch[7][3:0] & dir[7][3:0];
  assign port_g = latch[6]      & dir[6];
  assign port_f = latch[5]      & dir[5];

endmodule

`default_nettype wire
