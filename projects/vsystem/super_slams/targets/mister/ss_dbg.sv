//============================================================================
//  Super Slams -- debug overlay
//
//  Sixteen 16-bit values, drawn as SIXTEEN CELLS PER ROW, one BIT each, bit 15
//  leftmost, four pixel rows per row of cells with a one-pixel gutter.
//
//  That encoding is deliberately identical to the three sibling lanes.  Root
//  CLAUDE.md section 9 and power_spikes/docs/FACTORY_REUSE.md section 3: the
//  ENCODING is the reusable asset, the rows are not.  Keeping it identical
//  means tools/read_overlay.py is nearly the same file for every board here,
//  and a screenshot from one lane can be read by anyone who has read another.
//
//  Bits, not hex digits, because a photograph of a CRT has to survive being
//  read by a script: a 4x5 hex glyph does not, and a 6-pixel-wide filled or
//  empty cel does.
//
//  Pages exist because sixteen rows at four pixels is 64 lines of a 224-line
//  screen, and comparing the picture against a MAME frame needs the picture.
//  Four rows a page, 16 lines, leaves 208.
//============================================================================
`default_nettype none

module ss_dbg #(
    parameter int H_VISIBLE = 320,
    parameter int V_START   = 8,     // first line of the overlay
    parameter int ROW_H     = 4,     // pixel rows per cel row
    parameter int CELL_W    = 6,     // pixels per cel
    parameter int GUTTER    = 1
) (
    input  wire        clk,
    input  wire        ce_pix,
    input  wire        enable,
    input  wire [1:0]  page,

    // The CRTC's own counters, straight through.  NOT reconstructed locally.
    //
    // The first version rebuilt x and y here from hsync/vblank edges, on the
    // argument that this module sits after the video pipeline's two-pixel
    // delay.  It reset `y` on the vblank RISING edge -- the start of blanking
    // -- so by the first visible line y had already counted the 38 blanking
    // lines, and the whole overlay was drawn INSIDE vertical blanking where
    // nothing can see it.  Zero pixels on screen, and no way to tell that from
    // "the overlay is switched off".
    //
    // The two-pixel offset it was correcting for is invisible in an overlay.
    // Reconstructing a counter that already exists is how it got a chance to
    // be wrong.  DEBUG_LOG O7.
    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,

    input  wire [7:0]  in_r, in_g, in_b,
    output reg  [7:0]  out_r, out_g, out_b,

    input  wire [15:0] d00, d01, d02, d03,
    input  wire [15:0] d04, d05, d06, d07,
    input  wire [15:0] d08, d09, d10, d11,
    input  wire [15:0] d12, d13, d14, d15
);

  wire [8:0] x = hcnt;
  wire [8:0] y = vcnt;

  // ---- which cell, if any ------------------------------------------------
  wire [8:0] ry = y - 9'(V_START);
  wire [3:0] row_in_page = ry[5:2];              // 4 pixel rows per cel row
  wire       row_ok = (y >= 9'(V_START)) && (ry < 9'(4 * ROW_H));
  wire       pix_ok = (ry[1:0] != 2'd3);         // bottom pixel row is gutter

  // `cell` is a RESERVED KEYWORD in SystemVerilog (config declarations) and
  // Quartus rejects it as an identifier.  Verilator does not, so this only
  // showed up 20 seconds into the first synthesis.
  // NINE BITS, NOT FIVE, AND THE TRUNCATION PAINTED A SECOND COPY.
  //
  // x is hcnt, 0..455, so x / 6 reaches 75.  Narrowed to five bits that wraps:
  // x = 192..287 gives 32..47, truncated to 0..15, `cel < 16` is true again
  // and THE WHOLE OVERLAY IS DRAWN A SECOND TIME across the middle of the
  // screen.
  //
  // It cost most of an afternoon.  The 20-minute trace ran with the debug MRA,
  // its captures went into a contact sheet beside ordinary ones, and the
  // second copy landed on the in-game scoreboard -- which was then chased as a
  // rendering fault through a MAME comparison, a cache theory, a bank theory
  // and a whole new golden model for the FG layer.  The same scoreboard with
  // the overlay OFF is pixel-clean.
  //
  // A debug instrument that paints over the picture has to be certain where it
  // paints, or it becomes the thing being debugged.
  wire [8:0] cel9   = x / CELL_W[8:0];
  wire [4:0] cel    = cel9[4:0];
  wire [8:0] in_cel = x % CELL_W[8:0];
  wire       cel_ok = (cel9 < 9'd16) && (in_cel < 9'(CELL_W - GUTTER));

  // Row index within the whole table: page selects a block of four.
  wire [3:0] row = {page, row_in_page[1:0]};

  reg [15:0] val;
  always @(*) begin
    case (row)
      4'd0:  val = d00;  4'd1:  val = d01;  4'd2:  val = d02;  4'd3:  val = d03;
      4'd4:  val = d04;  4'd5:  val = d05;  4'd6:  val = d06;  4'd7:  val = d07;
      4'd8:  val = d08;  4'd9:  val = d09;  4'd10: val = d10;  4'd11: val = d11;
      4'd12: val = d12;  4'd13: val = d13;  4'd14: val = d14;  default: val = d15;
    endcase
  end

  // bit 15 leftmost
  wire bit_set = val[4'd15 - cel[3:0]];
  wire draw    = enable && row_ok && pix_ok && cel_ok;

  always @(posedge clk) if (ce_pix) begin
    if (draw) begin
      // A set bit is white, a clear bit is dark blue.  Not black: a black cel
      // and "the overlay is not being drawn at all" would look the same, and
      // this factory has read a blank screen as data more than once.
      out_r <= bit_set ? 8'hFF : 8'h00;
      out_g <= bit_set ? 8'hFF : 8'h00;
      out_b <= bit_set ? 8'hFF : 8'h60;
    end else begin
      out_r <= in_r;
      out_g <= in_g;
      out_b <= in_b;
    end
  end

endmodule

`default_nettype wire
