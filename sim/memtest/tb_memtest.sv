// Testbench for memtest.sv + fb_sram.sv (REQ-MEM-06): the self-test must pass on good memory
// and must flag a failure when a fault is injected.
//   +fault_sram       : SRAM data bit 5 stuck at 0 on writes
//   +fault_sdram      : SDRAM model corrupts one word
//   +sram_taa=<ns>    : SRAM read access time (default 10)
//   +sram_twp=<ns>    : SRAM minimum WE pulse; shorter pulses don't write (default 8)
//   +expect_sweep=<hex>: expected sweep_fail mask after all 8 settings ran
`timescale 1ns/1ps

module tb_memtest;

localparam real T_SYS = 18.624;
reg clk_sys = 0, clk_ram = 0;
always #(T_SYS/2) clk_sys = ~clk_sys;
always #(T_SYS/4) clk_ram = ~clk_ram;
reg reset = 1;

wire [15:0] FB0_A, FB0_DO, FB0_DI, FB1_A, FB1_DO, FB1_DI;
wire  [1:0] FB0_WE, FB1_WE;
wire        FB0_RD, FB1_RD, FB_FS;
wire [16:0] sram_a;
wire [15:0] sram_dq;
wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;
wire [24:1] sdr_addr;
wire        sdr_rd;
wire  [1:0] sdr_wr;
wire [15:0] sdr_din;
reg  [15:0] sdr_dout;
reg         sdr_busy = 0;
wire [15:0] sram_passes, sdram_passes;
wire        sram_fail, sdram_fail;
wire  [3:0] cfg_rd, cfg_we;
wire        cfg_half;
wire  [7:0] sweep_done, sweep_fail;
wire  [2:0] sweep_cur;

// Small region and short hold so a full 8-setting sweep simulates in reasonable time.
memtest #(.AW(8)) mt (
	.clk(clk_sys), .reset(reset),
	.FB0_A(FB0_A), .FB0_DO(FB0_DO), .FB0_WE(FB0_WE), .FB0_RD(FB0_RD), .FB0_DI(FB0_DI),
	.FB1_A(FB1_A), .FB1_DO(FB1_DO), .FB1_WE(FB1_WE), .FB1_RD(FB1_RD), .FB1_DI(FB1_DI),
	.FB_FS(FB_FS), .cfg_rd(cfg_rd), .cfg_we(cfg_we), .cfg_half(cfg_half),
	.sdr_addr(sdr_addr), .sdr_rd(sdr_rd), .sdr_wr(sdr_wr), .sdr_din(sdr_din),
	.sdr_dout(sdr_dout), .sdr_busy(sdr_busy),
	.sram_passes(sram_passes), .sram_fail(sram_fail),
	.sweep_done(sweep_done), .sweep_fail(sweep_fail), .sweep_cur(sweep_cur),
	.sdram_passes(sdram_passes), .sdram_fail(sdram_fail)
);

reg sys_tog = 0;   // fb_sram mid-edge reference: toggles every clk_sys cycle
always @(posedge clk_sys) sys_tog <= ~sys_tog;

fb_sram fb (
	.clk_ram(clk_ram), .reset(reset),
	.FB0_A(FB0_A), .FB0_DO(FB0_DO), .FB0_WE(FB0_WE), .FB0_RD(FB0_RD), .FB0_DI(FB0_DI),
	.FB1_A(FB1_A), .FB1_DO(FB1_DO), .FB1_WE(FB1_WE), .FB1_RD(FB1_RD), .FB1_DI(FB1_DI),
	.FB_FS(FB_FS), .sys_tog(sys_tog), .cfg_rd(cfg_rd), .cfg_we(cfg_we), .cfg_half(cfg_half),
	.sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
	.sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
);

// SRAM model: read data valid t_aa after the address (X before that), writes need a WE pulse of
// at least t_wp.
reg [15:0] mem [0:131071];
bit fault_sram, fault_sdram;
real t_aa = 10.0, t_wp = 8.0;
realtime a_time = 0, we_fall = 0;
reg [15:0] rd_val;
always @(sram_a) a_time = $realtime;
// Before t_aa the bus carries garbage (random, not X: X would hide failures, since X != exp is X).
always @* begin
	rd_val = $urandom;
	#(t_aa) rd_val = mem[sram_a];
end
assign sram_dq = (!sram_oe_n && sram_we_n) ? rd_val : 16'hZZZZ;
always @(negedge sram_we_n) we_fall = $realtime;
always @(posedge sram_we_n) if ($realtime - we_fall >= t_wp) begin
	automatic logic [15:0] d = sram_dq;
	if (fault_sram) d[5] = 0;
	if (!sram_ub_n) mem[sram_a][15:8] = d[15:8];
	if (!sram_lb_n) mem[sram_a][7:0]  = d[7:0];
end

// sdram.sv port model: rising edge of rd/wr starts a request; busy for 4-12 clk_ram cycles
reg [15:0] smem [0:131071];
reg old_rd = 0, old_wr = 0;
always @(posedge clk_ram) begin
	old_rd <= sdr_rd; old_wr <= |sdr_wr;
	if ((sdr_rd && !old_rd) || (|sdr_wr && !old_wr)) begin
		automatic int n = $urandom_range(4, 12);
		automatic bit is_wr = |sdr_wr;
		automatic logic [16:0] a = sdr_addr[17:1];
		sdr_busy <= 1;
		fork begin
			repeat (n) @(posedge clk_ram);
			if (is_wr) smem[a] = (fault_sdram && a == 17'h0ABCD) ? ~sdr_din : sdr_din;
			else sdr_dout <= smem[a];
			sdr_busy <= 0;
		end join_none
	end
end

initial begin
	fault_sram  = $test$plusargs("fault_sram");
	fault_sdram = $test$plusargs("fault_sdram");
	void'($value$plusargs("sram_taa=%f", t_aa));
	void'($value$plusargs("sram_twp=%f", t_wp));
	repeat (10) @(posedge clk_sys);
	reset = 0;
	// All 8 sweep settings and two SDRAM passes, or a timeout.
	fork
		wait (sweep_done == 8'hFF && sdram_passes >= 2);
		#(400ms);
	join_any
	$display("sweep done %b fail %b, sdram passes %0d fail %b", sweep_done, sweep_fail, sdram_passes, sdram_fail);
	if ($test$plusargs("expect_sweep")) begin : check_sweep
		bit [7:0] expect_mask;
		void'($value$plusargs("expect_sweep=%h", expect_mask));
		if (sweep_done == 8'hFF && sweep_fail == expect_mask && !sdram_fail) $display("PASS");
		else $display("FAIL: expected sweep_fail %b", expect_mask);
	end
	else if (fault_sram || fault_sdram) begin
		if ((fault_sram && !sram_fail) || (fault_sdram && !sdram_fail)) $display("FAIL: injected fault not detected");
		else if ((!fault_sram && sram_fail) || (!fault_sdram && sdram_fail)) $display("FAIL: false alarm on the good memory");
		else $display("PASS");
	end else begin
		if (sweep_done == 8'hFF && sdram_passes >= 2 && !sram_fail && !sdram_fail) $display("PASS");
		else $display("FAIL");
	end
	$finish;
end

endmodule
