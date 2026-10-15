//============================================================================
//  Super Slams -- video top: CRTC, the three layers, the mixer and the palette
//
//  Layer order, from suprslam.cpp:236-249:
//
//      black fill
//      BG through the 053936          opaque, bottom
//      if !(spr_ctrl & 8)  sprites
//      FG "screen" tilemap            transparent pen 15
//      if  (spr_ctrl & 8)  sprites
//
//  The game's VS9209 G[3] selects the swap: 0 during gameplay (HUD on top),
//  1 during ranking (score sprites above FG portraits). MAME connects H instead
//  and never sees the swap. ss_main supplies the actual G outputs; DEBUG_LOG O19.
//
//  ---- the palette is xGBR555, NOT xRGB555 ------------------------------
//
//  suprslam.cpp:456.  Green is [14:10], BLUE is [9:5], red is [4:0].  Power
//  Spikes is xRGB and this is the same factory, so the temptation to copy that
//  line across is real; swapping green and blue produces a picture that looks
//  like a palette ROM fault rather than like a decode fault.
//
//  ---- the raster totals are INFERRED, and that is not the same as MATCHED --
//
//  TODO(HARDWAREIZE): H_TOTAL 456 / V_TOTAL 262 and the 38-line vblank are
//  accuracy = EMULATION_DERIVED, leaning on values MAME itself does not
//  claim.  suprslam.cpp asks for set_refresh_hz(60) and set_vblank_time(2300
//  us) with a `hand-tuned` comment (UPSTREAM_TODO_AUDIT U7), and set_size is
//  512x512 -- a bitmap, not a raster.  456x262 is the standard NTSC-ish total
//  that makes the visible 320x224 and the pixel clock work out; no PCB
//  measurement of this board's CRTC exists.  The picture is correct and 262
//  lines per frame is confirmed on hardware, but that confirms OUR CRTC, not
//  the PCB's.
//
//  Each layer renders one line AHEAD into a double buffer, so the mixer is a
//  pure lookup with no deadlines: three reads, one compare, one palette
//  fetch.  That is a different architecture from the sibling lane, where the
//  tilemap fetched just in time against a 39-clock deadline, and it is the
//  reason this core has no equivalent of that lane's O11/O18/O19.
//============================================================================
`default_nettype none

module ss_video #(
    parameter int H_TOTAL   = 456,
    parameter int H_VISIBLE = 320,
    parameter int V_TOTAL   = 262,
    parameter int V_VISIBLE = 224
) (
    input  wire        clk,
    // `rst` holds the layer engines and the colour output.  `vrst` holds ONLY
    // the raster (ss_crtc and the sync/blank output pipe), which keeps running
    // through the board's reset so the OSD loading bar has a picture to be drawn
    // on -- ss_vrst.sv.  Both come out of reset on the same clock.
    input  wire        rst,
    input  wire        vrst,
    input  wire        ce_pix,

    // --- CRTC out ---------------------------------------------------------
    output wire [8:0]  hcnt,
    output wire [8:0]  vcnt,
    output wire        hblank,
    output wire        vblank,
    output wire        hsync,
    output wire        vsync,
    output wire        vsync_ahead,      // the 053936's vsync: ss_crtc header
    output wire        vblank_start,
    output wire        line_start,

    // --- per-line render trigger, one clock at the start of every line ----
    output reg         render_start,
    output reg  [8:0]  render_line,

    // --- layer line-buffer read ports -------------------------------------
    output wire        lb_par,
    output wire [8:0]  lb_x,
    input  wire [7:0]  roz_q,
    input  wire [7:0]  fg_q,
    input  wire [10:0] spr_q,

    // --- palette RAM read port --------------------------------------------
    output reg  [10:0] pal_addr,
    input  wire [15:0] pal_data,

    input  wire        spr_above_fg,     // VS9209 port G bit 3

    // --- pixel out --------------------------------------------------------
    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue,
    output reg         hs, vs, hb, vb,

    // Lines actually STARTED, PER FRAME.  Expect exactly V_TOTAL = 262.
    // Zero means no layer has ever been asked to render, which the overrun
    // counters cannot distinguish from health -- and did not, for four rounds
    // of hardware measurement.  A per-frame count has a known right answer; a
    // cumulative one only has "rising", which is the weaker claim.
    output reg  [15:0] dbg_render_cnt
);

  wire ls_raw, vbs_raw;
  ss_crtc #(
      .H_TOTAL(H_TOTAL), .H_VISIBLE(H_VISIBLE),
      .V_TOTAL(V_TOTAL), .V_VISIBLE(V_VISIBLE)
  ) u_crtc (
      .clk(clk), .rst(vrst), .ce_pix(ce_pix),
      .hcnt(hcnt), .vcnt(vcnt),
      .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
      .vsync_ahead(vsync_ahead),
      .visible(), .vblank_start(vbs_raw), .line_start(ls_raw)
  );

  // The raster now runs while the rest of the core is held, so its pulses are
  // masked by `rst`: every consumer of line_start / vblank_start (render
  // trigger, vblank interrupt, the arbiter's per-line statistics, the sound and
  // SDRAM frame counters) was written for a CRTC that never pulses during a
  // reset, and must not see one.  They are registered one clock after the ce
  // that made them, so the mask is on the same clock they are used.
  assign line_start   = ls_raw  & ~rst;
  assign vblank_start = vbs_raw & ~rst;

  // ---- one line ahead ----------------------------------------------------
  //
  // Every layer renders line V+1 while line V is displayed, so the parity of
  // the buffer being DISPLAYED is vcnt[0] and the parity being written is
  // vcnt[0] ^ 1 -- which is render_line[0], since render_line = vcnt + 1.
  wire [8:0] next_line = (vcnt == 9'(V_TOTAL - 1)) ? 9'd0 : (vcnt + 9'd1);
  reg [15:0] acc_render;

  // `line_start` is ALREADY a one-clock pulse, and it is NOT a ce_pix clock.
  //
  // ss_crtc sets it inside its own `if (ce_pix)`, as a registered output, so
  // it is high during the clock AFTER the ce_pix that produced it -- and at
  // 48 MHz with a 7.16 MHz pixel enable, the clock after a ce_pix is never
  // itself a ce_pix.  Qualifying it here with `ce_pix &&` therefore made the
  // condition UNSATISFIABLE: render_start never fired, no layer ever rendered
  // a single line, and the whole screen was one palette entry for the life of
  // the core.
  //
  // Every other consumer of line_start and vblank_start in this core uses the
  // pulse directly, which is why the vblank interrupt worked perfectly while
  // the video did nothing.  This was the only place that added the qualifier.
  //
  // What made it expensive to find: the per-layer OVERRUN counters all read 0
  // and were taken as "every layer finishes every line".  They mean "no layer
  // was still busy when the next start arrived" -- which is also true when no
  // start ever arrives.  dbg_render_cnt below removes that ambiguity: it
  // counts the starts themselves, so zero cannot be read as health.
  always @(posedge clk) begin
    render_start <= 1'b0;
    if (rst) begin
      render_line <= 9'd0;
      dbg_render_cnt <= 16'd0;
      acc_render     <= 16'd0;
    end else begin
      if (line_start) begin
        render_line  <= next_line;
        render_start <= 1'b1;
        acc_render   <= acc_render + 16'd1;
      end
      if (vblank_start) begin
        dbg_render_cnt <= acc_render + (line_start ? 16'd1 : 16'd0);
        acc_render     <= 16'd0;
      end
    end
  end

  assign lb_par = vcnt[0];
  assign lb_x   = hcnt;

  // ---- the mixer ---------------------------------------------------------
  //
  // Which layer owns the pixel.  The FG layer's hole is pen 15 and NOT pen 0
  // (suprslam.cpp:200), the BG layer has no hole at all, and the sprite layer
  // carries its own opaque bit because it is sparse.
  wire       fg_solid  = (fg_q[3:0] != 4'hF);
  wire       spr_solid = spr_q[10];

  reg [10:0] idx;
  always @(*) begin
    if (spr_above_fg) begin
      if      (spr_solid) idx = 11'h200 + {1'b0, spr_q[9:0]};
      else if (fg_solid)  idx = {3'b000, fg_q};
      else                idx = 11'h100 + {3'b000, roz_q};
    end else begin
      if      (fg_solid)  idx = {3'b000, fg_q};
      else if (spr_solid) idx = 11'h200 + {1'b0, spr_q[9:0]};
      else                idx = 11'h100 + {3'b000, roz_q};
    end
  end

  // TWO stages, and the count matters.  Walk one pixel through:
  //
  //   ce N     hcnt becomes X.  lb_x is combinational from hcnt, and the line
  //            buffers are clocked on `clk` (not ce_pix), so their registered
  //            outputs settle to pixel X's data within one 48 MHz clock --
  //            long before the next ce_pix.
  //   ce N+1   pal_addr <= idx(X), and the flags for X are captured into d1.
  //            The palette RAM then settles, again on `clk`.
  //   ce N+2   the colour of X is registered out, gated by d1 -- which holds
  //            X's blanking -- and hs/vs/hb/vb take d1 as well.
  //
  // So the colour and the flags both describe pixel X at ce N+2.  A third
  // stage would put the flags a pixel behind the picture, which shows up as
  // one wrong column at each edge of the active area and as an image offset
  // by one against MAME -- small enough to be blamed on the CRTC totals,
  // which are themselves inferred (HARDWARE section 7) and would then get
  // "corrected" to compensate.
  reg hs_d1, vs_d1, hb_d1, vb_d1;

  // The colour is held at black by `rst` -- during a reset the picture is a
  // black raster with sync, which is what the loading bar is drawn on.
  always @(posedge clk) begin
    if (rst) begin
      red <= 8'd0; green <= 8'd0; blue <= 8'd0;
    end else if (ce_pix) begin
      pal_addr <= idx;

      // xGBR555.  The top bits are replicated into the low bits so that
      // 5'b11111 becomes 8'hFF rather than 8'hF8 -- otherwise white is dim.
      red   <= (hb_d1 | vb_d1) ? 8'd0 : {pal_data[ 4: 0], pal_data[ 4: 2]};
      green <= (hb_d1 | vb_d1) ? 8'd0 : {pal_data[14:10], pal_data[14:12]};
      blue  <= (hb_d1 | vb_d1) ? 8'd0 : {pal_data[ 9: 5], pal_data[ 9: 7]};
    end
  end

  // The sync / blank pipe follows the raster, so it is held by `vrst` and NOT
  // by `rst`.  (It was not reset at all before, which left hs/vs frozen at
  // their last value for the whole of any reset.)
  always @(posedge clk) begin
    if (vrst) begin
      {hs_d1, vs_d1, hb_d1, vb_d1} <= 4'b0;
      {hs,    vs,    hb,    vb   } <= 4'b0;
    end else if (ce_pix) begin
      {hs_d1, vs_d1, hb_d1, vb_d1} <= {hsync, vsync, hblank, vblank};
      {hs,    vs,    hb,    vb   } <= {hs_d1, vs_d1, hb_d1, vb_d1};
    end
  end

endmodule

`default_nettype wire
