//============================================================================
//  Super Slams -- true dual-port board RAM
//
//  Port A is the 68000, with byte lanes.  Port B is a video engine, read only.
//  One clock of latency on BOTH ports: an address assigned at the end of clock
//  N is readable in clock N+2.  Every engine in this core is written to that
//  rule, and consuming the data one clock early is the single most productive
//  bug in this class of design -- every value comes from the previous lookup,
//  which looks like a displacement rather than like a wrong read.
//
//  MUST INFER AS M10K.  Root CLAUDE.md section 7 puts "did memory infer as
//  memory" at step 0 of resource triage because a description that cannot be a
//  block RAM becomes flip-flops with no warning at all.
//
//  ---- TWO BYTE-WIDE ARRAYS, NOT ONE 16-BIT ARRAY WITH PART-SELECT WRITES ---
//
//  The obvious way to write a byte-enabled memory is
//
//      if (ds[1]) mem[a][15:8] <= din[15:8];
//      if (ds[0]) mem[a][ 7:0] <= din[ 7:0];
//
//  and it is the form that cost this session a build.  Quartus 17.0 does not
//  reliably infer a part-select write into a packed array as a byte-enabled
//  RAM; it fell back to logic and analysis-and-synthesis was still grinding on
//  a single core after 30 minutes at 10.7 GB, with two 32768 x 16 instances --
//  524,288 flip-flops each -- to place.  It never printed a warning; the only
//  symptom was that it did not finish.
//
//  Splitting into `hi` and `lo` gives each array one whole-word write and
//  infers cleanly.  This is the shape power_spikes/rtl/ps_top.sv already used,
//  and copying its INTERFACE while inventing a new BODY is how the lesson got
//  lost -- the body was the lesson.
//
//  The other rules still apply: no combinational read, no reset of the array,
//  one registered output per port.
//
//  The largest instance here is 32768 x 16 -- work RAM and the sprite tile LUT
//  -- which is 512 Kbit, or about 52 M10K each.
//============================================================================
`default_nettype none

module ss_dpram #(
    parameter int AW = 12
) (
    input  wire            clk,

    input  wire [AW-1:0]   a_addr,
    input  wire [15:0]     a_din,
    input  wire            a_we,
    input  wire [1:0]      a_ds,        // {upper byte, lower byte}
    output reg  [15:0]     a_q,

    input  wire [AW-1:0]   b_addr,
    output reg  [15:0]     b_q
);

  reg [7:0] hi [0:(1 << AW) - 1];
  reg [7:0] lo [0:(1 << AW) - 1];

  always @(posedge clk) begin
    if (a_we && a_ds[1]) hi[a_addr] <= a_din[15:8];
    if (a_we && a_ds[0]) lo[a_addr] <= a_din[ 7:0];
    a_q <= {hi[a_addr], lo[a_addr]};
    b_q <= {hi[b_addr], lo[b_addr]};
  end

endmodule


//----------------------------------------------------------------------------
//  Single-port variant, for memories no video engine reads.
//----------------------------------------------------------------------------
module ss_ram #(
    parameter int AW = 15
) (
    input  wire            clk,
    input  wire [AW-1:0]   addr,
    input  wire [15:0]     din,
    input  wire            we,
    input  wire [1:0]      ds,
    output reg  [15:0]     q
);

  reg [7:0] hi [0:(1 << AW) - 1];
  reg [7:0] lo [0:(1 << AW) - 1];

  always @(posedge clk) begin
    if (we && ds[1]) hi[addr] <= din[15:8];
    if (we && ds[0]) lo[addr] <= din[ 7:0];
    q <= {hi[addr], lo[addr]};
  end

endmodule

`default_nettype wire
