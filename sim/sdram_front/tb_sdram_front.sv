// s32x_sdram_front.sv with the real sdram.sv and an SDRAM chip model, driven the way the SH-2 bus
// controller drives the 32X SDRAM area (REQ-MEM-03):
//   - read bursts (8 beats = a 16-byte cache-line fill, starting at the critical word and wrapping)
//     and 1- or 2-beat reads; only the first beat waits for WAIT; after that one beat per SH-2
//     cycle, data latched on the SH-2's falling clock enable
//   - 1- or 2-beat writes that wait once per beat (TRAS) while WAIT is asserted
//   - random Genesis-style ROM reads competing on port 1
// Every read beat is checked against a shadow memory (words never written are not checked).
`timescale 1ns/1ps

module tb_sdram_front;

localparam real T_SYS = 18.624;
localparam int  OPS = 20000;
reg clk_sys = 0, clk_ram = 0;
always #(T_SYS/2) clk_sys = ~clk_sys;
always #(T_SYS/4) clk_ram = ~clk_ram;
reg reset = 1, init = 1;

// SH-2 clock enables as in 32X.sv: three CE_R and three CE_F per 7 MCLK
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

// Mid clk_ram edge in the clk_sys cycle, as generated in s32x_system.sv
reg sys_tog = 0, ram_tog_n = 0, ram_tog_p = 0;
always @(posedge clk_sys) sys_tog <= ~sys_tog;
always @(negedge clk_ram) ram_tog_n <= sys_tog;
always @(posedge clk_ram) ram_tog_p <= ram_tog_n;
wire ram_mid = ram_tog_n ^ ram_tog_p;

// SH-2 side
reg  [17:1] a = 0;
reg  [15:0] d = 0;
reg         cs = 0, rd = 0;
reg   [1:0] we = 0;
wire [15:0] q;
wire        wait_o, overflow;

wire [24:1] p_addr; wire p_rd; wire [1:0] p_wr; wire [15:0] p_din;
wire [15:0] dout0, dout1; wire busy0, busy1;
reg  [24:1] rom_addr = 0; reg rom_rd = 0;

s32x_sdram_front dut (
	.clk(clk_sys), .reset(reset),
	.a(a), .d(d), .cs(cs), .rd(rd), .we(we), .q(q), .wait_o(wait_o),
	.p_addr(p_addr), .p_rd(p_rd), .p_wr(p_wr), .p_din(p_din), .p_dout(dout0), .p_busy(busy0),
	.overflow(overflow)
);

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
wire [1:0]  SDRAM_BA;

sdram sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
	.init(init), .clk(clk_ram), .mid(ram_mid),
	.addr0(p_addr), .rd0(p_rd), .wr0(p_wr), .din0(p_din), .dout0(dout0), .busy0(busy0),
	.addr1(rom_addr), .rd1(rom_rd), .wr1(2'b00), .din1(16'd0), .dout1(dout1), .busy1(busy1),
	.addr2(24'd0), .rd2(1'b0), .wr2(2'b00), .din2(16'd0), .dout2(), .busy2(),
	.addr3(24'd0), .rd3(1'b0), .wr3(2'b00), .din3(16'd0), .dout3(), .busy3()
);

sdram_model chip (
	.clk(SDRAM_CLK), .cke(SDRAM_CKE), .a(SDRAM_A), .ba(SDRAM_BA), .dq(SDRAM_DQ),
	.dqm({SDRAM_DQMH, SDRAM_DQML}), .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE)
);

// Genesis-like ROM traffic on port 1
always @(posedge clk_sys) if (!reset) begin
	if (!rom_rd && $urandom_range(0, 9) == 0) begin rom_addr <= {1'b0, 23'($urandom)}; rom_rd <= 1; end
	else if (rom_rd && !busy1 && $urandom_range(0, 3) == 0) rom_rd <= 0;
end

// Shadow of the SH-2's view (a small window, so lines are reused and writes hit the buffer)
localparam int WIN = 2048;                 // words
reg [15:0] shadow [WIN];
reg        known  [WIN];
int errors = 0, n_rd = 0, n_wr = 0, n_miss = 0;
initial for (int i = 0; i < WIN; i++) known[i] = 0;

task automatic wait_ce_r(); do @(posedge clk_sys); while (!CE_R); endtask
task automatic wait_ce_f(); do @(posedge clk_sys); while (!CE_F); endtask

// One read of n beats starting at word w0, wrapping within its 8-word line
task automatic sh_read(input int w0, input int n);
	int line = w0 & ~7;
	wait_ce_r();
	for (int b = 0; b < n; b++) begin
		automatic int w = (n == 8) ? (line | ((w0 + b) & 7)) : (w0 + b);
		a <= 17'(w); cs <= 1; rd <= 1;
		if (b == 0) begin
			// TRCAS: move on at a CE_R that sees WAIT released
			do begin wait_ce_r(); #1; end while (wait_o);
			if (b == 0) n_miss += 0;
		end
		else wait_ce_r();
		wait_ce_f(); #1;                           // TRD: latch the data
		n_rd++;
		if (known[w] && q !== shadow[w]) begin
			errors++;
			if (errors <= 20) $display("%t ERROR: read beat %0d of %0d at word %04h: got %04h expected %04h",
			                           $realtime, b, n, w, q, shadow[w]);
		end
		rd <= 0;
	end
	cs <= 0;
endtask

// One write of n beats (1 or 2) at word w0; each beat waits in TRAS while WAIT is asserted
task automatic sh_write(input int w0, input int n, input bit [1:0] bwe);
	for (int b = 0; b < n; b++) begin
		automatic int w = w0 + b;
		automatic bit [15:0] v = $urandom;
		wait_ce_r();
		a <= 17'(w); d <= v; we <= bwe; cs <= 1;
		do begin wait_ce_r(); #1; end while (wait_o);  // TRAS: waits while WAIT is asserted
		wait_ce_f();                                // TWCAS: WE released
		we <= 0;
		if (bwe[1]) shadow[w][15:8] = v[15:8];
		if (bwe[0]) shadow[w][7:0]  = v[7:0];
		if (bwe == 2'b11) known[w] = 1;
		n_wr++;
		wait_ce_r();                               // TWNOP
	end
	cs <= 0;
endtask

initial begin
	repeat (20) @(posedge clk_ram);
	init = 0;
	repeat (400) @(posedge clk_ram);
	reset = 0;
	// Fill the window so every word is known
	for (int w = 0; w < WIN; w += 2) sh_write(w, 2, 2'b11);
	for (int op = 0; op < OPS; op++) begin
		automatic int k = $urandom_range(0, 99);
		automatic int w = $urandom_range(0, WIN - 9);
		if (k < 40)      sh_read(w, 8);
		else if (k < 55) sh_read(w & ~1, 2);
		else if (k < 65) sh_read(w, 1);
		else if (k < 85) sh_write(w & ~1, 2, 2'b11);
		else if (k < 95) sh_write(w, 1, $urandom_range(0, 1) ? 2'b10 : 2'b01);
		else             repeat ($urandom_range(1, 40)) @(posedge clk_sys);
	end
	repeat (200) @(posedge clk_sys);
	$display("%0d read beats, %0d write beats, overflow %b", n_rd, n_wr, overflow);
	if (errors == 0 && !overflow) $display("PASS");
	else $display("FAIL: %0d errors", errors);
	$finish;
end

endmodule
