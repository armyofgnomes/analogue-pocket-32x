// Differential testbench for the 32X framebuffer path (REQ-MEM-02, REQ-S32X-05).
//
// Two copies of upstream S32X_VDP get identical inputs:
//   ref: USE_ASYNC_FB=0 with single-cycle block-RAM framebuffers, exactly as MiSTer's S32X.sv
//   dut: USE_ASYNC_FB=1 with fb_sram.sv and a 35 ns async SRAM model, as in s32x_system.sv
// A bus-functional model plays the SH-2 side through the VDP's register/palette/framebuffer
// ports (random word/byte/overwrite writes, reads, auto-fills, buffer swaps and mode changes)
// while synthetic Genesis sync/EDCLK drive the display. Every clk_sys cycle all VDP outputs
// (pixels, priority, blanking, bus data/ack) must match between the two.
//
// Plusargs: +frames=<n> (default 6)  +mode=<0..3> (fixed bitmap mode; default random per frame)
//           +h32 (H32 dot timing; the 32X VDP's counters only work in H40, so 32X games
//           always use H40 and this is only for experiments)  +idle (no draw traffic while displaying)  +ppm (dump frames)

`timescale 1ns/1ps

module tb_vdp;

localparam real T_SYS = 18.624;   // 53.693 MHz

reg clk_sys = 0, clk_ram = 0;
always #(T_SYS/2) clk_sys = ~clk_sys;
always #(T_SYS/4) clk_ram = ~clk_ram;

reg rst_n = 0;

int frames_max = 6, fixed_mode = -1;
bit h32 = 0, idle = 0, ppm = 0;

///////////////////////////////////////////////////////////////////////////////
// Clock enables as in 32X.sv: VCLK every 7 MCLK, SH-2 CE_R/CE_F three times per VCLK

reg CE_R = 0, CE_F = 0;
always @(posedge clk_sys) begin
	static bit [2:0] vdiv = 0;
	static bit [2:0] clk_cnt = 3'b111;
	bit vclk;
	vdiv <= (vdiv == 6) ? 3'd0 : vdiv + 3'd1;
	vclk = (vdiv == 6);
	if (~&clk_cnt) clk_cnt <= clk_cnt + 1'd1;
	CE_F <= 0; CE_R <= 0;
	if (vclk) begin clk_cnt <= 1; CE_F <= 1; end
	case (clk_cnt)
		3'd0, 3'd2, 3'd4: CE_F <= 1;
		3'd1, 3'd3, 3'd5: CE_R <= 1;
		default:;
	endcase
end

///////////////////////////////////////////////////////////////////////////////
// Genesis-side video timing: 3420 MCLK lines, 262 lines (NTSC). EDCLK = 2x dot clock
// (MCLK/4 in H40, MCLK/5 in H32); HSYNC low long enough (H40) or short (H32) for the VDP's
// H32 detection.

int hc = 0, vc = 0;
reg EDCLK = 0, HSYNC_N = 1, VSYNC_N = 1;
int ed_cnt = 0;
always @(posedge clk_sys) begin
	hc <= (hc == 3419) ? 0 : hc + 1;
	if (hc == 3419) vc <= (vc == 261) ? 0 : vc + 1;
	HSYNC_N <= !(hc < (h32 ? 250 : 320));
	VSYNC_N <= !(vc >= 232 && vc < 235);
	if (h32) begin
		ed_cnt <= (ed_cnt == 4) ? 0 : ed_cnt + 1;
		EDCLK  <= ed_cnt < 2;
	end else begin
		ed_cnt <= (ed_cnt == 3) ? 0 : ed_cnt + 1;
		EDCLK  <= ed_cnt < 2;
	end
end

///////////////////////////////////////////////////////////////////////////////
// Shared SH-2-side bus inputs

reg  [17:1] A = 0;
reg  [15:0] DI = 0;
reg         RD_N = 1, LWR_N = 1, UWR_N = 1;
reg         DRAM_CS_N = 1, REG_CS_N = 1, PAL_CS_N = 1;

`define VDP_OUTPUTS(p) \
	wire [15:0] p``_DO; wire p``_ACK_N, p``_VINT, p``_HINT; \
	wire [15:0] p``_FB0_A, p``_FB0_DI, p``_FB0_DO, p``_FB1_A, p``_FB1_DI, p``_FB1_DO; \
	wire  [1:0] p``_FB0_WE, p``_FB1_WE; wire p``_FB0_RD, p``_FB1_RD, p``_FB_FS; \
	wire        p``_DOT_CE, p``_HS_N, p``_VS_N, p``_YSO_N, p``_HBL; \
	wire  [4:0] p``_R, p``_G, p``_B;

`VDP_OUTPUTS(r)
`VDP_OUTPUTS(d)

`define VDP_INST(p, async) \
	S32X_VDP #(async) p``_vdp ( \
		.CLK(clk_sys), .RST_N(rst_n), .CE_R(CE_R), .CE_F(CE_F), .MRES_N(1'b1), \
		.VSYNC_N(VSYNC_N), .HSYNC_N(HSYNC_N), .EDCLK(EDCLK), .YS_N(1'b1), .PAL(1'b0), \
		.A(A), .DI(DI), .DO(p``_DO), .RD_N(RD_N), .LWR_N(LWR_N), .UWR_N(UWR_N), .ACK_N(p``_ACK_N), \
		.DRAM_CS_N(DRAM_CS_N), .REG_CS_N(REG_CS_N), .PAL_CS_N(PAL_CS_N), \
		.VINT(p``_VINT), .HINT(p``_HINT), \
		.FB0_A(p``_FB0_A), .FB0_DI(p``_FB0_DI), .FB0_DO(p``_FB0_DO), .FB0_WE(p``_FB0_WE), .FB0_RD(p``_FB0_RD), \
		.FB1_A(p``_FB1_A), .FB1_DI(p``_FB1_DI), .FB1_DO(p``_FB1_DO), .FB1_WE(p``_FB1_WE), .FB1_RD(p``_FB1_RD), \
		.FB_FS(p``_FB_FS), .DOT_CE(p``_DOT_CE), .R(p``_R), .G(p``_G), .B(p``_B), \
		.HS_N(p``_HS_N), .VS_N(p``_VS_N), .YSO_N(p``_YSO_N), .HBL(p``_HBL), .DBG_DOT_TIME() \
	);

`VDP_INST(r, 0)
`VDP_INST(d, 1)

///////////////////////////////////////////////////////////////////////////////
// Reference framebuffers: MiSTer's spram (registered address, 1-cycle read) on clk_sys

reg [15:0] rmem0 [0:65535];
reg [15:0] rmem1 [0:65535];
reg [15:0] rq0, rq1;
assign r_FB0_DI = rq0;
assign r_FB1_DI = rq1;
always @(posedge clk_sys) begin
	if (r_FB0_WE[1]) rmem0[r_FB0_A][15:8] <= r_FB0_DO[15:8];
	if (r_FB0_WE[0]) rmem0[r_FB0_A][7:0]  <= r_FB0_DO[7:0];
	if (r_FB1_WE[1]) rmem1[r_FB1_A][15:8] <= r_FB1_DO[15:8];
	if (r_FB1_WE[0]) rmem1[r_FB1_A][7:0]  <= r_FB1_DO[7:0];
	rq0 <= rmem0[r_FB0_A];
	rq1 <= rmem1[r_FB1_A];
end

///////////////////////////////////////////////////////////////////////////////
// DUT framebuffers: fb_sram with the production timing and a 35 ns async SRAM

wire [16:0] SRAM_A;
wire [15:0] SRAM_DQ;
wire        SRAM_OE_N, SRAM_WE_N, SRAM_UB_N, SRAM_LB_N;
reg         ram_reset = 1;

fb_sram fb (
	.clk_ram(clk_ram), .reset(ram_reset),
	.FB0_A(d_FB0_A), .FB0_DO(d_FB0_DO), .FB0_WE(d_FB0_WE), .FB0_RD(d_FB0_RD), .FB0_DI(d_FB0_DI),
	.FB1_A(d_FB1_A), .FB1_DO(d_FB1_DO), .FB1_WE(d_FB1_WE), .FB1_RD(d_FB1_RD), .FB1_DI(d_FB1_DI),
	.FB_FS(d_FB_FS), .cfg_rd(4'd4), .cfg_we(4'd2), .cfg_half(1'b0),
	.sram_a(SRAM_A), .sram_dq(SRAM_DQ), .sram_oe_n(SRAM_OE_N), .sram_we_n(SRAM_WE_N),
	.sram_ub_n(SRAM_UB_N), .sram_lb_n(SRAM_LB_N)
);

reg [15:0] sram [0:131071];
reg [15:0] sram_rd;
always @(SRAM_A or SRAM_OE_N) begin
	sram_rd = 16'hxxxx;
	#(35.0) sram_rd = sram[SRAM_A];
end
assign SRAM_DQ = (!SRAM_OE_N && SRAM_WE_N) ? sram_rd : 16'hZZZZ;
always @(posedge SRAM_WE_N) begin
	if (!SRAM_UB_N) sram[SRAM_A][15:8] = SRAM_DQ[15:8];
	if (!SRAM_LB_N) sram[SRAM_A][7:0]  = SRAM_DQ[7:0];
end

initial begin
	for (int i = 0; i < 65536; i++) begin
		rmem0[i] = $urandom; rmem1[i] = $urandom;
		sram[{1'b0, 16'(i)}] = rmem0[i];
		sram[{1'b1, 16'(i)}] = rmem1[i];
	end
end

///////////////////////////////////////////////////////////////////////////////
// Output comparison

int errors = 0, pix_errors = 0, frame = 0, frame_pix_err = 0;
int n_wr = 0, n_bwr = 0, n_rd = 0, n_fill = 0, n_swap = 0;

always @(posedge clk_sys) if (rst_n) begin
	#2;
	if ({r_R, r_G, r_B, r_YSO_N, r_HBL} !== {d_R, d_G, d_B, d_YSO_N, d_HBL}) begin
		pix_errors++; frame_pix_err++;
		if (pix_errors <= 20)
			$display("%t PIXEL MISMATCH line %0d H_CNT %03h mode %0d fs %0d: ref %02h/%02h/%02h ys%0d  dut %02h/%02h/%02h ys%0d  (disp addr ref %04h dut %04h)",
			         $realtime, r_vdp.V_CNT, r_vdp.H_CNT, r_vdp.MODE, r_vdp.FS, r_R, r_G, r_B, r_YSO_N, d_R, d_G, d_B, d_YSO_N,
			         r_vdp.FB_DISP_A, d_vdp.FB_DISP_A);
	end
	if ({r_ACK_N, r_DO, r_VINT, r_DOT_CE, r_FB_FS} !== {d_ACK_N, d_DO, d_VINT, d_DOT_CE, d_FB_FS}) begin
		errors++;
		if (errors <= 20)
			$display("%t BUS MISMATCH: ref ack %b do %04h  dut ack %b do %04h (A %05h rd %b)", $realtime,
			         r_ACK_N, r_DO, d_ACK_N, d_DO, {A, 1'b0}, !RD_N);
	end
end

// Every reference write must be in the SRAM a few cycles later (the VDP's write hold window)
typedef struct { longint t; bit ch; bit [15:0] a; } wr_rec_t;
wr_rec_t wr_q[$];
int wr_errors = 0;
longint cyc = 0;
always @(posedge clk_sys) begin
	cyc++;
	if (|r_FB0_WE) wr_q.push_back('{cyc, 1'b0, r_FB0_A});
	if (|r_FB1_WE) wr_q.push_back('{cyc, 1'b1, r_FB1_A});
	while (wr_q.size() && wr_q[0].t + 14 < cyc) begin
		automatic wr_rec_t w = wr_q.pop_front();
		automatic bit [15:0] rv = w.ch ? rmem1[w.a] : rmem0[w.a];
		automatic bit newer = 0;
		foreach (wr_q[i]) if (wr_q[i].ch == w.ch && wr_q[i].a == w.a) newer = 1;   // still in flight
		if (!newer && sram[{w.ch, w.a}] !== rv) begin
			wr_errors++;
			if (wr_errors <= 10)
				$display("%t WRITE LOST FB%0d[%04h]: ref %04h sram %04h (written %0d cycles ago)",
				         $realtime, w.ch, w.a, rv, sram[{w.ch, w.a}], cyc - w.t);
		end
	end
end

// +trace_t0=<ns>: fb_sram activity from t0-1200 ns to t0+40 ns (the sequence is unchanged)
real trace_t0 = -1;
initial void'($value$plusargs("trace_t0=%f", trace_t0));
always @(posedge clk_ram) if (trace_t0 >= 0 && $realtime >= trace_t0 - 1200.0 && $realtime < trace_t0 + 40.0)
	$display("%t st=%0d cnt=%0d op=%0d a=%05h oe=%b we=%b dq=%04h | fs=%b dot=%b dispA=%04h dq_ref=%04h di0=%04h di1=%04h | we0=%b we1=%b rd0=%b rd1=%b a0=%04h a1=%04h pend w%b%b r%b%b",
	         $realtime, fb.state, fb.cnt, fb.op_ch, SRAM_A, SRAM_OE_N, SRAM_WE_N, SRAM_DQ, d_FB_FS, d_DOT_CE,
	         d_vdp.FB_DISP_A, r_vdp.FB_DISP_Q, d_FB0_DI, d_FB1_DI, d_FB0_WE, d_FB1_WE, d_FB0_RD, d_FB1_RD,
	         d_FB0_A, d_FB1_A, fb.wr_pend[0], fb.wr_pend[1], fb.rd_pend[0], fb.rd_pend[1]);

// Frame boundaries (end of the VDP's vblank start) and optional PPM dumps of both outputs
int fd_r = 0, fd_d = 0;
int px = 0;
always @(posedge clk_sys) if (rst_n && r_DOT_CE) begin
	if (r_vdp.H_CNT == 9'h017 + 2 && !r_vdp.VBLK && fd_r) px = 0;
	if (ppm && fd_r && !r_HBL && !r_vdp.VBLK) begin
		$fwrite(fd_r, "%c%c%c", {r_R, 3'b0}, {r_G, 3'b0}, {r_B, 3'b0});
		$fwrite(fd_d, "%c%c%c", {d_R, 3'b0}, {d_G, 3'b0}, {d_B, 3'b0});
	end
end

///////////////////////////////////////////////////////////////////////////////
// SH-2-side bus-functional model

localparam CS_REG = 0, CS_PAL = 1, CS_DRAM = 2;

task automatic bus(input int cs, input bit [17:1] a, input bit [15:0] d, input bit rd,
                   input bit [1:0] we, output bit [15:0] q);
	int t = 0;
	@(posedge clk_sys); #1;
	A = a; DI = d;
	REG_CS_N = cs != CS_REG; PAL_CS_N = cs != CS_PAL; DRAM_CS_N = cs != CS_DRAM;
	RD_N = !rd; UWR_N = !we[1]; LWR_N = !we[0];
	do begin
		@(posedge clk_sys); #1;
		if (++t > 20000) begin $display("%t ERROR: bus timeout", $realtime); errors++; break; end
	end while (r_ACK_N);
	q = r_DO;
	RD_N = 1; UWR_N = 1; LWR_N = 1;
	REG_CS_N = 1; PAL_CS_N = 1; DRAM_CS_N = 1;
	@(posedge clk_sys); #1;
endtask

task automatic reg_wr(input bit [3:0] off, input bit [15:0] d);
	bit [15:0] q;
	bus(CS_REG, {13'd0, off[3:1]}, d, 0, 2'b11, q);
endtask

task automatic reg_rd(input bit [3:0] off, output bit [15:0] q);
	bus(CS_REG, {13'd0, off[3:1]}, 0, 1, 2'b00, q);
endtask

task automatic wait_fill_done();
	bit [15:0] q;
	// Upstream sets FEN (FILL_EXEC) a few cycles after the AFDR write (FILL_PEND waits for CE_R)
	repeat (8) @(posedge clk_sys);
	do reg_rd(4'hA, q); while (q[1]);   // FBCR.FEN
endtask

// One random framebuffer operation on the draw buffer
task automatic random_op();
	bit [15:0] q;
	int k = $urandom_range(0, 99);
	bit [17:1] a = {($urandom_range(0, 9) == 0), 16'($urandom)};
	if (k < 45) begin
		bus(CS_DRAM, a, $urandom, 0, 2'b11, q); n_wr++;
	end else if (k < 70) begin
		bus(CS_DRAM, a, $urandom, 0, $urandom_range(0, 1) ? 2'b10 : 2'b01, q); n_bwr++;
	end else if (k < 97) begin
		bus(CS_DRAM, {1'b0, a[16:1]}, 0, 1, 2'b00, q); n_rd++;
	end else begin
		reg_wr(4'h4, $urandom_range(0, 255));       // AFLR
		reg_wr(4'h6, $urandom);                     // AFAR
		reg_wr(4'h8, $urandom);                     // AFDR: starts the fill
		wait_fill_done(); n_fill++;
	end
	repeat ($urandom_range(0, 12)) @(posedge clk_sys);
endtask

initial begin
	bit [15:0] q;
	int mode;
	void'($value$plusargs("frames=%d", frames_max));
	void'($value$plusargs("mode=%d", fixed_mode));
	h32  = $test$plusargs("h32");
	idle = $test$plusargs("idle");
	ppm  = $test$plusargs("ppm");

	repeat (8) @(posedge clk_ram);
	ram_reset = 0;
	repeat (8) @(posedge clk_sys);
	rst_n = 1;

	// Palette (mode 0: PEN always set)
	for (int i = 0; i < 256; i++) bus(CS_PAL, 17'(i), $urandom, 0, 2'b11, q);

	for (frame = 0; frame < frames_max; frame++) begin
		// Wait for vblank, then set up the next frame: mode, shift, priority, buffer swap.
		while (!r_vdp.VBLK) @(posedge clk_sys);
		mode = fixed_mode >= 0 ? fixed_mode : $urandom_range(1, 3);
		reg_wr(4'h0, {8'h00, 1'b0 /*PRI*/, 1'b0, 4'h0, 2'(mode)});
		reg_wr(4'h2, 16'($urandom_range(0, 1)));
		reg_rd(4'hA, q);
		reg_wr(4'hA, {15'd0, ~q[0]}); n_swap++;
		// Games poll FBCR until the swap has happened before drawing into the new buffer
		begin
			bit [15:0] q2;
			do reg_rd(4'hA, q2); while (q2[0] == q[0]);
		end
		// Draw traffic until the next vblank (register latches happen around H_CNT 0x157)
		while (r_vdp.VBLK) if (!idle) random_op(); else @(posedge clk_sys);
		if (ppm) begin
			fd_r = $fopen($sformatf("ref_%0d.ppm", frame), "wb");
			fd_d = $fopen($sformatf("dut_%0d.ppm", frame), "wb");
			$fwrite(fd_r, "P6\n320 %0d\n255\n", 224); $fwrite(fd_d, "P6\n320 %0d\n255\n", 224);
		end
		frame_pix_err = 0;
		while (!r_vdp.VBLK) if (!idle) random_op(); else @(posedge clk_sys);
		if (ppm) begin $fclose(fd_r); $fclose(fd_d); fd_r = 0; fd_d = 0; end
		$display("%t frame %0d mode %0d: %0d pixel mismatches (ops: %0d wr %0d byte %0d rd %0d fill)",
		         $realtime, frame, mode, frame_pix_err, n_wr, n_bwr, n_rd, n_fill);
	end

	if (errors == 0 && pix_errors == 0 && wr_errors == 0) $display("PASS");
	else $display("FAIL: %0d bus mismatches, %0d pixel mismatches, %0d lost writes", errors, pix_errors, wr_errors);
	$finish;
end

endmodule
