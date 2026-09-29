// Full-system simulation: s32x_system (Genesis + 32X + cart + SDRAM/SRAM controllers) with an
// SDRAM chip model and an async SRAM model (~35 ns, like the Pocket's), running a real cartridge
// image through the BIOS (M4).
//
// The ROM image (+rom=<path>, never committed) is preloaded into the SDRAM model directly; only the
// header and the last word go through the real loader port, so ROM size and region detection run
// as on hardware. Each video frame is written to frame_NNN.ppm in the run directory.
//
// Plusargs: +rom=<file>  +frames=<n> (default 3)  +trace (bus/CPU milestones)
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
		fd_img = $fopen($sformatf("frame_%03d.ppm", frame), "wb");
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

initial begin
	trace = $test$plusargs("trace");
	void'($value$plusargs("frames=%d", frames_max));
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
	$display("%t progress: frame %0d line %0d, FB writes %0d, 32X SDRAM accesses %0d, FS=%b",
	         $realtime, frame, y, n_fb_wr, n_sdr, dut.FB_FS);
end

endmodule
