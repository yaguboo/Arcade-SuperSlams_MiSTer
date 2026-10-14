//============================================================================
//  Super Slams -- board top
//
//  Platform-neutral.  No hps_io, no ioctl_*, no MISTER_*: the MiSTer wrapper
//  hands this module a byte stream, a few switches and a pixel bus, and it
//  would hand a Pocket wrapper the same ones.
//
//  ---- one clock domain, 48 MHz ------------------------------------------
//
//  DECISIONS D1.  The board's CPU and sound clocks are all 32 MHz / 2^k, so at
//  48 MHz every one of them is an exact integer divider and none of them
//  jitters:
//
//      68000    48 / 3  = 16.000 MHz
//      Z80      48 / 12 =  4.000 MHz
//      YM2610   48 / 6  =  8.000 MHz
//
//  The pixel clock is not a divider of 64, so it is a fractional clock enable
//  -- the same construct the sibling lane uses, and for the same reason: one
//  domain and no CDC beats an exact second PLL output.
//
//      48 MHz * 315/2112 = 7.159090909... MHz, exactly the NTSC 315/22 MHz
//      crystal halved (2112 = 22 x 96).  Pulses land 6 or 7 clocks apart and
//      the AVERAGE is exact, which is what a raster needs.
//
//  ---- everything renders one line ahead ---------------------------------
//
//  All three layers fill a double line buffer for line V+1 while line V is
//  displayed, so no layer has a within-line deadline and the mixer is a pure
//  lookup.  That is deliberately NOT the sibling lane's architecture, where
//  the tilemap fetched just in time against a 39-clock deadline -- and it is
//  why this core has no equivalent of that lane's O11/O18/O19 shimmer.
//
//  Each layer counts the lines it failed to finish.  The counters are here
//  from the first build, not added after something looks wrong.
//============================================================================
`default_nettype none

module ss_top (
    input  wire        clk,              // 48.000 MHz
    input  wire        rst,              // synchronous, active high

    // THE MEMORY TRANSPORT MUST RUN DURING THE ROM LOAD.
    //
    // MiSTer holds RESET high for the WHOLE download, and the arbiter is the
    // thing doing the downloading -- so it cannot be held in `rst` or it never
    // acks the download client, `ioctl_wait` stays high forever, the HPS hangs
    // on its handshake, and MiSTer gives up and returns to the menu.
    //
    // That is not a hypothesis.  This core's first deployment failed exactly
    // that way and took six experiments to corner: the bitstream loads
    // perfectly on its own (`load_core <rbf>`), and this core's .mra loads
    // perfectly with a DIFFERENT core's bitstream -- only the two together
    // fail, because only then is there a ROM to transfer.  DEBUG_LOG O6.
    input  wire        mem_rst,          // ~pll_locked ONLY
    input  wire        pll_locked,

    // --- ROM download, platform-neutral -----------------------------------
    input  wire        dl_active,
    input  wire        dl_req,
    input  wire [24:0] dl_addr,
    input  wire [15:0] dl_data,
    output wire        dl_ack,

    // --- controls ---------------------------------------------------------
    input  wire        pause,
    input  wire [7:0]  p1, p2, sys_in,
    input  wire [7:0]  dsw1, dsw2,
    input  wire        spr_buffer_en,
    input  wire        cpu_first,        // OSD: the 68000 outranks the video clients

    // --- video out --------------------------------------------------------
    output wire        ce_pix,
    output wire [7:0]  red, green, blue,
    output wire        hsync, vsync, hblank, vblank,

    // --- audio out --------------------------------------------------------
    output wire signed [15:0] snd_l,
    output wire signed [15:0] snd_r,
    output wire        snd_sample,

    // --- SDRAM pins -------------------------------------------------------
    output wire [12:0] SDRAM_A,
    output wire [1:0]  SDRAM_BA,
    inout  wire [15:0] SDRAM_DQ,
    output wire        SDRAM_DQML,
    output wire        SDRAM_DQMH,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_CKE,

    // --- observability ----------------------------------------------------
    // The raster counters, for the target's overlay.  Exposed rather than
    // rebuilt on the far side: DEBUG_LOG O7 is what rebuilding them cost.
    output wire [8:0]  dbg_hcnt,
    output wire [8:0]  dbg_vcnt,
    // PER FRAME, not cumulative.  A saturating running total says only
    // "it happened at least once since reset", which for a counter that ticks
    // once a line reaches 0xFFFF in four seconds and then says nothing at all.
    // A per-frame count is a rate: N lines of 262 missed, this frame.
    output wire [15:0] dbg_roz_overrun,
    output wire [15:0] dbg_fg_overrun,
    // PER FRAME.  roz_overrun and fg_overrun have read 0 on every hardware
    // sample ever taken and have done their job; these two answer the
    // question that is actually open -- how much of the frame the 68000
    // spends waiting for its program ROM.
    output wire [15:0] dbg_cpu_wait,
    output wire [15:0] dbg_cpu_miss,
    output wire [15:0] dbg_spin_fr,
    // The audio discontinuity counters existed in ss_sound and were LEFT
    // UNCONNECTED here -- a whole instrument built and then wired to nothing,
    // which synthesises away and reads as a clean zero if anybody ever puts it
    // on a row.  A person at the board reports heavy noise.
    output wire [15:0] dbg_jump_fr,
    output wire [15:0] dbg_maxd_fr,
    // The arbiter's own pair, published as the WORST line of the frame.
    // dbg_line_busy / dbg_line_acks is clocks per completed read, measured
    // where the contention happens rather than derived from anything.
    output wire [15:0] dbg_line_acks,
    output wire [15:0] dbg_line_busy,
    // Cause and effect for the crackle, both per frame: late_fr is ADPCM-A
    // fetches the SDRAM did not finish in the chip's slot, jump_fr is the
    // output discontinuities that produces.  Both were implemented and left
    // unconnected.
    output wire [15:0] dbg_late_fr,
    output wire [15:0] dbg_pcmb_late_fr,
    output wire [15:0] dbg_pcma_worst,
    // Inside jt10: the peak of the PSG/SSG output and of the FM sum.  MAME
    // never enables the SSG NOISE generator on this game (0 of 6,000 frames,
    // all three channels) and its tone channels are on in 3 % of frames at
    // volumes 0..4 of 31 -- 2.4 % of output RMS.  A person at the board
    // describes broadband hiss, "a radio that is not tuned in", which is what
    // that generator sounds like and what a starved ADPCM stream does NOT
    // sound like (that is dull and low, shadow_force A55).  So: is our SSG
    // loud?
    output wire [15:0] dbg_peak_psg,
    output wire [15:0] dbg_peak_fm,
    output wire [15:0] dbg_mad,        // mean |snd_l| over 1024 samples
    output wire [15:0] dbg_mdd,        // mean |delta| over the same 1024
    output wire [15:0] dbg_pcma_bad,   // CUMULATIVE slots that took a stale byte
    output wire [15:0] dbg_spr_overrun,
    output wire [15:0] dbg_spr_tiles,
    output wire [15:0] dbg_row_hit,
    output wire [15:0] dbg_row_miss,
    output wire [15:0] dbg_row_conflict,
    output wire [31:0] dbg_d7,
    output wire [23:1] dbg_cpu_a,
    output wire        dbg_halted_n,
    output wire [15:0] dbg_vregs4,
    output wire [15:0] dbg_vregs5,
    output wire        dbg_super_mode,

    // ---- ROM probe -------------------------------------------------------
    // Seven words read back OUT OF SDRAM after the download, one per region,
    // at offsets chosen because their expected values are all different:
    //
    //   maincpu 00FE  audiocpu ED56  fgtiles 3333  bgtiles DDDD
    //   sprites 5FFF  adpcma   0889  adpcmb  0808
    //
    // This answers a question nothing else on the board can: did the ROM
    // arrive, in the right place, in the right byte order.  The packer checks
    // its own image and the .mra stream, but neither of those is the SDRAM.
    output wire [15:0] dbg_probe0, dbg_probe1, dbg_probe2, dbg_probe3,
    output wire [15:0] dbg_probe4, dbg_probe5, dbg_probe6,
    output wire        dbg_probe_done,

    // ---- the vblank interrupt, counted at both ends ----------------------
    // The game sits in a loop at ROM 0x5F0 reading a work-RAM counter twice
    // and spinning while it does not change -- a vblank wait, and the counter
    // is bumped by the level-1 handler.  The board never leaves that loop, so
    // either the interrupt is not delivered or the handler runs and its write
    // does not stick.  These two separate those:
    //
    //   irq_cnt rising, iack_cnt 0   -> the 68000 never takes it
    //   both rising                  -> it takes it; the fault is downstream
    //   irq_cnt 0                    -> vblank_start never fires
    output reg  [15:0] dbg_irq_cnt,
    output reg  [15:0] dbg_iack_cnt,
    output wire [15:0] dbg_ctr_wr_cnt,
    output wire [15:0] dbg_ctr_wr_val,
    output wire [15:0] dbg_ctr_rd_val,
    output wire [15:0] dbg_pc_min,
    output wire [15:0] dbg_pc_max,
    output wire [15:0] dbg_wr_fgv, dbg_wr_bgv, dbg_wr_spr, dbg_wr_pal,
    output wire [15:0] dbg_render_cnt,
    // Offers the controller made that the arbiter DECLINED.  The 68000 is the
    // lowest-priority client and, now that three layers actually fetch, is
    // the one that will feel it first.
    output wire [15:0] dbg_cpu_stall,
    // ---- the sound chain, one rung of the ladder each --------------------
    // Every one of these already existed inside ss_sound and none of them had
    // ever been looked at: sound is the last part of this board nobody has
    // verified, and it cannot be verified by listening from here.
    output wire [15:0] dbg_z80_cyc,     // the Z80 is executing
    output wire [15:0] dbg_latch_ack,   // ...and consuming 68000 commands
    output wire [15:0] dbg_ym_wr,       // ...and writing the YM2610
    output wire [15:0] dbg_sample,      // ...which is producing samples
    output wire [15:0] dbg_peak_l,      // ...that are not silence  (L)
    output wire [15:0] dbg_peak_r,      // ...                      (R)
    output wire [15:0] dbg_fm_kon,      // FM notes keyed on
    output wire [15:0] dbg_pcma_kon,
    // where the sprite engine's worst line went
    output wire [15:0] dbg_spr_busy,
    output wire [15:0] dbg_spr_wait,
    // CUMULATIVE truncated lines since reset.  This is the closure number.
    output wire [15:0] dbg_spr_trunc
);

`include "ss_rommap.svh"

  localparam int H_TOTAL   = 456;
  localparam int H_VISIBLE = 320;
  localparam int V_TOTAL   = 262;
  localparam int V_VISIBLE = 224;

  // ---- the raster outlives the board's reset ------------------------------
  //
  // ss_vrst.sv: `rstc` is what every part of the core EXCEPT the raster is held
  // in (rst, one clock longer); `vrst` is what the raster is held in.  The
  // raster -- pixel enable, ss_crtc, the sync/blank output pipe -- keeps running
  // while MiSTer holds RESET for the ROM download, so the OSD loading bar has a
  // picture to be drawn on and an analog monitor keeps its sync.
  wire rstc, vrst;
  ss_vrst u_vrst (.clk(clk), .rst(rst), .pll_locked(pll_locked),
                  .rstc(rstc), .vrst(vrst));

  // ---- pixel clock enable ------------------------------------------------
  //
  // 315/2112 of 48 MHz, restarted from a fixed phase at the end of every line
  // so a line is exactly 3057 clocks.  Both terms are exact: 315/22 MHz is the
  // NTSC colour subcarrier relationship the PCB's 14.31818 crystal is, and
  // 2112 = 22*96.  Why the restart: ss_pixen.sv.
  wire [8:0] hcnt, vcnt;
  wire       ce_pix_r;
  ss_pixen #(.H_TOTAL(H_TOTAL)) u_pixen (
      .clk(clk), .rst(vrst), .hcnt(hcnt), .ce_pix(ce_pix_r)
  );
  assign ce_pix = ce_pix_r;

  wire ce_en = ~dl_active & ~pause & pll_locked;

  // ---- arbiter nets, declared here because the sound ROM snoop below uses
  // arb_ack[0] and `default_nettype none` means declaration order matters.
  localparam int NCLI = 7;
  wire [NCLI-1:0]      arb_req, arb_ack, arb_we, arb_hold;
  wire [25*NCLI-1:0]   arb_addr;
  wire [16*NCLI-1:0]   arb_din;
  wire [2*NCLI-1:0]    arb_ds;
  wire [15:0]          mem_dout;    // arbiter -> clients
  wire [15:0]          sd_dout;     // controller -> arbiter
  wire cpu_rst = dl_active | ~pll_locked;

  // ---- video -------------------------------------------------------------
  assign dbg_hcnt = hcnt;
  assign dbg_vcnt = vcnt;
  wire       hb_i, vb_i, hs_i, vs_i, vsa_i, vblank_start, line_start;

  // ---- per-frame overrun rate --------------------------------------------
  // The layer modules keep a saturating running total, which is the right
  // thing for them to own and the wrong thing to read.  Difference it here,
  // at the one place that already has vblank_start, rather than adding a
  // frame input to three modules that sit in the per-pixel render path.
  // ss_sprite now publishes its own per-frame figures, so it is NOT
  // differenced here -- doing both would difference a difference.
  wire [15:0] roz_ovr_raw, fg_ovr_raw;
  reg  [15:0] roz_ovr_p, fg_ovr_p;
  reg  [15:0] roz_ovr_f, fg_ovr_f;
  always @(posedge clk) begin
    if (rstc) begin
      roz_ovr_p <= 16'd0; fg_ovr_p <= 16'd0;
      roz_ovr_f <= 16'd0; fg_ovr_f <= 16'd0;
    end else if (vblank_start) begin
      roz_ovr_f <= roz_ovr_raw - roz_ovr_p;   roz_ovr_p <= roz_ovr_raw;
      fg_ovr_f  <= fg_ovr_raw  - fg_ovr_p;    fg_ovr_p  <= fg_ovr_raw;
    end
  end
  assign dbg_roz_overrun = roz_ovr_f;
  assign dbg_fg_overrun  = fg_ovr_f;

  wire       render_start;
  wire [8:0] render_line;
  wire       lb_par;
  wire [8:0] lb_x;
  wire [7:0] roz_lb_q, fg_lb_q;
  wire [10:0] spr_lb_q;
  wire [10:0] pal_addr;
  wire [15:0] pal_q;
  wire [3:0] spr_ctrl;

  ss_video #(
      .H_TOTAL(H_TOTAL), .H_VISIBLE(H_VISIBLE),
      .V_TOTAL(V_TOTAL), .V_VISIBLE(V_VISIBLE)
  ) u_video (
      .clk(clk), .rst(rstc), .vrst(vrst), .ce_pix(ce_pix_r),
      .hcnt(hcnt), .vcnt(vcnt),
      .hblank(hb_i), .vblank(vb_i), .hsync(hs_i), .vsync(vs_i), .vsync_ahead(vsa_i),
      .vblank_start(vblank_start), .line_start(line_start),
      .render_start(render_start), .render_line(render_line),
      .lb_par(lb_par), .lb_x(lb_x),
      .roz_q(roz_lb_q), .fg_q(fg_lb_q), .spr_q(spr_lb_q),
      .pal_addr(pal_addr), .pal_data(pal_q),
      .spr_above_fg(spr_ctrl[3]),
      .red(red), .green(green), .blue(blue),
      .hs(hsync), .vs(vsync), .hb(hblank), .vb(vblank),
      .dbg_render_cnt(dbg_render_cnt)
  );

  // ---- the vblank interrupt ---------------------------------------------
  //
  // irq1_line_hold: the line is HELD until the CPU acknowledges.  Clearing it
  // anywhere else is the sibling lane's DEBUG_LOG O10, and both wrong versions
  // boot and draw:
  //
  //     cleared at end-of-vblank   the handler runs TWICE a frame
  //     cleared on the iack LEVEL  the board freezes after one frame
  //
  // So: clear at the END of the acknowledge cycle, with an end-of-vblank
  // fallback in case an acknowledge never arrives.
  wire iack_stb;
  reg  vbl_irq, iack_q, vb_d;
  always @(posedge clk) begin
    if (rstc) begin
      vbl_irq <= 1'b0;
      iack_q  <= 1'b0;
      vb_d    <= 1'b0;
      dbg_irq_cnt  <= 16'd0;
      dbg_iack_cnt <= 16'd0;
    end else begin
      if (vblank_start && dbg_irq_cnt  != 16'hFFFF) dbg_irq_cnt  <= dbg_irq_cnt  + 16'd1;
      if (iack_stb && !iack_q && dbg_iack_cnt != 16'hFFFF)
        dbg_iack_cnt <= dbg_iack_cnt + 16'd1;
      iack_q <= iack_stb;
      vb_d   <= vb_i;
      if (vblank_start)                vbl_irq <= 1'b1;
      else if (iack_q && !iack_stb)    vbl_irq <= 1'b0;   // acknowledge ended
      else if (vb_d && !vb_i)          vbl_irq <= 1'b0;   // fallback
    end
  end

  // ---- CPU side ----------------------------------------------------------
  wire [24:0] cpu_rom_a;  wire cpu_rom_req, cpu_rom_ack;
  wire [11:0] bgv_addr;   wire [15:0] bgv_q;
  wire [10:0] fgv_addr;   wire [15:0] fgv_q;
  wire [11:0] spr_addr;   wire [15:0] spr_q;
  wire [14:0] lut_addr;   wire [15:0] lut_q;
  wire        psac_ctrl_we, psac_line_cs, psac_line_we;
  wire [3:0]  psac_ctrl_a;
  wire [15:0] psac_ctrl_d, psac_line_d, psac_line_q;
  wire [1:0]  psac_ctrl_ds, psac_line_ds;
  wire [10:0] psac_line_a;
  wire [8:0]  fg_scrollx;
  wire [3:0]  screen_bank;
  wire [2:0]  bg_bank;
  wire [7:0]  latch_data;
  wire        latch_we;
  wire [7:0]  port_g;

  ss_main u_main (
      .clk(clk), .rst(rstc), .cpu_rst(cpu_rst), .ce_en(ce_en),
      .rom_addr(cpu_rom_a), .rom_req(cpu_rom_req),
      .rom_ack(cpu_rom_ack), .rom_data(mem_dout),
      .vblank_irq(vbl_irq), .iack_stb(iack_stb),
      .p1(p1), .p2(p2), .sys_in(sys_in), .dsw1(dsw1), .dsw2(dsw2),
      .spr_ctrl(spr_ctrl), .port_g(port_g),
      .latch_data(latch_data), .latch_we(latch_we),
      .bgv_addr(bgv_addr), .bgv_q(bgv_q),
      .fgv_addr(fgv_addr), .fgv_q(fgv_q),
      .spr_addr(spr_addr), .spr_q(spr_q),
      .lut_addr(lut_addr), .lut_q(lut_q),
      .pal_addr(pal_addr), .pal_q(pal_q),
      .psac_ctrl_we(psac_ctrl_we), .psac_ctrl_a(psac_ctrl_a),
      .psac_ctrl_d(psac_ctrl_d), .psac_ctrl_ds(psac_ctrl_ds),
      .psac_line_cs(psac_line_cs), .psac_line_we(psac_line_we),
      .psac_line_a(psac_line_a), .psac_line_d(psac_line_d),
      .psac_line_ds(psac_line_ds), .psac_line_q(psac_line_q),
      .fg_scrollx(fg_scrollx), .screen_bank(screen_bank), .bg_bank(bg_bank),
      .vblank_start(vblank_start), .spr_buffer_en(spr_buffer_en),
      .dl_active(dl_active),
      .dbg_cpu_wait(dbg_cpu_wait), .dbg_cpu_miss(dbg_cpu_miss),
      .dbg_spin_fr(dbg_spin_fr),
      .dbg_addr(dbg_cpu_a), .dbg_d7(dbg_d7), .dbg_halted_n(dbg_halted_n),
      .dbg_vregs4(dbg_vregs4), .dbg_vregs5(dbg_vregs5),
      .dbg_fd1020_wr_cnt(dbg_ctr_wr_cnt),
      .dbg_fd1020_wr_val(dbg_ctr_wr_val),
      .dbg_fd1020_rd_val(dbg_ctr_rd_val),
      .frame_tick(vblank_start),
      .dbg_pc_min(dbg_pc_min), .dbg_pc_max(dbg_pc_max),
      .dbg_wr_fgv(dbg_wr_fgv), .dbg_wr_bgv(dbg_wr_bgv),
      .dbg_wr_spr(dbg_wr_spr), .dbg_wr_pal(dbg_wr_pal)
  );

  // ---- the three layers --------------------------------------------------
  wire [24:0] roz_a, fg_a, spr_a;
  wire        roz_req, fg_req, spr_req, spr_hold;
  wire        roz_ack, fg_ack, spr_ack;

  ss_roz #(.H_VISIBLE(H_VISIBLE), .BGTILES_BASE_W(BGTILES_BASE_W)) u_roz (
      .clk(clk), .rst(rstc),
      .start(render_start), .sline(render_line), .busy(),
      .ce_pix(ce_pix_r), .hcnt(hcnt), .hsync(hs_i), .vsync_ahead(vsa_i),
      .ctrl_we(psac_ctrl_we), .ctrl_a(psac_ctrl_a),
      .ctrl_d(psac_ctrl_d), .ctrl_ds(psac_ctrl_ds),
      .line_cs(psac_line_cs), .line_we(psac_line_we), .line_a(psac_line_a),
      .line_d(psac_line_d), .line_ds(psac_line_ds), .line_q(psac_line_q),
      .vram_addr(bgv_addr), .vram_data(bgv_q),
      .bg_bank(bg_bank),
      .rom_addr(roz_a), .rom_req(roz_req), .rom_ack(roz_ack),
      .rom_data(mem_dout),
      .lb_par(lb_par), .lb_x(lb_x), .lb_q(roz_lb_q),
      .super_mode(dbg_super_mode), .dbg_overrun(roz_ovr_raw)
  );

  ss_fgmap #(.H_VISIBLE(H_VISIBLE), .FGTILES_BASE_W(FGTILES_BASE_W)) u_fg (
      .clk(clk), .rst(rstc),
      .start(render_start), .sline(render_line[7:0]), .busy(),
      .vram_addr(fgv_addr), .vram_data(fgv_q),
      .scrollx(fg_scrollx), .screen_bank(screen_bank), .flip(1'b0),
      .rom_addr(fg_a), .rom_req(fg_req), .rom_ack(fg_ack),
      .rom_data(mem_dout),
      .lb_par(lb_par), .lb_x(lb_x), .lb_q(fg_lb_q),
      .dbg_overrun(fg_ovr_raw)
  );

  ss_sprite #(.H_VISIBLE(H_VISIBLE), .SPRITES_BASE_W(SPRITES_BASE_W)) u_spr (
      .clk(clk), .rst(rstc),
      .start(render_start), .sline(render_line), .busy(),
      .sram_addr(spr_addr), .sram_data(spr_q),
      .lut_addr(lut_addr), .lut_data(lut_q),
      .rom_addr(spr_a), .rom_req(spr_req), .rom_hold(spr_hold),
      .rom_ack(spr_ack), .rom_data(mem_dout), .rom_adv(arb_adv[5]),
      .lb_par(lb_par), .lb_x(lb_x), .lb_q(spr_lb_q),
      .frame(vblank_start),
      .dbg_trunc_total(dbg_spr_trunc),
      .dbg_overrun(dbg_spr_overrun), .dbg_tiles(dbg_spr_tiles),
      .dbg_busy_clks(dbg_spr_busy), .dbg_wait_clks(dbg_spr_wait)
  );

  // ---- sound -------------------------------------------------------------
  //
  // The Z80's 128 KB program ROM is snooped out of the download stream into
  // BRAM rather than left in SDRAM.  103 M10K blocks, and it buys back about
  // 1.2 M words/s -- 17 % of the typical budget on a board with far less
  // headroom than the sibling had.  DECISIONS D5.
  wire dl_in_snd = dl_active && (dl_addr >= AUDIOCPU_BASE_W)
                             && (dl_addr <  AUDIOCPU_BASE_W + 25'h10000);
  wire [20:1] pcma_a;  wire pcma_req, pcma_ack;
  wire [19:1] pcmb_a;  wire pcmb_req, pcmb_ack;

  ss_sound u_sound (
      .clk(clk), .rst(rstc | ~pll_locked), .rom_rst(~pll_locked),
      .ce_en(ce_en), .frame(vblank_start),
      .rom_we(dl_in_snd & dl_req & arb_ack[0]),
      .rom_wa(dl_addr[15:0] - AUDIOCPU_BASE_W[15:0]),
      .rom_wd(dl_data),
      .latch_din(latch_data), .latch_we(latch_we), .latch_pending(),
      .adpcma_a(pcma_a), .adpcma_q(mem_dout),
      .adpcma_req(pcma_req), .adpcma_ack(pcma_ack),
      .adpcmb_a(pcmb_a), .adpcmb_q(mem_dout),
      .adpcmb_req(pcmb_req), .adpcmb_ack(pcmb_ack),
      .snd_l(snd_l), .snd_r(snd_r), .snd_sample(snd_sample),
      .dbg_z80_cyc(dbg_z80_cyc), .dbg_ym_wr(dbg_ym_wr),
      .dbg_pcma_fetch(), .dbg_pcm_late(),
      .dbg_state(), .dbg_rom_w0(), .dbg_rom_n(), .dbg_peak(),
      .dbg_latch_ack(dbg_latch_ack), .dbg_peak_l(dbg_peak_l),
      .dbg_peak_r(dbg_peak_r), .dbg_pcma_kon(dbg_pcma_kon),
      .dbg_fm_kon(dbg_fm_kon), .dbg_sample(dbg_sample),
      .dbg_io_rd(), .dbg_last_b1(),
      // dbg_peak_fm and dbg_peak_psg USED TO BE TIED OFF HERE as well as
      // connected below -- the same pin named twice on one instance.  Quartus
      // accepted it silently and picked one; Verilator refuses, which is how
      // it was found.  Same family as LESSONS_LEARNED L15: a debug port whose
      // connection is not what the reader thinks it is.
      .dbg_irq(), .dbg_intack(), .dbg_timer_w(),
      .dbg_roe_a(), .dbg_peak_op(), .dbg_aon_cnt(),
      .dbg_eg_min(), .dbg_keyon_cnt(), .dbg_mmr_kon(), .dbg_kon_latch(),
      .dbg_kon_match(), .dbg_csr_slots(), .dbg_fm_koff(), .dbg_last_kon(),
      .dbg_late_fr(dbg_late_fr), .dbg_fetch_fr(), .dbg_pcmb_fr(),
      .dbg_pcmb_late_fr(dbg_pcmb_late_fr), .dbg_pcma_worst(dbg_pcma_worst),
      .dbg_peak_psg(dbg_peak_psg), .dbg_peak_fm(dbg_peak_fm),
      .dbg_mad(dbg_mad), .dbg_mdd(dbg_mdd), .dbg_pcma_bad(dbg_pcma_bad),
      .dbg_jump_fr(dbg_jump_fr), .dbg_maxd_fr(dbg_maxd_fr),
      .dbg_jump_a(), .dbg_jump_b()
  );

  // ---- ROM probe ---------------------------------------------------------
  reg  [2:0]  pidx;
  reg         probe_req;
  reg         probe_done;
  reg         dl_active_d;
  reg  [15:0] pq0, pq1, pq2, pq3, pq4, pq5, pq6;

  reg [24:0] probe_a;
  always @(*) begin
    case (pidx)
      3'd0: probe_a = 25'h000000;   // maincpu   expect 00FE
      3'd1: probe_a = 25'h080000;   // audiocpu  expect ED56
      3'd2: probe_a = 25'h100400;   // fgtiles   expect 3333
      3'd3: probe_a = 25'h200400;   // bgtiles   expect DDDD
      3'd4: probe_a = 25'h401C00;   // sprites   expect 5FFF
      3'd5: probe_a = 25'h800000;   // adpcma    expect 0889
      default: probe_a = 25'h900000; // adpcmb   expect 0808
    endcase
  end

  always @(posedge clk) begin
    if (mem_rst) begin
      pidx <= 3'd0; probe_req <= 1'b0; probe_done <= 1'b0; dl_active_d <= 1'b0;
    end else begin
      dl_active_d <= dl_active;
      if (dl_active_d && !dl_active) begin
        pidx <= 3'd0; probe_req <= 1'b1; probe_done <= 1'b0;
      end else if (probe_req && arb_ack[0]) begin
        case (pidx)
          3'd0: pq0 <= mem_dout;  3'd1: pq1 <= mem_dout;
          3'd2: pq2 <= mem_dout;  3'd3: pq3 <= mem_dout;
          3'd4: pq4 <= mem_dout;  3'd5: pq5 <= mem_dout;
          default: pq6 <= mem_dout;
        endcase
        if (pidx == 3'd6) begin probe_req <= 1'b0; probe_done <= 1'b1; end
        else                    pidx <= pidx + 3'd1;
      end
    end
  end

  assign dbg_probe0 = pq0;  assign dbg_probe1 = pq1;  assign dbg_probe2 = pq2;
  assign dbg_probe3 = pq3;  assign dbg_probe4 = pq4;  assign dbg_probe5 = pq5;
  assign dbg_probe6 = pq6;  assign dbg_probe_done = probe_done;

  // ---- SDRAM arbitration -------------------------------------------------
  //
  // Priority, highest first.  The ordering rule is SLACK, not importance:
  //
  //   0 download   the CPU is in reset, so it owns the bus
  //   1 fg         bounded -- exactly 320 pixels, about 900 clocks
  //   2 roz        bounded -- exactly 320 pixels, about 1100 clocks
  //   3 adpcma     tiny but with a real deadline: a late sample is audible
  //   4 adpcmb     tinier
  //   5 sprite     the heaviest, and the only UNBOUNDED one -- a sort list
  //                full of uninitialised RAM at boot could ask for 512
  //                entries of 64 tiles.  Bounded clients go first precisely
  //                so that cannot starve them.
  //   6 cpu        a stalled 68000 is only a slower 68000
  //
  // This is a design choice, not a hardware fact: the real board has no
  // arbiter, each of these has its own mask ROM and its own pins.  The
  // sibling lane's copy of this module carries a scar worth reading before
  // reordering it -- its ADPCM client was moved twice on guesses and both
  // moves were reverted, because the real fault was a client asking seventy
  // times too often.  No arbiter order fixes that.  Measure first.
  // Client 0 is the download during the load and the ROM probe afterwards.
  // Two users of one slot, never at the same time -- the probe only starts on
  // the falling edge of dl_active.  Borrowing the highest-priority client is
  // deliberate: on a lower one the probe waited forever behind the video
  // engines in the sibling lane and read back nothing.
  wire        cl0_req  = dl_active ? dl_req  : probe_req;
  wire [24:0] cl0_addr = dl_active ? dl_addr : probe_a;
  wire        cl0_we   = dl_active;

  // ---- urgent: ADPCM-A, and only after it has already waited -------------
  //
  // power_spikes DEBUG_LOG O13.  jt10 presents a new ADPCM-A sample address
  // every ~666 kHz slot and consumes whatever is on `datain` at the end of
  // it; a byte that arrives after the slot moved on is a WRONG NIBBLE, and
  // jt10_acc amplifies ADPCM-A by 7.25x on its way into the mix.  One wrong
  // nibble therefore steps the output by a multiple, which is a crackle.
  //
  // At 48 MHz a 666 kHz slot is ~72 clocks.  The bit is raised at 32 -- less
  // than half the slot, so the boost only ever covers a fetch that is already
  // in trouble, and a fetch that would have been served in time never sets it.
  //
  // ADPCM-A IS THE ONLY CLIENT THAT MAY SET A BIT HERE.  The sibling lane gave
  // one to its sprite engine and undid its own tilemap fix: an override is a
  // priority inversion with a window around it, and a client with a whole
  // scanline of slack does not get to interrupt one with 72 clocks.
  reg [6:0] pcma_wait;
  always @(posedge clk) begin
    if (rstc || !pcma_req || pcma_ack) pcma_wait <= 7'd0;
    else if (pcma_wait != 7'd127)     pcma_wait <= pcma_wait + 7'd1;
  end
  wire pcma_urgent = pcma_req && (pcma_wait >= 7'd32);
  wire [NCLI-1:0] arb_adv;
  wire [NCLI-1:0] arb_urgent = { 1'b0, 1'b0, 1'b0, pcma_urgent,
                                 1'b0, 1'b0, 1'b0 };

  assign arb_req  = { cpu_rom_req, spr_req, pcmb_req, pcma_req,
                      roz_req, fg_req, cl0_req };
  assign arb_hold = { 1'b0, spr_hold, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0 };
  assign arb_we   = { 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, cl0_we };
  assign arb_ds   = { 2'b11, 2'b11, 2'b11, 2'b11, 2'b11, 2'b11, 2'b11 };
  assign arb_addr = { cpu_rom_a,
                      spr_a,
                      {ADPCMB_BASE_W[24:19], pcmb_a},
                      {ADPCMA_BASE_W[24:20], pcma_a},
                      roz_a,
                      fg_a,
                      cl0_addr };
  assign arb_din  = { 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, dl_data };

  assign dl_ack      = arb_ack[0] & dl_active;
  assign fg_ack      = arb_ack[1];
  assign roz_ack     = arb_ack[2];
  assign pcma_ack    = arb_ack[3];
  assign pcmb_ack    = arb_ack[4];
  assign spr_ack     = arb_ack[5];
  assign cpu_rom_ack = arb_ack[6];

  wire [24:0] m_addr;  wire [15:0] m_din;  wire m_req, m_we;
  wire [1:0]  m_ds;    wire m_ack, m_ack_early, m_handoff;

  // mem_rst, NOT rst -- see the port declaration.  The arbiter is what carries
  // the ROM download, so holding it in the system reset deadlocks the load.
  ss_memarb #(.N(NCLI), .CPU_ID(6)) u_arb (
      .clk(clk), .rst(mem_rst),
      .req(arb_req), .hold(arb_hold), .addr(arb_addr), .din(arb_din),
      .we(arb_we), .ds(arb_ds), .ack(arb_ack), .dout(mem_dout),
      .m_addr(m_addr), .m_din(m_din), .m_dout(sd_dout),
      .m_req(m_req), .m_we(m_we), .m_ds(m_ds),
      .m_ack(m_ack), .m_ack_early(m_ack_early), .m_handoff(m_handoff),
      .line_start(line_start), .frame(vblank_start), .cpu_first(cpu_first),
      .urgent(arb_urgent), .adv(arb_adv),
      .dbg_cpu_stall(dbg_cpu_stall),
      // THESE WERE NOT CONNECTED.  ss_memarb implements them and its own
      // header says why they are the number that matters -- "busy_clks /
      // acks IS clocks-per-read with nothing inferred" -- and the
      // instantiation omitted both, so they were dangling outputs and were
      // synthesised away.  Third instrument in this project found built and
      // wired to nothing.
      .dbg_line_acks(dbg_line_acks), .dbg_line_busy(dbg_line_busy)
  );

  ss_sdram #(.CLK_HZ(48_000_000)) u_sdram (
      .clk(clk), .init(~pll_locked), .frame(vblank_start),
            .addr(m_addr), .din(m_din), .dout(sd_dout),
      .req(m_req), .we(m_we), .ds(m_ds),
      .ack(m_ack), .ack_early(m_ack_early), .handoff(m_handoff),
      .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
      .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
      .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
      .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
      .dbg_row_hit(dbg_row_hit), .dbg_row_miss(dbg_row_miss),
      .dbg_row_conflict(dbg_row_conflict),
      .dbg_bus_work(), .dbg_bus_waste()
  );

endmodule

`default_nettype wire
