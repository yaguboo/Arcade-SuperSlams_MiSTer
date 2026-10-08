//============================================================================
//  Super Slams -- video timing
//
//  docs/HARDWARE.md section 7 has the derivation and its evidence tags, and
//  says plainly that this is the weakest part of the board description.
//
//      pixel clock  7.159090 MHz   = 14.31818 / 2   divider UNVERIFIED
//      H total      456                             INFERRED
//      V total      262                             INFERRED
//      visible      320 x 224      MAME visarea     EMULATION-DERIVED
//      refresh      59.93 Hz       vs MAME's 60     EMULATION-DERIVED
//
//  MAME uses set_size/set_visarea and NOT set_raw, so there is no
//  hardware-derived raster in MAME at all -- the totals below are arithmetic
//  that lands on 60 Hz and on the standard 15.70 kHz line rate using the PCB's
//  own 14.31818 MHz crystal, which the parts list places next to VS920D and
//  the 053936.  Three numbers that were not fitted to each other agree to 5 %:
//  262 - 224 = 38 blank lines is 2417 us of vblank against the 2300 us MAME
//  calls "hand-tuned".
//
//  THIS IS LOAD-BEARING.  The per-line SDRAM budget in HARDWARE section 8
//  rests on 3053 core clocks per line, which is 48 MHz / (60 x 262).  If the
//  picture rolls on hardware or the frame rate is wrong, re-derive this first
//  and re-check that budget -- do not start by tuning a sprite engine.
//
//  The alternatives considered, both of which also give ~60 Hz and neither of
//  which anything on the PCB sheet rules out: 24 MHz / 4 with H total 384
//  (a more typical 83 % active line), and 32 MHz / 4 with H total 512.
//
//  ---- sync positions: set by the 053936, not by the scaler ----------------
//
//  Until 2026-10-06 these were guesses that only moved the picture in the
//  scaler window (360/36, 232/3).  They are now load-bearing: ss_psac drives
//  jt053936 from THESE hsync / vsync pins, and the chip's counters start at
//  their falling edges, so the sync positions decide which source pixel lands
//  on screen column 0 and on line 0.
//
//  What sets them is the GAME.  At 1:1 and unscrolled it programs
//  ctrl[00] = FE98 and ctrl[01] = FF58 (HARDWARE 6.1): X start -45 pixels and
//  Y start -21 lines (start register / 8 at step 0x0800), and it fills the
//  line RAM from entry 21 = ctrl[0E] (0001) + 20 for screen line 0.  It is
//  written for a raster in which the first visible pixel is the 45th pixel
//  clock after the counter loads and the first visible line is the 21st
//  hsync after vsync.  MAME reaches the same picture with set_offsets(-45,
//  -21); here the raster does it and the chip runs with offsets 0.
//
//    hsync falls at hcnt 406.  jt053936 loads its line start 4 cens after the
//          falling edge it samples (2 for the edge, 1 for tick_hs, 1 for the
//          counter's hs_l), its x pins are one cen behind the accumulator,
//          and ss_psac records the pins against the hcnt they are shown at:
//          406 + 4 + 1 + 45 = 456 = column 0 of the next line.  Measured,
//          not only counted: sim/tb_ss_psac_golden.sv, 0 mismatches, and
//          405/407 both fail (MUTANT=hs).
//    vsync changes at the END of hsync (jtframe_vtimer does the same), so
//          its falling edge and hsync's land on the same pixel enable.  That
//          coincidence is REQUIRED, not cosmetic: jt053936 resolves a
//          simultaneous vs+hs tick as "load the frame base AND fetch line-RAM
//          entry ln0", and only then do simple mode (base + k*vstep) and
//          per-line mode (entry ln0 + k - 1) agree on the same line k with
//          the game's own ln0 = 1.  An edge one pixel apart moves one mode a
//          line against the other (MUTANT=vsedge).
//    vsync falls at the hsync end of line 240: 21 hsyncs later is the hsync
//          on line 261 that loads line 0.  V_SYNC_ON 237 for a 3-line pulse.
//
//  Widths (36 pixels = 5.0 us, 3 lines) are still UNVERIFIED and still only
//  matter to the monitor.  vsync_ahead is the same vsync one line early for
//  the chip -- ss_psac's header says why the chip runs a line ahead.
//============================================================================
`default_nettype none

module ss_crtc #(
    parameter int H_TOTAL   = 456,
    parameter int H_VISIBLE = 320,
    parameter int H_SYNC_ON = 370,   // falling edge 406: header
    parameter int H_SYNC_W  = 36,    // UNVERIFIED  (~5.0 us)
    parameter int V_TOTAL   = 262,
    parameter int V_VISIBLE = 224,
    parameter int V_SYNC_ON = 237,   // falling edge line 240: header
    parameter int V_SYNC_W  = 3      // UNVERIFIED
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    output reg  [8:0]  hcnt,
    output reg  [8:0]  vcnt,
    output reg         hblank,
    output reg         vblank,
    output reg         hsync,
    output reg         vsync,
    // vsync one line early, same pixel position -- the 053936's vsync pin
    output reg         vsync_ahead,
    output wire        visible,

    // one ce_pix-wide pulse at the first pixel of the first blanked line
    output reg         vblank_start,
    // one ce_pix-wide pulse at the start of every line
    output reg         line_start
);

  assign visible = ~hblank & ~vblank;

  always @(posedge clk) begin
    vblank_start <= 1'b0;
    line_start   <= 1'b0;

    if (rst) begin
      hcnt   <= 9'd0;
      vcnt   <= 9'd0;
      hblank <= 1'b0;
      vblank <= 1'b0;
      hsync  <= 1'b0;
      vsync  <= 1'b0;
      vsync_ahead <= 1'b0;
    end else if (ce_pix) begin
      if (hcnt == H_TOTAL - 1) begin
        hcnt       <= 9'd0;
        line_start <= 1'b1;
        if (vcnt == V_TOTAL - 1) vcnt <= 9'd0;
        else                     vcnt <= vcnt + 9'd1;
      end else begin
        hcnt <= hcnt + 9'd1;
      end

      // Blanking and sync are decoded from the *next* counter value so the
      // flags line up with the pixel they belong to.
      begin : decode
        reg [8:0] nh, nv, na;
        nh = (hcnt == H_TOTAL - 1) ? 9'd0 : hcnt + 9'd1;
        nv = (hcnt == H_TOTAL - 1)
             ? ((vcnt == V_TOTAL - 1) ? 9'd0 : vcnt + 9'd1)
             : vcnt;
        na = (nv == V_TOTAL - 1) ? 9'd0 : nv + 9'd1;

        hblank <= (nh >= H_VISIBLE);
        vblank <= (nv >= V_VISIBLE);
        hsync  <= (nh >= H_SYNC_ON) && (nh < H_SYNC_ON + H_SYNC_W);
        // vsync moves only where hsync falls, so the two falling edges are
        // the same pixel enable (header).
        if (nh == 9'(H_SYNC_ON + H_SYNC_W)) begin
          vsync       <= (nv >= V_SYNC_ON) && (nv < V_SYNC_ON + V_SYNC_W);
          vsync_ahead <= (na >= 9'(V_SYNC_ON)) && (na < 9'(V_SYNC_ON + V_SYNC_W));
        end

        if (nv == V_VISIBLE && nh == 0) vblank_start <= 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
