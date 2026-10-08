//============================================================================
//  Super Slams -- Fujitsu CG10103 sprites (MAME's VSYSTEM_SPR)
//
//  NOT the chip Power Spikes has.  pspikes.cpp includes vsystem_spr2.h and
//  suprslam.cpp includes vsystem_spr.h; MAME keeps them in separate files
//  because they are separate parts, and the attribute layout differs in five
//  fields.  docs/POWER_SPIKES_REUSE_ANALYSIS.md section 4 has the table.
//
//  ---- the list is two levels ---------------------------------------------
//
//  Words 0..511 of sprite RAM are a SORT LIST, and the attributes live in the
//  same 4096-word RAM at 4*(index & 0x3FF) -- so the list and the attribute
//  table overlap, and indices 0..127 point back into the list.  That is how
//  the chip is addressed, not a bug.
//
//      list word   [14] END OF LIST -- stop, do not look further
//                  [15] skip this entry
//                  [9:0] sprite index
//
//      attr w0     [8:0] oy    [11:9] ysize   [15:12] zoomy
//      attr w1     [8:0] ox    [11:9] xsize   [15:12] zoomx
//      attr w2     [0] map bit 16   [13:8] colour (6 bits)
//                  [14] flipx      [15] flipy
//      attr w3     map bits 15:0
//
//  Tile numbers are INDIRECT: the chip walks `map` and the tile number is
//  sp_videoram[map++] -- the VS9210's job.  Straight increment, with none of
//  the power-of-two row-stride correction VSYSTEM_SPR2 needs.
//
//  There is NO per-sprite priority: suprslam.cpp never calls set_pri_cb.  The
//  list is drawn in order and later entries win, so this engine writes
//  unconditionally and the last write to a pixel is the one that stays.
//
//  ---- ZOOM: this is where the sibling lane is wrong -----------------------
//
//  MAME transforms the field as `zoom = 32 - raw` and passes `zoom << 11` as a
//  16.16 scale to gfx_element::zoom_transpen, which is
//  emu/drawgfxt.ipp:750-756 and 796:
//
//      dstwidth = (scalex * 16 + 0x8000) >> 16     ->  (zoom + 1) >> 1
//      dx       = (16 << 16) / dstwidth
//      srcx(c)  = (c * dx) >> 16          and, flipped, ((dst-1-c) * dx) >> 16
//
//  Power Spikes computes `src = (c * zoom) >> 5` with a destination width of
//  `zoom / 2`.  At zoom 32 both give src = c, which is why that core matches
//  MAME -- 86 % of the sprites this game draws are 1:1 too (measured: 3562 of
//  4154).  Away from 1:1 the two disagree, and they disagree by INVERSION:
//  at zoom 17 MAME reads source columns 0,1,3,5,7,9,11,13,14 across 9
//  destination pixels, and (c*zoom)>>5 reads 0,0,1,2,3,4,5,6 across 8 --
//  the left half of the tile stretched, instead of the whole tile shrunk.
//  docs/LESSONS_LEARNED.md L1.
//
//  `dx` needs a division, but only eight divisors are reachable (dstwidth is
//  9..16), so DX_TAB below is that division, done once and by hand.
//
//  Note dstwidth is (zoom+1)>>1 while the tile SPACING is (n*zoom)>>1, and for
//  odd zoom those differ by one -- so tiles overlap by a pixel and two tile
//  ROWS can cover the same scanline.  Both are drawn, in order, which is what
//  MAME does; this is not an off-by-one to be tidied away.
//
//  ---- budget ------------------------------------------------------------
//
//  Measured over 1200 frames of attract, boot excluded: 34 list entries at
//  most, and 55 tiles on the worst scanline.  The list can hold 512 and the
//  format allows 8x8 tiles per sprite; sizing on the format rather than on the
//  game would buy hardware nobody uses.  A tile costs one LUT read, four
//  SDRAM words and up to 16 blit clocks, so the worst measured line is about
//  1500 of the 3053 clocks a line has.  dbg_overrun and dbg_tiles are here
//  from the first build because attract is not gameplay.
//============================================================================
`default_nettype none

module ss_sprite #(
    parameter int H_VISIBLE = 320,
    parameter bit [24:0] SPRITES_BASE_W = 25'h400000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,            // one clock, start of a line
    input  wire        frame,            // one clock, start of a frame
    input  wire [8:0]  sline,            // the line to RENDER (one ahead)
    output reg         busy,

    // --- sprite RAM read port (4096 words) --------------------------------
    output reg  [11:0] sram_addr,
    input  wire [15:0] sram_data,

    // --- sprite tile LUT RAM read port (32768 words) ----------------------
    output reg  [14:0] lut_addr,
    input  wire [15:0] lut_data,

    // --- SDRAM ------------------------------------------------------------
    output wire [24:0] rom_addr,
    output reg         rom_req,
    output reg         rom_hold,
    input  wire        rom_ack,
    input  wire        rom_adv,          // FIX: arbiter offer for a holder
    input  wire [15:0] rom_data,

    // --- line buffer, display side ----------------------------------------
    input  wire        lb_par,
    input  wire [8:0]  lb_x,
    output wire [10:0] lb_q,             // {opaque, colour[5:0], pen[3:0]}

    // ---- READ THESE TOGETHER, AND MIND WHICH IS WHICH ----------------------
    //
    // dbg_trunc_total is CUMULATIVE and saturating: lines the engine had not
    // finished when the next one started, since reset.  It is the closure
    // number -- "zero truncated lines over workload W" is one reading of it,
    // not a percentile over sampled frames.  Sampling a per-frame counter by
    // screenshot cannot see an event that happens in 1 % of frames.
    //
    // The other three are PER FRAME.  They used to be all-time maxima while
    // the overlay called them "worst line of frame", which is how a spr_wait
    // frozen at the first line that ever saturated got read as a like-for-like
    // comparison between two builds.  An all-time maximum of a thing that
    // saturates tells you almost nothing after the first time it happens.
    //
    // Classification: a frame with dbg_trunc_total unchanged is a frame where
    // dbg_tiles is DEMAND -- what the game asked for and got.  A frame where
    // it moved is one where dbg_tiles is the engine's CEILING on that line.
    // Without that distinction a pinned reading is ambiguous, and it was.
    output reg  [15:0] dbg_trunc_total,  // CUMULATIVE truncated lines
    output reg  [15:0] dbg_overrun,      // per frame, same event
    output reg  [15:0] dbg_tiles,        // per frame: most tiles on any line

    // ---- where the line's clocks actually go -------------------------------
    // The simulation bench and the board disagree about this change: the bench
    // says the tile got 17 % cheaper and the board says 7 % dearer.  One of
    // them is modelling the SDRAM wrong and it is not going to be settled by
    // reasoning about it, so measure the two halves on the hardware that has
    // the real memory attached.
    //
    // Both are the WORST LINE of the frame, republished every line-start, so
    // they can be read against dbg_tiles from the same frame.
    output reg  [15:0] dbg_busy_clks,    // per frame: worst line's clocks
    output reg  [15:0] dbg_wait_clks     // ...that same line's rom stall
);

  // ---- line buffers: FOUR arrays, and the second split is the point ------
  //
  // Two of them are the display double buffer, which is what ss_roz.sv
  // explains.  The other split is by PIXEL PARITY -- even x in one array, odd
  // x in another -- and it exists so the blit can retire TWO pixels a clock.
  //
  // The obvious way to write two pixels a clock is a second write port, and
  // no M10K has one; this core already built 11,264 flip-flops by accident
  // that way.  Splitting by parity needs no second port: two consecutive
  // destination pixels are always one even and one odd, so they land in
  // DIFFERENT arrays, each of which keeps exactly one write and one read
  // port.  Same total bits -- 4 x 256 x 11 is 2 x 512 x 11.
  //
  // MEASURED, not assumed.  sim/tb_ss_sprite.sv sweeps the ROM latency: at
  // the latency the real SDRAM delivers, the fetch costs about 15 clocks a
  // tile and the blit 18, so the blit was the longer of the two halves the
  // pipeline runs in parallel.  Halving it moves the limit back onto the
  // fetch, and it halves the buffer clear as well -- 320 clocks a line become
  // 160, which is 160 more clocks for tiles.
  reg [10:0] lb0e [0:255];
  reg [10:0] lb0o [0:255];
  reg [10:0] lb1e [0:255];
  reg [10:0] lb1o [0:255];
  reg [10:0] q0e, q0o, q1e, q1o;

  // Up to two pixels per clock, each with its own enable: one of a pair can be
  // transparent or off-screen while the other is not.
  reg        wr_e_en, wr_o_en;
  reg [7:0]  wr_e_a,  wr_o_a;
  reg [10:0] wr_e_d,  wr_o_d;
  wire       wr_par = sline[0];

  reg        clr_en;
  reg [7:0]  clr_x;          // 0..159, clears both parities at once

  // The clear and the blit are separate FSM states and can never both fire,
  // so they are muxed onto one write port per array rather than written as
  // two `if`s -- which would be two write ports and a read, and no M10K has
  // three.  Root CLAUDE.md section 7, step 0: if a module is not in the
  // fitter's RAM summary, it is logic.
  wire       we_e = wr_e_en | clr_en;
  wire       we_o = wr_o_en | clr_en;
  wire [7:0] wa_e = clr_en ? clr_x : wr_e_a;
  wire [7:0] wa_o = clr_en ? clr_x : wr_o_a;
  wire [10:0] wd_e = clr_en ? 11'd0 : wr_e_d;
  wire [10:0] wd_o = clr_en ? 11'd0 : wr_o_d;

  wire [7:0] rd_a = lb_x[8:1];

  always @(posedge clk) begin
    if (we_e && !wr_par) lb0e[wa_e] <= wd_e;
    if (we_o && !wr_par) lb0o[wa_o] <= wd_o;
    if (we_e &&  wr_par) lb1e[wa_e] <= wd_e;
    if (we_o &&  wr_par) lb1o[wa_o] <= wd_o;
    q0e <= lb0e[rd_a];  q0o <= lb0o[rd_a];
    q1e <= lb1e[rd_a];  q1o <= lb1o[rd_a];
  end
  // lb_x is registered one clock ahead of the data, so the parity that selects
  // between the two arrays has to be delayed with it.
  reg lb_x0_d;
  always @(posedge clk) lb_x0_d <= lb_x[0];
  assign lb_q = lb_par ? (lb_x0_d ? q1o : q1e)
                       : (lb_x0_d ? q0o : q0e);

  // ---- the reciprocal table ----------------------------------------------
  //
  // TODO(HARDWAREIZE): accuracy = EMULATION_DERIVED.
  // vsystem_spr.cpp:53 -- "Zoom factor is not correct, the scale is probably
  // non-linear" -- is upstream saying its OWN zoom is wrong.  The table below
  // reproduces MAME exactly and is therefore wrong in the same way, on
  // purpose: matching a known reference beats improvising against none, and
  // the sibling lane improvised and inverted the reciprocal (LESSONS L1).
  // The arithmetic runs in the FPGA, so this is PURE_RTL and does NOT block
  // release (factory rules 2026-09-06 section 2.4).  Replace when someone
  // measures a real CG10103.  docs/UPSTREAM_TODO_AUDIT.md U1.
  //
  //     zoom     = 32 - raw
  //     dstwidth = (zoom + 1) >> 1 = (33 - raw) >> 1      9..16
  //     dx       = (16 << 16) / dstwidth
  //
  // Written out rather than divided, so the values can be checked against
  // emu/drawgfxt.ipp by hand and so no divider appears in a per-pixel path.
  function automatic [17:0] dx_of(input [3:0] raw);
    case ((6'd33 - {2'd0, raw}) >> 1)      // = dstwidth, 9..16
      6'd16:   dx_of = 18'd65536;
      6'd15:   dx_of = 18'd69905;
      6'd14:   dx_of = 18'd74898;
      6'd13:   dx_of = 18'd80659;
      6'd12:   dx_of = 18'd87381;
      6'd11:   dx_of = 18'd95325;
      6'd10:   dx_of = 18'd104857;
      default: dx_of = 18'd116508;         // dstwidth 9
    endcase
  endfunction

  function automatic [4:0] dstsize_of(input [3:0] raw);
    dstsize_of = 5'((6'd33 - {2'd0, raw}) >> 1);
  endfunction

  // ---- decoded sprite ----------------------------------------------------
  reg [8:0]  s_oy, s_ox;
  reg [2:0]  s_ysize, s_xsize;
  reg [3:0]  s_zy_raw, s_zx_raw;
  reg [5:0]  s_colour;
  reg        s_flipx, s_flipy;
  // 15 bits, not the 17 the format defines.  attr w2 bit 0 is map bit 16 and
  // w3 is bits 15:0, but the LUT RAM this indexes holds 32768 words -- MAME
  // would read past the end of its array.  The two top bits are dropped HERE,
  // at the decode, so the discard is visible next to the field it belongs to.
  // Largest index the game actually produced in 1200 frames: 0x3F80.
  reg [14:0] s_map;

  wire [5:0]  s_zoomy = 6'd32 - {2'd0, s_zy_raw};
  wire [5:0]  s_zoomx = 6'd32 - {2'd0, s_zx_raw};
  wire [4:0]  s_dsth  = dstsize_of(s_zy_raw);
  wire [4:0]  s_dstw  = dstsize_of(s_zx_raw);
  wire [17:0] s_dy    = dx_of(s_zy_raw);
  wire [17:0] s_dx    = dx_of(s_zx_raw);

  // ---- walkers -----------------------------------------------------------
  reg [9:0]  lidx;                 // sort-list index 0..511 (10 bits to end)
  reg [2:0]  k;                    // tile ROW visit index
  // TWO tile indices, because the fetch runs a tile ahead of the blit.
  // FOUR BITS, NOT THREE, AND THAT IS THE WHOLE POINT.  s_xsize is 3 bits, so
  // the largest block the format allows is xsize = 7 -- eight tiles across --
  // and the loop below ends on `fj > s_xsize`.  A 3-bit fj wraps 7 -> 0 and
  // that condition is then UNSATISFIABLE: the engine walks the same row for
  // ever and every sprite after it in the list is lost.
  //
  // The four team-name sprites on TEAM SELECT are the only ones in this game
  // that use xsize = 7, and they were exactly what was missing from that
  // screen.  The pipeline rewrite introduced this by changing the original
  // `j == s_xsize` to `fj > s_xsize`; equality could reach 7 and the
  // comparison cannot.  Same shape as the ce_pix && line_start fault this core
  // started the day with, and self-inflicted.
  reg [3:0]  fj;                   // tile the FETCH is working on
  reg [3:0]  bj;                   // tile the BLIT is working on
  reg        fbank, bbank;         // which word bank each stage owns
  reg [1:0]  loaded;               // bank has a tile issued into it
  reg [14:0] map_row;              // map index at the start of this row,
                                   // already narrowed to what the LUT can hold
  reg [1:0]  wsel;                 // which of the 4 words of the source row
  reg [7:0]  have;                 // {bank, wsel} -> that word has landed
  // The blit consumes words in the order `col_in_tile[3:2]` walks, which is
  // FORWARD normally and BACKWARD under flipx.  Fetching in that same order is
  // what lets the two overlap for flipped sprites as well as upright ones; a
  // fixed 0,1,2,3 would make every flipped tile wait for the whole row.
  wire [1:0] last_w = s_flipx ? 2'd0 : 2'd3;
  wire [1:0] next_w = s_flipx ? (wsel - 2'd1) : (wsel + 2'd1);
  reg [15:0] rw [0:7];             // {bank, wsel} -- two rows in flight
  reg signed [10:0] tsx [0:1];     // each bank's screen x
  reg [4:0]  c;                    // destination column inside the tile
  reg [3:0]  src_row;
  reg [15:0] tile_no;
  reg [15:0] tiles_this_line;
  reg [15:0] busy_acc, wait_acc;
  // per-frame accumulators, published on `frame`
  reg [15:0] tiles_fmax, busy_fmax, wait_fmax, ovr_facc;

  // visit index -> tile index; a flipped block is visited in reverse while the
  // map index still advances forwards, which is how MAME's loop is written.
  wire [2:0] ycnt = s_flipy ? (s_ysize - k) : k;
  wire [2:0] xcnt  = s_flipx ? (s_xsize - fj[2:0]) : fj[2:0];  // fetch side

  // MAME: oy + ycnt * zoomy / 2, and C parses that as (ycnt * zoomy) / 2 --
  // accumulate THEN halve, so the spacing is not a uniform zoomy>>1.
  // The halve is part of the expression, not a slice of a named product, so
  // that the bit thrown away has no name to be mistaken for a signal.
  wire [8:0] yspace = 9'(({4'd0, ycnt} * {4'd0, s_zoomy}) >> 1);
  wire [8:0] xspace = 9'(({4'd0, xcnt} * {4'd0, s_zoomx}) >> 1);
  wire [9:0] yoff   = {1'b0, s_oy} + {1'b0, yspace};
  wire [9:0] xoff   = {1'b0, s_ox} + {1'b0, xspace};

  // TODO(HARDWAREIZE): accuracy = EMULATION_DERIVED.  vsystem_spr.cpp:54
  // calls this wrap "just a hack" and guesses the chip decides per sprite.
  // docs/UPSTREAM_TODO_AUDIT.md U2.
  //
  // The chip draws every tile four times, at (x,y), (x-0x200, y), (x, y-0x200)
  // and (x-0x200, y-0x200) -- its own comment calls the wrap "just a hack".
  // A 320-pixel line and a 16-pixel tile cannot see two copies 512 apart, so
  // rather than blit twice, pick the copy that can be on screen.
  wire signed [10:0] ya = {1'b0, yoff};
  wire signed [10:0] rel_a = $signed({2'b0, sline}) - ya;
  wire signed [10:0] rel_b = rel_a + 11'sd512;
  wire hit_a = (rel_a >= 0) && (rel_a < $signed({6'd0, s_dsth}));
  wire hit_b = (rel_b >= 0) && (rel_b < $signed({6'd0, s_dsth}));
  wire row_hit = hit_a | hit_b;
  wire [4:0] rel = hit_a ? rel_a[4:0] : rel_b[4:0];

  wire signed [10:0] xa = {1'b0, xoff};
  wire signed [10:0] sx_sel = (xa <= 11'sd319) ? xa : (xa - 11'sd512);

  // MAME clips inside drawgfx and pays for the tile regardless; we can decline
  // it before the lookup.  Measured worth about 7 % of tiles at the high
  // percentiles (tools/ss_sprload.lua, "ON-SCREEN tiles only"), which is
  // small -- but it costs one comparator and one clock instead of ~20.
  wire tile_visible = (sx_sel + $signed({6'd0, s_dstw}) > 11'sd0)
                   && (sx_sel < 11'sd320);

  // ---- SPRITE prefetch ---------------------------------------------------
  // Measured on the board during a real match: the engine truncates lines
  // while issuing only 90-107 tiles, well under the 116 it can reach in
  // attract.  The missing time is the LIST WALK -- three clocks to read a
  // sort-list entry and five more for its four attribute words, on every one
  // of up to 45 entries, most of which do not touch the line at all.  About
  // 500 clocks of 3057, and it comes straight out of the tile budget.
  //
  // The sprite RAM port is idle for the whole of S_ROW and S_DRAW, so the next
  // entry is read while the current sprite is being drawn.  A sprite that
  // cannot reach this line is then dropped in ONE clock instead of eight.
  //
  // Same idea as the tile-lookup prefetch above, one level out.
  localparam [3:0] SP_IDLE = 4'd0, SP_L1 = 4'd1, SP_L2 = 4'd2,
                   SP_A0   = 4'd3, SP_A1 = 4'd4, SP_A2 = 4'd5,
                   SP_A3   = 4'd6, SP_A4 = 4'd7;
  reg [3:0]  sp;
  reg [9:0]  sp_scan;          // next list index to look at
  reg [9:0]  sp_idx;           // the index the shadow words belong to
  reg [15:0] sp_w0, sp_w1, sp_w2, sp_w3;
  reg        sp_valid, sp_end;

  // ---- whole-sprite Y reject, from w0 alone -------------------------------
  // A sprite that cannot touch this line used to cost the other three
  // attribute words and a walk down every tile row looking for a hit that was
  // never there -- about 11 clocks, on every one of up to 45 list entries, on
  // every one of 262 lines.  w0 carries oy, ysize and zoomy, which is the
  // whole vertical extent, so the question is answerable one word in.
  wire [9:0]  spr_top  = {1'b0, s_oy};
  wire [9:0]  spr_span = 10'((({4'd0, s_ysize} * {4'd0, s_zoomy}) >> 1))
                       + {5'd0, s_dsth};
  wire signed [10:0] sy_a = $signed({2'b0, sline}) - $signed({1'b0, spr_top});
  wire signed [10:0] sy_b = sy_a + 11'sd512;
  wire spr_y_hit = ((sy_a >= 0) && (sy_a < $signed({1'b0, spr_span})))
                || ((sy_b >= 0) && (sy_b < $signed({1'b0, spr_span})));

  // The same test on the PREFETCHED word, so a sprite that cannot reach this
  // line never becomes the current one at all.
  wire [5:0] sp_zoomy = 6'd32 - {2'd0, sp_w0[15:12]};
  wire [4:0] sp_dsth  = dstsize_of(sp_w0[15:12]);
  wire [9:0] sp_span  = 10'((({4'd0, sp_w0[11:9]} * {4'd0, sp_zoomy}) >> 1))
                      + {5'd0, sp_dsth};
  wire signed [10:0] spy_a = $signed({2'b0, sline}) - $signed({2'b0, sp_w0[8:0]});
  wire signed [10:0] spy_b = spy_a + 11'sd512;
  wire sp_y_hit = ((spy_a >= 0) && (spy_a < $signed({1'b0, sp_span})))
               || ((spy_b >= 0) && (spy_b < $signed({1'b0, sp_span})));

  // The block flip is folded in the way drawgfxt.ipp:796 does it -- the source
  // accumulator starts at the far end and steps backwards, which forwards is
  // (dstsize - 1 - index).
  wire [4:0] eff_r = s_flipy ? (s_dsth - 5'd1 - rel) : rel;
  wire [4:0] eff_c = s_flipx ? (s_dstw - 5'd1 - c)   : c;
  // WIDEN BEFORE YOU MULTIPLY.  The sibling lane sized this product to its
  // 6-bit context, it evaluated modulo 64, and every sprite pixel came from
  // source column 0 or 1 -- vertical stripes at exactly the right position and
  // size, which reads as a ROM interleave fault rather than as arithmetic.
  // >> 16 is the 16.16 fixed point, and the result is 0..15 because
  // (dstsize-1) * dx is always under 16<<16 by construction.  Sliced in the
  // expression for the same reason as above.
  wire [3:0] row_in_tile = 4'((({18'd0, eff_r} * s_dy) >> 16));
  wire [3:0] col_in_tile = 4'((({18'd0, eff_c} * s_dx) >> 16));

  // 8 MB / 128 bytes per tile = 65536 tiles, so the whole 16-bit LUT word is
  // the tile number and nothing is dropped.  SPRITES_BASE_W is bit 22 and the
  // index below is 22 bits, so this is an OR -- tools/build_rom.py aligns the
  // regions for exactly this.
  // The address advances COMBINATIONALLY on the ack, not one clock after it.
  //
  // ss_sdram's chain fast path issues the next READ from S_CL3 -- the same
  // clock our ack arrives -- and it uses whatever `addr` says at that moment.
  // With `wsel` advancing on a non-blocking assignment the next address only
  // appeared a clock later, so the chain could not be used and every word paid
  // the full S_IDLE path.  ss_memarb says as much in the branch that excludes
  // holders from `early`: "a holder has not seen its ack, so its address is
  // still the word just read".  That is true of a REGISTERED pointer and this
  // makes it false.
  //
  // MEASURED, on hardware, before the change: the worst sprite line took 3057
  // clocks -- an entire line -- and 1371 of them were rom_req high with no
  // ack.  45 % of the line, waiting.
  // FIX: TWO pointers.  `wsel` is the next word to STORE (advances on the
  // ack).  `wfetch` is the next word to ISSUE: it advances on the arbiter's
  // offer (S_CL2), so that during S_CL3 -- the clock the chain samples the
  // address, one clock BEFORE the ack -- the address is already the next
  // word.  If no offer came (the word went round through S_IDLE), the ack
  // finds wfetch == wsel and advances both.
  reg  [1:0] wfetch;
  assign rom_addr = SPRITES_BASE_W | {3'd0, tile_no, src_row, wfetch};

  // the 16 pixels of the fetched row, MSB nibble first (packed_msb)
  wire [15:0] rwsel = rw[{bbank, col_in_tile[3:2]}];
  reg [3:0] pen;
  always @(*) begin
    case (col_in_tile[1:0])
      2'd0: pen = rwsel[15:12];
      2'd1: pen = rwsel[11: 8];
      2'd2: pen = rwsel[ 7: 4];
      default: pen = rwsel[3:0];
    endcase
  end

  // The SECOND pixel of the pair.  Its source column needs its own multiply
  // -- with zoom, consecutive destination columns are not consecutive source
  // columns -- and its own word, which may be a different one of the four.
  wire [4:0] c_b    = c + 5'd1;
  wire [4:0] eff_cb = s_flipx ? (s_dstw - 5'd1 - c_b) : c_b;
  wire [3:0] col_b  = 4'((({18'd0, eff_cb} * s_dx) >> 16));
  wire [15:0] rwsel_b = rw[{bbank, col_b[3:2]}];
  reg  [3:0] pen_b;
  always @(*) begin
    case (col_b[1:0])
      2'd0: pen_b = rwsel_b[15:12];
      2'd1: pen_b = rwsel_b[11: 8];
      2'd2: pen_b = rwsel_b[ 7: 4];
      default: pen_b = rwsel_b[3:0];
    endcase
  end

  wire signed [10:0] px = tsx[bbank] + $signed({6'd0, c});
  wire signed [10:0] px_b = px + 11'sd1;
  wire on_screen_b = (px_b >= 0) && (px_b < $signed(11'(H_VISIBLE)));

  // Both words present?  Early in a tile only some of the four have landed,
  // and then the blit falls back to one pixel a clock rather than waiting.
  wire have_a = have[{bbank, col_in_tile[3:2]}];
  wire have_b = have[{bbank, col_b[3:2]}];
  wire pair_ok = (c_b < s_dstw) && have_a && have_b;
  wire on_screen = (px >= 0) && (px < $signed(11'(H_VISIBLE)));

  // map index of the tile being fetched
  // The LUT holds 32768 words, so only 15 bits of the 17-bit map index can
  // reach it.  MAME would read out of bounds; the game does not go there (the
  // largest index measured in 1200 frames is 0x3F80).
  wire [14:0] map_cur = map_row + {11'd0, fj};

  // ---- FSM ---------------------------------------------------------------
  localparam [4:0] S_IDLE  = 5'd0,  S_CLR   = 5'd1,
                   S_L0    = 5'd2,  S_L1    = 5'd3,  S_L2    = 5'd4,
                   S_A0    = 5'd5,  S_A1    = 5'd6,  S_A2    = 5'd7,
                   S_A3    = 5'd8,  S_A4    = 5'd9,
                   S_ROW   = 5'd10,
                   S_DRAW  = 5'd14,
                   S_NEXT  = 5'd16;
  reg [4:0] st;

  // Inside S_DRAW two stages run at once.  The fetch works on tile `fj` while
  // the blit works on tile `bj`, one behind, out of the other word bank.
  localparam [1:0] F_IDLE = 2'd0, F_L1 = 2'd1, F_L2 = 2'd2, F_RUN = 2'd3;
  reg [1:0] fst;
  reg       brun;

  // ---- LUT prefetch ------------------------------------------------------
  // The map lookup costs three clocks -- issue, wait, latch -- because the LUT
  // RAM registers its output, and that is already minimal for a lookup done on
  // its own.  The only way to make it cheaper is to stop doing it on its own:
  // the LUT port is idle for the whole of F_RUN, so the NEXT tile's lookup
  // rides along with this tile's four ROM words and is waiting when the fetch
  // stage comes back round.
  //
  // Three clocks of about twenty-one, measured -- and it is the last thing
  // that can be taken out of the tile path without touching the shared SDRAM
  // controller, which is proven hardware and serves seven clients.
  localparam [1:0] P_IDLE = 2'd0, P_W1 = 2'd1, P_W2 = 2'd2, P_RDY = 2'd3;
  reg [1:0]  pf;
  reg [15:0] pf_tile;
  reg [3:0]  pf_j;


  always @(posedge clk) begin
    if (busy) begin
      if (busy_acc != 16'hFFFF) busy_acc <= busy_acc + 16'd1;
      // a clock asking the SDRAM and not getting an answer is the fetch
      // stalling; everything else is the engine doing its own work
      if (rom_req && !rom_ack && wait_acc != 16'hFFFF)
        wait_acc <= wait_acc + 16'd1;
    end
    wr_e_en <= 1'b0;
    wr_o_en <= 1'b0;
    clr_en  <= 1'b0;

    if (rst) begin
      st          <= S_IDLE;
      busy        <= 1'b0;
      rom_req     <= 1'b0;
      rom_hold    <= 1'b0;
      have        <= 8'd0;
      loaded      <= 2'd0;
      fst         <= F_IDLE;
      brun        <= 1'b0;
      pf          <= P_IDLE;
      sp          <= SP_IDLE;
      sp_valid    <= 1'b0;
      sp_end      <= 1'b0;
      sp_scan     <= 10'd1;
      fbank       <= 1'b0;
      bbank       <= 1'b0;
      dbg_trunc_total <= 16'd0;
      dbg_overrun <= 16'd0;
      dbg_tiles   <= 16'd0;
      dbg_busy_clks <= 16'd0;
      dbg_wait_clks <= 16'd0;
      busy_acc    <= 16'd0;
      wait_acc    <= 16'd0;
      tiles_fmax  <= 16'd0;
      busy_fmax   <= 16'd0;
      wait_fmax   <= 16'd0;
      ovr_facc    <= 16'd0;
      tiles_this_line <= 16'd0;
    end else if (start) begin
      // Counted BEFORE the reset so the reset cannot hide it.
      if (busy) begin
        if (dbg_trunc_total != 16'hFFFF)
          dbg_trunc_total <= dbg_trunc_total + 16'd1;
        if (ovr_facc != 16'hFFFF) ovr_facc <= ovr_facc + 16'd1;
      end
      if (tiles_this_line > tiles_fmax) tiles_fmax <= tiles_this_line;
      // the split belongs to ONE line -- the worst of this frame -- so both
      // move together or neither does
      if (busy_acc > busy_fmax) begin
        busy_fmax <= busy_acc;
        wait_fmax <= wait_acc;
      end
      busy_acc <= 16'd0;
      wait_acc <= 16'd0;
      tiles_this_line <= 16'd0;
      busy     <= 1'b1;
      rom_req  <= 1'b0;
      rom_hold <= 1'b0;
      clr_x    <= 8'd0;
      // entry 0 is walked the ordinary way; the prefetch scans from 1
      sp       <= SP_IDLE;
      sp_valid <= 1'b0;
      sp_end   <= 1'b0;
      sp_scan  <= 10'd1;
      st       <= S_CLR;
    end else begin
      case (st)
        S_IDLE: ;

        // Clear the buffer about to be drawn into -- sprites are sparse and
        // last frame's pixels would otherwise still be there.  320 of the
        // 3053 clocks a line has.  Doing it here rather than trailing the
        // display read keeps the two ports off one address by construction.
        // COLUMN 0 USED TO SURVIVE THIS.  `clr_en` is a register, so it is
        // high in the clock AFTER the state runs -- and `clr_x` had already
        // been incremented by then, so the first address ever written was 1.
        // x = 0 kept whatever the last sprite to reach it had left, for as
        // long as the core ran.  Found by sim/tb_ss_sprite.sv against the
        // golden model, six pixels out of 8640, all of them x = 0.
        //
        // The fix is to let the counter stand still for the one clock it takes
        // `clr_en` to come up, so the address written is always the one the
        // state is pointing at.
        S_CLR: begin
          clr_en <= 1'b1;
          if (clr_en) begin
            // One index clears BOTH parities, so 320 pixels take 160 clocks.
            if (clr_x == 8'((H_VISIBLE / 2) - 1)) begin
              lidx <= 10'd0;
              st   <= S_L0;
            end else begin
              clr_x <= clr_x + 8'd1;
            end
          end
        end

        // The RAM registers its output, so an address set at the end of state
        // N is readable in state N+2.  Advancing one state early is the fault
        // the sibling lane spent a session on: every value comes from the
        // PREVIOUS lookup, which looks like a displacement, not a wrong read.
        S_L0: begin sram_addr <= {2'd0, lidx}; st <= S_L1; end
        S_L1: st <= S_L2;
        S_L2: begin
          if (sram_data[14]) begin                 // END OF LIST
            busy <= 1'b0;
            st   <= S_IDLE;
          end else if (sram_data[15]) begin        // skip this entry
            st <= S_NEXT;
          end else begin
            sram_addr <= {sram_data[9:0], 2'd0};
            st <= S_A0;
          end
        end

        // Latency accounting, spelled out because getting it wrong here reads
        // every field from the PREVIOUS word and still produces sprites:
        //     address assigned at the end of state N
        //     the RAM output register loads at the end of N+1
        //     the value is assignable in state N+2
        // S_L2 assigns B+0, so w0 is readable in S_A1 -- not S_A2.
        S_A0: begin sram_addr <= sram_addr + 12'd1; st <= S_A1; end
        S_A1: begin
          sram_addr <= sram_addr + 12'd1;
          s_oy     <= sram_data[8:0];            // w0
          s_ysize  <= sram_data[11:9];
          s_zy_raw <= sram_data[15:12];
          st <= S_A2;
        end
        S_A2: if (!spr_y_hit) begin
          // Nowhere near this line.  Skip w1..w3 and the row walk entirely.
          st <= S_NEXT;
        end else begin
          sram_addr <= sram_addr + 12'd1;
          s_ox     <= sram_data[8:0];            // w1
          s_xsize  <= sram_data[11:9];
          s_zx_raw <= sram_data[15:12];
          st <= S_A3;
        end
        S_A3: begin
          s_colour  <= sram_data[13:8];          // w2
          s_flipx   <= sram_data[14];
          s_flipy   <= sram_data[15];
          st <= S_A4;
        end
        S_A4: begin
          s_map <= sram_data[14:0];              // w3
          k  <= 3'd0;
          st <= S_ROW;
        end

        S_ROW: begin
          if (row_hit) begin
            src_row <= row_in_tile;
            // this row's first tile: base + k*(xsize+1).  The map index just
            // counts up in VISIT order -- unlike VSYSTEM_SPR2 there is no
            // power-of-two row-stride correction here.
            // WIDEN BEFORE YOU ADD, for the same reason the zoom multiply
            // says WIDEN BEFORE YOU MULTIPLY.  `s_xsize + 3'd1` inside a
            // concatenation is SELF-DETERMINED at three bits, so the row
            // stride for an eight-tile-wide sprite -- xsize = 7 -- came out
            // 7 + 1 = 0 and every tile row read the FIRST row's tiles.
            // Invisible in this game until TEAM SELECT, whose team names are
            // the only xsize = 7 sprites it has.
            map_row <= s_map + 15'({11'd0, k} * {11'd0, (4'(s_xsize) + 4'd1)});
            fj     <= 4'd0;
            bj     <= 4'd0;
            fbank  <= 1'b0;
            bbank  <= 1'b0;
            loaded <= 2'd0;
            have   <= 8'd0;
            fst    <= F_IDLE;
            brun   <= 1'b0;
            pf     <= P_IDLE;
            st     <= S_DRAW;
          end else if (k == s_ysize) begin
            st <= S_NEXT;
          end else begin
            k <= k + 3'd1;
          end
        end

        // ---- ONE ROW OF TILES, FETCH AND BLIT IN PARALLEL ---------------
        //
        // A tile used to cost the SUM of its parts: lookup, then four words,
        // then sixteen pixels -- about 27 clocks, which measured out at 64
        // tiles a line on hardware and then 81 once the fetch and the blit of
        // the SAME tile were overlapped.  tools/ss_sprload.lua says this game
        // asks for up to 145 on-screen tiles on a line, p99 106, so 81 still
        // drops tiles on about one line in a hundred -- and those lines are
        // all in the same busy frames, which is why it looked like the sprites
        // broke up rather than like a steady loss.
        //
        // So the fetch now runs a tile AHEAD of the blit, into the other of
        // two word banks.  Steady state is max(fetch, blit) rather than their
        // sum: about 19 clocks, or roughly 113 tiles a line.
        //
        // The two stages share only `s_*` (per sprite, stable for the whole
        // row) and the bank.  sim/tb_ss_sprite.sv compares every pixel against
        // a model written from vsystem_spr.cpp, so a mistake here is caught
        // before a bitstream rather than after a board session.
        S_DRAW: begin

          // ---------------- fetch stage -----------------------------------
          case (fst)
            F_IDLE: begin
              if (fj <= {1'b0, s_xsize} && !loaded[fbank]) begin
                if (!tile_visible) begin
                  // Off the sides entirely: skip it whole.  Never loaded, so
                  // the blit never sees it and the banks stay in step.
                  fj  <= fj + 4'd1;
                end else if (pf == P_RDY && pf_j == fj) begin
                  // already looked up during the previous tile's fetch
                  tile_no      <= pf_tile;
                  wsel         <= s_flipx ? 2'd3 : 2'd0;
                  wfetch       <= s_flipx ? 2'd3 : 2'd0;
                  have[{fbank, 2'd0}] <= 1'b0;
                  have[{fbank, 2'd1}] <= 1'b0;
                  have[{fbank, 2'd2}] <= 1'b0;
                  have[{fbank, 2'd3}] <= 1'b0;
                  tsx[fbank]   <= sx_sel;
                  loaded[fbank] <= 1'b1;
                  rom_req      <= 1'b1;
                  rom_hold     <= 1'b1;
                  if (tiles_this_line != 16'hFFFF)
                    tiles_this_line <= tiles_this_line + 16'd1;
                  if (fj + 4'd1 <= {1'b0, s_xsize}) begin
                    lut_addr <= map_row + {11'd0, (fj + 4'd1)};
                    pf_j     <= fj + 4'd1;
                    pf       <= P_W1;
                  end else begin
                    pf <= P_IDLE;
                  end
                  fst <= F_RUN;
                end else begin
                  lut_addr <= map_cur;
                  pf       <= P_IDLE;
                  fst      <= F_L1;
                end
              end
            end
            F_L1: fst <= F_L2;
            F_L2: begin
              tile_no      <= lut_data;
              wsel         <= s_flipx ? 2'd3 : 2'd0;
              wfetch       <= s_flipx ? 2'd3 : 2'd0;
              have[{fbank, 2'd0}] <= 1'b0;
              have[{fbank, 2'd1}] <= 1'b0;
              have[{fbank, 2'd2}] <= 1'b0;
              have[{fbank, 2'd3}] <= 1'b0;
              tsx[fbank]   <= sx_sel;
              loaded[fbank] <= 1'b1;
              rom_req      <= 1'b1;
              rom_hold     <= 1'b1;
              if (tiles_this_line != 16'hFFFF)
                tiles_this_line <= tiles_this_line + 16'd1;
              // the next tile's lookup rides along with this tile's fetch
              if (fj + 4'd1 <= {1'b0, s_xsize}) begin
                lut_addr <= map_row + {11'd0, (fj + 4'd1)};
                pf_j     <= fj + 4'd1;
                pf       <= P_W1;
              end else begin
                pf <= P_IDLE;
              end
              fst <= F_RUN;
            end
            F_RUN: begin
              if (rom_adv && wfetch != last_w)
                wfetch <= s_flipx ? (wfetch - 2'd1) : (wfetch + 2'd1);
              if (rom_ack) begin
              rw[{fbank, wsel}]   <= rom_data;
              have[{fbank, wsel}] <= 1'b1;
              if (wsel == last_w) begin
                rom_req  <= 1'b0;
                rom_hold <= 1'b0;
                fj       <= fj + 4'd1;
                fbank    <= ~fbank;
                fst      <= F_IDLE;
              end else begin
                wsel     <= next_w;
                rom_hold <= (next_w != last_w);
                if (wfetch == wsel) wfetch <= next_w;   // no offer came: S_IDLE path
              end
              end
            end
          endcase

          // ---------------- LUT prefetch pipeline -------------------------
          case (pf)
            P_W1: pf <= P_W2;
            P_W2: begin pf_tile <= lut_data; pf <= P_RDY; end
            default: ;                      // P_IDLE and P_RDY hold
          endcase

          // ---------------- blit stage ------------------------------------
          if (!brun) begin
            // A bank is blittable the moment its tile is ISSUED -- the pixels
            // wait on `have`, not on the whole row arriving.
            if (loaded[bbank]) begin
              c    <= 5'd0;
              brun <= 1'b1;
            end
          end else if (c != s_dstw) begin
            if (pair_ok) begin
              // TWO pixels, one even and one odd, so they are two different
              // arrays and still one write port each.  Which of the pair is
              // even depends on where the tile landed, so the routing is a
              // mux rather than a fixed assignment.
              // transparent pen is 15 -- vsystem_spr.cpp's m_transpen default
              if (!px[0]) begin
                if (on_screen   && pen   != 4'hF) begin
                  wr_e_en <= 1'b1; wr_e_a <= px[8:1];
                  wr_e_d  <= {1'b1, s_colour, pen};
                end
                if (on_screen_b && pen_b != 4'hF) begin
                  wr_o_en <= 1'b1; wr_o_a <= px[8:1];
                  wr_o_d  <= {1'b1, s_colour, pen_b};
                end
              end else begin
                if (on_screen   && pen   != 4'hF) begin
                  wr_o_en <= 1'b1; wr_o_a <= px[8:1];
                  wr_o_d  <= {1'b1, s_colour, pen};
                end
                if (on_screen_b && pen_b != 4'hF) begin
                  wr_e_en <= 1'b1; wr_e_a <= px_b[8:1];
                  wr_e_d  <= {1'b1, s_colour, pen_b};
                end
              end
              c <= c + 5'd2;
            end else if (have_a) begin
              if (on_screen && pen != 4'hF) begin
                if (!px[0]) begin
                  wr_e_en <= 1'b1; wr_e_a <= px[8:1];
                  wr_e_d  <= {1'b1, s_colour, pen};
                end else begin
                  wr_o_en <= 1'b1; wr_o_a <= px[8:1];
                  wr_o_d  <= {1'b1, s_colour, pen};
                end
              end
              c <= c + 5'd1;
            end
          end else begin
            loaded[bbank] <= 1'b0;
            bbank <= ~bbank;
            bj    <= bj + 4'd1;
            brun  <= 1'b0;
          end

          // ---------------- is the row finished? --------------------------
          // Both stages idle and the fetch past the last tile.  `loaded` is
          // checked rather than bj, because a tile the X reject dropped never
          // reaches the blit at all.
          if (fj > {1'b0, s_xsize} && fst == F_IDLE && !brun
              && loaded == 2'd0) begin
            if (k == s_ysize) st <= S_NEXT;
            else begin k <= k + 3'd1; st <= S_ROW; end
          end
        end

        S_NEXT: begin
          if (sp_valid) begin
            // The next sprite is already here.  If it cannot reach this line
            // it is dropped in THIS ONE CLOCK -- the eight the ordinary walk
            // would have spent reading it were spent while the last sprite was
            // being drawn, and cost nothing.
            sp_valid <= 1'b0;
            lidx     <= sp_idx;
            if (sp_y_hit) begin
              s_oy     <= sp_w0[8:0];
              s_ysize  <= sp_w0[11:9];
              s_zy_raw <= sp_w0[15:12];
              s_ox     <= sp_w1[8:0];
              s_xsize  <= sp_w1[11:9];
              s_zx_raw <= sp_w1[15:12];
              s_colour <= sp_w2[13:8];
              s_flipx  <= sp_w2[14];
              s_flipy  <= sp_w2[15];
              s_map    <= sp_w3[14:0];
              k  <= 3'd0;
              st <= S_ROW;
            end
            // else: stay in S_NEXT and take the one after it
          end else if (sp_end) begin
            busy <= 1'b0;
            st   <= S_IDLE;
          end
          // else WAIT.  There is deliberately no fallback to walking the list
          // here: a second walker with its own index over the same list is
          // what broke this the first time.  The prefetch runs in this state,
          // so waiting is bounded.
        end

        default: st <= S_IDLE;
      endcase

      // ---- SPRITE PREFETCH -----------------------------------------------
      // Runs in S_ROW, S_DRAW and S_NEXT -- exactly the states where the main
      // walk is not using the sprite RAM port.  Anything else and the two
      // would drive `sram_addr` against each other.
      //
      // S_NEXT HAS TO BE IN THAT LIST.  Without it, a sprite dropped for not
      // reaching this line leaves the main FSM sitting in S_NEXT with nothing
      // prefetched and no way to refill, so it fell back to walking the list
      // itself -- and then TWO walkers advanced independently, `lidx` and
      // `sp_scan`, over the same list.  Entries got drawn twice and others
      // skipped, the line filled with work that should not have been there,
      // and spr_trunc went from 8,000 to SATURATED on the board.
      if (st == S_ROW || st == S_DRAW || st == S_NEXT) begin
        case (sp)
          SP_IDLE: if (!sp_valid && !sp_end) begin
            if (sp_scan == 10'd512) begin
              // ran off the end without a marker.  The game always sets one
              // (measured: 0 of 216 samples without), so this is the safety
              // stop -- and it MUST set sp_end, or S_NEXT waits for ever.
              sp_end <= 1'b1;
            end else begin
              sram_addr <= {2'd0, sp_scan};
              sp <= SP_L1;
            end
          end
          SP_L1: sp <= SP_L2;
          SP_L2: begin
            if (sram_data[14]) begin
              sp_end <= 1'b1;                       // end of list, ahead of us
              sp     <= SP_IDLE;
            end else if (sram_data[15]) begin
              sp_scan <= sp_scan + 10'd1;           // skipped entry
              sp      <= SP_IDLE;
            end else begin
              sram_addr <= {sram_data[9:0], 2'd0};
              sp <= SP_A0;
            end
          end
          SP_A0: begin sram_addr <= sram_addr + 12'd1; sp <= SP_A1; end
          SP_A1: begin sram_addr <= sram_addr + 12'd1; sp_w0 <= sram_data; sp <= SP_A2; end
          SP_A2: begin sram_addr <= sram_addr + 12'd1; sp_w1 <= sram_data; sp <= SP_A3; end
          SP_A3: begin sp_w2 <= sram_data; sp <= SP_A4; end
          SP_A4: begin
            sp_w3    <= sram_data;
            sp_idx   <= sp_scan;
            sp_scan  <= sp_scan + 10'd1;
            sp_valid <= 1'b1;
            sp       <= SP_IDLE;
          end
          default: sp <= SP_IDLE;
        endcase
      end

      // ---- publish once a frame ------------------------------------------
      // Last in the block on purpose: if `frame` and `start` land on the same
      // clock this clears rather than accumulates, losing that ONE line of
      // that frame.  Stated here rather than left to be discovered, because
      // the alternative -- a second always block -- costs a duplicate reset
      // and a second place to keep in step.
      if (frame) begin
        dbg_tiles     <= tiles_fmax;
        dbg_busy_clks <= busy_fmax;
        dbg_wait_clks <= wait_fmax;
        dbg_overrun   <= ovr_facc;
        tiles_fmax    <= 16'd0;
        busy_fmax     <= 16'd0;
        wait_fmax     <= 16'd0;
        ovr_facc      <= 16'd0;
      end
    end
  end

endmodule

`default_nettype wire
