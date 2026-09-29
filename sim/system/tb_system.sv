// Full-system simulation: s32x_system (Genesis + 32X + cart + SDRAM/SRAM controllers) with an
// SDRAM chip model and an async SRAM model (~35 ns, like the Pocket's), running a real cartridge
// image through the BIOS (M4).
//
// The ROM image (+rom=<path>, never committed) is preloaded into the SDRAM model directly; only the
// header and the last word go through the real loader port, so ROM size and region detection run
// as on hardware. Each video frame is written to frame_N.ppm in the run directory.
//
// Plusargs: +rom=<file>  +frames=<n> (default 3)  +trace (bus/CPU milestones)  +stop_ms=<n>
`timescale 1ns/1ps

module tb_system;

localparam real T_SYS = 18.624;
reg clk_sys = 0, clk_ram = 0;
always #(T_SYS/2) clk_sys = ~clk_sys;
always #(T_SYS/4) clk_ram = ~clk_ram;

reg pll_locked = 0;
reg reset = 1;
reg rom_loading = 0, rom_wr = 0;
reg [23:0] rom_wr_addr = 0;
reg [15:0] rom_wr_data = 0;

wire [7:0] r, g, b;
wire ce_pix, hblank, vblank, hs_n, vs_n, interlace, field, pal;
wire [1:0] resolution;
wire [15:0] audio_l, audio_r;

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
wire [1:0]  SDRAM_BA;
wire [16:0] SRAM_A;
wire [15:0] SRAM_DQ;
wire        SRAM_OE_N, SRAM_WE_N, SRAM_UB_N, SRAM_LB_N;

s32x_system dut (
	.clk_sys(clk_sys), .clk_ram(clk_ram), .pll_locked(pll_locked), .reset(reset),
	.rom_loading(rom_loading), .rom_wr(rom_wr), .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data),
	.joy_1(12'd0), .joy_2(12'd0), .j3but(1'b1),
	.r(r), .g(g), .b(b), .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hs_n(hs_n), .vs_n(vs_n),
	.resolution(resolution), .interlace(interlace), .field(field), .pal(pal),
	.audio_l(audio_l), .audio_r(audio_r),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
	.SRAM_A(SRAM_A), .SRAM_DQ(SRAM_DQ), .SRAM_OE_N(SRAM_OE_N), .SRAM_WE_N(SRAM_WE_N),
	.SRAM_UB_N(SRAM_UB_N), .SRAM_LB_N(SRAM_LB_N),
	.memtest_status()
);

sdram_model chip (
	.clk(SDRAM_CLK), .cke(SDRAM_CKE), .a(SDRAM_A), .ba(SDRAM_BA), .dq(SDRAM_DQ),
	.dqm({SDRAM_DQMH, SDRAM_DQML}), .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE)
);

// Async SRAM, 35 ns access (the hardware sweep: > 28 ns needed, 32.6 ns works)
reg [15:0] sram [0:131071];
reg [15:0] sram_rd;
always @* begin
	sram_rd = 16'hxxxx;
	#(35.0) sram_rd = sram[SRAM_A];
end
assign SRAM_DQ = (!SRAM_OE_N && SRAM_WE_N) ? sram_rd : 16'hZZZZ;
always @(posedge SRAM_WE_N) begin
	if (!SRAM_UB_N) sram[SRAM_A][15:8] = SRAM_DQ[15:8];
	if (!SRAM_LB_N) sram[SRAM_A][7:0]  = SRAM_DQ[7:0];
end

///////////////////////////////////////////////////////////////////////////////
// ROM preload

// sdram.sv address mapping for a word address W (= byte address / 2): bank W[23:22],
// row W[12:0], column {0, W[21:13]} (see sdram.sv STATE_START / STATE_CONT).
function automatic bit [24:0] sdram_key(input bit [23:0] w);
	sdram_key = {w[23:22], w[12:0], 1'b0, w[21:13]};
endfunction

reg [7:0] rom [0:4194303];
int rom_size = 0;

task automatic load_rom(input string path);
	int fd, n;
	fd = $fopen(path, "rb");
	if (fd == 0) begin $display("ERROR: can't open ROM %s", path); $finish; end
	n = $fread(rom, fd);
	$fclose(fd);
	rom_size = n;
	for (int w = 0; w < n / 2; w++)
		chip.mem[sdram_key(w)] = {rom[2*w], rom[2*w + 1]};   // big-endian 68K words
	$display("preloaded %0d bytes from %s", n, path);
endtask

// Loader-port writes (as core_top's data_loader): data[7:0] = byte at addr, [15:8] = next byte
task automatic loader_write(input bit [23:0] a);
	@(posedge clk_sys);
	rom_wr_addr <= a;
	rom_wr_data <= {rom[a + 1], rom[a]};
	rom_wr <= 1;
	@(posedge clk_sys);
	@(posedge clk_sys);
	rom_wr <= 0;
	repeat (16) @(posedge clk_sys);
endtask

///////////////////////////////////////////////////////////////////////////////
// Frame dump: one PPM per frame, from ce_pix / hblank / vblank as the Pocket formatter sees them

int frame = 0, x = 0, y = 0, frames_max = 3;
int fd_img = 0;
reg [23:0] line_buf [0:511];
int line_len = 0;
reg old_vbl = 1, old_hbl = 1;
string rom_path;

always @(posedge clk_sys) if (ce_pix) begin
	old_hbl <= hblank;
	if (!hblank && !vblank) begin
		if (x < 512) line_buf[x] = {r, g, b};
		x++;
	end
	if (hblank && !old_hbl && !vblank && x > 0) begin
		if (fd_img) for (int i = 0; i < x; i++)
			$fwrite(fd_img, "%c%c%c", line_buf[i][23:16], line_buf[i][15:8], line_buf[i][7:0]);
		line_len = x;
		y++;
		x = 0;
	end
end

always @(posedge clk_sys) begin
	old_vbl <= vblank;
	if (vblank && !old_vbl) begin
		if (fd_img) begin
			$fclose(fd_img);
			$display("%t frame %0d: %0d x %0d written", $realtime, frame, line_len, y);
			frame++;
			if (frame >= frames_max) begin $display("DONE"); $finish; end
		end
		fd_img = $fopen($sformatf("frame_%0d.ppm", frame), "wb");
		// Fixed 320x224 header; actual size is printed above (H32 would be 256 wide).
		$fwrite(fd_img, "P6\n%0d %0d\n255\n", 320, 224);
		y = 0;
		x = 0;
	end
end

///////////////////////////////////////////////////////////////////////////////
// Milestones (+trace)

bit trace;
int n_fb_wr = 0, n_sdr = 0;
reg old_fs = 0;
always @(posedge clk_sys) if (trace) begin
	if (|dut.FB0_WE || |dut.FB1_WE) n_fb_wr++;
	if (dut.FB_FS != old_fs) $display("%t 32X VDP framebuffer swap -> FS=%b", $realtime, dut.FB_FS);
	old_fs <= dut.FB_FS;
end
always @(posedge clk_ram) if (trace && (dut.s32x_sdr_rd || |dut.s32x_sdr_wr)) n_sdr++;

int n_clkenp = 0;
always @(posedge clk_sys) if (trace && dut.gen.ba.M68K_CLKENp === 1'b1) n_clkenp++;

// First 68K bus cycles (+trace): address strobe, acknowledge, and the cart/SDRAM handshake
int n_bus = 0;
reg old_as = 1;
realtime t_as;
always @(posedge clk_sys) if (trace) begin
	old_as <= dut.GEN_AS_N;
	if (old_as && !dut.GEN_AS_N) t_as = $realtime;
	if (!old_as && dut.GEN_AS_N && n_bus < 24) begin
		n_bus++;
		$display("%t 68K bus cycle %0d: A=%06h took %0.0f ns", $realtime, n_bus, {dut.GEN_VA, 1'b0}, $realtime - t_as);
	end
end
// A bus cycle stuck for > 20 us: show the handshake signals
always @(posedge clk_sys) if (trace && !dut.GEN_AS_N && $realtime - t_as > 20000.0 && $realtime - t_as < 20000.0 + T_SYS) begin
	$display("%t STUCK 68K cycle at A=%06h: S32X_DTACK_N=%b CART_DTACK_N=%b CE0_N=%b ROM_RD=%b busy1=%b RAS2_N=%b ADEN=%b",
	         $realtime, {dut.GEN_VA, 1'b0}, dut.S32X_DTACK_N, dut.CART_DTACK_N, dut.GEN_CE0_N,
	         dut.CART_ROM_RD, dut.sdr_busy[1], dut.GEN_RAS2_N, dut.S32X.s32x_if.ADCR.ADEN);
	$display("    BA: mstate=%0d msrc=%0d MEM_RDY=%b M68K_MBUS_DTACK_N=%b CLKENp pulses so far %0d, ENABLE=%b RST_N=%b",
	         dut.gen.ba.mstate, dut.gen.ba.msrc, dut.gen.MEM_RDY, dut.gen.ba.M68K_MBUS_DTACK_N,
	         n_clkenp, dut.gen.ba.ENABLE, dut.gen.ba.RST_N);
end

// SH-2 SDRAM request stuck (> 20 us with CS and RD/WE active): show both sides of port 0
realtime t_sdr_req = -1;
bit sdr_stuck_reported = 0;
always @(posedge clk_sys) if (trace) begin
	automatic bit req = dut.S32X_SDR_CS && (dut.S32X_SDR_RD || |dut.S32X_SDR_WE);
	if (!req) t_sdr_req = -1;
	else if (t_sdr_req < 0) t_sdr_req = $realtime;
	else if (!sdr_stuck_reported && $realtime - t_sdr_req > 20000.0) begin
		sdr_stuck_reported = 1;
		$display("%t STUCK SH-2 SDRAM request: A=%05h RD=%b WE=%b DO=%04h busy0=%b | sdram ch_req=%b ch_pend=%b state=%0d active=%b ch_n=%0d",
		         $realtime, {dut.S32X_SDR_A, 1'b0}, dut.S32X_SDR_RD, dut.S32X_SDR_WE, dut.S32X_SDR_DO, dut.sdr_busy[0],
		         dut.sdram.ch_req, dut.sdram.ch_pend, dut.sdram.state, dut.sdram.active, dut.sdram.ch_n);
	end
end
// Every SH-2 SDRAM request edge, for the first 100 (to see the access pattern)
int n_sdr_log = 0;
reg old_sdr_rd = 0;
reg [1:0] old_sdr_we = 0;
always @(posedge clk_ram) if (trace) begin
	old_sdr_rd <= dut.s32x_sdr_rd;
	old_sdr_we <= dut.s32x_sdr_wr;
	if (n_sdr_log < 100 && ((dut.s32x_sdr_rd && !old_sdr_rd) || (|dut.s32x_sdr_wr && !(|old_sdr_we)))) begin
		n_sdr_log++;
		$display("%t SDR req %0d: %s A=%06h busy0=%b", $realtime, n_sdr_log, dut.s32x_sdr_rd ? "RD" : "WR",
		         {dut.s32x_sdr_addr, 1'b0}, dut.sdr_busy[0]);
	end
end

// SH-2 snapshot every 1 ms once the SH-2s are out of reset (+shsnap, needs ACC=1 for core.PC)
bit shsnap;
initial shsnap = $test$plusargs("shsnap");
always begin
	#(1ms);
	if (shsnap && dut.S32X.s32x_if.ADCR.RES)
		$display("%t SH2 M: PC=%08h SLP=%b A=%07h CS0/1/2/3=%b%b%b%b RD=%b BS=%b IRL=%h | S: PC=%08h SLP=%b A=%07h CS=%b%b%b%b IRL=%h | WAIT_N=%b BREQ/BACK=%b%b RV=%b | 68K %06h",
		         $realtime,
		         dut.S32X.MSH.core.PC, dut.S32X.MSH.core.SLP, {dut.S32X.SHA, 1'b0} >> 1,
		         dut.S32X.SHCS0M_N, dut.S32X.SHCS1_N, dut.S32X.SHCS2_N, dut.S32X.SHCS3_N, dut.S32X.SHRD_N, dut.S32X.SHBS_N,
		         dut.S32X.SHMIRL_N,
		         dut.S32X.SSH.core.PC, dut.S32X.SSH.core.SLP, {dut.S32X.SHSA, 1'b0} >> 1,
		         dut.S32X.SHCS0S_N, dut.S32X.SHSCS1_N, dut.S32X.SHSCS2_N, dut.S32X.SHSCS3_N, dut.S32X.SHSIRL_N,
		         dut.S32X.SHWAIT_N, dut.S32X.SHBREQ_N, dut.S32X.SHBACK_N, dut.S32X.s32x_if.DCR.RV,
		         {dut.gen.M68K_A, 1'b0});
end

// Master SH-2 PC history (+shsnap): the last 64 distinct PCs, dumped when it first reaches the
// BIOS's unhandled-exception trap at 0x13C. Also the slave's first 48 PCs after reset.
reg [31:0] pc_ring [0:63];
reg        pc_ili  [0:63];
reg        pc_int  [0:63];
realtime   pc_t    [0:63];
int        pc_wr = 0, n_spc = 0;
reg [31:0] last_mpc = 0, last_spc = 0;
bit        trap_dumped = 0;
always @(posedge clk_sys) if (shsnap && dut.S32X.s32x_if.ADCR.RES) begin
	if (dut.S32X.MSH.core.PC !== last_mpc) begin
		last_mpc = dut.S32X.MSH.core.PC;
		pc_ring[pc_wr % 64] = last_mpc; pc_ili[pc_wr % 64] = 1'b0;
		pc_int[pc_wr % 64] = dut.S32X.MSH.core.INT_REQ; pc_t[pc_wr % 64] = $realtime;
		pc_wr++;
		if (last_mpc == 32'h13C && !trap_dumped) begin
			trap_dumped = 1;
			$display("%t MASTER SH-2 reached trap 0x13C; previous PCs:", $realtime);
			for (int i = (pc_wr > 64 ? pc_wr - 64 : 0); i < pc_wr; i++)
				$display("    %t PC=%08h ILI=%b INT_REQ=%b", pc_t[i % 64], pc_ring[i % 64], pc_ili[i % 64], pc_int[i % 64]);
		end
	end
	if (dut.S32X.SSH.core.PC !== last_spc && n_spc < 48) begin
		last_spc = dut.S32X.SSH.core.PC;
		n_spc++;
		$display("%t slave SH-2 PC=%08h ILI=%b INT_REQ=%b", $realtime, last_spc, 1'b0, dut.S32X.SSH.core.INT_REQ);
	end
end

// Bus trace window (+win_start=<ns> +win_end=<ns>): every master/slave SH-2 bus cycle start
// (BS_N falling), with address, chip selects, read/write, WAIT and the SDRAM port state.
real win_start = -1, win_end = -1;
initial begin
	void'($value$plusargs("win_start=%f", win_start));
	void'($value$plusargs("win_end=%f", win_end));
end
reg old_mbs = 1, old_sbs = 1;
always @(posedge clk_sys) if (win_start >= 0 && $realtime >= win_start && $realtime <= win_end) begin
	old_mbs <= dut.S32X.SHBS_N;
	old_sbs <= dut.S32X.SHSBS_N;
	if (old_mbs && !dut.S32X.SHBS_N)
		$display("%t M bus: A=%08h CS0123=%b%b%b%b RD=%b RDWR_N=%b DQM=%b DO=%08h WAIT_N=%b PC=%08h",
		         $realtime, {dut.S32X.SHA, 1'b0} >> 1, dut.S32X.SHCS0M_N, dut.S32X.SHCS1_N, dut.S32X.SHCS2_N,
		         dut.S32X.SHCS3_N, dut.S32X.SHRD_N, dut.S32X.SHRD_WR_N, dut.S32X.SHDQM_N, dut.S32X.SHDO,
		         dut.S32X.SHWAIT_N, dut.S32X.MSH.core.PC);
	if (old_sbs && !dut.S32X.SHSBS_N)
		$display("%t S bus: A=%08h CS0123=%b%b%b%b RD=%b PC=%08h", $realtime, {dut.S32X.SHSA, 1'b0} >> 1,
		         dut.S32X.SHCS0S_N, dut.S32X.SHSCS1_N, dut.S32X.SHSCS2_N, dut.S32X.SHSCS3_N, dut.S32X.SHSRD_N,
		         dut.S32X.SSH.core.PC);
end
always @(posedge clk_ram) if (win_start >= 0 && $realtime >= win_start && $realtime <= win_end &&
                              (dut.s32x_sdr_rd || |dut.s32x_sdr_wr || dut.sdr_busy[0]))
	$display("%t   sdr port0: rd=%b wr=%b A=%06h din=%04h busy=%b", $realtime, dut.s32x_sdr_rd, dut.s32x_sdr_wr,
	         {dut.s32x_sdr_addr, 1'b0}, dut.s32x_sdr_din, dut.sdr_busy[0]);

// Master SH-2 register-file writes every clock in [rf_start, rf_end] ns (+rf_start/+rf_end, ACC=1)
real rf_start = -1, rf_end = -1;
initial begin
	void'($value$plusargs("rf_start=%f", rf_start));
	void'($value$plusargs("rf_end=%f", rf_end));
end
always @(posedge clk_sys) if (rf_start >= 0 && $realtime >= rf_start && $realtime <= rf_end)
	$display("%t RF PC=%08h CE=%b EN=%b PCST=%b BST=%b WAIT_N=%b | A: n=%0d d=%08h we=%b | B: n=%0d d=%08h we=%b | latch n=%0d we=%b | RAM wr n=%0d d=%08h we=%b",
	         $realtime, dut.S32X.MSH.core.PC, dut.S32X.MSH.core.CE, dut.S32X.MSH.core.EN,
	         dut.S32X.MSH.core.PC_STALL, dut.S32X.MSH.core.BUS_STALL, dut.S32X.SHWAIT_N,
	         dut.S32X.MSH.core.REGS_WAN, dut.S32X.MSH.core.REGS_WAD, dut.S32X.MSH.core.REGS_WAE,
	         dut.S32X.MSH.core.REGS_WBN, dut.S32X.MSH.core.REGS_WBD, dut.S32X.MSH.core.REGS_WBE,
	         dut.S32X.MSH.core.regfile.WB_ADDR_LATCH, dut.S32X.MSH.core.regfile.WBE_LATCH,
	         dut.S32X.MSH.core.regfile.W_ADDR, dut.S32X.MSH.core.regfile.REG_D,
	         dut.S32X.MSH.core.regfile.REG_WE & dut.S32X.MSH.core.regfile.EN);

// 32X adapter state (68K-side register A15100): ADEN = 32X enabled, RES = SH-2s released from
// reset, FM = framebuffer access (0: 68K, 1: SH-2)
reg [2:0] old_adcr = 3'bxxx;
int n_msh_cs0 = 0, n_ssh_cs0 = 0;
always @(posedge clk_sys) if (trace) begin
	automatic logic [2:0] adcr = {dut.S32X.s32x_if.ADCR.ADEN, dut.S32X.s32x_if.ADCR.RES, dut.S32X.s32x_if.ADCR.FM};
	if (adcr !== old_adcr)
		$display("%t 32X adapter: ADEN=%b RES=%b FM=%b (68K at %06h)", $realtime, adcr[2], adcr[1], adcr[0],
		         {dut.gen.M68K_A, 1'b0});
	old_adcr <= adcr;
	if (!dut.S32X.SHCS0M_N) n_msh_cs0++;
	if (!dut.S32X.SHCS0S_N) n_ssh_cs0++;
end

initial begin
	trace = $test$plusargs("trace");
	void'($value$plusargs("frames=%d", frames_max));
	begin : stop_timer
		int stop_ms;
		if ($value$plusargs("stop_ms=%d", stop_ms)) fork begin #(stop_ms * 1ms); $display("STOP at %0d ms", stop_ms); $finish; end join_none
	end
	if (!$value$plusargs("rom=%s", rom_path)) begin $display("ERROR: +rom=<file> required"); $finish; end
	load_rom(rom_path);

	repeat (20) @(posedge clk_ram);
	pll_locked = 1;
	repeat (400) @(posedge clk_ram);      // SDRAM init sequence

	// Header region (0x100-0x1FF) and the last word through the real loader
	rom_loading = 1;
	for (int a = 'h100; a < 'h200; a += 2) loader_write(a);
	loader_write(rom_size - 2);
	rom_loading = 0;
	repeat (20) @(posedge clk_sys);
	$display("rom_sz=%06h pal=%b", dut.rom_sz, pal);
	reset = 0;
end

// Progress report every ~5 ms of simulated time
always begin
	#(5ms);
	$display("%t progress: frame %0d line %0d, 68K at %06h, SH-2 CS0 cycles M/S %0d/%0d, FB writes %0d, 32X SDRAM accesses %0d, FS=%b",
	         $realtime, frame, y, {dut.gen.M68K_A, 1'b0}, n_msh_cs0, n_ssh_cs0, n_fb_wr, n_sdr, dut.FB_FS);
end

endmodule
