// REQ-ARCH-03 fit experiment: S32X_MiSTer system logic (gen + S32X + CART) with no MiSTer
// sys/ framework, targeting the Pocket's 5CEBA4F23C8.
//
// Wiring follows S32X.sv (emu) in S32X_MiSTer. Every external memory bus (cart ROM, cart
// SRAM, 32X SDRAM, both 32X framebuffers) is brought out to top-level ports, which the qsf
// makes virtual pins, so none of them lands in block RAM. Runtime options stay as inputs so
// synthesis can't constant-fold logic the real core will need. Features the Pocket core won't
// have (mouse, lightgun, serial joystick, extra multitap pads, Game Genie, VDP debug layers)
// are tied off, as they would be in the real core.

module s32x_fit_top
(
	input         clk_sys,
	input         reset,
	input         rom_download,
	input         PAL,

	// Options that stay runtime-selectable on the Pocket
	input         EXPORT,
	input         J3BUT,
	input   [1:0] LPF_MODE,
	input         EN_GEN_FM,
	input         EN_GEN_PSG,
	input         EN_32X_PWM,
	input         EN_HIFI_PCM,
	input         LADDER,
	input         OBJ_LIMIT_HIGH,
	input         FMBUSY_QUIRK,
	input         BORDER,

	// Cartridge configuration (set from the ROM header at load time)
	input  [23:0] rom_sz,
	input         s32x_rom,
	input   [3:0] eeprom_map,
	input         noram_quirk,
	input         realtec_map,
	input   [2:0] sf_map,

	input  [11:0] joy_1,
	input  [11:0] joy_2,

	// Cart ROM / SRAM (SDRAM on the Pocket)
	output [23:1] CART_ROM_A,
	input  [15:0] CART_ROM_DI,
	output [15:0] CART_ROM_DO,
	output        CART_ROM_RD,
	output        CART_ROM_WRL,
	output        CART_ROM_WRH,
	output [14:0] CART_SRAM_A,
	input   [7:0] CART_SRAM_DI,
	output  [7:0] CART_SRAM_DO,
	output        CART_SRAM_RD,
	output        CART_SRAM_WR,
	input         rom_busy,
	input         sram_busy,

	// 32X SDRAM (256 KB)
	output [17:1] S32X_SDR_A,
	input  [15:0] S32X_SDR_DI,
	output [15:0] S32X_SDR_DO,
	output        S32X_SDR_CS,
	output  [1:0] S32X_SDR_WE,
	output        S32X_SDR_RD,
	input         S32X_SDR_WAIT,

	// 32X framebuffers (2x 128 KB), external
	output [15:0] FB0_A,
	input  [15:0] FB0_DI,
	output [15:0] FB0_DO,
	output  [1:0] FB0_WE,
	output        FB0_RD,
	output [15:0] FB1_A,
	input  [15:0] FB1_DI,
	output [15:0] FB1_DO,
	output  [1:0] FB1_WE,
	output        FB1_RD,

	// Video
	output  [3:0] GEN_R,
	output  [3:0] GEN_G,
	output  [3:0] GEN_B,
	output        GEN_DOT_CE,
	output        GEN_HBLANK,
	output        GEN_VBLANK,
	output        GEN_HS,
	output        GEN_VS,
	output        YS_N,
	output        FIELD,
	output        INTERLACE,
	output  [1:0] RESOLUTION,
	output  [4:0] S32X_R,
	output  [4:0] S32X_G,
	output  [4:0] S32X_B,
	output        S32X_DOT_CE,
	output        S32X_YSO_N,
	output        S32X_HBLANK,

	// Audio
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R
);

wire [23:1] GEN_VA;
wire [15:0] GEN_VDI, GEN_VDO;
wire        GEN_RNW, GEN_LDS_N, GEN_UDS_N;
wire        GEN_AS_N, GEN_DTACK_N, GEN_ASEL_N;
wire        GEN_RAS2_N, GEN_CAS2_N;
wire        GEN_VCLK_CE, GEN_CE0_N;
wire        GEN_LWR_N, GEN_UWR_N, GEN_CAS0_N;
wire        GEN_TIME_N;
wire        EDCLK;
wire        GEN_MEM_BUSY;

wire [15:0] S32X_SL, S32X_SR;

gen gen
(
	.RESET_N(~reset),
	.MCLK(clk_sys),

	.VA(GEN_VA),
	.VDI(GEN_VDI),
	.VDO(GEN_VDO),
	.RNW(GEN_RNW),
	.LDS_N(GEN_LDS_N),
	.UDS_N(GEN_UDS_N),
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

	.LOADING(rom_download),
	.EXPORT(EXPORT),
	.PAL(PAL),

	.RED(GEN_R),
	.GREEN(GEN_G),
	.BLUE(GEN_B),
	.YS_N(YS_N),
	.EDCLK(EDCLK),
	.VS(GEN_VS),
	.HS(GEN_HS),
	.HBL(GEN_HBLANK),
	.VBL(GEN_VBLANK),
	.BORDER(BORDER),
	.DOT_CE(GEN_DOT_CE),
	.FIELD(FIELD),
	.INTERLACE(INTERLACE),
	.RESOLUTION(RESOLUTION),

	.J3BUT(J3BUT),
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

	.EN_GEN_FM(EN_GEN_FM),
	.EN_GEN_PSG(EN_GEN_PSG),
	.EN_32X_PWM(EN_32X_PWM),
	.EN_HIFI_PCM(EN_HIFI_PCM),
	.LADDER(LADDER),
	.LPF_MODE(LPF_MODE),
	.FMBUSY_QUIRK(FMBUSY_QUIRK),

	.EXT_SL(S32X_SL),
	.EXT_SR(S32X_SR),

	.DAC_LDATA(AUDIO_L),
	.DAC_RDATA(AUDIO_R),

	.OBJ_LIMIT_HIGH(OBJ_LIMIT_HIGH),

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
                      CART_SRAM_RD || CART_SRAM_WR ? sram_busy :
                                                     rom_busy;

wire [15:0] S32X_VDO;
wire        S32X_DTACK_N;
wire [15:0] CART_VDO;
wire        CART_DTACK_N;

assign GEN_VDI = s32x_rom ? S32X_VDO : CART_VDO;
assign GEN_DTACK_N = S32X_DTACK_N & CART_DTACK_N;

wire [23:1] S32X_CA;
wire [15:0] S32X_CDO;
wire        S32X_CASEL_N, S32X_CLWR_N, S32X_CUWR_N;
wire        S32X_CCE0_N, S32X_CCAS0_N, S32X_CCAS2_N;

S32X #(
	.USE_ROM_WAIT(1),
	.USE_ASYNC_FB(0)
) S32X
(
	.RST_N(~(reset | rom_download)),
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

	.VSYNC_N(GEN_VS),
	.HSYNC_N(GEN_HS),
	.EDCLK(EDCLK),
	.YS_N(YS_N),
	.PAL(PAL),

	.CA(S32X_CA),
	.CDI(CART_VDO),
	.CDO(S32X_CDO),
	.CASEL_N(S32X_CASEL_N),
	.CLWR_N(S32X_CLWR_N),
	.CUWR_N(S32X_CUWR_N),
	.CCE0_N(S32X_CCE0_N),
	.CCAS0_N(S32X_CCAS0_N),
	.CCAS2_N(S32X_CCAS2_N),
	.ROM_WAIT(CART_SRAM_RD || CART_SRAM_WR ? sram_busy : rom_busy),

	.SDR_A(S32X_SDR_A),
	.SDR_DI(S32X_SDR_DI),
	.SDR_DO(S32X_SDR_DO),
	.SDR_CS(S32X_SDR_CS),
	.SDR_WE(S32X_SDR_WE),
	.SDR_RD(S32X_SDR_RD),
	.SDR_WAIT(S32X_SDR_WAIT),

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

CART cart
(
	.CLK(clk_sys),
	.RST_N(~(reset || rom_download)),

	.VCLK(GEN_VCLK_CE),
	.VA(!s32x_rom ? GEN_VA : S32X_CA),
	.VDI(!s32x_rom ? GEN_VDO : S32X_CDO),
	.VDO(CART_VDO),
	.AS_N(GEN_AS_N),
	.DTACK_N(CART_DTACK_N),
	.LWR_N(!s32x_rom ? GEN_LWR_N : S32X_CLWR_N),
	.UWR_N(!s32x_rom ? GEN_UWR_N : S32X_CUWR_N),
	.CE0_N(!s32x_rom ? GEN_CE0_N : S32X_CCE0_N),
	.CAS0_N(!s32x_rom ? GEN_CAS0_N : S32X_CCAS0_N),
	.CAS2_N(!s32x_rom ? GEN_CAS2_N : S32X_CCAS2_N),
	.ASEL_N(!s32x_rom ? GEN_ASEL_N : S32X_CASEL_N),
	.TIME_N(GEN_TIME_N),

	.ROM_A(CART_ROM_A),
	.ROM_DI(CART_ROM_DI),
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
	.s32x(s32x_rom),
	.eeprom_map(eeprom_map),
	.noram_quirk(noram_quirk),
	.realtec_map(realtec_map),
	.sf_map(sf_map)
);

endmodule
