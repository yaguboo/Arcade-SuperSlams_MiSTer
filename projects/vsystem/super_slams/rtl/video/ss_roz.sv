//============================================================================
//  Super Slams -- the BG layer: VS920D tilemap sampled through the 053936
//
//  64 x 64 tiles of 16x16x4 = a 1024 x 1024 source, wrapping, sampled at an
//  arbitrary (x, y) per displayed pixel.  Nothing about pixel n-1 helps with
//  pixel n in the general case, which is what makes this the expensive layer.
//
//  Bottom of the stack and FULLY OPAQUE -- suprslam.cpp never calls
//  set_transparent_pen on this tilemap, so colour 0 is a colour.  Treating it
//  as transparent looks almost right and quietly replaces those pixels with
//  whatever is under them, which is the black fill.
//
//  ---- structure ---------------------------------------------------------
//
//  Renders one line AHEAD into a double line buffer, so it has a whole line
//  (3053 core clocks at 48 MHz, HARDWARE section 7) to produce 320 pixels
//  rather than having to keep up with the 7.16 MHz dot clock in real time.
//  dbg_overrun counts the lines it did not finish; that counter exists from
//  the first build because the alternative is finding out from the picture.
//
//  Pipeline, following projects/namco/na1_na2/rtl/video/na2_roz.sv, which is
//  our own and is proven on hardware:
//
//      clock t    : issue the tilemap address for pixel n+1
//                   AND resolve pixel n from the tilemap word fetched at t-1
//
//  so the steady state is one pixel per clock.  The two lookups are separate
//  memories -- tilemap in BRAM, tiles in SDRAM -- so they pipeline.
//
//  ---- the word cache is what makes this affordable ----------------------
//
//  One 16-bit SDRAM word holds FOUR 4bpp pixels.  At 1:1 zoom four consecutive
//  screen pixels want the same word, so caching the last word turns 320
//  fetches a line into about 80.  HARDWARE section 8 budgets on that:
//
//      1:1 with the cache      80 words/line     1.08 M words/s
//      rotation, cache beaten 320 words/line     4.32 M words/s
//
//  Rotation was never observed in the frames we measured (incxy and incyx are
//  0 in every sample), but attract is not the whole game, so the worst case is
//  budgeted for and the overrun counter is the check.
//============================================================================
`default_nettype none

module ss_roz #(
    parameter int H_VISIBLE = 320,
    parameter bit [24:0] BGTILES_BASE_W = 25'h200000
) (
    input  wire        clk,
    input  wire        rst,

    // --- job --------------------------------------------------------------
    input  wire        start,           // one clock, at the start of a line
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [8:0]  sline,           // the line to RENDER; only its parity
                                        // is used here (the buffer to write)
    /* verilator lint_on UNUSEDSIGNAL */
    output reg         busy,

    // --- the raster, for the 053936 (ss_psac header) -----------------------
    input  wire        ce_pix,
    input  wire [8:0]  hcnt,
    input  wire        hsync,
    input  wire        vsync_ahead,

    // --- CPU ports, passed through to ss_psac -----------------------------
    input  wire        ctrl_we,
    input  wire [3:0]  ctrl_a,
    input  wire [15:0] ctrl_d,
    input  wire [1:0]  ctrl_ds,
    input  wire        line_cs,
    input  wire        line_we,
    input  wire [10:0] line_a,
    input  wire [15:0] line_d,
    input  wire [1:0]  line_ds,
    output wire [15:0] line_q,

    // --- BG videoram, read port (the CPU owns the other port) -------------
    output reg  [11:0] vram_addr,
    input  wire [15:0] vram_data,

    // --- tile bank, from 0xFFE000 -----------------------------------------
    // Three bits, not four.  MAME forms a 16-bit tile number as
    // (data & 0xFFF) + (bank_reg[11:8] << 12) and then gfx_element wraps it
    // modulo the 32768 tiles this 4 MB ROM holds -- so bank bit 3 is exactly
    // that wrap.  Dropped at the register in ss_main so the discard is visible
    // where the register is, not buried in an address.
    input  wire [2:0]  bg_bank,

    // --- SDRAM ------------------------------------------------------------
    output reg  [24:0] rom_addr,
    output reg         rom_req,
    input  wire        rom_ack,
    input  wire [15:0] rom_data,

    // --- line buffer, display side ----------------------------------------
    input  wire        lb_par,          // which buffer to display
    input  wire [8:0]  lb_x,
    output wire [7:0]  lb_q,            // {colour[3:0], pen[3:0]}, always opaque

    output wire        super_mode,
    output reg  [15:0] dbg_overrun
);

  // ---- the coordinate generator -----------------------------------------
  //
  // ss_psac runs jt053936 off the real raster, one line early, and records
  // the chip's output pins for the line being rendered.  `psac_ready` says
  // src_x/src_y hold pixel 0's entry, every `psac_step` moves on one pixel,
  // and `psac_ok` says the entry has been written yet -- the chip produces
  // one per pixel enable, so a walker faster than the raster waits for it.
  reg         psac_start;
  wire        psac_ready;
  wire        psac_step;
  wire        psac_ok;
  wire [9:0]  src_x, src_y;

  ss_psac u_psac (
      .clk(clk), .rst(rst),
      .ce_pix(ce_pix), .hcnt(hcnt), .hsync(hsync), .vsync_ahead(vsync_ahead),
      .ctrl_we(ctrl_we), .ctrl_a(ctrl_a), .ctrl_d(ctrl_d), .ctrl_ds(ctrl_ds),
      .line_cs(line_cs), .line_we(line_we), .line_a(line_a),
      .line_d(line_d), .line_ds(line_ds), .line_q(line_q),
      .start(psac_start), .ready(psac_ready),
      .step(psac_step), .src_ok(psac_ok), .src_x(src_x), .src_y(src_y),
      .super_mode(super_mode)
  );

  // ---- line buffers ------------------------------------------------------
  //
  // TWO ARRAYS, not one indexed by parity in the top address bit.  With one
  // array the display read and the render write can land on the same address
  // in the same clock; no M10K port can do that, Quartus builds the whole
  // thing out of flip-flops and says nothing.  The sibling lane paid 7,673 ALM
  // for that shape.  Root CLAUDE.md section 7, step 0.
  reg [7:0] lb0 [0:511];
  reg [7:0] lb1 [0:511];
  reg [7:0] lb_q0, lb_q1;

  reg        wr_en;
  reg [8:0]  wr_x;
  reg [7:0]  wr_d;
  wire       wr_par = sline[0];

  always @(posedge clk) begin
    if (wr_en && !wr_par) lb0[wr_x] <= wr_d;
    if (wr_en &&  wr_par) lb1[wr_x] <= wr_d;
    lb_q0 <= lb0[lb_x];
    lb_q1 <= lb1[lb_x];
  end
  // The display reads the buffer the renderer is NOT writing.
  assign lb_q = lb_par ? lb_q1 : lb_q0;

  // ---- the walker --------------------------------------------------------
  //
  //   stage A   issues the tilemap address for a pixel and latches its (tx,ty)
  //   stage B   one clock later, has that pixel's tilemap word on `vram_data`
  //             and turns it into a tile ROM address
  //
  //  Both stages hold together on a stall, and holding stage A is what keeps
  //  `vram_data` still: the BRAM output only changes when its address does.
  //  (na2_roz.sv has to latch the word instead, because there the tilemap port
  //  deliberately runs on during a stall.  Here it does not, so there is no
  //  second copy to keep in step -- one less thing to get wrong.)
  reg [9:0]  n;                    // pixel whose address stage A issues next
  reg        run;

  // Wrap is ON (suprslam.cpp:459 set_wrap(1)) and the source is 1024x1024, so
  // out-of-range simply wraps -- there is no "not drawn" case here, unlike
  // NA-2 whose ROZ has wrap off.
  // The tilemap address takes the tile part (bits 9:4) straight from the
  // accumulator, and only the position INSIDE the tile is carried down the
  // pipeline -- so these are the four low bits, not the whole coordinate.
  wire [3:0] tx = src_x[3:0];
  wire [3:0] ty = src_y[3:0];

  // Stage A carries the full 10-bit source coordinate because it is what forms
  // the tilemap address.  Stage B only ever needs the position INSIDE the
  // 16x16 tile, so it carries four bits -- narrowing here is not tidiness, it
  // is the difference between the synthesiser keeping twelve registers alive
  // across a stall and not.
  reg [3:0]  a_tx, a_ty;   reg [8:0] a_x;   reg a_v;
  reg [3:0]  b_tx, b_ty;   reg [8:0] b_x;   reg b_v;


  // ---- stage B's tilemap word must be HELD ---------------------------------
  // `advance` loads B from A and moves `vram_addr` to the NEXT pixel on the
  // same edge.  ss_dpram registers its output, so `vram_data` carries B's own
  // word for EXACTLY ONE CLOCK after an advance, and the next pixel's word
  // from then on.  At one pixel per clock that is invisible; on a cache miss
  // the colour nibble written to the line buffer and the tag compared against
  // the cache would both come from the pixel AFTER this one.
  // (The `always` block that drives these sits below, next to `advance`.)
  reg        b_fresh;
  reg [15:0] b_word_r;
  wire [15:0] b_word = b_fresh ? vram_data : b_word_r;

  wire [3:0]  b_colour = b_word[15:12];
  // 4 MB / 128 bytes per tile = 32768 tiles, so the tile number is 15 bits and
  // bg_bank's top bit cannot be reached.  Dropped here rather than silently
  // truncated at the address, so that a bank value that overflows is visible
  // as a wrapped picture and not as an address that aliases somewhere else.
  wire [14:0] b_tile   = {bg_bank, b_word[11:0]};

  // BGTILES_BASE_W is bit 21 and the index below is 21 bits, so this is an OR
  // and not an add -- see tools/build_rom.py on why the regions are aligned.
  wire [24:0] b_rom_a = BGTILES_BASE_W | {4'd0, b_tile, b_ty, b_tx[3:2]};

  // ---- one-word cache ----------------------------------------------------
  reg [24:0] cache_a;
  reg [15:0] cache_d;
  reg        cache_v;
  wire       cache_hit = cache_v && (cache_a == b_rom_a);

  // packed_msb: pixel 0 is the high nibble of the even byte, and our SDRAM
  // word is {even byte, odd byte} big-endian, so the four pixels of a word run
  // straight down from bit 15.
  wire [15:0] src = cache_hit ? cache_d : rom_data;
  reg  [3:0]  pen;
  always @(*) begin
    case (b_tx[1:0])
      2'd0: pen = src[15:12];
      2'd1: pen = src[11: 8];
      2'd2: pen = src[ 7: 4];
      default: pen = src[3:0];
    endcase
  end

  // B can retire this clock if its word is already cached, or if the fetch it
  // asked for is acking right now.
  wire b_done   = b_v && (cache_hit || (rom_req && rom_ack));
  // ...and the whole pipeline advances when B is empty or B retires.
  wire advance  = run && (!b_v || b_done);

  // Stage A issues a pixel -- and so the record moves to the next entry --
  // exactly when the walk branch below issues under `advance`.  `start` and
  // `psac_ready` win over the walk in that block, so they gate the step too,
  // or the record would run ahead of a walker that did not move.
  assign psac_step = advance && (n != H_VISIBLE[9:0]) && psac_ok
                     && !start && !psac_ready;

  // Holds B's own tilemap word for the length of a stall -- see b_word above.
  // Not a combinational loop: b_fresh is a register, so advance -> b_fresh
  // crosses a clock edge.
  always @(posedge clk) begin
    if (rst) begin
      b_fresh  <= 1'b0;
      b_word_r <= 16'd0;
    end else begin
      b_fresh <= advance;
      if (b_fresh) b_word_r <= vram_data;
    end
  end


  always @(posedge clk) begin
    psac_start <= 1'b0;
    wr_en      <= 1'b0;

    if (rst) begin
      run         <= 1'b0;
      busy        <= 1'b0;
      a_v         <= 1'b0;
      b_v         <= 1'b0;
      rom_req     <= 1'b0;
      cache_v     <= 1'b0;
      n           <= 10'd0;
      dbg_overrun <= 16'd0;
    end else begin

      if (start) begin
        // A line that had not finished when the next one began is an overrun.
        // Counted BEFORE the reset so the reset cannot hide it.
        if (busy && dbg_overrun != 16'hFFFF) dbg_overrun <= dbg_overrun + 16'd1;
        psac_start <= 1'b1;
        busy       <= 1'b1;
        run        <= 1'b0;
        a_v        <= 1'b0;
        b_v        <= 1'b0;
        rom_req    <= 1'b0;
        // The cache does NOT survive a line.  It could -- the last word of one
        // line is often the first word of the next -- but then `cache_a` would
        // have to be proved still valid across a bank-register write, and a
        // stale tile is a whole wrong 16x16 block, not one wrong pixel.
        cache_v    <= 1'b0;
      end else if (psac_ready) begin
        n         <= 10'd0;
        run       <= 1'b1;
        a_v       <= 1'b0;
        b_v       <= 1'b0;
      end else if (run) begin

        // ---- stage B retires ------------------------------------------------
        if (b_done) begin
          wr_en <= 1'b1;
          wr_x  <= b_x;
          wr_d  <= {b_colour, pen};
          if (!cache_hit) begin
            cache_a <= b_rom_a;
            cache_d <= rom_data;
            cache_v <= 1'b1;
          end
          rom_req <= 1'b0;
        end else if (b_v && !cache_hit && !rom_req) begin
          // ---- stage B stalls, and asks -------------------------------------
          // `b_rom_a` is built from the HELD word, not from `vram_data`
          // directly -- see b_word above.  vram_addr has already moved on.
          rom_addr <= b_rom_a;
          rom_req  <= 1'b1;
        end

        // ---- the pipeline steps ---------------------------------------------
        if (advance) begin
          b_tx <= a_tx;  b_ty <= a_ty;  b_x <= a_x;  b_v <= a_v;

          if (n == H_VISIBLE[9:0]) begin
            a_v <= 1'b0;
            // A is dry and B has just taken A's last pixel; when that one
            // retires the line is done.
            if (!a_v) begin
              run  <= 1'b0;
              busy <= 1'b0;
            end
          end else if (psac_ok) begin
            // psac_step is high on this same clock: src_x/src_y move to
            // pixel n+1 on this edge.
            vram_addr <= {src_y[9:4], src_x[9:4]};
            a_tx <= tx[3:0];  a_ty <= ty[3:0];  a_x <= n[8:0];  a_v <= 1'b1;
            n    <= n + 10'd1;
          end else begin
            // The chip has not reached pixel n yet: a bubble, B still moves.
            a_v  <= 1'b0;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
