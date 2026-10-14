//============================================================================
//  Super Slams -- let the video timing outlive the board's reset
//
//  MiSTer holds RESET high for the whole ROM download, and until now that held
//  ss_crtc too, so the core put out no hsync, no vsync and no pixel enable for
//  the whole load.  The loading bar is drawn by the framework's OSD, which
//  counts lines and pixels of the video it is handed (sys/osd.v works from
//  de_in / hs_in / vs_in); with no raster it has nothing to draw on, and an
//  analog monitor gets no sync at all.  HDMI is saved by the scaler, which
//  makes its own timing.  Reported on a CRT, 2026-10-14.
//
//  So the raster (ss_pixen + ss_crtc + the sync/blank output pipe) runs from
//  PLL lock on, through any RESET.  Two outputs:
//
//    rstc   the reset the REST of the core sees: `rst` stretched by one clock
//    vrst   the reset the raster sees: ~pll_locked, plus ONE clock on the clock
//           the board's reset is released
//
//  Why the stretch.  At the clock `rst` falls, the raster is still on whatever
//  phase it free-ran to, and a layer engine released on that same clock would
//  see a hsync that is about to be forced low -- a falling edge it would load
//  a line on.  Holding the core one clock longer than `rst`, and restarting the
//  raster on that clock, makes both come out of reset on the SAME clock with
//  the raster at counter 0 and hsync low -- exactly the state they came out of
//  reset in when the raster was simply held.  sim/tb_ss_vidrst.sv compares the
//  two cycle for cycle.
//
//  The raster is NOT restarted when `rst` rises, so a user Reset or the start
//  of a load does not interrupt the picture.
//============================================================================
`default_nettype none

module ss_vrst (
    input  wire clk,
    input  wire rst,
    input  wire pll_locked,
    output wire rstc,
    output wire vrst
);

  reg rst_q = 1'b1;
  always @(posedge clk) rst_q <= rst;

  assign rstc = rst | rst_q;
  assign vrst = ~pll_locked | (rst_q & ~rst);

endmodule

`default_nettype wire
