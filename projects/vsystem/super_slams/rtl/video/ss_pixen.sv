//============================================================================
//  Super Slams -- pixel clock enable, with a line-locked phase
//
//  The pixel clock is 14.31818 MHz / 2 = 7.159090 MHz, and the core runs at
//  48 MHz, so one pixel is 2112/315 = 6.7048 core clocks.  A clock enable can
//  only land on a whole clock, so the gaps between enables are 6 or 7 clocks
//  (70 % are 7, measured by running this accumulator).
//
//  WHY THE PHASE IS RESET ONCE A LINE.  On an HDMI picture that does not
//  matter: the scaler samples a pixel when its enable fires and never looks at
//  how long the enable took.  On the ANALOG output it does: video_mixer holds
//  each pixel for as long as its enable lasted (video_mixer.sv: VGA_R/G/B
//  change only `if (CE_PIXEL)`), so a 6-clock pixel and a 7-clock pixel are
//  literally different widths on the screen, and where they fall decides where
//  every vertical edge lands.
//
//  A free-running accumulator makes a line 456 x 6.7048 = 3057.37 clocks, so
//  the 6/7 pattern starts 0.37 clocks later on every line, and the frame is
//  801,031.3 clocks so it starts differently on every frame.  A vertical edge
//  therefore wobbles by up to one core clock (20.8 ns, 15 % of a pixel) from
//  line to line AND from frame to frame, which is the fine, moving shimmer on
//  a still picture that was reported on a CRT (2026-10-14; HDMI was clean).
//
//  Restarting the accumulator from the same value at the end of every line
//  makes a line an INTEGER number of clocks, 3057, identical every time.  Then
//  every column has the same width on every line and every frame, so the same
//  edge sits at the same place and nothing moves.  The columns are still not
//  perfectly even (some 6 clocks wide, some 7, at most 1.3 clocks off a uniform
//  ramp) but that is a fixed geometry, not a shimmer.
//
//  What it costs: the line is 3057 clocks instead of 3057.37, i.e. 15701.7 Hz
//  and a 59.9300 Hz frame instead of 59.9296 Hz.  Nothing in the core can see
//  that -- every consumer works off this enable or off vblank_start.
//
//  PHASE0 = 244 is not magic: of the 315 possible restart values 198 give a
//  3057-clock line and 117 give 3058; among the 3057 ones 244 has (jointly,
//  with 245) the smallest deviation of any pixel column from a uniform ramp
//  (1.30 clocks).  sim/tb_ss_pixen.sv proves the line length for THIS value.
//
//  `hcnt` is ss_crtc's counter.  The enable on which it is H_TOTAL-1 is the last
//  pixel of the line; ss_crtc wraps it to 0 on that same enable, so restarting
//  from PHASE0 on that clock is "the first gap of the next line".  After reset
//  the accumulator holds PHASE0 and hcnt is 0, which is the same state, so the
//  first line after a restart is no different from any other.
//============================================================================
`default_nettype none

module ss_pixen #(
    parameter int H_TOTAL = 456,
    parameter int PHASE0  = 244
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [8:0] hcnt,
    output reg        ce_pix
);

  localparam int ADD = 315;
  localparam int MOD = 2112;

  reg  [11:0] pixacc;

  wire        last_px = ce_pix && (hcnt == 9'(H_TOTAL - 1));
  wire [11:0] base    = last_px ? 12'(PHASE0) : pixacc;
  wire [11:0] sum     = base + 12'(ADD);

  always @(posedge clk) begin
    if (rst) begin
      pixacc <= 12'(PHASE0);
      ce_pix <= 1'b0;
    end else if (sum >= 12'(MOD)) begin
      pixacc <= sum - 12'(MOD);
      ce_pix <= 1'b1;
    end else begin
      pixacc <= sum;
      ce_pix <= 1'b0;
    end
  end

endmodule

`default_nettype wire
