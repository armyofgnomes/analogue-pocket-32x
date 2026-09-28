//
// Console system: S32X_MiSTer's Genesis (gen) + cartridge mapper (CART) + SDRAM.
//
// M2 (Genesis on Pocket): the 32X block is not instantiated yet, so the cart is wired straight
// to the Genesis bus (upstream S32X.sv's s32x_rom = 0 path). Wiring follows upstream S32X.sv.
//
// Clock domains: everything here runs on clk_sys (MCLK) except the SDRAM controller, which runs
// on clk_ram (2x MCLK, same PLL) and samples its request inputs from the clk_sys domain, exactly
// as in upstream.
//

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
	output        SDRAM_CKE
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
	.YS_N(),
	.EDCLK(),
	.VS(vs_n),
	.HS(hs_n),
	.HBL(hblank),
	.VBL(vblank),
	.BORDER(1'b0),
	.DOT_CE(ce_pix),
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
	.EN_32X_PWM(1'b0),
	.EN_HIFI_PCM(1'b0),
	.LADDER(1'b1),
	.LPF_MODE(2'b00),
	.FMBUSY_QUIRK(1'b0),

	.EXT_SL(16'd0),
	.EXT_SR(16'd0),

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
assign r = color_lut[GEN_R];
assign g = color_lut[GEN_G];
assign b = color_lut[GEN_B];

// Lock the resolution for the whole frame (as upstream S32X.sv)
reg  [1:0] res;
always @(posedge clk_sys) begin
	reg old_vbl;
	old_vbl <= vblank;
	if (old_vbl & ~vblank) res <= gen_resolution;
end
assign resolution = res;

///////////////////////////////////////////////////
// Cartridge

assign GEN_VDI = CART_VDO;
assign GEN_DTACK_N = CART_DTACK_N;

CART cart
(
	.CLK(clk_sys),
	.RST_N(~sys_reset),

	.VCLK(GEN_VCLK_CE),
	.VA(GEN_VA),
	.VDI(GEN_VDO),
	.VDO(CART_VDO),
	.AS_N(GEN_AS_N),
	.DTACK_N(CART_DTACK_N),
	.LWR_N(GEN_LWR_N),
	.UWR_N(GEN_UWR_N),
	.CE0_N(GEN_CE0_N),
	.CAS0_N(GEN_CAS0_N),
	.CAS2_N(GEN_CAS2_N),
	.ASEL_N(GEN_ASEL_N),
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
	.s32x(1'b0),
	.eeprom_map(4'd0),
	.noram_quirk(1'b0),
	.realtec_map(1'b0),
	.sf_map(3'd0)
);

///////////////////////////////////////////////////
// SDRAM (upstream sdram.sv, Pocket timing patch). Byte addresses, 32 MB usable:
//   0x0000000-0x0FFFFFF  cart ROM (port 1 reads, port 3 loader writes)
//   0x1000000-0x103FFFF  reserved: 32X SDRAM (port 0, M3)
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

	.addr0(24'd0),
	.rd0(1'b0),
	.wr0(2'b00),
	.din0(16'd0),
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
