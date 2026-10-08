//============================================================================
//  Super Slams -- the FG "screen" layer: VS920F
//
//  64 x 32 tiles of 8x8x4, scrolled horizontally only, drawn ON TOP of
//  everything (suprslam.cpp:247, and the sprite/FG swap bit that could put
//  sprites above it is never written -- HARDWARE section 4).
//
//  TWO THINGS HERE ARE NOT WHAT THEY LOOK LIKE, and both produce a picture:
//
//  1. TRANSPARENT PEN IS 15, NOT 0.  suprslam.cpp:200 calls
//     set_transparent_pen(15) on this tilemap and nothing else on this board
//     does.  Treating 0 as the hole gives a plausible screen with the wrong
//     parts of it missing.
//
//  2. THE TILES ARE packed_LSB while the two 16x16 layers are packed_MSB.
//     emu/video/generic.cpp:108 gives this layout an x order of
//     {1,0,3,2,5,4,7,6}*4, so within each byte the LOW nibble is the LEFT
//     pixel -- the opposite of the ROZ and sprite layers.  Getting it wrong
//     swaps every pixel pair, which reads as a ROM interleave fault.
//
//  Structure is deliberately the same walker as ss_roz.sv: a two-stage
//  pipeline that holds as one, and a one-word cache.  One correct shape used
//  twice beats two shapes each half-debugged.  It costs more clocks than a
//  tile-at-a-time fetch would, and the line budget (HARDWARE section 8) has
//  room: 320 pixels plus ~80 misses is under 900 of 3053 clocks.
//============================================================================
`default_nettype none

module ss_fgmap #(
    parameter int H_VISIBLE = 320,
    parameter bit [24:0] FGTILES_BASE_W = 25'h100000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    // Eight bits: this map is 32 tiles = 256 lines tall and wraps in it, and
    // only lines 0..223 are ever rendered.  Bit 0 is also the line-buffer
    // parity, so a narrower port is not a loss of anything.
    input  wire [7:0]  sline,
    output reg         busy,

    // --- FG videoram read port (the CPU owns the other port) --------------
    output reg  [10:0] vram_addr,
    input  wire [15:0] vram_data,

    // screen_vregs[0x04/2].  Nine bits: the tilemap is 64 tiles = 512 pixels
    // wide and the scroll wraps in it, so anything above bit 8 has no meaning
    // to this layer.  Measured 0x0000 for every frame of attract, which is
    // exactly why the register is worth wiring rather than assuming.
    input  wire [8:0]  scrollx,
    input  wire [3:0]  screen_bank,      // bank_reg[15:12]
    input  wire        flip,

    output reg  [24:0] rom_addr,
    output reg         rom_req,
    input  wire        rom_ack,
    input  wire [15:0] rom_data,

    input  wire        lb_par,
    input  wire [8:0]  lb_x,
    output wire [7:0]  lb_q,             // {colour[3:0], pen[3:0]}, 15 = hole

    output reg  [15:0] dbg_overrun
);

  // ---- line buffers: two arrays.  ss_roz.sv says why. --------------------
  reg [7:0] lb0 [0:511];
  reg [7:0] lb1 [0:511];
  reg [7:0] lb_q0, lb_q1;

  reg       wr_en;
  reg [8:0] wr_x;
  reg [7:0] wr_d;
  wire      wr_par = sline[0];

  always @(posedge clk) begin
    if (wr_en && !wr_par) lb0[wr_x] <= wr_d;
    if (wr_en &&  wr_par) lb1[wr_x] <= wr_d;
    lb_q0 <= lb0[lb_x];
    lb_q1 <= lb1[lb_x];
  end
  assign lb_q = lb_par ? lb_q1 : lb_q0;

  // ---- source coordinate -------------------------------------------------
  //
  // src_x = (screen_x + scrollx) & 0x1FF.  The direction was traced through
  // tilemap.cpp by the sibling lane rather than guessed -- two negations
  // cancel and the obvious reading comes out backwards.
  //
  // The map is 32 tiles tall = 256 lines and the screen is 224, and there is
  // no vertical scroll register on this layer, so src_y is just the line.
  //
  // Flip screen is applied to the FETCH coordinate, which is where MAME
  // applies it for a tilemap.  The sprite engine gets raw counters instead,
  // because MAME does sprite flip inside the sprite maths.
  reg [8:0] n;
  wire [8:0] sx_raw = flip ? (H_VISIBLE[8:0] - 9'd1 - n) : n;
  wire [7:0] sy     = flip ? (8'd223 - sline) : sline;
  wire [8:0] src_x  = sx_raw + scrollx;
  wire [7:0] src_y  = sy;

  reg [2:0]  a_x3, a_y3;      // position inside the 8x8 tile
  reg [8:0]  a_px;
  reg        a_v;
  reg [2:0]  b_x3, b_y3;
  reg [8:0]  b_px;
  reg        b_v;


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
  // 2 MB / 32 bytes per tile = 65536 tiles, so the whole 16-bit tile number is
  // real here -- unlike the ROZ layer, nothing is dropped.
  wire [15:0] b_tile   = {screen_bank, b_word[11:0]};
  wire [24:0] b_rom_a  = FGTILES_BASE_W | {5'd0, b_tile, b_y3, b_x3[2]};

  reg [24:0] cache_a;
  reg [15:0] cache_d;
  reg        cache_v;
  wire       cache_hit = cache_v && (cache_a == b_rom_a);
  wire [15:0] src = cache_hit ? cache_d : rom_data;

  // packed_LSB: low nibble of a byte is the LEFT pixel.  Our SDRAM word is
  // {even byte, odd byte} big-endian, so pixel 0 is bits 11:8 and pixel 1 is
  // 15:12 -- the pair is swapped relative to the 16x16 layers.
  reg [3:0] pen;
  always @(*) begin
    case (b_x3[1:0])
      2'd0: pen = src[11: 8];
      2'd1: pen = src[15:12];
      2'd2: pen = src[ 3: 0];
      default: pen = src[7:4];
    endcase
  end

  wire b_done  = b_v && (cache_hit || (rom_req && rom_ack));
  wire advance = busy && (!b_v || b_done);

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
    wr_en <= 1'b0;

    if (rst) begin
      busy        <= 1'b0;
      a_v         <= 1'b0;
      b_v         <= 1'b0;
      rom_req     <= 1'b0;
      cache_v     <= 1'b0;
      n           <= 9'd0;
      dbg_overrun <= 16'd0;
    end else if (start) begin
      if (busy && dbg_overrun != 16'hFFFF) dbg_overrun <= dbg_overrun + 16'd1;
      busy    <= 1'b1;
      n       <= 9'd0;
      a_v     <= 1'b0;
      b_v     <= 1'b0;
      rom_req <= 1'b0;
      cache_v <= 1'b0;
    end else if (busy) begin

      if (b_done) begin
        wr_en <= 1'b1;
        wr_x  <= b_px;
        wr_d  <= {b_colour, pen};
        if (!cache_hit) begin
          cache_a <= b_rom_a;
          cache_d <= rom_data;
          cache_v <= 1'b1;
        end
        rom_req <= 1'b0;
      end else if (b_v && !cache_hit && !rom_req) begin
        rom_addr <= b_rom_a;
        rom_req  <= 1'b1;
      end

      if (advance) begin
        b_x3 <= a_x3;  b_y3 <= a_y3;  b_px <= a_px;  b_v <= a_v;

        if (n == H_VISIBLE[8:0]) begin
          a_v <= 1'b0;
          if (!a_v) busy <= 1'b0;
        end else begin
          vram_addr <= {src_y[7:3], src_x[8:3]};
          a_x3 <= src_x[2:0];
          a_y3 <= src_y[2:0];
          a_px <= n;
          a_v  <= 1'b1;
          n    <= n + 9'd1;
        end
      end
    end
  end

endmodule

`default_nettype wire
