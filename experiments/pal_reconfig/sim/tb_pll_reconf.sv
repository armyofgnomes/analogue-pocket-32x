// NTSC/PAL PLL switch (REQ-ARCH-06): pll_core with Altera's PLL model (altera_lnsim) and the
// real reconfiguration controller. Measures clk_sys (outclk_0) and clk_ram (outclk_1) before and
// after switching to PAL and back, and checks that `busy` covers every period where the clocks
// aren't right yet.
`timescale 1ps/1ps
module tb_pll_reconf;

reg clk_74a = 0;
always #6734 clk_74a = ~clk_74a;          // 74.25 MHz

reg  pal = 0;
wire clk_sys, clk_ram, clk_vid, clk_vid_90, locked, busy;
pll_core dut (
	.refclk(clk_74a), .rst(1'b0), .pal(pal), .busy(busy),
	.outclk_0(clk_sys), .outclk_1(clk_ram), .outclk_2(clk_vid), .outclk_3(clk_vid_90), .locked(locked)
);

integer errors = 0;

// Average frequency over 1000 clk_sys and 2000 clk_ram rising edges
task automatic measure(input string what, input real want_mhz);
	realtime t0, t1;
	real mhz_sys, mhz_ram;
	@(posedge clk_sys); t0 = $realtime;
	repeat (1000) @(posedge clk_sys);
	t1 = $realtime;
	mhz_sys = 1000.0 * 1e6 / (t1 - t0);
	@(posedge clk_ram); t0 = $realtime;
	repeat (2000) @(posedge clk_ram);
	t1 = $realtime;
	mhz_ram = 2000.0 * 1e6 / (t1 - t0);
	$display("%s: clk_sys %.6f MHz, clk_ram %.6f MHz (want %.6f / %.6f), locked=%b busy=%b", what,
	         mhz_sys, mhz_ram, want_mhz, 2 * want_mhz, locked, busy);
	if (mhz_sys < want_mhz - 0.001 || mhz_sys > want_mhz + 0.001 ||
	    mhz_ram < 2 * want_mhz - 0.002 || mhz_ram > 2 * want_mhz + 0.002) begin
		$display("ERROR: %s frequency", what); errors++;
	end
endtask

task automatic wait_idle(input string what);
	realtime t0;
	t0 = $realtime;
	wait (busy);
	$display("%s: busy at +%0.1f us", what, ($realtime - t0) / 1e6);
	wait (!busy);
	$display("%s: done after %0.1f us, locked=%b", what, ($realtime - t0) / 1e6, locked);
	if (!locked) begin $display("ERROR: %s not locked after busy", what); errors++; end
endtask

// While not busy, the PLL must stay locked (the console runs only then)
always @(negedge locked) if (!busy && $realtime > 200us) begin
	$display("ERROR: lock lost at %t while not busy", $realtime); errors++;
end

initial begin
	wait (locked);
	#50us;
	measure("NTSC at power-up", 53.693180);
	pal = 1;
	wait_idle("to PAL");
	measure("PAL", 53.203424);
	pal = 0;
	wait_idle("back to NTSC");
	measure("NTSC again", 53.693180);
	if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
	$finish;
end

initial begin #50ms; $display("FAIL: timeout (locked=%b busy=%b st=%0d)", locked, busy, dut.st); $finish; end

endmodule
