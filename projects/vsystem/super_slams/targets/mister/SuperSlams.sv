//============================================================================
//  Super Slams -- MiSTer target
//
//  Wires the board-independent core in rtl/ss_top.sv to the MiSTer framework.
//  Everything platform-specific lives here: hps_io, ioctl, the PLL, the OSD
//  and arcade_video.  Nothing in rtl/ knows any of it exists.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

// This core has no framebuffer -- horizontal game, no rotation -- so the .qsf
// does not define MISTER_FB and the FB_* ports therefore DO NOT EXIST:
// sys/emu_ports.vh declares them inside `ifdef MISTER_FB.  Assigning them
// anyway creates implicit nets that go nowhere and synthesis warns about each.
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN,
        DDRAM_BE, DDRAM_WE, DDRAM_RD} = 0;

// Nothing drives these by default and an undriven output is only a warning,
// so the picture would simply come out the wrong shape.  320 x 224 on a 4:3
// monitor is the original.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// jt10 puts out signed 16-bit stereo already mixed (FM + SSG + ADPCM-A +
// ADPCM-B), so AUDIO_S is 1 and nothing is scaled here.  AUDIO_MIX stays 0:
// the board is genuinely stereo -- suprslam.cpp:468-471 routes YM2610 output
// 1 to the left speaker and output 2 to the right, with output 0 (FM) to both
// at 0.75 -- so mixing the two channels together would be a change, not a fix.
assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;

// The audio output path is below the core instantiation, where clk_sys,
// snd_l/snd_r and the sample strobe are in scope.  See "HOLD THE AUDIO".


assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"SuperSlams;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	// The .mra carries a full <switches> block transcribed from
	// suprslam.cpp's INPUT_PORTS.  Without this line the framework still
	// delivers the defaults at ioctl index 254 -- the board really does get
	// them -- but no menu ever shows them, so Service Mode and Difficulty
	// would be set in stone at whatever the .mra shipped.
	//
	// NOTE: this board reads its DIPs ONCE, at boot (measured: VS9209 ports D
	// and E are read exactly once in 900 frames).  Changing one on the OSD
	// does nothing until the core is reset.  That is the board, not the menu.
	"DIP;",
	"-;",

	// ---- Debug page --------------------------------------------------------
	// Probes, not settings a player wants, so they get their own page and the
	// first screen stays Aspect / Scandoubler / DIP.
	"P1,Debug;",
	"P1O[10],Debug overlay,Off,On;",
	"P1O[13:12],Overlay page,0-15,16-31,32-47,48-63;",
	// DECISIONS D4.  On: the sprite shadow is copied only when the game arms
	// it by writing FF3000, which is what that address is believed to be.
	// Off: copy every vblank regardless, so FF3000 does nothing.  Both are
	// plausible hardware and the difference is visible -- which is the point.
	"P1O[15],Sprite buffer,FF3000-armed,Every frame;",
	// The 68000 is the only SDRAM client with no slack -- every video engine
	// renders a line ahead into a line buffer and has 3057 clocks, the CPU is
	// in a wait state for every clock its read is outstanding.  Default High.
	// Normal is the old order, kept switchable so the two can be compared at
	// the board and so a layer that starts missing its deadline can be undone
	// without a rebuild.
	"P1O[17],CPU priority,High,Normal;",
	"P1O[18],Audio hold,Sample-latched,Live;",
	// Freezes the 68000 and the sound (ss_top: ce_en = ~pause & ~dl_active).
	// The video engines keep scanning and keep contending for SDRAM, so a
	// paused screen is a STATIC picture drawn by a LIVE renderer -- the only
	// way to photograph a frame-to-frame artefact without the game's own
	// animation confounding it.
	"P1O[14],Pause,Off,On;",
	"-;",
	// --- 표준 OSD, docs/OSD_POLICY.md -------------------------------------
	// `On` 이 먼저여야 기본이 On 이다 -- MiSTer 는 코어 로드 때 status 를 0 으로
	// 지운다.  비트 11 인 이유는 12~15,17,18 이 이미 쓰이고 있어서다.
	"O[11],Pause when OSD open,On,Off;",
	"-;",
	// 운영자 스위치.  전에는 J1 에 있어서 패드 버튼 네 개를 차지했다.
	// 이 넷은 DIP 가 아니라 VS9209 로 읽는 캐비닛 입력이라 DIP 메뉴로 뺄 수
	// 없다 -- 그래서 OSD 항목이다 (docs/OSD_POLICY.md 3절).
	// TEST 는 기판 자신의 메뉴를 여는 버튼이고, 그것이 없으면 운영자 설정과
	// 입력 테스트와 사운드 테스트에 닿을 수 없다.
	"O[16],Service coin,Off,On;",
	"O[19],Test (board menu),Off,On;",
	"O[20],Coin 3,Off,On;",
	"O[21],Tilt,Off,On;",
	"-;",
	"R[0],Reset;",
	// Must list the SAME names, in the SAME order, as the .mra's <buttons>:
	// the mra maps a pad by position, so a name missing here is a joystick
	// bit the OSD cannot reach and a name in the wrong place is a button
	// wired to the wrong pin.
	// Service / Test / Coin 3 / Tilt 는 여기서 뺐다 -- 플레이어가 게임 중에
	// 누를 것이 아니고, 패드 버튼은 유한하다 (docs/OSD_POLICY.md 3절).
	// 위 OSD 항목으로 옮겼고 sys_in 도 같이 바꿨다.
	// 2026-10-06, user on the board: the first button passes and the second
	// shoots.  The wiring (j1[4] -> BUTTON1, j1[5] -> BUTTON2) was right; the
	// labels were swapped.  MAME names them only BUTTON1/2/3.
	"J1,Pass,Shoot,Dash,Button 4,Start,Coin,Pause;",
	"jn,A,B,X,Y,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire [21:0]  gamma_bus;
wire [127:0] status;
wire   [1:0] buttons;

wire         ioctl_download;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire  [15:0] ioctl_index;
wire         ioctl_wait;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(),
	.joystick_3(),

	.ps2_key(ps2_key),

	// hps_io declares these inputs with no default, so leaving them open makes
	// them float.  An open ioctl_wait goes onto HPS_BUS[37] as "core not
	// ready" and hangs the HPS partway through the ROM load -- a session lost
	// to that on the first board in this factory.  Tie every one off.
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0),
	.ps2_kbd_clk_in(1'b0),
	.ps2_kbd_data_in(1'b0),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b0),
	.ps2_mouse_data_in(1'b0),
	.video_rotated(1'b0),
	.new_vmode(1'b0),
	// OSD defaults come from the .mra, not from a rebuild.  Bit 0 (Reset) is
	// masked off: seeding it would hold the core in reset from the moment the
	// .mra finished loading, which is a baffling way to find an .mra typo.
	.status_in({104'd0, mra_status[23:1], 1'b0}),
	.status_set(mra_status_set),
	.info_req(1'b0),
	.info(8'd0),
	.sd_lba('{default:32'd0}),
	.sd_blk_cnt('{default:6'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{default:8'd0}),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0)
);

///////////////////   .MRA-SUPPLIED OSD DEFAULTS   ///////////////////////
//
// MiSTer clears every status bit on a fresh arcade load, so the DEFAULT is
// what a session actually starts with.  Rebuilding the bitstream to flip a
// debug option costs ~40 minutes; editing three bytes in the .mra costs
// seconds.
//
//   <rom index="1"><part>hh mm ll</part></rom>
//     hh = status[23:16]   mm = status[15:8]   ll = status[7:0]
//
// tools/build_rom.py generates this block; see OSD_DEFAULTS there.
reg [23:0] mra_status      = 24'd0;
reg        mra_status_seen = 1'b0;
reg        ioctl_dl_d      = 1'b0;
reg        mra_status_done = 1'b0;
reg        mra_status_set  = 1'b0;

always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd1) && !ioctl_addr[26:2]) begin
		case (ioctl_addr[1:0])
			2'd0: mra_status[23:16] <= ioctl_dout;
			2'd1: mra_status[15:8]  <= ioctl_dout;
			2'd2: begin mra_status[7:0] <= ioctl_dout; mra_status_seen <= 1'b1; end
			default: ;
		endcase
	end
end

always @(posedge clk_sys) begin
	ioctl_dl_d     <= ioctl_download;
	mra_status_set <= 1'b0;
	if (ioctl_dl_d && !ioctl_download && mra_status_seen && !mra_status_done) begin
		// Only when NO saved settings were loaded.  MiSTer loads <setname>.CFG
		// into status BEFORE the ROM download, and status_set makes Main replace
		// all 128 bits with status_in (Main_MiSTer user_io.cpp
		// check_status_change) -- so pushing the .mra defaults unconditionally
		// overwrote every saved OSD setting on every load ("settings do not
		// save", reported 2026-10-07).  A saved file has some bit of [127:1]
		// set; a fresh load has none.  [0] is the reset bit Main pulses.
		mra_status_set  <= ~|status[127:1];
		mra_status_done <= 1'b1;
	end
end

///////////////////////   CLOCKS   ///////////////////////////////
//
// 48.000 MHz, and every board clock divides from it EXACTLY:
//     68000 / 3 = 16 MHz, Z80 / 12 = 4 MHz, YM2610 / 6 = 8 MHz.
// That exactness is the point -- DECISIONS D1, which also records why this is
// 48 and not the 64 the first build used: 64 missed setup timing by 1.910 ns
// on a nine-level, routing-dominated path from the arbiter's address mux into
// the SDRAM controller's row-hit decision.
// outclk_1 is the same frequency shifted half a period for SDRAM_CLK
// (-10417 ps at 48 MHz).
//
// The worst bug in this factory's history was a PLL that Quartus accepted,
// TimeQuest blessed, and the fitter programmed with an out-of-range VCO --
// so the core clock never ran on hardware and nothing said a word.  The gate
// stays: build.sh runs tools/check_pll.py against the Fitter's PLL Usage
// Summary, which reports the counters as PROGRAMMED rather than as requested.
// DO NOT REMOVE THAT CHECK.
wire clk_sys, clk_sdram, clk_aux, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_aux),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

// clk_aux is the 100 MHz output that exists ONLY to constrain the PLL solver.
//
// THE RULE IS NOT "leave a legal VCO available".  It is "make the SMALLEST
// POSSIBLE VCO legal".  The fitter picks VCO = k * lcm(core, aux) for the
// smallest k that satisfies it, so if the lcm itself is below 600 the fitter
// will happily program a VCO that cannot lock.  240 MHz was tried here on the
// reasoning that lcm(48,240) = 240 leaves 720/960/1200 available -- and the
// fitter programmed 480, which is also a multiple of 240 and is below the
// floor.  check_pll.py caught it; nothing else would have.
//
// lcm(48, 100) = 1200.  There is no smaller common multiple, so 1200 is the
// only VCO the fitter can choose, it is legal, and it is inside the range this
// machine has actually programmed (600, 1000 and 1400 are measured across the
// three sibling lanes -- and 100 MHz is the aux Shadow Force already uses).
//
// IT MUST STILL HAVE A REAL LOAD.  Left unconnected, Quartus deletes the
// counter, re-solves the PLL with two outputs and puts the VCO back wherever
// it likes.
//
// So it drives a counter whose top bit is observable: if pll_alive never
// toggles, that clock is not running.
reg [23:0] aux_cnt = 24'd0;
always @(posedge clk_aux) aux_cnt <= aux_cnt + 24'd1;

reg [2:0] aux_sync = 3'd0;
always @(posedge clk_sys) aux_sync <= {aux_sync[1:0], aux_cnt[23]};
wire pll_alive = aux_sync[2] ^ aux_sync[1];

// pll_alive is a ONE-CLOCK pulse every 168 ms, so a screenshot samples it as 0
// essentially always -- which is indistinguishable from "that clock is dead".
// Count the edges instead: a non-zero value that CHANGES between two shots is
// proof the third PLL output is running, and a stuck value is proof it is not.
reg [15:0] aux_edges = 16'd0;
always @(posedge clk_sys) if (pll_alive) aux_edges <= aux_edges + 16'd1;

wire rst_sys = RESET | status[0] | buttons[1] | ~pll_locked;

// The core is held in reset while ROMs load.  The memory bus must NOT be: it
// is the thing doing the loading.
wire rst_mem = ~pll_locked;

///////////////////////   INPUT   ////////////////////////////////
//
// docs/HARDWARE.md section 11 and suprslam.cpp:302-337.  ALL ACTIVE LOW.
//
// Joystick bit order follows the J1 line above:
//   0 right  1 left  2 down  3 up
//   4 Shoot  5 Pass  6 Dash  7 Button 4  8 Start  9 Coin  10 Pause
//   11 Service  12 Test
//
// The VS9209 port bit order is NOT the joystick order -- port A is
// up/down/left/right in bits 0..3, which is the reverse of the pad's
// right/left/down/up.  Writing the concatenation without checking is how a
// core comes out with the stick rotated 180 degrees.
// --- Pause -----------------------------------------------------------------
// 버튼 토글 + OSD 자동 정지.  ioctl_download 에서 반드시 푼다 -- 로드 뒤 남은
// pause 는 화면상 행과 구별되지 않는다.  docs/OSD_POLICY.md 2절.
wire pause_btn = joystick_0[10] | joystick_1[10];   // J1 7번째 = Pause
reg  pause_btn_d, pause_latch;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (ioctl_download)                  pause_latch <= 1'b0;
	else if (~pause_btn_d & pause_btn)   pause_latch <= ~pause_latch;
end
wire pause_core = status[14] | pause_latch | (OSD_STATUS & ~status[11]);

wire [31:0] j1 = joystick_0;
wire [31:0] j2 = joystick_1;

wire [7:0] p1_in = ~{ j1[7], j1[6], j1[5], j1[4],      // B4 B3 B2 B1
                      j1[0], j1[1], j1[2], j1[3] };    // right left down up
wire [7:0] p2_in = ~{ j2[7], j2[6], j2[5], j2[4],
                      j2[0], j2[1], j2[2], j2[3] };

// Port C.  Every bit MAME defines is now reachable.
//
// SERVICE1 is the service coin and SERVICE2 is the TEST button that opens the
// board's own menu -- without it the operator settings, the input test and the
// sound test are unreachable, which is a third of what this PCB can show you.
// They are the last two entries in the .mra button list, deliberately with NO
// default pad binding: they are operator controls, and a Test button under
// somebody's thumb during a match is worse than one they have to go and map.
//
// COIN3 (0x04) and SERVICE1 (0x80) are DIFFERENT BITS of SYSTEM.  They shared
// one button until the board's own I/O TEST was reached on 2026-09-06 and
// showed COIN3 and SERVICE lighting together from a single press -- something
// no cabinet's wiring can produce.  Both now have their own name.
//
// TILT keeps no pad default (a tilt switch is not on the control panel) but is
// wired, so the bit is reachable and the port matches suprslam.cpp exactly.
// 네 개가 J1 에서 OSD 로 옮겨졌다 (2026-09-09).  포트의 비트 배치는 그대로고
// 바뀐 것은 그 비트를 무엇이 구동하는가뿐이다 -- suprslam.cpp 와 여전히 일치한다.
wire [7:0] sys_in = ~{ status[16],        // [7] SERVICE1
                       status[21],        // [6] TILT
                       status[19],        // [5] SERVICE2 "Test"
                       j2[8],             // [4] START2
                       j1[8],             // [3] START1
                       status[20],        // [2] COIN3  -- test mode only
                       j2[9],             // [1] COIN2
                       j1[9] };           // [0] COIN1

// DIP switches arrive from the .mra <switches> block at ioctl index 254.
// SW1 is the low byte, SW2 the high byte; the board reads them active low.
// tools/build_rom.py derives the defaults FF,7F from the SECOND argument of
// each PORT_DIPNAME -- Demo Sounds defaults ON and Country defaults to World,
// and both of those are the second argument rather than the first setting
// listed.  The sibling lane shipped Demo Sounds off by hand and then spent
// hours investigating a dead FM path that was the game correctly being silent.
reg [15:0] dsw = 16'hFF7F;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'h00FE) && !ioctl_addr[26:1]) begin
		if (!ioctl_addr[0]) dsw[7:0]  <= ioctl_dout;
		else                dsw[15:8] <= ioctl_dout;
	end
end

///////////////////////   CORE   /////////////////////////////////

wire [24:0] dl_addr;
wire [15:0] dl_data;
wire        dl_req, dl_ack, dl_active;

wire [7:0]  vid_r, vid_g, vid_b;
wire        ce_pix, hblank, vblank, hsync, vsync;
wire signed [15:0] snd_l, snd_r;

wire  [8:0] dbg_hcnt, dbg_vcnt;
wire [15:0] dbg_probe0, dbg_probe1, dbg_probe2, dbg_probe3;
wire [15:0] dbg_probe4, dbg_probe5, dbg_probe6;
wire        dbg_probe_done;
wire [15:0] dbg_irq_cnt, dbg_iack_cnt;
wire [15:0] dbg_ctr_wr_cnt, dbg_ctr_wr_val, dbg_ctr_rd_val;
wire [15:0] dbg_pc_min, dbg_pc_max;
wire [15:0] dbg_wr_fgv, dbg_wr_bgv, dbg_wr_spr, dbg_wr_pal;
wire [15:0] dbg_render_cnt;
wire [15:0] dbg_cpu_stall;
wire [15:0] dbg_z80_cyc, dbg_latch_ack, dbg_ym_wr, dbg_sample;
wire [15:0] dbg_peak_l, dbg_peak_r, dbg_fm_kon, dbg_pcma_kon;
wire [15:0] dbg_spr_busy, dbg_spr_wait, dbg_spr_trunc;
wire [15:0] dbg_roz_overrun, dbg_fg_overrun, dbg_spr_overrun, dbg_spr_tiles;
wire [15:0] dbg_cpu_wait, dbg_cpu_miss, dbg_spin_fr;
wire [15:0] dbg_jump_fr, dbg_maxd_fr;
wire [15:0] dbg_line_acks, dbg_line_busy;
wire [15:0] dbg_late_fr, dbg_pcmb_late_fr, dbg_pcma_worst;
wire [15:0] dbg_peak_psg, dbg_peak_fm;
wire [15:0] dbg_mad, dbg_mdd, dbg_pcma_bad;
wire        snd_sample;
wire [15:0] dbg_row_hit, dbg_row_miss, dbg_row_conflict;
wire [15:0] dbg_vregs4, dbg_vregs5;
wire [31:0] dbg_d7;
wire [23:1] dbg_cpu_a;
wire        dbg_halted_n, dbg_super_mode;

ss_download u_download
(
	.clk(clk_sys),
	.rst(rst_mem),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.dl_addr(dl_addr),
	.dl_data(dl_data),
	.dl_req(dl_req),
	.dl_ack(dl_ack),
	.dl_active(dl_active)
);

ss_top u_core
(
	.clk(clk_sys),
	.rst(rst_sys),
	// rst_mem is ~pll_locked ONLY.  MiSTer holds RESET high for the whole ROM
	// download and the memory transport is what performs it, so it must not be
	// held in rst_sys.  This wire existed and was NEVER CONNECTED in the first
	// version of this file, which is what made the core fail to load at all.
	.mem_rst(rst_mem),
	.pll_locked(pll_locked),

	.dl_active(dl_active),
	.dl_req(dl_req),
	.dl_addr(dl_addr),
	.dl_data(dl_data),
	.dl_ack(dl_ack),

	.pause(pause_core),
	.p1(p1_in), .p2(p2_in), .sys_in(sys_in),
	.dsw1(dsw[7:0]), .dsw2(dsw[15:8]),
	.spr_buffer_en(~status[15]),
	.cpu_first(~status[17]),

	.ce_pix(ce_pix),
	.red(vid_r), .green(vid_g), .blue(vid_b),
	.hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),

	.snd_l(snd_l), .snd_r(snd_r),

	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),

	.dbg_hcnt(dbg_hcnt),
	.dbg_vcnt(dbg_vcnt),
	.dbg_roz_overrun(dbg_roz_overrun),
	.dbg_cpu_wait(dbg_cpu_wait), .dbg_cpu_miss(dbg_cpu_miss),
	.dbg_spin_fr(dbg_spin_fr),
	.dbg_jump_fr(dbg_jump_fr), .dbg_maxd_fr(dbg_maxd_fr),
	.dbg_line_acks(dbg_line_acks), .dbg_line_busy(dbg_line_busy),
	.dbg_late_fr(dbg_late_fr), .dbg_pcmb_late_fr(dbg_pcmb_late_fr),
	.dbg_pcma_worst(dbg_pcma_worst),
	.dbg_peak_psg(dbg_peak_psg), .dbg_peak_fm(dbg_peak_fm),
	.dbg_mad(dbg_mad), .dbg_mdd(dbg_mdd), .dbg_pcma_bad(dbg_pcma_bad),
	.snd_sample(snd_sample),
	.dbg_fg_overrun(dbg_fg_overrun),
	.dbg_spr_overrun(dbg_spr_overrun),
	.dbg_spr_tiles(dbg_spr_tiles),
	.dbg_row_hit(dbg_row_hit),
	.dbg_row_miss(dbg_row_miss),
	.dbg_row_conflict(dbg_row_conflict),
	.dbg_d7(dbg_d7),
	.dbg_cpu_a(dbg_cpu_a),
	.dbg_halted_n(dbg_halted_n),
	.dbg_vregs4(dbg_vregs4),
	.dbg_vregs5(dbg_vregs5),
	.dbg_super_mode(dbg_super_mode),
	.dbg_probe0(dbg_probe0), .dbg_probe1(dbg_probe1), .dbg_probe2(dbg_probe2),
	.dbg_probe3(dbg_probe3), .dbg_probe4(dbg_probe4), .dbg_probe5(dbg_probe5),
	.dbg_probe6(dbg_probe6), .dbg_probe_done(dbg_probe_done),
	.dbg_irq_cnt(dbg_irq_cnt), .dbg_iack_cnt(dbg_iack_cnt),
	.dbg_ctr_wr_cnt(dbg_ctr_wr_cnt), .dbg_ctr_wr_val(dbg_ctr_wr_val),
	.dbg_ctr_rd_val(dbg_ctr_rd_val),
	.dbg_pc_min(dbg_pc_min), .dbg_pc_max(dbg_pc_max),
	.dbg_wr_fgv(dbg_wr_fgv), .dbg_wr_bgv(dbg_wr_bgv),
	.dbg_wr_spr(dbg_wr_spr), .dbg_wr_pal(dbg_wr_pal),
	.dbg_render_cnt(dbg_render_cnt), .dbg_cpu_stall(dbg_cpu_stall),
	.dbg_z80_cyc(dbg_z80_cyc), .dbg_latch_ack(dbg_latch_ack),
	.dbg_ym_wr(dbg_ym_wr), .dbg_sample(dbg_sample),
	.dbg_peak_l(dbg_peak_l), .dbg_peak_r(dbg_peak_r),
	.dbg_fm_kon(dbg_fm_kon), .dbg_pcma_kon(dbg_pcma_kon),
	.dbg_spr_busy(dbg_spr_busy), .dbg_spr_wait(dbg_spr_wait),
	.dbg_spr_trunc(dbg_spr_trunc)
);

// ---- HOLD THE AUDIO BETWEEN SAMPLES -------------------------------------
//
// Every board in this factory writes `assign AUDIO_L = snd_l;` and a person
// who has heard all four says the buzz is the same on all four -- with four
// different sound chips.  So it is not the chip; it is the one line they
// share.
//
// jt12_top computes snd_left = fm_snd_left + (psg_snd << 5).  The FM half is
// latched once per sample inside the accumulator; the PSG half changes at its
// own, unrelated rate.  So `snd_l` moves BETWEEN samples, and MiSTer's audio
// clock takes whatever it finds there -- values the chip never produced, at a
// rate unrelated to either.  That is an aliasing source, and it fits what was
// measured on this board today: jump_fr = 0 in sixteen frames and maxd_fr
// inside MAME's own range, i.e. the SAMPLES are clean.  Whatever is audible
// is not in them.
//
// It also fits WHEN it is audible.  The SSG is silent in attract (mixer
// register 07 = 0x3F, every channel off, measured) and used in a match (0x38
// forty-six times) -- and the complaint is about the game, not attract.
//
// Latched, the output changes exactly once per sample.  status[18] returns
// the old behaviour so the two can be compared at the board rather than by
// rebuilding, because this is a hypothesis and it is labelled as one.
reg signed [15:0] aud_l, aud_r;
always @(posedge clk_sys) if (snd_sample) begin
	aud_l <= snd_l;
	aud_r <= snd_r;
end
assign AUDIO_L = status[18] ? snd_l : aud_l;
assign AUDIO_R = status[18] ? snd_r : aud_r;


///////////////////////   DEBUG OVERLAY   ////////////////////////
//
// Sixteen cells a row, one BIT each, bit 15 leftmost, four pixel rows with a
// gutter.  That encoding is deliberately IDENTICAL to the sibling lanes so
// tools/read_overlay.py is nearly the same file for all of them, and anyone
// who has read one overlay can read this one.  The encoding is the reusable
// asset; the rows are not.

wire [7:0] ov_r, ov_g, ov_b;

ss_dbg u_dbg
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.enable(status[10]),
	.page(status[13:12]),
	.hcnt(dbg_hcnt),
	.vcnt(dbg_vcnt),
	.in_r(vid_r), .in_g(vid_g), .in_b(vid_b),
	.out_r(ov_r), .out_g(ov_g), .out_b(ov_b),

	// ---- THE PICTURE IS UP.  These rows now answer a different question ----
	// The layers render, and what is wrong with the picture is TEMPORAL: sprites
	// cut off, a tile row smeared down the screen, and the game running slow.
	// All three are what running out of time per line looks like, so page 0 is
	// the four numbers that decide it and page 1 is the rest of the same story.
	// The ROM probes stay on pages 2-3: they have already done their job, but
	// they are the control that says the bus is still delivering.
	// page 0 -- did every line get drawn, and who ran out of time
	.d00(dbg_render_cnt),                  // MUST BE 262.  V_TOTAL, per frame
	.d01(dbg_spr_trunc),                   // CUMULATIVE truncated lines --
	                                       // THE CLOSURE NUMBER.  0 after a
	                                       // whole workload means no line ever
	                                       // ran out of time.
	.d02(dbg_spr_tiles),                   // PER FRAME: most tiles on a line
	// AUX_EDGES MUST STAY ON A ROW.  It is the only consumer of the PLL's
	// third output, and that output is the only reason the VCO is legal:
	// the core clock is 48 MHz twice, lcm(48,48) = 48, and Quartus will
	// happily program a 432 MHz VCO that cannot lock.  Moving this counter
	// off the overlay to make room for the sound rows did exactly that --
	// the fitter dropped the unused 100 MHz output, the VCO collapsed to
	// 432, and check_pll refused the bitstream.  DEBUG_LOG O13.
	//
	// It displaces dbg_cpu_stall, which was not measuring what its name
	// says: ss_memarb's `declined` counts any clock the controller had an
	// early ack and the arbiter did not switch, for ANY client, which is
	// ordinary operation rather than CPU starvation.  A row that reads
	// 30,000-60,000 every frame and means nothing in particular is worth
	// less than a clock that has to stay alive.
	.d03(aux_edges),                       // non-zero AND CHANGING, or the
	                                       // third PLL output is gone
	// page 1 -- the other two layers, and what the SDRAM is doing about it
	// These two were roz_overrun and fg_overrun.  Both read 0 on every
	// hardware sample ever taken, including ten in a live match, so they have
	// answered their question and the rows are worth more spent on the one
	// that is open: the game runs at 58 % of MAME's speed and the 68000 is
	// the lowest-priority client on the SDRAM its program lives in.
	//
	// Compare against MAME's own trace through a driven match:
	//   cpu_miss  39,373 uncached / 9,838 with 1024 entries / 3,333 with 8192
	//   cpu_wait  out of 801,000 core clocks in a frame
	// cpu_wait has answered its question: extra clocks per cache miss went
	// 13.1 -> 4.6 with cpu_first, measured.  What is open is the thing the
	// person at the board actually feels -- the game's own headroom -- and
	// that is spin_fr, in MAME's own units.  Read it against spr_tiles on
	// page 0 from the same frame; MAME's reference is in ss_main.sv.
	.d04(dbg_spin_fr),                     // per frame: spin reads = headroom
	.d05(dbg_cpu_miss),                    // per frame: cache misses served
	// THE SPLIT.  Worst sprite line of the frame: how many clocks it took and
	// how many of those were spent asking the SDRAM and not being answered.
	// Read against d02 (tiles) from the same frame -- busy/tiles is the real
	// clocks-per-tile, and wait/busy says which half to work on next.  The
	// simulation bench and the board disagree by 24 % about the last change
	// and this is the number that settles it.
	// PER FRAME now, and they were not before: they were all-time maxima
	// while these comments called them the worst line of the frame.  An
	// all-time maximum of a quantity that saturates freezes at the first
	// saturated line and then says nothing, which is how two builds got
	// compared on two different lines.
	.d06(dbg_spr_busy),                    // per frame: worst line's clocks
	.d07(dbg_spr_wait),                    // ...that SAME line's rom stall
	// ---- pages 2 and 3: THE SOUND CHAIN ------------------------------
	// The ROM probes held these eight rows and have done their job -- all
	// seven regions have read back byte-correct on every capture since the
	// core first loaded.  Sound is now the last unverified part of this
	// board, and it cannot be checked by listening from another continent.
	//
	// Read them as a LADDER, top to bottom.  The first one that is zero is
	// where the chain breaks, and every rung above it being non-zero is
	// what makes that statement mean something.
	// page 2 -- does the chain run
	// d08/d09 were z80_cyc and latch_ack.  Both have been non-zero on every
	// capture since the core first ran, so the ladder's bottom two rungs have
	// answered their question and ym_wr/sample below still hold the top two.
	//
	// What is open is whether the memory system is slow or merely contended,
	// and busy/acks answers exactly that with nothing inferred: read against
	// cpu_wait and cpu_miss on page 1, a high clocks-per-read means the SDRAM
	// path itself, a low one with a high cpu_wait means the 68000 is queuing
	// behind other clients.  Those are different faults with different fixes.
	// WHICH .mra STATUS BITS ACTUALLY ARRIVE.  line_acks has answered and gives
	// up its row.  Read as hex: high byte is status[23:16], low byte is
	// status[15:8] -- the two bytes the .mra supplies.  The FAULT mra sets
	// bits 19, 11 and 9, so a core that received all of them reads 0AB4.
	// Whatever it actually reads is the answer to which bits survive hps_io.
	.d08({status[23:16], status[15:8]}),
	.d09(dbg_line_busy),                   // WORST line: clocks with demand
	// ym_wr and sample were here and both read FFFF on every capture -- they
	// are cumulative and saturate in seconds, so they say only "more than
	// 65535 since reset".  Giving the CPU priority SPENDS the video clients'
	// slack, and power_spikes O11 is explicit that a claim about one client
	// is half a claim until the others are read.  These are that other half.
	// roz_overrun and fg_overrun read 0 on all sixteen samples of build 19,
	// so cpu_first is proven not to have spent the layers' slack and they
	// have answered.  The BGM is the live complaint: a person at the board
	// hears roughly half the channels.  MAME says this game drives FM
	// channels 1,2,5,6 and ALL SIX ADPCM-A channels, with the SSG on for
	// only 3 % of frames (tools/ss_chan.lua), so these two are the ones that
	// carry the music.
	.d10(dbg_fm_kon),                      // FM key-on writes, cumulative
	.d11(dbg_pcma_kon),                    // ADPCM-A key-on writes
	// page 3 -- is any of it audible
	// These were peak_l and peak_r, max-held.  They answered "is any of it
	// audible" and it is.  The open question is the NOISE, and the way to
	// count noise is to count the thing the person complained about:
	// sample-to-sample discontinuities.  MAME's own render of this game --
	// 4,800,001 samples at 48 kHz -- has a largest |delta| of 3,840 and ZERO
	// above 4,096, so 4,096 is a line correct audio does not cross and any
	// count here above zero is an event this game does not produce.
	// jump_fr and late_fr both read 0 on every hardware sample and have
	// answered; the reported noise is broadband hiss, which a differential
	// codec cannot make (its damage is dull and low, shadow_force A55) and
	// which the SSG's noise generator makes exactly.  MAME never enables
	// that generator on this game -- 0 of 6,000 frames on all three
	// channels -- and its SSG is 2.4 % of output RMS.  These two say whether
	// ours is behaving like that.
	// ---- THE TWO COMPLAINTS, MEASURED -- not a cause, the symptom -----
	//
	// peak_psg was here and has ANSWERED: 0 on 15 of 18 board captures, and
	// MAME's SSG is 0.4 % of this game's mix energy.  peak_l was here and is
	// identical to peak_fm on every capture, so it carried nothing peak_fm
	// does not.  Both give up their rows to the thing actually complained of.
	//
	// mad = mean |snd_l|, mdd = mean |snd_l[n]-snd_l[n-1]|, both over exactly
	// 1024 output samples so the mean is a shift.  MAME through the same
	// scenes, with ADPCM-A broken two ways as controls (tools/ss_music.lua):
	//
	//     run                          mean|x|   mean|dx|   ratio
	//     correct                        692       102      0.148
	//     ADPCM-A decoding scrambled    2240      1454      0.649   <- hiss
	//     ADPCM-A keyed off              286        36      0.125   <- gone
	//
	// mdd/mad RISING is the hiss.  mad FALLING is the missing instruments.
	// Two symptoms, two numbers, and a reference and a positive control for
	// each -- which is what every earlier row on this page lacked.
	.d12(dbg_mad),                         // mean |snd_l| / 1024 samples
	.d13(dbg_mdd),                         // mean |delta| / same 1024
	// peak_fm has answered and reads the same on every build since the clock
	// fix -- 8,690 / 8,721 / 8,845 -- so it gives up its row to the fault
	// itself, counted CUMULATIVELY.  pcma_worst below is a per-frame duration
	// and a screenshot lands on one frame: 56 captures pooled over today
	// cover 0.8 % of the frames that went past.  This one counts every slot
	// since reset, so a single capture answers "has a byte EVER been late".
	.d14(dbg_pcma_bad),                    // CUMULATIVE stale-byte slots
	// TOP BIT IS THE OSD BIT ITSELF.  The on-board control ran twice and
	// pcma_bad read 0 in BOTH -- with the fault MRA as well as without -- so
	// either status[19] never arrives or the injector is inert, and the two
	// *** status[19] 는 2026-09-09 에 "Test (board menu)" 로 재사용됐다. ***
	// 아래 서술은 그때의 fault injector 이야기이고 지금 그 비트의 뜻이 아니다.
	// 출하 .mra 의 index-1 기본값은 00 80 00 이라 비트 19 는 0 이다.
	// look identical from outside.  This splits them in one row: read it as
	// hex, high bit = the OSD bit as the core sees it, low byte = pcma_worst
	// (which has never exceeded 55, so eight bits is plenty).
	//
	//   0037  fault OFF, worst 55        8037  fault ON, worst 55
	//
	// If the FAULT mra shows 00xx, the .mra bit is not reaching the core and
	// nothing downstream matters.  If it shows 80xx while pcma_bad stays 0,
	// the injector is inert and the fault is mine, again.
	.d15(dbg_pcma_worst)
);

///////////////////////   VIDEO   ////////////////////////////////

wire [2:0] fx = status[4:2];

// ss_dbg REGISTERS its colour on ce_pix, so ov_* is one pixel behind vid_*.
// The syncs and blanks come straight out of ss_top, so without this the first
// visible pixel of every line carries the last BLANKED pixel's colour -- a
// black column at x=0 -- and the last visible pixel is pushed into blanking.
// Delay them by the same one enable rather than removing the overlay's
// register, which is there to keep the mux out of the pixel path.
reg ov_hs, ov_vs, ov_hb, ov_vb;
always @(posedge clk_sys) if (ce_pix) begin
	ov_hs <= hsync;
	ov_vs <= vsync;
	ov_hb <= hblank;
	ov_vb <= vblank;
end

// CLK_VIDEO and CE_PIXEL are OUTPUTS of arcade_video and `.*` binds them to
// the top-level ports of the same name.  Assigning CLK_VIDEO here as well is
// a second driver, and Quartus says so in a message that names `dsw[0]` --
// the fanout it happened to pick -- rather than naming the clock.
// WIDTH is what arcade_video uses for the "Original" aspect: 320 visible
// pixels.  Getting it wrong stretches the picture in a way that looks like a
// timing fault.
arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({ov_r, ov_g, ov_b}),
	.HBlank(ov_hb),
	.VBlank(ov_vb),
	.HSync(ov_hs),
	.VSync(ov_vs),
	.fx(fx)
);

endmodule
