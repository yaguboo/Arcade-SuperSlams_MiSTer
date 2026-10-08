//============================================================================
//  Super Slams -- KONAMI 053936 "PSAC2" coordinate generator
//
//  The 053936 has no tilemap of its own.  It generates one (x, y) source
//  coordinate per displayed pixel and the board's own tilemap hardware --
//  VS920D here -- looks it up.  The chip is jotego's jt053936
//  (third_party/video/jt053936, GPL-3.0-or-later, vendored UNMODIFIED --
//  DECISIONS D3, revised 2026-10-06).  This file owns what the vendored chip
//  does not: the line RAM (the 053936 only addresses an EXTERNAL line RAM),
//  the CPU ports, and the hand-over of the chip's output pins to ss_roz.
//
//  ---- how the chip is driven: the real raster, one line early -------------
//
//  As on the PCB and as jtcores wires it (jtprmr_psac.v, jtriders_psac.v):
//  cen is the pixel clock enable, hs is ss_crtc's hsync, vs is ss_crtc's
//  vsync.  Nothing here generates a pulse of its own.  The chip's counters,
//  its line-RAM DMA and its line/frame loads all run off those pins.
//
//  With ONE difference, and it is a fixed one: vs is `vsync_ahead`, the same
//  vsync one line early, so the chip computes line L+1 while line L is on
//  screen.  ss_roz renders every line one ahead into its double line buffer
//  (ss_video's architecture: three layers, no per-pixel deadlines), so line
//  L+1's coordinates are needed during line L.  Driven on time, the chip would
//  produce them during line L+1 -- too late for a renderer that has already
//  filled the buffer.  hs and cen are not changed at all: a line is the same
//  length, so "one line early" is exactly the vertical counter plus one.
//
//  The other ways considered:
//    * two lines early with a double coordinate buffer -- no throttle in
//      ss_roz, but the chip would read the CPU's registers one line earlier
//      than the renderer used to, and it costs a second buffer;
//    * on time, with a recorded copy of line N's coordinates -- the copy is
//      complete only at the end of line N, a line after ss_roz needed it.
//  One line early keeps the chip's register reads at the same moment as the
//  virtual-raster version they replace (the job for line L+1 ran during L).
//
//  ---- the hand-over: a line of the chip's output pins ---------------------
//
//  The chip emits a coordinate every pixel enable, in real time.  ss_roz
//  consumes them at its own pace, stalling on SDRAM.  So the pins x / y are
//  RECORDED against the hcnt they belong to -- `cbuf[hcnt] <= {y, x}` on
//  each pixel enable for hcnt 0..319 -- and ss_roz reads the record.  It may
//  read entry n only after it was written: `src_ok`.  Because the chip writes
//  entry c at hcnt c of the same line ss_roz renders in, ss_roz can never be
//  more than a line behind and needs no second buffer; when it is faster than
//  the chip it simply trails it by a pixel or two.
//
//  The record is cleared (wr_cnt = 0) at the last pixel of every line, so a
//  new job cannot read the previous line's entries.  A job still unfinished
//  then is an overrun by ss_roz's own definition -- the next start is two
//  clocks away.
//
//  ---- alignment: the raster, not constants ----------------------------------
//
//  XOFFSET / YOFFSET are 0 and register 0x0E is the game's own (0001).  The
//  -45 / -21 that MAME applies (suprslam.cpp:460 set_offsets) are the same
//  45 pixel clocks and 21 lines that the game itself programs into ctrl[00] /
//  ctrl[01] at rest (FE98 / FF58, HARDWARE 6.1); on this core they are WHERE
//  ss_crtc's syncs fall, which its header derives and the golden bench
//  measures.  The chip's own pixel/line counters (hcnt0 / vcnt0, registers
//  0x0C / 0x0D) drive only its window logic, i.e. ob -- see below.
//
//  TODO(HARDWAREIZE): the sync positions are the ones that make the game's
//  registers land where MAME does.  The PCB's own are unmeasured; a capture of
//  the 053936's NHSY / NVSY against the video would close it.
//
//  ---- fixed point --------------------------------------------------------
//
//  MAME k053936.cpp builds 16.16 values: start = (256*v) << 5 = v << 13,
//  step = s << 5 (s*256 << 5 with an x256 flag).  jt053936_counter keeps a
//  24-bit accumulator with start = {v, 8'd0} = v << 8 and step = s (s << 8
//  with the flag): EXACTLY MAME's value >> 5.  The source pixel is MAME
//  (v >> 16) & 0x3FF = jt cnt[20:11] = x[9:0].
//
//  ---- line-RAM DMA timing --------------------------------------------------
//
//  Port B of the line RAM is addressed straight from the chip's {la, lh}; the
//  BRAM output is one clock late, so dtackn stays high until the registered
//  word was read from the address the chip presents now (qb_tag).  With a
//  pixel enable every 6-7 clocks that never costs the chip a cen.
//
//  ---- known differences from MAME, none reached by measured frames ---------
//
//  * Registers 2..5 are the chip's DMA destination: CPU writes to them are
//    IGNORED while ctrl[07] bit 6 is set (jt053936, after Furrtek's die
//    trace).  MAME always stores them.
//  * The chip reads its registers in real time, a line ahead of the display;
//    MAME draws the frame from the values at the end of it.  A mid-frame write
//    takes effect from a line on, not for the whole frame.
//  * ob (the chip's NOB pin) is not used.  suprslam.cpp set_wrap(1) never
//    clips, and the game holds ctrl[07][5] = 0, which jt053936_window reads
//    as "layer disabled" -> ob = 1 on every pixel, while MAME and the board
//    both show the layer.  So the VS920D path on this PCB does not gate on
//    NOB.
//============================================================================
`default_nettype none

module ss_psac #(
    parameter int H_TOTAL   = 456,
    parameter int H_VISIBLE = 320
) (
    input  wire        clk,
    input  wire        rst,

    // --- the raster: ss_crtc's pins, the chip's hs / vs / cen ---------------
    input  wire        ce_pix,
    input  wire [8:0]  hcnt,
    input  wire        hsync,
    input  wire        vsync_ahead,

    // --- CPU: control registers, 0xFFD000-0xFFD01F, write only -------------
    input  wire        ctrl_we,
    input  wire [3:0]  ctrl_a,
    input  wire [15:0] ctrl_d,
    input  wire [1:0]  ctrl_ds,

    // --- CPU: line RAM, 0xFF8000-0xFF8FFF, read/write ---------------------
    input  wire        line_cs,
    input  wire        line_we,
    input  wire [10:0] line_a,          // word index, 512 lines x 4
    input  wire [15:0] line_d,
    input  wire [1:0]  line_ds,
    output wire [15:0] line_q,

    // --- render job --------------------------------------------------------
    // `start` at the start of a job; `ready` the clock after, when src_x/src_y
    // hold entry 0.  Then one `step` per pixel issued, and only while src_ok.
    input  wire        start,
    output reg         ready,
    input  wire        step,
    output wire        src_ok,          // src_x/src_y hold a written entry

    output wire [9:0]  src_x,           // source pixel, 1024 x 1024, wrapping
    output wire [9:0]  src_y,

    output reg         super_mode       // ctrl[07] bit 6, for the overlay
);

  // ---- ctrl[07] bit 6 shadow, for the debug overlay -------------------------
  // Same strobe, same byte lane as the chip's own copy.
  always @(posedge clk) begin
    if (rst)                                          super_mode <= 1'b0;
    else if (ctrl_we && ctrl_a == 4'h7 && ctrl_ds[0]) super_mode <= ctrl_d[6];
  end

  // ---- line RAM, 2048 x 16, true dual port -------------------------------
  //
  // Port A is the CPU, port B is the chip's DMA.  Byte lanes on port A because
  // MAME's linectrl_w uses COMBINE_DATA and the 68000 can reach it with LDS or
  // UDS alone.
  //
  // TWO BYTE-WIDE ARRAYS, for the reason spelled out at length in
  // rtl/memory/ss_dpram.sv: a part-select write into a packed array does not
  // reliably infer as a byte-enabled M10K in Quartus 17.0, and when it does
  // not, nothing says so -- synthesis simply stops finishing.
  reg [7:0] lram_hi [0:2047];
  reg [7:0] lram_lo [0:2047];
  reg [15:0] lram_qa, lram_qb;
  reg [10:0] qb_tag;              // the address lram_qb was read from

  wire [8:0]  jt_la;
  wire [2:1]  jt_lh;
  wire [10:0] fetch_a = {jt_la, jt_lh};

  always @(posedge clk) begin
    if (line_cs && line_we && line_ds[1]) lram_hi[line_a] <= line_d[15:8];
    if (line_cs && line_we && line_ds[0]) lram_lo[line_a] <= line_d[ 7:0];
    lram_qa <= {lram_hi[line_a], lram_lo[line_a]};
    lram_qb <= {lram_hi[fetch_a], lram_lo[fetch_a]};
  end
  // Kept OUT of the RAM block so it stays a plain 11-bit register beside the
  // M10K rather than something the inference has to reason about.
  always @(posedge clk) qb_tag <= fetch_a;
  assign line_q = lram_qa;

  // BRAM latency as the chip's DTACK: the word is good only once it was read
  // from the address the chip is presenting now.
  wire jt_dtackn = (qb_tag != fetch_a);

  // ---- the chip -------------------------------------------------------------
  // Every register is written exactly as the CPU writes it, 0x0E included.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [12:0] jt_nx, jt_ny;             // the accumulator, one cen early
  wire [12:0] jt_x, jt_y;               // the output pins; [12:10] wrap away
  wire        jt_xh, jt_yh, jt_ob;      // half pixel; ob unused, see header
  wire        jt_dma_n;
  wire [7:0]  jt_ioctl_din;
  /* verilator lint_on UNUSEDSIGNAL */

  jt053936 u_chip (
      .rst        ( rst          ),
      .clk        ( clk          ),
      .cen        ( ce_pix       ),
      .din        ( ctrl_d       ),
      .addr       ( ctrl_a       ),
      .hs         ( hsync        ),
      .vs         ( vsync_ahead  ),
      .cs         ( ctrl_we      ),
      .dtackn     ( jt_dtackn    ),
      .dsn        ( ~ctrl_ds     ),
      .dma_n      ( jt_dma_n     ),
      .ldout      ( lram_qb      ),
      .lh         ( jt_lh        ),
      .la         ( jt_la        ),
      .x          ( jt_x         ),
      .xh         ( jt_xh        ),
      .y          ( jt_y         ),
      .yh         ( jt_yh        ),
      .nx         ( jt_nx        ),
      .ny         ( jt_ny        ),
      .ob         ( jt_ob        ),
      .ioctl_addr ( 5'd0         ),
      .ioctl_din  ( jt_ioctl_din )
  );

  // ---- the record of one line of pins -------------------------------------
  //
  // On a pixel enable, hcnt and the x / y pins both still hold what the
  // previous enable set, so this pairs each coordinate with the column it is
  // shown at.  Wrap is ON (suprslam.cpp:459 set_wrap(1)) over a 1024 x 1024
  // source: the low ten bits are the coordinate.
  reg [19:0] cbuf [0:511];
  reg [19:0] cbuf_q;
  reg [8:0]  wr_cnt, wr_cnt_d;    // entries 0..wr_cnt-1 written this line
  reg [8:0]  rd_p;                // entry cbuf_q holds

  always @(posedge clk) begin
    if (ce_pix && hcnt < 9'(H_VISIBLE)) cbuf[hcnt] <= {jt_y[9:0], jt_x[9:0]};
  end

  always @(posedge clk) begin
    if (rst) begin
      wr_cnt <= 9'd0;
    end else if (ce_pix) begin
      if (hcnt < 9'(H_VISIBLE))              wr_cnt <= hcnt + 9'd1;
      else if (hcnt == 9'(H_TOTAL - 1))      wr_cnt <= 9'd0;
    end
  end

  // The read address runs one entry ahead on a step, so cbuf_q always holds
  // entry rd_p.  An entry is good once it was written at least one clock
  // before the edge that read it: wr_cnt_d, not wr_cnt.
  wire [8:0] rd_a = start ? 9'd0 : (rd_p + {8'd0, step});

  always @(posedge clk) cbuf_q <= cbuf[rd_a];

  always @(posedge clk) begin
    if (rst) begin
      wr_cnt_d <= 9'd0;
      ready    <= 1'b0;
      rd_p     <= 9'd0;
    end else begin
      wr_cnt_d <= wr_cnt;
      ready    <= start;
      rd_p     <= rd_a;
    end
  end

  assign src_ok = (rd_p < wr_cnt_d);
  assign src_x  = cbuf_q[9:0];
  assign src_y  = cbuf_q[19:10];

endmodule

`default_nettype wire
