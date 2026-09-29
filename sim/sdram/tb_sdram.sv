// memtest's SDRAM sequence through the real upstream sdram.sv (Pocket timing patch) and an SDRAM
// chip model, with random Genesis-style cart ROM reads competing on port 1 (REQ-MEM-03).
`timescale 1ns/1ps

module tb_sdram;

localparam real T_SYS = 18.624;
reg clk_sys = 0, clk_ram = 0;
always #(T_SYS/2) clk_sys = ~clk_sys;
always #(T_SYS/4) clk_ram = ~clk_ram;
reg reset = 1, init = 1;

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
wire [1:0]  SDRAM_BA;

wire [24:1] sdr_addr; wire sdr_rd; wire [1:0] sdr_wr; wire [15:0] sdr_din;
wire [15:0] dout0, dout1; wire busy0, busy1;
reg  [24:1] rom_addr = 0; reg rom_rd = 0;

wire [15:0] sdram_passes; wire sdram_fail;

memtest mt (
	.clk(clk_sys), .reset(reset),
	.FB0_A(), .FB0_DO(), .FB0_WE(), .FB0_RD(), .FB0_DI(16'd0),
	.FB1_A(), .FB1_DO(), .FB1_WE(), .FB1_RD(), .FB1_DI(16'd0), .FB_FS(), .cfg_rd(), .cfg_we(), .cfg_half(),
	.sdr_addr(sdr_addr), .sdr_rd(sdr_rd), .sdr_wr(sdr_wr), .sdr_din(sdr_din),
	.sdr_dout(dout0), .sdr_busy(busy0),
	.sram_passes(), .sram_fail(), .sdram_passes(sdram_passes), .sdram_fail(sdram_fail)
);

// Mid clk_ram edge in the clk_sys cycle, as generated in s32x_system.sv
reg sys_tog = 0, ram_tog_n = 0, ram_tog_p = 0;
always @(posedge clk_sys) sys_tog <= ~sys_tog;
always @(negedge clk_ram) ram_tog_n <= sys_tog;
always @(posedge clk_ram) ram_tog_p <= ram_tog_n;
wire ram_mid = ram_tog_n ^ ram_tog_p;

sdram sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
	.init(init), .clk(clk_ram), .mid(ram_mid),
	.addr0(sdr_addr), .rd0(sdr_rd), .wr0(sdr_wr), .din0(sdr_din), .dout0(dout0), .busy0(busy0), .line0(1'b0), .dout0_line(),
	.addr1(rom_addr), .rd1(rom_rd), .wr1(2'b00), .din1(16'd0), .dout1(dout1), .busy1(busy1),
	.addr2(24'd0), .rd2(1'b0), .wr2(2'b00), .din2(16'd0), .dout2(), .busy2(),
	.addr3(24'd0), .rd3(1'b0), .wr3(2'b00), .din3(16'd0), .dout3(), .busy3()
);

sdram_model chip (
	.clk(SDRAM_CLK), .cke(SDRAM_CKE), .a(SDRAM_A), .ba(SDRAM_BA), .dq(SDRAM_DQ),
	.dqm({SDRAM_DQMH, SDRAM_DQML}), .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE)
);

// Genesis-like ROM traffic on port 1: a read every ~7-20 MCLK
always @(posedge clk_sys) if (!reset) begin
	if (!rom_rd && $urandom_range(0, 9) == 0) begin rom_addr <= $urandom; rom_rd <= 1; end
	else if (rom_rd && !busy1 && $urandom_range(0, 3) == 0) rom_rd <= 0;
end

// Runtime trace of the first requests: +trace_first
bit trace_first;
initial trace_first = $test$plusargs("trace_first");
always @(posedge clk_ram) if (trace_first && !reset && mt.d_addr < 6 && mt.sdram_passes == 0 && mt.d_phase == 0)
	$display("%t mt.st=%0d addr=%05h wr=%b busy0=%b | ctl st=%0d mode=%0d init=%b rst=%0d ch_req=%b ch_pend=%b ch_n=%0d active=%b | cmd=%b%b%b a=%h ba=%0d",
	         $realtime, mt.d_state, mt.d_addr, sdr_wr, busy0, sdram.state, sdram.mode, init, sdram.reset, sdram.ch_req, sdram.ch_pend,
	         sdram.ch_n, sdram.active, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_A, SDRAM_BA);

// Report the first mismatching reads
int n_bad = 0;
always @(posedge clk_sys) if (mt.d_state == 2 && !busy0 && mt.d_phase == 1) begin
	automatic logic [15:0] exp = mt.pattern(mt.d_addr, mt.sdram_passes);
	if (dout0 !== exp && n_bad < 10) begin
		n_bad++;
		$display("%t MISMATCH word %05h: got %04h expected %04h (model holds %04h)", $realtime,
		         mt.d_addr, dout0, exp, chip.mem.exists({2'b00, 6'd0, mt.d_addr}) ? 16'h0 : 16'h0);
	end
end

// Progress / hang detector
int last_change = 0, cyc = 0;
reg [24:1] last_addr;
always @(posedge clk_sys) begin
	cyc++;
	if (sdr_addr !== last_addr) begin last_addr <= sdr_addr; last_change = cyc; end
	if (!reset && cyc - last_change > 5000) begin
		$display("%t HANG: memtest SDRAM address stuck at %06h, rd=%b wr=%b busy0=%b state=%0d, sdram state=%0d ch_req=%b ch_pend=%b",
		         $realtime, {sdr_addr, 1'b0}, sdr_rd, sdr_wr, busy0, mt.d_state, sdram.state, sdram.ch_req, sdram.ch_pend);
		$display("FAIL"); $finish;
	end
end

initial begin
	repeat (20) @(posedge clk_ram);
	init = 0;
	repeat (400) @(posedge clk_ram);    // SDRAM init sequence
	reset = 0;
	fork
		wait (sdram_passes >= 2);
		#(300ms);
	join_any
	$display("sdram passes %0d fail %b, model errors %0d", sdram_passes, sdram_fail, chip.errors);
	if (sdram_passes >= 2 && !sdram_fail && chip.errors == 0) $display("PASS"); else $display("FAIL");
	$finish;
end

endmodule
