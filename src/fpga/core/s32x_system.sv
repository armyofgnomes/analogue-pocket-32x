//
// Console system: S32X_MiSTer's Genesis (gen) + 32X (S32X) + cartridge mapper (CART), with the
// cart ROM and 32X SDRAM in SDRAM (sdram.sv), the cart save RAM in block RAM (s32x_save_ram.sv)
// and the 32X framebuffers in the async SRAM (fb_sram.sv). Wiring follows upstream S32X.sv with
// s32x_rom = 1: like a real 32X, every cart (32X or plain Genesis) goes through the 32X, which
// passes Genesis carts through.
//
// MEMTEST builds (tools/build.sh --memtest) leave the 32X out (GENESIS_ONLY) and let memtest.sv
// drive the framebuffer SRAM and the 32X SDRAM port instead.
//
// Clock domains: everything here runs on clk_sys (MCLK) except the SDRAM controller, which runs
// on clk_ram (2x MCLK, same PLL) and samples its request inputs from the clk_sys domain, exactly
// as in upstream.
//
// The cart quirks, color table and layer mixing below follow upstream S32X.sv by srg320, based on
// Sorgelig's FPGAGen port (Copyright (c) 2017-2019 Sorgelig, Genesis code Copyright (c) 2010-2013
// Gregory Estrade). That file is GPL-2.0-or-later; this one is GPL-3.0.
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

	// 32X BIOS loading (clk_sys, while rom_loading): word address [12] = 1 68K BIOS (128 words),
	// else the SH-2 image (master at word 0, slave at word 1024); big-endian 16-bit words
	input         bios_wr,
	input  [12:1] bios_wr_addr,
	input  [15:0] bios_wr_data,

	// Save memory (cart SRAM / EEPROM), APF bridge side on its own clock; see s32x_save_ram.sv
	input         save_clk,
	input  [13:0] save_a,         // 32-bit word address in the 64 KB save file
	input  [15:0] save_d,         // {byte at 4k+3, byte at 4k+1}
	input         save_we,
	output [15:0] save_q,

	// Controls (clk_sys domain). MiSTer format, active high:
	// [0] right [1] left [2] down [3] up [4] A [5] B [6] C [7] start [8] mode [9] X [10] Y [11] Z
	input  [11:0] joy_1,
	input  [11:0] joy_2,
	input         j3but,          // 1 = 3-button pad

	// Settings (clk_sys, quasi-static)
	input   [1:0] region_sel,     // 0 auto (cart header), 1 US, 2 Japan, 3 Europe; applied at reset
	input   [1:0] lpf_mode,       // audio filter: 0 Model 1, 1 Model 2, 2 minimal, 3 none
	input         fm_ym3438,      // FM chip: 0 YM2612 (ladder effect), 1 YM3438
	input         hifi_pcm,
	input         sprite_high,    // raise the per-line sprite limit (less flicker, not accurate)

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
	output        s32x_aden,      // the game has switched the 32X adapter on (32X mode)

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

// Per-game cartridge quirks from the header's product code at 0x180 (as upstream S32X.sv): EEPROM
// save chips (Acclaim/EA/Sega carts, e.g. NBA Jam TE 32X hangs at start without its EEPROM), Puggsy's
// fake RAM check, Hellfire's FM busy flag, Game no Kanzume's writable ROM area, the SF-00x mappers
// and the Realtec mapper. Lightgun timing, Pier Solar and the SVP (Virtua Racing) don't apply here.
reg  [3:0] eeprom_map;
reg        realtec_map, noram_quirk, fmbusy_quirk, schan_quirk;
reg  [2:0] sf_map;
always @(posedge clk_sys) begin
	reg        old_loading;
	reg [87:0] cart_id;
	reg [15:0] crc;
	reg [31:0] realtec_id;
	old_loading <= rom_loading;

	if (~old_loading & rom_loading) {eeprom_map, realtec_map, noram_quirk, fmbusy_quirk, schan_quirk, sf_map} <= 0;

	if (rom_loading & rom_wr) begin
		if (rom_wr_addr == 24'h180) cart_id[87:72] <= {rom_wr_data[7:0], rom_wr_data[15:8]};
		if (rom_wr_addr == 24'h182) cart_id[71:56] <= {rom_wr_data[7:0], rom_wr_data[15:8]};
		if (rom_wr_addr == 24'h184) cart_id[55:40] <= {rom_wr_data[7:0], rom_wr_data[15:8]};
		if (rom_wr_addr == 24'h186) cart_id[39:24] <= {rom_wr_data[7:0], rom_wr_data[15:8]};
		if (rom_wr_addr == 24'h188) cart_id[23:08] <= {rom_wr_data[7:0], rom_wr_data[15:8]};
		if (rom_wr_addr == 24'h18A) cart_id[07:00] <= rom_wr_data[7:0];
		if (rom_wr_addr == 24'h18E) crc <= {rom_wr_data[7:0], rom_wr_data[15:8]};
		if (rom_wr_addr == 24'h190) begin
			if     (cart_id[63:0] == "T-50446 ") eeprom_map   <= 4'b0001;  // John Madden Football 93
			else if(cart_id[63:0] == "T-50516 ") eeprom_map   <= 4'b0001;  // John Madden Football 93 Championship Edition
			else if(cart_id[63:0] == "T-50396 ") eeprom_map   <= 4'b0001;  // NHLPA Hockey 93
			else if(cart_id[63:0] == "T-50176 ") eeprom_map   <= 4'b0001;  // Rings of Power
			else if(cart_id[63:0] == "T-50606 ") eeprom_map   <= 4'b0001;  // Bill Walsh College Football
			else if(cart_id[63:0] == "MK-1215 ") eeprom_map   <= 4'b0010;  // Evander Real Deal Holyfield's Boxing
			else if(cart_id[63:0] == "G-4060  ") eeprom_map   <= 4'b0010;  // Wonder Boy
			else if(cart_id[63:0] == "00001211") eeprom_map   <= 4'b0010;  // Sports Talk Baseball
			else if(cart_id[63:0] == "MK-1228 ") eeprom_map   <= 4'b0010;  // Greatest Heavyweights
			else if(cart_id[63:0] == "G-5538  ") eeprom_map   <= 4'b0010;  // Greatest Heavyweights JP
			else if(cart_id[63:0] == "00004076") eeprom_map   <= 4'b0010;  // Honoo no Toukyuuji Dodge Danpei
			else if(cart_id[63:0] == "T-12046 ") eeprom_map   <= 4'b0010;  // Mega Man - The Wily Wars
			else if(cart_id[63:0] == "T-12053 ") eeprom_map   <= 4'b0010;  // Rockman Mega World
			else if(cart_id[63:0] == "G-4524  ") eeprom_map   <= 4'b0010;  // Ninja Burai Densetsu
			else if(cart_id[63:0] == "00054503") eeprom_map   <= 4'b0010;  // Game Toshokan
			else if(cart_id[63:0] == "T-81033 ") eeprom_map   <= 4'b0011;  // NBA Jam (J)
			else if(cart_id[63:0] == "T-081326") eeprom_map   <= 4'b0011;  // NBA Jam (U)(E)
			else if(cart_id[63:0] == "T-081276") eeprom_map   <= 4'b1011;  // NFL Quarterback Club
			else if(cart_id[63:0] == "T-81406 ") eeprom_map   <= 4'b1011;  // NBA Jam TE
			else if(cart_id[63:0] == "T-081586") eeprom_map   <= 4'b1100;  // NFL Quarterback Club '96
			else if(cart_id[63:0] == "T-81576 ") eeprom_map   <= 4'b1101;  // College Slam
			else if(cart_id[63:0] == "T-81476 ") eeprom_map   <= 4'b1101;  // Frank Thomas Big Hurt Baseball
			else if(cart_id[63:0] == "T-8104B ") eeprom_map   <= 4'b1011;  // NBA Jam TE (32X)
			else if(cart_id[63:0] == "T-8102B ") eeprom_map   <= 4'b1011;  // NFL Quarterback Club (32X)
			else if(cart_id[63:0] == "T-113016") noram_quirk  <= 1;        // Puggsy fake RAM check
			else if(cart_id[63:0] == "T-35036 ") fmbusy_quirk <= 1;        // Hellfire US
			else if(cart_id[63:0] == "T-25073 ") fmbusy_quirk <= 1;        // Hellfire JP
			else if(cart_id[63:0] == "MK-1137-") fmbusy_quirk <= 1;        // Hellfire EU
			else if(cart_id[63:0] == "T-68???-") schan_quirk  <= 1;        // Game no Kanzume Otokuyou
			else if(cart_id[87:40] == "SF-001")  sf_map       <= {crc == 16'h3E08, 2'b01}; // Beggar Prince
			else if(cart_id[87:40] == "SF-002")  sf_map       <= {1'b1, 2'b10};           // Legend of Wukong
			else if(cart_id[87:40] == "SF-004")  sf_map       <= {1'b1, 2'b11};           // Star Odyssey
		end
		if (rom_wr_addr == 24'h7E100) realtec_id[31:16] <= {rom_wr_data[7:0], rom_wr_data[15:8]};
		if (rom_wr_addr == 24'h7E102) realtec_id[15:0]  <= {rom_wr_data[7:0], rom_wr_data[15:8]};
		if (rom_wr_addr == 24'h7E104 && realtec_id == "SEGA") realtec_map <= 1;   // Earth Defend, Funny World, Whac-a-Critter
	end
end

// Console reset: external reset, a user reset (core_top), or ROM loading
wire        sys_reset = reset | rom_loading;

// Region: from the setting, or (auto) from the header preferring US, then Japan, then Europe (no
// header region: US). Chosen while the console is held in reset (ROM loading, or a user reset,
// which a region change triggers). PAL is signalled to the VDP, but MCLK stays NTSC until
// REQ-ARCH-06 (PAL runs ~1% fast).
reg export_r, pal_r;
always @(posedge clk_sys) begin
	if (sys_reset) begin
		case (region_sel)
		2'd1: {export_r, pal_r} <= 2'b10;
		2'd2: {export_r, pal_r} <= 2'b00;
		2'd3: {export_r, pal_r} <= 2'b11;
		default:
			if      (hdr_u)  {export_r, pal_r} <= 2'b10;
			else if (hdr_j)  {export_r, pal_r} <= 2'b00;
			else if (hdr_e)  {export_r, pal_r} <= 2'b11;
			else             {export_r, pal_r} <= 2'b10;
		endcase
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

wire [15:0] CART_VDO;
wire        CART_DTACK_N;
wire [23:1] CART_ROM_A;
wire [15:0] CART_ROM_DO;
wire        CART_ROM_WRL, CART_ROM_WRH, CART_ROM_RD;
wire [14:0] CART_SRAM_A;
wire  [7:0] CART_SRAM_DO;
wire        CART_SRAM_WR, CART_SRAM_RD;
wire  [7:0] CART_SRAM_DI;
wire        CART_SRAM_BUSY;
wire  [9:0] CART_EEPROM_A;
wire  [7:0] CART_EEPROM_D, CART_EEPROM_Q;
wire        CART_EEPROM_WE;

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
	.EN_HIFI_PCM(hifi_pcm),
	.LADDER(~fm_ym3438),
	.LPF_MODE(lpf_mode),
	.FMBUSY_QUIRK(fmbusy_quirk),

	.EXT_SL(S32X_SL),
	.EXT_SR(S32X_SR),

	.DAC_LDATA(audio_l),
	.DAC_RDATA(audio_r),

	.OBJ_LIMIT_HIGH(sprite_high),

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
                      CART_SRAM_RD || CART_SRAM_WR ? CART_SRAM_BUSY :
                                                     sdr_busy[1];

// Genesis 9-bit color to 24-bit (same LUT as upstream S32X.sv)
wire [7:0] color_lut[16] = '{
	8'd0,   8'd27,  8'd49,  8'd71,
	8'd87,  8'd103, 8'd119, 8'd130,
	8'd146, 8'd157, 8'd174, 8'd190,
	8'd206, 8'd228, 8'd255, 8'd255
};
// Lock the resolution for the whole frame (as upstream S32X.sv)
reg  [1:0] res;
always @(posedge clk_sys) begin
	reg old_vbl;
	old_vbl <= vblank;
	if (old_vbl & ~vblank) res <= gen_resolution;
end
assign resolution = res;

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
// In H32 the 32X VDP still outputs a 320-dot active line (at the H32 dot rate), 64 dots wider than
// the Genesis picture, which the Pocket's 256-wide scaler mode showed shifted (Primal Rage's SEGA
// logo, Mega Man: The Wily Wars). The 32X layer can't be used in H32, so take the pixel timing from
// the Genesis there. `res` is locked per frame (below).
assign hblank = res[0] ? S32X_HBLANK : GEN_HBLANK;
assign ce_pix = res[0] ? S32X_DOT_CE : GEN_DOT_CE;
`endif


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
wire        s32x_sdr_line;          // port-0 read is an 8-word line read (sdram.sv patch 0008)
wire [127:0] sdr_do0_line;

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
assign s32x_sdr_line = 1'b0;                 // memtest uses single-word accesses on port 0
assign s32x_aden = 1'b0;
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
wire        s32x_sdr_wait;
wire [15:0] s32x_sdr_di, s32x_fb0_di, s32x_fb1_di;

assign GEN_VDI     = S32X_VDO;
assign GEN_DTACK_N = S32X_DTACK_N & CART_DTACK_N;
assign {C_VA, C_VDI, C_LWR_N, C_UWR_N, C_CE0_N, C_CAS0_N, C_CAS2_N, C_ASEL_N} =
       {S32X_CA, S32X_CDO, S32X_CLWR_N, S32X_CUWR_N, S32X_CCE0_N, S32X_CCAS0_N, S32X_CCAS2_N, S32X_CASEL_N};

S32X #(
	.USE_ROM_WAIT(1),
`ifdef SIM_MISTER_MEM
	.USE_ASYNC_FB(0)        // sim-only reference: MiSTer's configuration (see below)
`else
	.USE_ASYNC_FB(1)        // framebuffers in external SRAM (fb_sram.sv relies on this mode)
`endif
) S32X
(
	.RST_N(~sys_reset),
	.CLK(clk_sys),

	.BIOS_WE(bios_wr),
	.BIOS_A(bios_wr_addr),
	.BIOS_D(bios_wr_data),
	.ADEN(s32x_aden),

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
	.ROM_WAIT(CART_SRAM_RD || CART_SRAM_WR ? CART_SRAM_BUSY : sdr_busy[1]),

	.SDR_A(S32X_SDR_A),
	.SDR_DI(s32x_sdr_di),
	.SDR_DO(S32X_SDR_DO),
	.SDR_CS(S32X_SDR_CS),
	.SDR_WE(S32X_SDR_WE),
	.SDR_RD(S32X_SDR_RD),
	.SDR_WAIT(s32x_sdr_wait),

	.FB0_A(FB0_A),
	.FB0_DI(s32x_fb0_di),
	.FB0_DO(FB0_DO),
	.FB0_WE(FB0_WE),
	.FB0_RD(FB0_RD),
	.FB1_A(FB1_A),
	.FB1_DI(s32x_fb1_di),
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

// 32X SDRAM (256 KB) on sdram.sv port 0 at 0x1000000, through s32x_sdram_front.sv (16-byte read
// line buffer and a write queue, like MiSTer's ddram.sv): the SH-2 treats this area as SDRAM and
// only honors WAIT on the first beat of a read burst, never on writes.
wire [15:0] s32x_front_q;
wire        s32x_front_wait, s32x_front_ovf;
s32x_sdram_front s32x_sdram_front
(
	.clk(clk_sys), .reset(sys_reset),
	.a(S32X_SDR_A), .d(S32X_SDR_DO), .cs(S32X_SDR_CS), .rd(S32X_SDR_RD), .we(S32X_SDR_WE),
	.q(s32x_front_q), .wait_o(s32x_front_wait),
	.p_addr(s32x_sdr_addr), .p_rd(s32x_sdr_rd), .p_wr(s32x_sdr_wr), .p_din(s32x_sdr_din),
	.p_line(s32x_sdr_line), .p_dout_line(sdr_do0_line), .p_busy(sdr_busy[0]),
	.overflow(s32x_front_ovf)
);
`ifdef SIM_DDRAM_REF
// Sim-only reference (+define+SIM_DDRAM_REF): the 32X SDRAM exactly as MiSTer's default build
// serves it, through upstream ddram.sv (16-byte line cache, registered busy) in front of a simple
// DDR3 model with a fixed read latency.
wire        ddr_busy;
wire [31:0] ddr_do;
wire  [7:0] ddr_burstcnt, ddr_be;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire        ddr_rd, ddr_we;
reg  [63:0] ddr_dout;
reg         ddr_dout_ready = 0;
ddram ref_ddram
(
	.DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(ddr_burstcnt), .DDRAM_ADDR(ddr_addr),
	.DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_dout_ready), .DDRAM_RD(ddr_rd), .DDRAM_DIN(ddr_din),
	.DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we),
	.clk(clk_ram),
	.mem_addr({10'b0000000000, S32X_SDR_A}), .mem_dout(ddr_do), .mem_din({16'h0000, S32X_SDR_DO}),
	.mem_rd(S32X_SDR_CS & S32X_SDR_RD), .mem_wr({2'b00, {2{S32X_SDR_CS}} & S32X_SDR_WE}),
	.mem_chan(2'd0), .mem_16b(1'b1), .mem_busy(ddr_busy)
);
reg [63:0] ddr_mem [0:32767];
initial for (int i = 0; i < 32768; i++) ddr_mem[i] = 0;
always @(posedge clk_ram) begin
	static int rd_cnt = 0;
	static reg [14:0] rd_a;
	ddr_dout_ready <= 0;
	if (ddr_we)
		for (int b = 0; b < 8; b++) if (ddr_be[b]) ddr_mem[ddr_addr[14:0]][b*8 +: 8] <= ddr_din[b*8 +: 8];
	if (ddr_rd) begin rd_cnt = 12; rd_a = ddr_addr[14:0]; end
	else if (rd_cnt) begin
		rd_cnt--;
		if (rd_cnt == 1) begin ddr_dout <= ddr_mem[rd_a];      ddr_dout_ready <= 1; end
		if (rd_cnt == 0) begin ddr_dout <= ddr_mem[rd_a + 1'd1]; ddr_dout_ready <= 1; end
	end
end
assign s32x_sdr_di   = ddr_do[15:0];
assign s32x_fb0_di   = FB0_DI;
assign s32x_fb1_di   = FB1_DI;
assign s32x_sdr_wait = ddr_busy;
`elsif SIM_MISTER_MEM
// Sim-only reference configuration (+define+SIM_MISTER_MEM): memories as in MiSTer, to compare
// against. 32X SDRAM as an ideal zero-wait RAM; framebuffers as block RAM with a registered read
// address (like MiSTer's spram), with USE_ASYNC_FB=0 above.
reg [15:0] ref_sdram [0:131071];
reg [15:0] ref_fb0 [0:65535], ref_fb1 [0:65535];
reg [15:0] ref_fb0_q, ref_fb1_q;
initial for (int i = 0; i < 131072; i++) ref_sdram[i] = 0;
always @(posedge clk_sys) begin
	if (S32X_SDR_CS && S32X_SDR_WE[1]) ref_sdram[S32X_SDR_A][15:8] <= S32X_SDR_DO[15:8];
	if (S32X_SDR_CS && S32X_SDR_WE[0]) ref_sdram[S32X_SDR_A][7:0]  <= S32X_SDR_DO[7:0];
	if (FB0_WE[1]) ref_fb0[FB0_A][15:8] <= FB0_DO[15:8];
	if (FB0_WE[0]) ref_fb0[FB0_A][7:0]  <= FB0_DO[7:0];
	if (FB1_WE[1]) ref_fb1[FB1_A][15:8] <= FB1_DO[15:8];
	if (FB1_WE[0]) ref_fb1[FB1_A][7:0]  <= FB1_DO[7:0];
	ref_fb0_q <= ref_fb0[FB0_A];
	ref_fb1_q <= ref_fb1[FB1_A];
end
assign s32x_sdr_di   = ref_sdram[S32X_SDR_A];
assign s32x_fb0_di   = ref_fb0_q;
assign s32x_fb1_di   = ref_fb1_q;
assign s32x_sdr_wait = 1'b0;
`else
assign s32x_sdr_di   = s32x_front_q;
assign s32x_fb0_di   = FB0_DI;
assign s32x_fb1_di   = FB1_DI;
assign s32x_sdr_wait = s32x_front_wait;
`endif
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
	.SRAM_DI(CART_SRAM_DI),
	.SRAM_DO(CART_SRAM_DO),
	.SRAM_RD(CART_SRAM_RD),
	.SRAM_WR(CART_SRAM_WR),

	.rom_sz(rom_sz),
`ifdef GENESIS_ONLY
	.s32x(1'b0),
`else
	.s32x(1'b1),
`endif
	.eeprom_map(eeprom_map),
	.noram_quirk(noram_quirk),
	.realtec_map(realtec_map),
	.sf_map(sf_map),

	.EEPROM_A(CART_EEPROM_A),
	.EEPROM_D(CART_EEPROM_D),
	.EEPROM_WE(CART_EEPROM_WE),
	.EEPROM_Q(CART_EEPROM_Q)
);

// Cart SRAM and EEPROM storage in block RAM, loaded and saved through the APF save slot
s32x_save_ram save_ram
(
	.clk(clk_sys),

	.sram_a(CART_SRAM_A),
	.sram_d(CART_SRAM_DO),
	.sram_rd(CART_SRAM_RD),
	.sram_wr(CART_SRAM_WR),
	.sram_q(CART_SRAM_DI),
	.sram_busy(CART_SRAM_BUSY),

	.eeprom_sel(|eeprom_map[2:0]),
	.eeprom_a(CART_EEPROM_A),
	.eeprom_d(CART_EEPROM_D),
	.eeprom_we(CART_EEPROM_WE),
	.eeprom_q(CART_EEPROM_Q),

	.b_clk(save_clk),
	.b_a(save_a),
	.b_d(save_d),
	.b_we(save_we),
	.b_q(save_q)
);

// clk_ram (2x clk_sys, same PLL) samples clk_sys-domain requests only on the edge in mid clk_sys
// cycle; the other edge coincides with the launching clk_sys edge and would re-sample the same
// values under a zero-margin hold check (core_constraints.sdc). sys_tog toggles every clk_sys
// cycle; sampled on the falling clk_ram edge (a quarter clk_sys cycle of margin both ways) it has
// changed since the previous rising clk_ram edge exactly on the mid edges. fb_sram derives the
// same from sys_tog on its own.
reg sys_tog = 0;
always @(posedge clk_sys) sys_tog <= ~sys_tog;
reg ram_tog_n = 0, ram_tog_p = 0;
always @(negedge clk_ram) ram_tog_n <= sys_tog;
always @(posedge clk_ram) ram_tog_p <= ram_tog_n;
// Mid edges alternate with the other clk_ram edges, so the next edge's mid is the inverse of this
// one's (ram_tog_n ^ ram_tog_p). Registered one edge ahead: only this flop sits on the half-cycle
// path from ram_tog_n (falling edge), not the ~100 input registers mid enables.
reg ram_mid = 0;
always @(posedge clk_ram) ram_mid <= ~(ram_tog_n ^ ram_tog_p);

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
	.FB_FS(FB_FS), .sys_tog(sys_tog),
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
	.mid(ram_mid),

	.addr0(s32x_sdr_addr),
	.rd0(s32x_sdr_rd),
	.wr0(s32x_sdr_wr),
	.din0(s32x_sdr_din),
	.line0(s32x_sdr_line),
	.dout0_line(sdr_do0_line),
	.dout0(sdr_do[0]),
	.busy0(sdr_busy[0]),

	.addr1({1'b0, CART_ROM_A[23:1]}),
	.rd1(CART_ROM_RD | CART_ROM_WRL | CART_ROM_WRH),
	.wr1({CART_ROM_WRH, CART_ROM_WRL} & {2{schan_quirk}}),
	.din1(CART_ROM_DO),
	.dout1(sdr_do[1]),
	.busy1(sdr_busy[1]),

	// Port 2 (cart SRAM on MiSTer) is unused: cart SRAM is in s32x_save_ram
	.addr2(24'd0),
	.rd2(1'b0),
	.wr2(2'b00),
	.din2(16'd0),
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
