// Testbench for fb_sram.sv (REQ-MEM-02, REQ-TOOL-04).
//
// Drives both framebuffer ports the way upstream S32X_VDP does with USE_ASYNC_FB=1 and checks
// every read against a shadow memory at the VDP's real deadline:
//   display buffer: RD always high, address changes on each dot enable, data checked at the next
//                   dot enable (8 MCLK in H40, 10 in H32)
//   draw buffer:    FIFO writes hold A/D/WE for 6 MCLK with a 1-cycle gap; SH-2 reads raise RD and
//                   sample 6 MCLK later; auto-fill holds WE while the address steps every 7 MCLK
// The SRAM model has a 10 ns access time and checks write timing and bus contention.

`timescale 1ns/1ps

module tb_fb_sram;

localparam real T_SYS = 18.624;   // 53.693 MHz
localparam int  CYCLES = 2000000; // clk_sys cycles to simulate
// MARGIN > 0 checks every read MARGIN MCLK cycles before the VDP's real deadline, to measure slack.
`ifndef MARGIN
`define MARGIN 0
`endif
localparam int  MARGIN = `MARGIN;

reg clk_sys = 0, clk_ram = 0;
always #(T_SYS/2) clk_sys = ~clk_sys;
always #(T_SYS/4) clk_ram = ~clk_ram;

reg reset = 1;

// VDP-side signals (driven on clk_sys like the VDP's registers)
reg  [15:0] FB_A [2];
reg  [15:0] FB_DO[2];
reg   [1:0] FB_WE[2];
reg         FB_RD[2];
wire [15:0] FB0_DI, FB1_DI;
reg         fs_q = 0;   // FS as the VDP drives it (registered); 1: FB0 is the draw buffer

wire [16:0] sram_a;
wire [15:0] sram_dq;
wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

fb_sram dut (
	.clk_ram(clk_ram), .reset(reset),
	.FB0_A(FB_A[0]), .FB0_DO(FB_DO[0]), .FB0_WE(FB_WE[0]), .FB0_RD(FB_RD[0]), .FB0_DI(FB0_DI),
	.FB1_A(FB_A[1]), .FB1_DO(FB_DO[1]), .FB1_WE(FB_WE[1]), .FB1_RD(FB_RD[1]), .FB1_DI(FB1_DI),
	.FB_FS(fs_q), .cfg_rd(4'd3), .cfg_we(4'd2),
	.sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
	.sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
);

wire [15:0] FB_DI[2] = '{FB0_DI, FB1_DI};

///////////////////////////////////////////////////////////////////////////////
// Async SRAM model: 128K x 16, tAA = 10 ns, writes latched on WE rising edge.

localparam real T_AA = 10.0;
reg  [15:0] mem [0:131071];
reg  [15:0] rd_data;
wire        sram_drive = !sram_oe_n && sram_we_n;
assign #(T_AA) sram_dq = sram_drive ? rd_data : 16'hZZZZ;
always @* rd_data = mem[sram_a];

int errors = 0;
realtime we_fall = -1, a_change = 0, d_change = 0;
always @(sram_a) a_change = $realtime;
always @(dut.dq_out or dut.dq_oe) d_change = $realtime;

always @(negedge sram_we_n) we_fall = $realtime;
always @(posedge sram_we_n) if (we_fall >= 0) begin
	if ($realtime - we_fall < 15.0) begin
		$display("%t ERROR: WE pulse %0.1f ns < 15 ns", $realtime, $realtime - we_fall); errors++;
	end
	if (a_change > we_fall - 5.0) begin
		$display("%t ERROR: address changed %0.1f ns before/while WE low", $realtime, we_fall - a_change); errors++;
	end
	if ($realtime - d_change < 8.0 || dut.dq_oe != 16'hFFFF) begin
		$display("%t ERROR: write data setup %0.1f ns or not driven", $realtime, $realtime - d_change); errors++;
	end
	if (!sram_ub_n) mem[sram_a][15:8] = sram_dq[15:8];
	if (!sram_lb_n) mem[sram_a][7:0]  = sram_dq[7:0];
end
// Address hold after WE rises: must not change within 5 ns
realtime we_rise = -1;
always @(posedge sram_we_n) we_rise = $realtime;
always @(sram_a) if (we_rise >= 0 && $realtime - we_rise < 5.0) begin
	$display("%t ERROR: address hold %0.1f ns after WE rise", $realtime, $realtime - we_rise); errors++;
end
always @(posedge clk_ram) if (|dut.dq_oe && sram_drive) begin
	$display("%t ERROR: bus contention (FPGA and SRAM both driving)", $realtime); errors++;
end

// Runtime trace window (keeps the compiled design, and so the random sequence, unchanged):
//   VSIM_ARGS="+trace_t0=<ns>" prints controller activity from t0-400 ns to t0+40 ns.
real trace_t0 = -1;
initial void'($value$plusargs("trace_t0=%f", trace_t0));
always @(posedge clk_ram) if (trace_t0 >= 0 && $realtime >= trace_t0 - 400.0 && $realtime < trace_t0 + 40.0)
	$display("%t st=%0d a=%05h oe=%b we=%b dq=%04h drawch=%b rd=%b%b we=%b/%b a0=%04h a1=%04h di0=%04h di1=%04h dstate=%0d",
	         $realtime, dut.state, sram_a, sram_oe_n, sram_we_n, sram_dq, dut.draw_ch, FB_RD[0], FB_RD[1],
	         FB_WE[0], FB_WE[1], FB_A[0], FB_A[1], FB0_DI, FB1_DI, dstate);

///////////////////////////////////////////////////////////////////////////////
// Shadow memory and traffic

reg [15:0] shadow [0:131071];
int n_disp = 0, n_shrd = 0, n_fifo = 0, n_fill = 0, n_swaps = 0;

bit fs;             // 1: FB0 is the draw buffer (as in VDP.sv), so display = FB1
bit h32;
int dot_div;        // MCLK per dot
int dot_cnt;
int disp_ch;
reg [15:0] disp_a_prev = 0;
bit disp_check_pending;

// Draw-side sequencer
typedef enum {D_IDLE, D_FIFO, D_GAP, D_READ, D_FILL} dstate_t;
dstate_t dstate;
int dcnt, fill_left;
int draw_ch;
reg [15:0] rd_addr;

initial begin
	for (int i = 0; i < 131072; i++) begin
		mem[i] = $urandom;
		shadow[i] = mem[i];
	end
end


// Latency measurement: request to data capture, in MCLK cycles (18.624 ns).
realtime t_rd_req = -1, t_disp_req = -1;
real     max_rd_lat = 0, max_disp_lat = 0;
string   max_rd_ctx;
always @(posedge clk_ram) if (dut.state == 3'd1 && dut.cnt == 0) begin   // ST_RD, capture this edge
	if (dstate == D_READ && t_rd_req >= 0 && dut.op_ch == draw_ch[0] && dut.sram_a[15:0] == rd_addr) begin
		automatic real lat = ($realtime - t_rd_req) / T_SYS;
		if (lat > max_rd_lat) begin
			max_rd_lat = lat;
			max_rd_ctx = $sformatf("at %0t", $realtime);
		end
		t_rd_req = -1;
	end
	if (t_disp_req >= 0 && dut.op_ch == disp_ch[0] && dut.sram_a[15:0] == disp_a_prev) begin
		automatic real lat = ($realtime - t_disp_req) / T_SYS;
		if (lat > max_disp_lat) max_disp_lat = lat;
		t_disp_req = -1;
	end
end

// A write is on time if the SRAM already holds it when the VDP's hold window ends.
task automatic check_write(input string what, input int ch, input bit [15:0] a);
	bit [16:0] sa = {ch[0], a};
	if (mem[sa] !== shadow[sa]) begin
		$display("%t ERROR: %s FB%0d[%04h] not written by deadline: sram %04h expected %04h (st=%0d draw_ch=%b wr_pend=%b)",
		         $realtime, what, ch, a, mem[sa], shadow[sa], dut.state, dut.draw_ch, dut.wr_pend[ch]);
		errors++;
	end
endtask

function automatic bit [15:0] merge(bit [15:0] old, bit [15:0] d, bit [1:0] we);
	merge = {we[1] ? d[15:8] : old[15:8], we[0] ? d[7:0] : old[7:0]};
endfunction

task automatic check(input string what, input int ch, input bit [15:0] a, input bit [15:0] got);
	bit [15:0] exp = shadow[{ch[0], a}];
	if (got !== exp) begin
		$display("%t ERROR: %s FB%0d[%04h] got %04h expected %04h", $realtime, what, ch, a, got, exp);
		errors++;
	end
endtask

initial begin
	fs = 0; h32 = 0; dot_div = 8; dot_cnt = 0;
	for (int c = 0; c < 2; c++) begin FB_A[c] = 0; FB_DO[c] = 0; FB_WE[c] = 0; FB_RD[c] = 0; end
	dstate = D_IDLE;
	disp_check_pending = 0;
	repeat (10) @(posedge clk_ram);
	reset = 0;

	// After CYCLES, stop issuing new draw operations and let the one in flight finish.
	for (int cyc = 0; cyc < CYCLES || dstate != D_IDLE; cyc++) begin
		@(posedge clk_sys);
		disp_ch = fs ? 1 : 0;
		draw_ch = fs ? 0 : 1;

		// Buffer swap (VDP swaps during vblank). Only when the draw side is idle.
		if (dstate == D_IDLE && $urandom_range(0, 3000) == 0) begin
			fs = ~fs; n_swaps++;
			if ($urandom_range(0, 1)) begin h32 = ~h32; dot_div = h32 ? 10 : 8; end
			disp_check_pending = 0;
			disp_ch = fs ? 1 : 0;
			draw_ch = fs ? 0 : 1;
		end

		// Display: on each dot enable, check the data for the previous address, then move on.
		FB_RD[disp_ch] <= 1;
		FB_WE[disp_ch] <= 0;
		if (disp_check_pending && dot_cnt == (dot_div - MARGIN) % dot_div) begin
			check("display", disp_ch, disp_a_prev, FB_DI[disp_ch]);
			n_disp++;
			disp_check_pending = 0;
		end
		if (dot_cnt == 0) begin
			disp_a_prev = $urandom_range(0, 1) ? disp_a_prev + 16'd1 : 16'($urandom);
			FB_A[disp_ch] <= disp_a_prev;
			t_disp_req = $realtime;
			disp_check_pending = 1;
		end
		dot_cnt = (dot_cnt + 1) % dot_div;

		fs_q <= fs;

		// Draw
		case (dstate)
			D_IDLE: begin
				FB_WE[draw_ch] <= 0;
				FB_RD[draw_ch] <= 0;
				// Alternate 50k-cycle phases: relaxed (some idle cycles) and saturated (none).
				if (cyc < CYCLES)
				case (((cyc / 50000) % 2) ? $urandom_range(0, 6) : $urandom_range(0, 9))
					0, 1, 2, 3: begin   // FIFO write: hold A/D/WE for 6 cycles
						FB_A[draw_ch]  <= $urandom;
						FB_DO[draw_ch] <= $urandom;
						FB_WE[draw_ch] <= $urandom_range(1, 3);
						dstate = D_FIFO; dcnt = 6;
					end
					4, 5: begin         // SH-2 read: RD high now, sampled 6 cycles later
						rd_addr = $urandom;
						t_rd_req = $realtime;
						FB_A[draw_ch] <= rd_addr;
						FB_RD[draw_ch] <= 1;
						dstate = D_READ; dcnt = 6 - MARGIN;
					end
					6: begin            // auto-fill of up to 16 words, 7 cycles each
						FB_A[draw_ch]  <= $urandom;
						FB_DO[draw_ch] <= $urandom;
						FB_WE[draw_ch] <= 2'b11;
						fill_left = $urandom_range(1, 16);
						dstate = D_FILL; dcnt = 7;
					end
					default: ;          // idle cycle
				endcase
			end
			D_FIFO: begin
				dcnt--;
				if (dcnt == 0) begin
					// The write must have landed by the end of the hold window.
					shadow[{draw_ch[0], FB_A[draw_ch]}] = merge(shadow[{draw_ch[0], FB_A[draw_ch]}], FB_DO[draw_ch], FB_WE[draw_ch]);
					check_write("FIFO write", draw_ch, FB_A[draw_ch]);
					n_fifo++;
					FB_WE[draw_ch] <= 0;
					dstate = D_GAP;
				end
			end
			D_GAP: dstate = D_IDLE;
			D_READ: begin
				dcnt--;
				if (dcnt == 0) begin
					check("SH-2 read", draw_ch, rd_addr, FB_DI[draw_ch]);
					n_shrd++;
					FB_RD[draw_ch] <= 0;
					dstate = D_IDLE;
				end
			end
			D_FILL: begin
				dcnt--;
				if (dcnt == 0) begin
					shadow[{draw_ch[0], FB_A[draw_ch]}] = FB_DO[draw_ch];
					check_write("fill write", draw_ch, FB_A[draw_ch]);
					n_fill++;
					fill_left--;
					if (fill_left == 0) begin
						FB_WE[draw_ch] <= 0;
						dstate = D_GAP;
					end else begin
						FB_A[draw_ch] <= FB_A[draw_ch] + 16'd1;
						dcnt = 7;
					end
				end
			end
		endcase

		if (errors > 20) break;
	end

	$display("worst latency (MCLK, request to capture): SH-2 read %0.2f (deadline 6, %s), display %0.2f (deadline 8)",
	         max_rd_lat, max_rd_ctx, max_disp_lat);
	$display("display reads %0d, SH-2 reads %0d, FIFO writes %0d, fill writes %0d, swaps %0d",
	         n_disp, n_shrd, n_fifo, n_fill, n_swaps);
	// Final check: every shadow word must match the SRAM.
	for (int i = 0; i < 131072; i++) if (mem[i] !== shadow[i]) begin
		if (errors < 30) $display("ERROR: final mem[%05h] = %04h, shadow %04h", i, mem[i], shadow[i]);
		errors++;
	end
	if (errors == 0) $display("PASS");
	else $display("FAIL: %0d errors", errors);
	$finish;
end

endmodule
