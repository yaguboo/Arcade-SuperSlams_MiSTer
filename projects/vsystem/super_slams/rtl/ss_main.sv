//============================================================================
//  Super Slams -- the 68000 side: CPU, address decode, and every board RAM
//
//  Memory map, suprslam.cpp:267-284.  Nothing else is decoded.
//
//      000000-0FFFFF  R   program ROM, 1 MB          -> SDRAM via ss_romcache
//      FB0000-FB1FFF  RW  sprite RAM       4 K words
//      FC0000-FCFFFF  RW  sprite tile LUT 32 K words  (the VS9210's table)
//      FD0000-FDFFFF  RW  work RAM        32 K words
//      FE0000-FE0FFF  RW  FG videoram      2 K words  (64 x 32)
//      FF0000-FF1FFF  RW  BG videoram      4 K words  (64 x 64)
//      FF2000-FF203F  RW  FG layer vregs  32 words
//      FF3000-FF3001   W  sprite buffer trigger
//      FF8000-FF8FFF  RW  053936 line RAM  2 K words
//      FF9001          W  sound latch, ODD byte
//      FFA000-FFAFFF  RW  palette          2 K words
//      FFD000-FFD01F   W  053936 control  16 words
//      FFE000-FFE001   W  tile bank
//      FFF000-FFF01F  RW  VS9209, ODD bytes only (umask 0x00FF)
//
//  ---- the tile bank register, 0xFFE000 --------------------------------
//
//      screen_bank = data & 0xF000      added to a 12-bit FG tile number
//      bg_bank     = (data & 0x0F00) << 4   added to a 12-bit BG tile number
//
//  So the two nibbles are NOT symmetric: the FG bank is bits 15:12 of the
//  register and lands at bits 15:12 of the tile number, while the BG bank is
//  bits 11:8 of the register and also lands at bits 15:12 of its tile number.
//  Measured value in attract: 0x0000 and 0x0202, so the FG bank is always 0
//  and the BG bank toggles between 0 and 2.
//
//  ---- the sprite buffer, 0xFF3000 -------------------------------------
//
//  MAME calls this "sprite buffer trigger?" and ignores it, drawing from live
//  sprite RAM after vblank -- which for a whole-frame renderer is the same as
//  drawing the end-of-frame state.  A SCANLINE renderer reading live RAM tears
//  whenever the CPU writes during active display, and the game writes this
//  address 0.98 times a frame, which is the shape of a per-frame swap.  So
//  sprite RAM is shadowed and the copy runs in vblank.  DECISIONS D4.
//============================================================================
`default_nettype none

module ss_main (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,          // held during ROM download
    input  wire        ce_en,            // global pause / download gate

    // --- program ROM, through the cache, to the arbiter -------------------
    output wire [24:0] rom_addr,
    output wire        rom_req,
    input  wire        rom_ack,
    input  wire [15:0] rom_data,

    // --- interrupt --------------------------------------------------------
    input  wire        vblank_irq,
    output wire        iack_stb,

    // --- VS9209 inputs ----------------------------------------------------
    input  wire [7:0]  p1, p2, sys_in, dsw1, dsw2,
    output wire [3:0]  spr_ctrl,
    output wire [7:0]  port_g,

    // --- sound latch ------------------------------------------------------
    output reg  [7:0]  latch_data,
    output reg         latch_we,

    // --- video engine read ports ------------------------------------------
    input  wire [11:0] bgv_addr,   output wire [15:0] bgv_q,
    input  wire [10:0] fgv_addr,   output wire [15:0] fgv_q,
    input  wire [11:0] spr_addr,   output wire [15:0] spr_q,
    input  wire [14:0] lut_addr,   output wire [15:0] lut_q,
    input  wire [10:0] pal_addr,   output wire [15:0] pal_q,

    // --- 053936, driven straight through to ss_roz ------------------------
    output wire        psac_ctrl_we,
    output wire [3:0]  psac_ctrl_a,
    output wire [15:0] psac_ctrl_d,
    output wire [1:0]  psac_ctrl_ds,
    output wire        psac_line_cs,
    output wire        psac_line_we,
    output wire [10:0] psac_line_a,
    output wire [15:0] psac_line_d,
    output wire [1:0]  psac_line_ds,
    input  wire [15:0] psac_line_q,

    // --- layer configuration ----------------------------------------------
    output wire [8:0]  fg_scrollx,
    output wire [3:0]  screen_bank,
    output wire [2:0]  bg_bank,

    // --- sprite buffering -------------------------------------------------
    input  wire        vblank_start,
    input  wire        spr_buffer_en,    // OSD: use the shadow, or draw live
    input  wire        dl_active,        // ROM download in progress

    // --- observability ----------------------------------------------------
    output wire [23:1] dbg_addr,
    output wire [31:0] dbg_d7,
    output wire        dbg_halted_n,
    output wire [15:0] dbg_vregs4,
    output wire [15:0] dbg_vregs5,

    // ---- the vblank counter at work RAM 0xFD1020, snooped ----------------
    //
    // The game spins at ROM 0x5F0 on this location and the level-1 handler
    // bumps it at ROM 0x572 with `addi.w #1, $fd1020.l`.  The interrupt IS
    // delivered and the 68000 DOES acknowledge it -- both counted on hardware,
    // ~60/s -- and the loop still never exits.  So either the write does not
    // happen, or it happens and the read does not see it, and those two need
    // separating before anything is changed.
    //
    //   wr_cnt rising, wr_val incrementing, rd_val following  -> not the fault
    //   wr_cnt rising, rd_val stuck                           -> READ path
    //   wr_cnt stuck at 0                                     -> the handler
    //                                                            never reaches
    //                                                            0x572
    output reg  [15:0] dbg_fd1020_wr_cnt,
    output reg  [15:0] dbg_fd1020_wr_val,
    output reg  [15:0] dbg_fd1020_rd_val,

    // ---- where the program actually IS, per frame -------------------------
    //
    // One address sample per screenshot is worthless for this: it caught
    // 0x5FC once and that ONE point was read as "stuck in the vblank wait",
    // which the counter snoop then disproved.  A range over a whole frame
    // cannot be misread that way.
    //
    // Fetch cycles only (FC = x10 is program space), latched between vblanks:
    //   a narrow range   -> a loop, and its address says which one
    //   a wide range     -> the program is running and the fault is elsewhere
    // MAME's PC over 600 frames of boot spans 0x00049A..0x00873A.
    input  wire        frame_tick,
    output reg  [15:0] dbg_pc_min,
    output reg  [15:0] dbg_pc_max,

    // ---- does the CPU write the VIDEO memories at all ---------------------
    //
    // Work RAM writes are proven to land and to read back.  The screen is
    // still one uniform colour, which is exactly what three silent layers
    // produce.  So: is the game putting anything IN the video memories, or
    // putting it in and the layers not reading it?  Those need different
    // fixes and look identical on screen.
    //
    //   all four rising   -> the game draws; the fault is in a layer
    //   fgv/bgv at zero   -> the game is not drawing, whatever else it does
    output reg  [15:0] dbg_wr_fgv,
    output reg  [15:0] dbg_wr_bgv,
    output reg  [15:0] dbg_wr_spr,
    output reg  [15:0] dbg_wr_pal,
    // PER FRAME, published on vblank_start.  A frame is 801,000 core clocks.
    //   dbg_cpu_wait  UNITS OF 16 CLOCKS the 68000 spent with a ROM read
    //                 outstanding.  A frame is 801,000 clocks = 50,063 units
    //   dbg_cpu_miss  cache misses served from SDRAM
    // MAME's own trace through a driven match says the CPU wants 39,373 ROM
    // words a frame and that an 8192-entry cache should leave 3,333 of them.
    output reg  [15:0] dbg_cpu_wait,
    output reg  [15:0] dbg_cpu_miss,
    // READS OF $FD1020 IN A FRAME = THE GAME'S OWN HEADROOM.
    //
    // The main loop is, from the ROM (DEBUG_LOG O6):
    //     5f6: cmp.w $fd1020.l, D0
    //     5fc: beq   $5f6
    // one read per turn of the spin and nothing else, so the count IS how
    // much of the frame the game had left after its work.  Zero means the
    // pass did not fit and that frame lands late -- which is what dropped
    // animation is.
    //
    // MAME's own figures over a driven workload (tools/ss_headroom.lua,
    // 5,100 frames), banded by the same frame's worst-line sprite tiles:
    //     0-15 tiles  mean 3147  min 2299
    //    32-47         mean 2467  min  885
    //    64-79         mean 1845  min  453
    //    80-95         mean 1435  min    1
    //    96-111        mean 1389  min    1
    // so this row is directly comparable with the reference, banded against
    // spr_tiles on page 0 from the same frame.
    output reg  [15:0] dbg_spin_fr
);

  // ---- the CPU -----------------------------------------------------------
  wire [23:1] cpu_a;
  wire [15:0] cpu_do;
  reg  [15:0] cpu_di;
  wire        cpu_rd, cpu_wr, uds_n, lds_n;
  reg         cpu_ack;
  wire [2:0]  fc;

  // Level 1 only.  suprslam.cpp:412 -- irq1_line_hold, and the driver's own
  // notes mark levels 2..7 as unused stubs.
  wire [2:0] ipl_n = vblank_irq ? 3'b110 : 3'b111;

  // 48 / 3 = 16.000 MHz, exactly.  CLK_DIV 3 is ODD, so ss_m68k puts enPhi1 at
  // divider 0 and enPhi2 at 1, and the next enPhi1 is two clocks later -- a
  // 33/67 duty cycle rather than 50/50.  fx68k is enable-driven and does not
  // care: the number of 68000 clocks per instruction is unchanged and the
  // FREQUENCY is exact, only the sub-cycle placement of the bus phases moves,
  // and nothing on this board samples the bus between our own clock edges.
  ss_m68k #(.CLK_DIV(3)) u_cpu (
      .clk(clk), .rst(rst), .cpu_rst(cpu_rst), .ce_en(ce_en),
      .addr(cpu_a), .dout(cpu_do), .din(cpu_di),
      .rd(cpu_rd), .wr(cpu_wr), .uds_n(uds_n), .lds_n(lds_n),
      .ack(cpu_ack), .ipl_n(ipl_n),
      .fc(fc), .iack_stb(iack_stb),
      .dbg_d7(dbg_d7), .as_n(), .halted_n(dbg_halted_n)
  );

  assign dbg_addr = cpu_a;
  wire [1:0] ds = {~uds_n, ~lds_n};
  wire [23:0] A  = {cpu_a, 1'b0};

  // ---- decode ------------------------------------------------------------
  wire in_ff   = (A[23:16] == 8'hFF);
  wire sel_rom = (A[23:20] == 4'h0);                    // 000000-0FFFFF
  wire sel_spr = (A[23:16] == 8'hFB) && (A[15:13] == 3'd0);
  wire sel_lut = (A[23:16] == 8'hFC);
  wire sel_wrk = (A[23:16] == 8'hFD);
  wire sel_fgv = (A[23:16] == 8'hFE) && (A[15:12] == 4'h0);

  wire sel_bgv  = in_ff && (A[15:13] == 3'd0);          // FF0000-FF1FFF
  wire sel_vreg = in_ff && (A[15:12] == 4'h2) && (A[11:6] == 6'd0);
  wire sel_trig = in_ff && (A[15:12] == 4'h3) && (A[11:1] == 11'd0);
  wire sel_line = in_ff && (A[15:12] == 4'h8);          // FF8000-FF8FFF
  wire sel_slat = in_ff && (A[15:12] == 4'h9) && (A[11:1] == 11'd0);
  wire sel_pal  = in_ff && (A[15:12] == 4'hA);          // FFA000-FFAFFF
  wire sel_pctl = in_ff && (A[15:12] == 4'hD) && (A[11:5] == 7'd0);
  wire sel_bank = in_ff && (A[15:12] == 4'hE) && (A[11:1] == 11'd0);
  wire sel_io   = in_ff && (A[15:12] == 4'hF) && (A[11:5] == 7'd0);

  // A write is held until it is acked, so the register file would take it
  // every enabled clock.  wr_taken gates it to the first.
  reg wr_taken;
  always @(posedge clk) begin
    if (rst)                  wr_taken <= 1'b0;
    else if (!cpu_wr)         wr_taken <= 1'b0;
    else if (ce_en && cpu_wr) wr_taken <= 1'b1;
  end
  wire wr1 = ce_en && cpu_wr && !wr_taken;

  // ---- program ROM cache -------------------------------------------------
  //
  // 1 MB of program is 512 K words and the cache is 16384 of them, direct
  // mapped.  MAINCPU_BASE_W is 0, so the cache's 19-bit word address IS the
  // SDRAM word address and no adder is needed.
  //
  // IT WAS 1024 UNTIL 2026-09-07, AND THAT WAS THE FRAME RATE.  A person at
  // the board reported severe slowdown; the game's own match clock measures
  // it, because MAME and the board run the same clock:
  //
  //     MAME    1.349 game-seconds per wall-second
  //     board   0.78                                 -> 58 % of MAME's speed
  //
  // The 68000 is bus-saturated by construction -- a read is 4 CPU clocks =
  // 12 core clocks at CLK_DIV 3 -- and it is the LOWEST priority client of
  // seven on a shared SDRAM its program ROM lives in.  Every clock of added
  // latency is a clock of lost speed, one for one.
  //
  // Sized by simulating a direct-mapped cache over MAME's own access trace
  // through a DRIVEN MATCH, before building anything (tools/ss_cpucache.lua):
  //
  //     uncached                   39,373 SDRAM words a frame
  //     1024 entries (what we had)  9,838   hit 75.0 %
  //     4096 entries                4,762   hit 87.9 %
  //     4096 entries                4,762   hit 87.9 %
  //     8192 entries                3,333   hit 91.5 %
  //    16384 entries                1,276   hit 96.8 %   <- this
  //    32768 entries                  300   hit 99.2 %   (80 M10K blocks, and
  //                                  only 64 came free)
  //     8192 entries                3,333   hit 91.5 %   -- DOES NOT FIT.
  //
  // 8192 synthesises fine once the invalidate is a walker, and then the
  // FITTER refuses it:
  //
  //     Error (170040): Can't place all RAM cells in design
  //     Error (11802):  Can't fit design in device
  //     Total block memory bits : 4,420,971 / 5,662,720  (78 %)
  //
  // 78 % of the BITS and it still does not fit, because the constraint is
  // M10K BLOCKS, not bits.  An M10K is 10,240 bits but its usable width falls
  // with depth -- 8192 deep is 1 bit wide -- so an 8192 x 16 array costs
  // SIXTEEN blocks while 4096 x 16 costs eight.  Doubling the depth doubled
  // the block cost of both the data and the tag arrays for a 30 % cut in
  // misses, and the device ran out.
  //
  // The lever that matters more is cpu_first anyway: of a miss's ~15 clocks,
  // about 7 are queuing, and that is free.
  //
  // Cost is ~146 K bits of block memory over the old one.  A cache of a
  // READ-ONLY ROM cannot change what the CPU sees, so there is no accuracy
  // question; the only correctness requirement is that it not survive the
  // ROM download.
  //
  // `rst | dl_active`, NOT `rst`.  rst_sys is RESET | status[0] | buttons[1] |
  // ~pll_locked and does not include dl_active, so a second dataslot load
  // without a system reset would leave the cache serving bytes the loader has
  // since replaced.  Today the 68000 is held in cpu_rst through a download and
  // so never fills it, which is why nothing has gone wrong yet -- but that is
  // an unstated assumption about a reset somebody else owns, and the sibling
  // lane wrote its version of this line for exactly that reason
  // (sf_romcache's header, and power_spikes LESSONS L3).
  wire        rom_cache_ack;
  wire [15:0] rom_cache_q;
  wire [19:1] rom_a_w;

  ss_romcache #(.IDX_BITS(14), .AW(19)) u_romc (
      .clk(clk), .rst(rst | dl_active),
      .c_a(cpu_a[19:1]), .c_rd(sel_rom & cpu_rd),
      .c_ack(rom_cache_ack), .c_q(rom_cache_q),
      .m_a(rom_a_w), .m_rd(rom_req), .m_ack(rom_ack), .m_q(rom_data)
  );
  assign rom_addr = {6'd0, rom_a_w};

  // ---- board RAMs --------------------------------------------------------
  wire [15:0] wrk_q, fgv_cpu_q, bgv_cpu_q, lut_cpu_q, pal_cpu_q, spr_cpu_q;

  ss_ram #(.AW(15)) u_work (
      .clk(clk), .addr(cpu_a[15:1]), .din(cpu_do),
      .we(wr1 & sel_wrk), .ds(ds), .q(wrk_q));

  // ---- the sprite tile LUT is read LIVE, like MAME ------------------------
  //
  // It was SHADOWED from build 16 to build 21, copied at vblank, on the
  // theory that reading it while the CPU writes it must tear -- 23.7 % of
  // writes to 0xFC0000 land during active display, measured.
  //
  // THAT WAS WRONG, and a person at the board settled it in one OSD toggle:
  // with the shadow, specific frames broke during fast action with the ball
  // and during the dunk festival; live, they did not.  vsystem_spr.cpp reads
  // m_sp_videoram[code] AT DRAW TIME, so live is what the reference does, and
  // a snapshot taken at vblank is a different frame's mapping for anything
  // animating fast.  The measurement was right; the conclusion drawn from it
  // was not -- "the CPU writes it during the visible area" does not imply
  // "therefore snapshot it", because the reference does not.
  //
  // Removing it also gives back 64 M10K blocks, which is what lets the
  // program-ROM cache go from 4096 entries to 16384 with the fitter at
  // 553 of 553.
  ss_dpram #(.AW(15)) u_lut (
      .clk(clk), .a_addr(cpu_a[15:1]), .a_din(cpu_do),
      .a_we(wr1 & sel_lut), .a_ds(ds), .a_q(lut_cpu_q),
      .b_addr(lut_addr), .b_q(lut_q));

  ss_dpram #(.AW(11)) u_fgv (
      .clk(clk), .a_addr(cpu_a[11:1]), .a_din(cpu_do),
      .a_we(wr1 & sel_fgv), .a_ds(ds), .a_q(fgv_cpu_q),
      .b_addr(fgv_addr), .b_q(fgv_q));

  ss_dpram #(.AW(12)) u_bgv (
      .clk(clk), .a_addr(cpu_a[12:1]), .a_din(cpu_do),
      .a_we(wr1 & sel_bgv), .a_ds(ds), .a_q(bgv_cpu_q),
      .b_addr(bgv_addr), .b_q(bgv_q));

  ss_dpram #(.AW(11)) u_pal (
      .clk(clk), .a_addr(cpu_a[11:1]), .a_din(cpu_do),
      .a_we(wr1 & sel_pal), .a_ds(ds), .a_q(pal_cpu_q),
      .b_addr(pal_addr), .b_q(pal_q));

  // ---- sprite RAM and its shadow ----------------------------------------
  //
  // The CPU owns the live RAM.  A copy engine walks all 4096 words into the
  // shadow when a frame starts AND the game has armed it by writing FF3000.
  // 4096 clocks of the ~155,000 a frame has, all of them inside vblank.
  wire [15:0] sprlive_q;
  reg  [11:0] copy_a;
  reg         copy_run, copy_armed;

  ss_dpram #(.AW(12)) u_sprram (
      .clk(clk), .a_addr(cpu_a[12:1]), .a_din(cpu_do),
      .a_we(wr1 & sel_spr), .a_ds(ds), .a_q(spr_cpu_q),
      .b_addr(copy_a), .b_q(sprlive_q));

  // The shadow's write port is the copy engine; its read port is the sprite
  // engine.  ONE delay stage, not two: the source RAM registers its output
  // once, so an address presented during clock N has its data on the bus
  // during clock N+1, and the write must carry the address that goes with the
  // data.  Two stages writes every word one address late -- which is a whole
  // sprite's attributes shifted by one word, so every sprite gets the previous
  // sprite's Y and its own X.  That looks like a sprite engine fault, not a
  // copy fault, which is why it is spelled out here.
  reg [11:0] copy_a_d1;
  reg        copy_v1;
  always @(posedge clk) begin
    copy_a_d1 <= copy_a;
    copy_v1   <= copy_run;
  end

  ss_dpram #(.AW(12)) u_sprshadow (
      .clk(clk), .a_addr(copy_a_d1), .a_din(sprlive_q),
      .a_we(copy_v1), .a_ds(2'b11), .a_q(),
      .b_addr(spr_addr), .b_q(spr_shadow_q));
  wire [15:0] spr_shadow_q;

  // The sprite engine always reads the SHADOW -- a true dual-port RAM has two
  // ports and the CPU and the copy engine already hold both, so there is no
  // third one to give it.  What the OSD switch changes is WHEN the copy runs:
  //
  //     spr_buffer_en = 1   copy only when the game armed it by writing
  //                         FF3000, which is DECISIONS D4's reading
  //     spr_buffer_en = 0   copy every vblank regardless, so FF3000 does
  //                         nothing
  //
  // Both are plausible hardware and the difference is visible, which is the
  // point of having the switch at all.  What it is NOT is "draw from live
  // RAM": that is what MAME does, and a scanline renderer cannot do it
  // without tearing.
  assign spr_q = spr_shadow_q;

  always @(posedge clk) begin
    if (rst) begin
      copy_run   <= 1'b0;
      copy_armed <= 1'b0;
      copy_a     <= 12'd0;
    end else begin
      if (wr1 && sel_trig) copy_armed <= 1'b1;
      if (vblank_start && (copy_armed || !spr_buffer_en)) begin
        copy_armed <= 1'b0;
        copy_run   <= 1'b1;
        copy_a     <= 12'd0;
      end else if (copy_run) begin
        if (copy_a == 12'hFFF) copy_run <= 1'b0;
        else                   copy_a   <= copy_a + 12'd1;
      end
    end
  end

  // ---- FG layer vregs ----------------------------------------------------
  //
  // 18 words are written every frame and MAME reads exactly one of them, the
  // scroll at 0x04.  0x08 = 0x0100, 0x0A = 0xFFB3 (-77) and 0x0C = 0xFFE6
  // (-26) are written every frame and are UNKNOWN -- they smell like layer
  // offsets, which is exactly what MAME's "sprite offset control?" TODO is
  // missing, so two of them are wired to the debug overlay.  HARDWARE H2.
  reg [15:0] vreg [0:31];
  integer vi;
  always @(posedge clk) begin
    if (rst) begin
      for (vi = 0; vi < 32; vi = vi + 1) vreg[vi] <= 16'd0;
    end else if (wr1 && sel_vreg) begin
      if (ds[1]) vreg[cpu_a[5:1]][15:8] <= cpu_do[15:8];
      if (ds[0]) vreg[cpu_a[5:1]][ 7:0] <= cpu_do[ 7:0];
    end
  end
  assign fg_scrollx = vreg[2][8:0];
  // ---- how much of the frame is the CPU waiting for its program? ---------
  // Both PER FRAME, published on vblank_start, because an all-time or
  // free-running counter of a saturating quantity says nothing after the
  // first busy frame.  801,000 core clocks in a frame is the scale.
  // IN UNITS OF 16 CLOCKS.  The first version counted single clocks into a
  // 16-bit register and read 0xFFFF on every one of sixteen hardware samples
  // -- a frame is 801,000 clocks, so it saturated in the first 8 % of a frame
  // and carried no information at all.  That is the third saturating counter
  // this factory has built after writing the lesson down twice.
  //
  // 801,000 / 16 = 50,063, which fits with room to spare, and the resolution
  // lost is 16 clocks out of a quantity whose interesting range is tens of
  // thousands.
  reg [15:0] wait_acc, miss_acc;
  reg [3:0]  wait_div;
  wire       cpu_rom_pending = sel_rom & cpu_rd & ~rom_cache_ack;
  always @(posedge clk) begin
    if (rst) begin
      wait_acc <= 16'd0; miss_acc <= 16'd0; wait_div <= 4'd0;
      dbg_cpu_wait <= 16'd0; dbg_cpu_miss <= 16'd0;
    end else if (vblank_start) begin
      dbg_cpu_wait <= wait_acc;
      dbg_cpu_miss <= miss_acc;
      wait_acc <= 16'd0;
      wait_div <= 4'd0;
      miss_acc <= (rom_req & rom_ack) ? 16'd1 : 16'd0;
    end else begin
      if (cpu_rom_pending) begin
        wait_div <= wait_div + 4'd1;
        if (wait_div == 4'd15 && wait_acc != 16'hFFFF) wait_acc <= wait_acc + 16'd1;
      end
      if (rom_req && rom_ack && miss_acc != 16'hFFFF) miss_acc <= miss_acc + 16'd1;
    end
  end

  assign dbg_vregs4 = vreg[4];
  assign dbg_vregs5 = vreg[5];

  // ---- tile bank ---------------------------------------------------------
  reg [15:0] bank;
  always @(posedge clk) begin
    if (rst) bank <= 16'd0;
    else if (wr1 && sel_bank) begin
      if (ds[1]) bank[15:8] <= cpu_do[15:8];
      if (ds[0]) bank[ 7:0] <= cpu_do[ 7:0];
    end
  end
  assign screen_bank = bank[15:12];
  // Three bits: the fourth is the wrap MAME's gfx_element does modulo the
  // 32768 tiles the 4 MB BG ROM holds.  ss_roz.sv has the reasoning.
  assign bg_bank     = bank[10:8];

  // ---- 053936, straight through -----------------------------------------
  assign psac_ctrl_we = wr1 & sel_pctl;
  assign psac_ctrl_a  = cpu_a[4:1];
  assign psac_ctrl_d  = cpu_do;
  assign psac_ctrl_ds = ds;
  assign psac_line_cs = sel_line;
  assign psac_line_we = wr1 & sel_line;
  assign psac_line_a  = cpu_a[11:1];
  assign psac_line_d  = cpu_do;
  assign psac_line_ds = ds;

  // ---- sound latch -------------------------------------------------------
  // 0xFF9001 is the ODD byte, so it only lands on an LDS cycle.
  always @(posedge clk) begin
    latch_we <= 1'b0;
    if (rst) latch_data <= 8'd0;
    else if (wr1 && sel_slat && ds[0]) begin
      latch_data <= cpu_do[7:0];
      latch_we   <= 1'b1;
    end
  end

  // ---- VS9209 ------------------------------------------------------------
  wire [7:0] io_q;
  ss_io u_io (
      .clk(clk), .rst(rst),
      .cs(sel_io), .we(wr1 & sel_io & ds[0]), .a(cpu_a[4:1]),
      .din(cpu_do[7:0]), .dout(io_q),
      .p1(p1), .p2(p2), .system(sys_in), .dsw1(dsw1), .dsw2(dsw2),
      .port_h(spr_ctrl), .port_g(port_g), .port_f()
  );

  // ---- snoop on 0xFD1020 -------------------------------------------------
  // Work RAM is 32768 words and 0xFD1020 is word 0x810 inside it.
  wire sel_ctr = sel_wrk && (cpu_a[15:1] == 15'h810);
  always @(posedge clk) begin
    if (rst) begin
      dbg_fd1020_wr_cnt <= 16'd0;
      dbg_fd1020_wr_val <= 16'd0;
      dbg_fd1020_rd_val <= 16'd0;
    end else begin
      if (wr1 && sel_ctr) begin
        dbg_fd1020_wr_val <= cpu_do;
        if (dbg_fd1020_wr_cnt != 16'hFFFF)
          dbg_fd1020_wr_cnt <= dbg_fd1020_wr_cnt + 16'd1;
      end
      // sampled where the CPU samples it: on the ack of a read
      if (cpu_ack && cpu_rd && sel_ctr) dbg_fd1020_rd_val <= wrk_q;
    end
  end

  // ---- the spin count, per frame -----------------------------------------
  reg [15:0] spin_acc;
  always @(posedge clk) begin
    if (rst) begin
      spin_acc <= 16'd0;
      dbg_spin_fr <= 16'd0;
    end else if (vblank_start) begin
      dbg_spin_fr <= spin_acc;
      spin_acc <= (cpu_ack && cpu_rd && sel_ctr) ? 16'd1 : 16'd0;
    end else if (cpu_ack && cpu_rd && sel_ctr && spin_acc != 16'hFFFF) begin
      spin_acc <= spin_acc + 16'd1;
    end
  end

  // ---- video-memory write counters ---------------------------------------
  always @(posedge clk) begin
    if (rst) begin
      dbg_wr_fgv <= 16'd0; dbg_wr_bgv <= 16'd0;
      dbg_wr_spr <= 16'd0; dbg_wr_pal <= 16'd0;
    end else if (wr1) begin
      if (sel_fgv && dbg_wr_fgv != 16'hFFFF) dbg_wr_fgv <= dbg_wr_fgv + 16'd1;
      if (sel_bgv && dbg_wr_bgv != 16'hFFFF) dbg_wr_bgv <= dbg_wr_bgv + 16'd1;
      if (sel_spr && dbg_wr_spr != 16'hFFFF) dbg_wr_spr <= dbg_wr_spr + 16'd1;
      if (sel_pal && dbg_wr_pal != 16'hFFFF) dbg_wr_pal <= dbg_wr_pal + 16'd1;
    end
  end

  // ---- program-counter range, per frame ---------------------------------
  wire is_fetch = cpu_rd && (fc[1:0] == 2'b10);   // program space, user or sup
  reg [15:0] pc_lo_acc, pc_hi_acc;
  always @(posedge clk) begin
    if (rst) begin
      pc_lo_acc <= 16'hFFFF; pc_hi_acc <= 16'd0;
      dbg_pc_min <= 16'd0;   dbg_pc_max <= 16'd0;
    end else if (frame_tick) begin
      dbg_pc_min <= pc_lo_acc;
      dbg_pc_max <= pc_hi_acc;
      pc_lo_acc  <= 16'hFFFF;
      pc_hi_acc  <= 16'd0;
    end else if (is_fetch) begin
      if (cpu_a[16:1] < pc_lo_acc) pc_lo_acc <= cpu_a[16:1];
      if (cpu_a[16:1] > pc_hi_acc) pc_hi_acc <= cpu_a[16:1];
    end
  end

  // ---- read mux and ack --------------------------------------------------
  //
  // Everything except the ROM answers in one clock, so the ack for those is
  // the read request delayed by one.  The ROM is the only source that can
  // stall, and it is the only one that gates cpu_ack.
  reg rd_d;
  always @(posedge clk) rd_d <= cpu_rd & ce_en;

  always @(*) begin
    cpu_di = 16'hFFFF;
    if      (sel_rom)  cpu_di = rom_cache_q;
    else if (sel_wrk)  cpu_di = wrk_q;
    else if (sel_lut)  cpu_di = lut_cpu_q;
    else if (sel_spr)  cpu_di = spr_cpu_q;
    else if (sel_fgv)  cpu_di = fgv_cpu_q;
    else if (sel_bgv)  cpu_di = bgv_cpu_q;
    else if (sel_pal)  cpu_di = pal_cpu_q;
    else if (sel_line) cpu_di = psac_line_q;
    else if (sel_vreg) cpu_di = vreg[cpu_a[5:1]];
    // umask16(0x00FF): the device is on the LOW byte, which on a big-endian
    // 68000 is the ODD address.  The upper byte is not driven by anything.
    else if (sel_io)   cpu_di = {8'hFF, io_q};
  end

  always @(*) begin
    if (sel_rom) cpu_ack = rom_cache_ack;
    else         cpu_ack = ce_en & (rd_d | cpu_wr);
  end

endmodule

`default_nettype wire
