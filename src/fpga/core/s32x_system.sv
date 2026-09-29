//
// Console system: S32X_MiSTer's Genesis (gen) + 32X (S32X) + cartridge mapper (CART), with the
// cart ROM, cart save RAM and 32X SDRAM in SDRAM (sdram.sv) and the 32X framebuffers in the async
// SRAM (fb_sram.sv). Wiring follows upstream S32X.sv with s32x_rom = 1: like a real 32X, every
// cart (32X or plain Genesis) goes through the 32X, which passes Genesis carts through.
//
// MEMTEST builds (tools/build.sh --memtest) leave the 32X out (GENESIS_ONLY) and let memtest.sv
// drive the framebuffer SRAM and the 32X SDRAM port instead.
//
// Clock domains: everything here runs on clk_sys (MCLK) except the SDRAM controller, which runs
// on clk_ram (2x MCLK, same PLL) and samples its request inputs from the clk_sys domain, exactly
// as in upstream.
//

`ifdef MEMTEST
`define GENESIS_ONLY
`endif

module s32x_system
(
	input         clk_sys,
	input         clk_ram,
	input         pll_locked,
	input         reset,          // clk_sys domain, active high

	// ROM loading (clk_sys domain)
	input         rom_loading,    // high while the ROM data slot is being written
	input         rom_wr,         // one write per 16-bit word, file byte order
	input  [23:0] rom_wr_addr,    // byte address
	input  [15:0] rom_wr_data,    // [7:0] = byte at rom_wr_addr, [15:8] = next byte

	// Controls (clk_sys domain). MiSTer format, active high:
	// [0] right [1] left [2] down [3] up [4] A [5] B [6] C [7] start [8] mode [9] X [10] Y [11] Z
	input  [11:0] joy_1,
	input  [11:0] joy_2,
	input         j3but,          // 1 = 3-button pad

	// Video (clk_sys domain)
	output  [7:0] r,
	output  [7:0] g,
	output  [7:0] b,
	output        ce_pix,
	output        hblank,
	output        vblank,
	output        hs_n,
	output        vs_n,
	output  [1:0] resolution,     // {V30, H40}, locked for the whole frame
	output        interlace,
	output        field,
	output        pal,

	// Audio (clk_sys domain), signed
	output [15:0] audio_l,
	output [15:0] audio_r,

	// SDRAM
	inout  [15:0] SDRAM_DQ,
	output [12:0] SDRAM_A,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output  [1:0] SDRAM_BA,
	output        SDRAM_nWE,
	output        SDRAM_nRAS,
	output        SDRAM_nCAS,
	output        SDRAM_CLK,
	output        SDRAM_CKE,

	// Async SRAM (32X framebuffers)
	output [16:0] SRAM_A,
	inout  [15:0] SRAM_DQ,
	output        SRAM_OE_N,
	output        SRAM_WE_N,
	output        SRAM_UB_N,
	output        SRAM_LB_N,

	// Memory self-test status (MEMTEST builds; zero otherwise):
	// {sdram_fail, sdram_passes[15:0], sweep_fail[7:0], sweep_done[7:0], sweep_cur[2:0]}
	output [35:0] memtest_status
);

///////////////////////////////////////////////////
// Cartridge header: size and region

reg [23:0] rom_sz;
reg        hdr_j, hdr_u, hdr_e;
wire [3:0] hrgn = rom_wr_data[3:0] - 4'd7;

always @(posedge clk_sys) begin
	reg old_loading;
	old_loading <= rom_loading;

	if (~old_loading & rom_loading) begin
		rom_sz <= 0;
		{hdr_j, hdr_u, hdr_e} <= 0;
	end

	if (rom_loading & rom_wr) begin
		if (rom_wr_addr + 24'd2 > rom_sz) rom_sz <= rom_wr_addr + 24'd2;

		// Region field at 0x1F0: "J"/"U"/"E" characters, or a new-style hex digit
		// (bit0 = Japan, bit2 = US, bit3 = Europe). Only the first three characters matter.
		if (rom_wr_addr == 24'h1F0 || rom_wr_addr == 24'h1F2) begin
			if      (rom_wr_data[7:0] == "J") hdr_j <= 1;
			else if (rom_wr_data[7:0] == "U") hdr_u <= 1;
			else if (rom_wr_data[7:0] == "E") hdr_e <= 1;
			else if (rom_wr_addr == 24'h1F0 && rom_wr_data[7:0] >= "0" && rom_wr_data[7:0] <= "9")
				{hdr_e, hdr_u, hdr_j} <= {rom_wr_data[3], rom_wr_data[2], rom_wr_data[0]};
			else if (rom_wr_addr == 24'h1F0 && rom_wr_data[7:0] >= "A" && rom_wr_data[7:0] <= "F")
				{hdr_e, hdr_u, hdr_j} <= {hrgn[3], hrgn[2], hrgn[0]};
			if      (rom_wr_data[15:8] == "J") hdr_j <= 1;
			else if (rom_wr_data[15:8] == "U") hdr_u <= 1;
			else if (rom_wr_data[15:8] == "E") hdr_e <= 1;
		end
	end
end

// Region preference: US, then Japan, then Europe. No header region: US.
// PAL is signalled to the VDP, but MCLK stays NTSC until REQ-ARCH-06 (PAL runs ~1% fast).
reg export_r, pal_r;
always @(posedge clk_sys) begin
	reg old_loading;
	old_loading <= rom_loading;
	if (old_loading & ~rom_loading) begin
		if      (hdr_u)  {export_r, pal_r} <= 2'b10;
		else if (hdr_j)  {export_r, pal_r} <= 2'b00;
		else if (hdr_e)  {export_r, pal_r} <= 2'b11;
		else             {export_r, pal_r} <= 2'b10;
	end
end
assign pal = pal_r;

///////////////////////////////////////////////////
// Genesis

wire [23:1] GEN_VA;
wire [15:0] GEN_VDI, GEN_VDO;
wire        GEN_AS_N, GEN_DTACK_N, GEN_ASEL_N;
wire        GEN_RAS2_N, GEN_CAS2_N;
wire        GEN_VCLK_CE, GEN_CE0_N;
wire        GEN_LWR_N, GEN_UWR_N, GEN_CAS0_N;
wire        GEN_TIME_N;
wire        GEN_MEM_BUSY;

wire  [3:0] GEN_R, GEN_G, GEN_B;
wire  [1:0] gen_resolution;
wire        GEN_YS_N, GEN_EDCLK, GEN_HBLANK, GEN_DOT_CE;
wire [15:0] S32X_SL, S32X_SR;
wire        sys_reset = reset | rom_loading;

wire [15:0] CART_VDO;
wire        CART_DTACK_N;
wire [23:1] CART_ROM_A;
wire [15:0] CART_ROM_DO;
wire        CART_ROM_WRL, CART_ROM_WRH, CART_ROM_RD;
wire [14:0] CART_SRAM_A;
wire  [7:0] CART_SRAM_DO;
wire        CART_SRAM_WR, CART_SRAM_RD;

wire [15:0] sdr_do[4];
wire  [3:0] sdr_busy;

gen gen
(
	.RESET_N(~sys_reset),
	.MCLK(clk_sys),

	.VA(GEN_VA),
	.VDI(GEN_VDI),
	.VDO(GEN_VDO),
	.RNW(),
	.LDS_N(),
	.UDS_N(),
	.AS_N(GEN_AS_N),
	.DTACK_N(GEN_DTACK_N),
	.ASEL_N(GEN_ASEL_N),
	.VCLK_CE(GEN_VCLK_CE),
	.CE0_N(GEN_CE0_N),
	.RAS2_N(GEN_RAS2_N),
	.CAS2_N(GEN_CAS2_N),
	.ROM_N(),
	.FDC_N(),
	.CART_N(1'b0),
	.DISK_N(1'b1),
	.LWR_N(GEN_LWR_N),
	.UWR_N(GEN_UWR_N),
	.CAS0_N(GEN_CAS0_N),
	.TIME_N(GEN_TIME_N),

	.LOADING(rom_loading),
	.EXPORT(export_r),
	.PAL(pal_r),

	.RED(GEN_R),
	.GREEN(GEN_G),
	.BLUE(GEN_B),
	.YS_N(GEN_YS_N),
	.EDCLK(GEN_EDCLK),
	.VS(vs_n),
	.HS(hs_n),
	.HBL(GEN_HBLANK),
	.VBL(vblank),
	.BORDER(1'b0),
	.DOT_CE(GEN_DOT_CE),
	.FIELD(field),
	.INTERLACE(interlace),
	.RESOLUTION(gen_resolution),

	.J3BUT(j3but),
	.JOY_1(joy_1),
	.JOY_2(joy_2),
	.JOY_3(12'd0),
	.JOY_4(12'd0),
	.JOY_5(12'd0),
	.MULTITAP(3'd0),

	.MOUSE(25'd0),
	.MOUSE_OPT(3'd0),

	.GUN_OPT(1'b0),
	.GUN_TYPE(1'b0),
	.GUN_SENSOR(1'b0),
	.GUN_A(1'b0),
	.GUN_B(1'b0),
	.GUN_C(1'b0),
	.GUN_START(1'b0),

	.SERJOYSTICK_IN(8'hFF),
	.SERJOYSTICK_OUT(),
	.SER_OPT(2'd0),

	.EN_GEN_FM(1'b1),
	.EN_GEN_PSG(1'b1),
`ifdef GENESIS_ONLY
	.EN_32X_PWM(1'b0),
`else
	.EN_32X_PWM(1'b1),
`endif
	.EN_HIFI_PCM(1'b0),
	.LADDER(1'b1),
	.LPF_MODE(2'b00),
	.FMBUSY_QUIRK(1'b0),

	.EXT_SL(S32X_SL),
	.EXT_SR(S32X_SR),

	.DAC_LDATA(audio_l),
	.DAC_RDATA(audio_r),

	.OBJ_LIMIT_HIGH(1'b0),

	.MEM_RDY(~GEN_MEM_BUSY),
	.GG_RESET(1'b0),
	.GG_EN(1'b0),
	.GG_CODE(129'd0),
	.GG_AVAILABLE(),

	.PAUSE_EN(1'b0),
	.BGA_EN(1'b1),
	.BGB_EN(1'b1),
	.SPR_EN(1'b1),
	.BG_GRID_EN(2'b00),
	.SPR_GRID_EN(1'b0),

	.DBG_M68K_A(),
	.DBG_VA_A()
);

assign GEN_MEM_BUSY = !GEN_RAS2_N                  ? 1'b0 :
                      CART_SRAM_RD || CART_SRAM_WR ? sdr_busy[2] :
                                                     sdr_busy[1];

// Genesis 9-bit color to 24-bit (same LUT as upstream S32X.sv)
wire [7:0] color_lut[16] = '{
	8'd0,   8'd27,  8'd49,  8'd71,
	8'd87,  8'd103, 8'd119, 8'd130,
	8'd146, 8'd157, 8'd174, 8'd190,
	8'd206, 8'd228, 8'd255, 8'd255
};
wire  [4:0] S32X_R, S32X_G, S32X_B;
wire        S32X_YSO_N, S32X_HBLANK, S32X_DOT_CE;

`ifdef GENESIS_ONLY
assign r = color_lut[GEN_R];
assign g = color_lut[GEN_G];
assign b = color_lut[GEN_B];
assign hblank = GEN_HBLANK;
assign ce_pix = GEN_DOT_CE;
`else
// Genesis and 32X layers mixed per pixel by the 32X priority output (YSO_N), as upstream
// S32X.sv does with both layers enabled. Timing comes from the 32X VDP, which follows the
// Genesis VDP's dot clock.
assign r = !S32X_YSO_N ? {S32X_R, S32X_R[4:2]} : color_lut[GEN_R];
assign g = !S32X_YSO_N ? {S32X_G, S32X_G[4:2]} : color_lut[GEN_G];
assign b = !S32X_YSO_N ? {S32X_B, S32X_B[4:2]} : color_lut[GEN_B];
assign hblank = S32X_HBLANK;
assign ce_pix = S32X_DOT_CE;
`endif

// Lock the resolution for the whole frame (as upstream S32X.sv)
reg  [1:0] res;
always @(posedge clk_sys) begin
	reg old_vbl;
	old_vbl <= vblank;
	if (old_vbl & ~vblank) res <= gen_resolution;
end
assign resolution = res;

///////////////////////////////////////////////////
// Framebuffer SRAM and 32X SDRAM port signals (driven by the 32X, or by memtest)

wire [15:0] FB0_A, FB0_DO, FB0_DI, FB1_A, FB1_DO, FB1_DI;
wire  [1:0] FB0_WE, FB1_WE;
wire        FB0_RD, FB1_RD, FB_FS;
wire  [3:0] fb_cfg_rd, fb_cfg_we;
wire        fb_cfg_half;

wire [24:1] s32x_sdr_addr;
wire        s32x_sdr_rd;
wire  [1:0] s32x_sdr_wr;
wire [15:0] s32x_sdr_din;

// Cart bus: from the Genesis directly (GENESIS_ONLY) or from the 32X's cart side.
wire [23:1] C_VA;
wire [15:0] C_VDI;
wire        C_LWR_N, C_UWR_N, C_CE0_N, C_CAS0_N, C_CAS2_N, C_ASEL_N;

`ifdef GENESIS_ONLY
assign GEN_VDI     = CART_VDO;
assign GEN_DTACK_N = CART_DTACK_N;
assign {C_VA, C_VDI, C_LWR_N, C_UWR_N, C_CE0_N, C_CAS0_N, C_CAS2_N, C_ASEL_N} =
       {GEN_VA, GEN_VDO, GEN_LWR_N, GEN_UWR_N, GEN_CE0_N, GEN_CAS0_N, GEN_CAS2_N, GEN_ASEL_N};
assign {S32X_SL, S32X_SR} = '0;
assign {S32X_R, S32X_G, S32X_B, S32X_YSO_N, S32X_HBLANK, S32X_DOT_CE} = '0;
`else
///////////////////////////////////////////////////
// 32X

wire [15:0] S32X_VDO;
wire        S32X_DTACK_N;
wire [23:1] S32X_CA;
wire [15:0] S32X_CDO;
wire        S32X_CASEL_N, S32X_CLWR_N, S32X_CUWR_N, S32X_CCE0_N, S32X_CCAS0_N, S32X_CCAS2_N;
wire [17:1] S32X_SDR_A;
wire [15:0] S32X_SDR_DO;
wire        S32X_SDR_CS, S32X_SDR_RD;
wire  [1:0] S32X_SDR_WE;

assign GEN_VDI     = S32X_VDO;
assign GEN_DTACK_N = S32X_DTACK_N & CART_DTACK_N;
assign {C_VA, C_VDI, C_LWR_N, C_UWR_N, C_CE0_N, C_CAS0_N, C_CAS2_N, C_ASEL_N} =
       {S32X_CA, S32X_CDO, S32X_CLWR_N, S32X_CUWR_N, S32X_CCE0_N, S32X_CCAS0_N, S32X_CCAS2_N, S32X_CASEL_N};

S32X #(
	.USE_ROM_WAIT(1),
	.USE_ASYNC_FB(1)        // framebuffers in external SRAM (fb_sram.sv relies on this mode)
) S32X
(
	.RST_N(~sys_reset),
	.CLK(clk_sys),

	.VCLK(GEN_VCLK_CE),
	.VA(GEN_VA),
	.VDI(GEN_VDO),
	.VDO(S32X_VDO),
	.AS_N(GEN_AS_N),
	.DTACK_N(S32X_DTACK_N),
	.LWR_N(GEN_LWR_N),
	.UWR_N(GEN_UWR_N),
	.CE0_N(GEN_CE0_N),
	.CAS0_N(GEN_CAS0_N),
	.CAS2_N(GEN_CAS2_N),
	.ASEL_N(GEN_ASEL_N),
	.VRES_N(1'b1),
	.MRES_N(1'b1),
	.CART_N(1'b0),

	.VSYNC_N(vs_n),
	.HSYNC_N(hs_n),
	.EDCLK(GEN_EDCLK),
	.YS_N(GEN_YS_N),
	.PAL(pal_r),

	.CA(S32X_CA),
	.CDI(CART_VDO),
	.CDO(S32X_CDO),
	.CASEL_N(S32X_CASEL_N),
	.CLWR_N(S32X_CLWR_N),
	.CUWR_N(S32X_CUWR_N),
	.CCE0_N(S32X_CCE0_N),
	.CCAS0_N(S32X_CCAS0_N),
	.CCAS2_N(S32X_CCAS2_N),
	.ROM_WAIT(CART_SRAM_RD || CART_SRAM_WR ? sdr_busy[2] : sdr_busy[1]),

	.SDR_A(S32X_SDR_A),
	.SDR_DI(sdr_do[0]),
	.SDR_DO(S32X_SDR_DO),
	.SDR_CS(S32X_SDR_CS),
	.SDR_WE(S32X_SDR_WE),
	.SDR_RD(S32X_SDR_RD),
	.SDR_WAIT(sdr_busy[0]),

	.FB0_A(FB0_A),
	.FB0_DI(FB0_DI),
	.FB0_DO(FB0_DO),
	.FB0_WE(FB0_WE),
	.FB0_RD(FB0_RD),
	.FB1_A(FB1_A),
	.FB1_DI(FB1_DI),
	.FB1_DO(FB1_DO),
	.FB1_WE(FB1_WE),
	.FB1_RD(FB1_RD),
	.FB_FS(FB_FS),

	.DOT_CE(S32X_DOT_CE),
	.R(S32X_R),
	.G(S32X_G),
	.B(S32X_B),
	.HS_N(),
	.VS_N(),
	.YSO_N(S32X_YSO_N),
	.HBL(S32X_HBLANK),

	.PWM_L(S32X_SL),
	.PWM_R(S32X_SR),

	.DBG_CA()
);

// 32X SDRAM (256 KB) on sdram.sv port 0 at 0x1000000, as upstream's use_sdr path.
assign s32x_sdr_addr = {7'b1000000, S32X_SDR_A};
assign s32x_sdr_rd   = S32X_SDR_CS & S32X_SDR_RD;
assign s32x_sdr_wr   = S32X_SDR_WE & {2{S32X_SDR_CS}};
assign s32x_sdr_din  = S32X_SDR_DO;
`endif

///////////////////////////////////////////////////
// Cartridge

CART cart
(
	.CLK(clk_sys),
	.RST_N(~sys_reset),

	.VCLK(GEN_VCLK_CE),
	.VA(C_VA),
	.VDI(C_VDI),
	.VDO(CART_VDO),
	.AS_N(GEN_AS_N),
	.DTACK_N(CART_DTACK_N),
	.LWR_N(C_LWR_N),
	.UWR_N(C_UWR_N),
	.CE0_N(C_CE0_N),
	.CAS0_N(C_CAS0_N),
	.CAS2_N(C_CAS2_N),
	.ASEL_N(C_ASEL_N),
	.TIME_N(GEN_TIME_N),

	.ROM_A(CART_ROM_A),
	.ROM_DI(sdr_do[1]),
	.ROM_DO(CART_ROM_DO),
	.ROM_RD(CART_ROM_RD),
	.ROM_WRL(CART_ROM_WRL),
	.ROM_WRH(CART_ROM_WRH),

	.SRAM_A(CART_SRAM_A),
	.SRAM_DI(sdr_do[2][7:0]),
	.SRAM_DO(CART_SRAM_DO),
	.SRAM_RD(CART_SRAM_RD),
	.SRAM_WR(CART_SRAM_WR),

	.rom_sz(rom_sz),
`ifdef GENESIS_ONLY
	.s32x(1'b0),
`else
	.s32x(1'b1),
`endif
	.eeprom_map(4'd0),
	.noram_quirk(1'b0),
	.realtec_map(1'b0),
	.sf_map(3'd0)
);

///////////////////////////////////////////////////
// 32X framebuffers in SRAM (fb_sram.sv)

reg  [1:0] ram_reset_sync;
always @(posedge clk_ram) ram_reset_sync <= {ram_reset_sync[0], ~pll_locked};

fb_sram fb_sram
(
	.clk_ram(clk_ram),
	.reset(ram_reset_sync[1]),
	.FB0_A(FB0_A), .FB0_DO(FB0_DO), .FB0_WE(FB0_WE), .FB0_RD(FB0_RD), .FB0_DI(FB0_DI),
	.FB1_A(FB1_A), .FB1_DO(FB1_DO), .FB1_WE(FB1_WE), .FB1_RD(FB1_RD), .FB1_DI(FB1_DI),
	.FB_FS(FB_FS),
	.cfg_rd(fb_cfg_rd), .cfg_we(fb_cfg_we), .cfg_half(fb_cfg_half),
	.sram_a(SRAM_A), .sram_dq(SRAM_DQ), .sram_oe_n(SRAM_OE_N), .sram_we_n(SRAM_WE_N),
	.sram_ub_n(SRAM_UB_N), .sram_lb_n(SRAM_LB_N)
);

`ifdef MEMTEST
memtest memtest
(
	.clk(clk_sys),
	.reset(reset),
	.FB0_A(FB0_A), .FB0_DO(FB0_DO), .FB0_WE(FB0_WE), .FB0_RD(FB0_RD), .FB0_DI(FB0_DI),
	.FB1_A(FB1_A), .FB1_DO(FB1_DO), .FB1_WE(FB1_WE), .FB1_RD(FB1_RD), .FB1_DI(FB1_DI),
	.FB_FS(FB_FS), .cfg_rd(fb_cfg_rd), .cfg_we(fb_cfg_we), .cfg_half(fb_cfg_half),
	.sdr_addr(s32x_sdr_addr), .sdr_rd(s32x_sdr_rd), .sdr_wr(s32x_sdr_wr), .sdr_din(s32x_sdr_din),
	.sdr_dout(sdr_do[0]), .sdr_busy(sdr_busy[0]),
	.sram_passes(), .sram_fail(),
	.sweep_cur(memtest_status[2:0]), .sweep_done(memtest_status[10:3]), .sweep_fail(memtest_status[18:11]),
	.sdram_passes(memtest_status[34:19]), .sdram_fail(memtest_status[35])
);
`else
// Production SRAM timing, from the hardware sweep: reads need more than 28 ns, 37 ns works.
assign fb_cfg_rd   = 4'd4;    // 37 ns read capture
assign fb_cfg_we   = 4'd2;    // 19 ns WE pulse
assign fb_cfg_half = 1'b0;
assign memtest_status = '0;
`endif

///////////////////////////////////////////////////
// SDRAM (upstream sdram.sv, Pocket timing patch). Byte addresses, 32 MB usable:
//   0x0000000-0x0FFFFFF  cart ROM (port 1 reads, port 3 loader writes)
//   0x1000000-0x103FFFF  32X SDRAM (port 0)
//   0x1800000-0x180FFFF  cart save RAM (port 2)

sdram sdram
(
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),

	.init(~pll_locked),
	.clk(clk_ram),

	.addr0(s32x_sdr_addr),
	.rd0(s32x_sdr_rd),
	.wr0(s32x_sdr_wr),
	.din0(s32x_sdr_din),
	.dout0(sdr_do[0]),
	.busy0(sdr_busy[0]),

	.addr1({1'b0, CART_ROM_A[23:1]}),
	.rd1(CART_ROM_RD | CART_ROM_WRL | CART_ROM_WRH),
	.wr1(2'b00),
	.din1(CART_ROM_DO),
	.dout1(sdr_do[1]),
	.busy1(sdr_busy[1]),

	.addr2({9'b110000000, CART_SRAM_A[14:0]}),
	.rd2(CART_SRAM_RD),
	.wr2({2{CART_SRAM_WR}}),
	.din2({8'hFF, CART_SRAM_DO}),
	.dout2(sdr_do[2]),
	.busy2(sdr_busy[2]),

	// Loader: file bytes are big-endian 68K words, so swap into {even, odd}.
	.addr3({1'b0, rom_wr_addr[23:1]}),
	.rd3(1'b0),
	.wr3({2{rom_loading & rom_wr}}),
	.din3({rom_wr_data[7:0], rom_wr_data[15:8]}),
	.dout3(sdr_do[3]),
	.busy3(sdr_busy[3])
);

endmodule
