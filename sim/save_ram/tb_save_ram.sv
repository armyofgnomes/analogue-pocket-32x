// Save RAM bench (REQ-SAVE-01): s32x_save_ram.sv with core_top.v's bridge glue, driven the way
// apf/io_bridge_peripheral.v drives the bridge.
//   1. The host writes a 64 KB save file (big-endian bridge words, as the Pocket does).
//   2. The console reads and writes cart SRAM with the 32X interface's handshake (wait for busy
//      to rise, then fall; busy seen only on SH-2 clock enables) and the Genesis bus's.
//   3. An EEPROM cart reads and writes its 1 KB.
//   4. The host reads the whole file back; every byte must match the model (odd bytes = data,
//      even bytes = 0xFF). io_bridge_peripheral latches the address, samples bridge_rd_data 4
//      clocks later, then pulses bridge_rd, so each read returns the word latched by the
//      previous read's pulse (as with core_bridge_cmd).
`timescale 1ns/1ps
module tb_save_ram;

reg clk_74a = 0, clk_sys = 0;
always #6.734 clk_74a = ~clk_74a;   // 74.25 MHz
always #9.312 clk_sys = ~clk_sys;   // 53.69 MHz

reg         bridge_wr = 0, bridge_rd = 0;
reg  [31:0] bridge_addr = 0, bridge_wr_data = 0;

wire [15:0] save_q;
reg  [31:0] save_rd_data;
wire        save_sel = bridge_addr[31:28] == 4'h6;
always @(posedge clk_74a) begin       // as in core_top.v
	if (bridge_rd && save_sel) save_rd_data <= {8'hFF, save_q[7:0], 8'hFF, save_q[15:8]};
end

reg  [14:0] sram_a = 0;
reg   [7:0] sram_d = 0;
reg         sram_rd = 0, sram_wr = 0;
wire  [7:0] sram_q;
wire        sram_busy;
reg         eeprom_sel = 0;
reg   [9:0] eeprom_a = 0;
reg   [7:0] eeprom_d = 0;
reg         eeprom_we = 0;
wire  [7:0] eeprom_q;

s32x_save_ram dut (
	.clk(clk_sys),
	.sram_a(sram_a), .sram_d(sram_d), .sram_rd(sram_rd), .sram_wr(sram_wr),
	.sram_q(sram_q), .sram_busy(sram_busy),
	.eeprom_sel(eeprom_sel), .eeprom_a(eeprom_a), .eeprom_d(eeprom_d), .eeprom_we(eeprom_we),
	.eeprom_q(eeprom_q),
	.b_clk(clk_74a), .b_a(bridge_addr[15:2]), .b_d({bridge_wr_data[7:0], bridge_wr_data[23:16]}),
	.b_we(bridge_wr & save_sel), .b_q(save_q));

// IF.sv registers ROM_WAIT on clk_sys (patch 0009) and looks at it on SH-2 clock enables
reg rom_wait_sync = 0;
always @(posedge clk_sys) rom_wait_sync <= sram_busy;
reg [2:0] ce_ph = 0;   // SH-2 clock enable: 3 of every 7 clocks
always @(posedge clk_sys) ce_ph <= (ce_ph == 6) ? 0 : ce_ph + 1'd1;
wire ce_f = (ce_ph == 0) || (ce_ph == 2) || (ce_ph == 4);

reg [7:0] model[65536];     // save file bytes
integer errors = 0;

// ---- host side (io_bridge_peripheral timing, SPI byte gaps shortened) ----
task host_write(input [31:0] off, input [31:0] data);
	begin
		@(posedge clk_74a);
		bridge_addr <= 32'h60000000 + off;
		repeat (8) @(posedge clk_74a);
		bridge_wr_data <= data;
		@(posedge clk_74a);
		bridge_wr <= 1;
		@(posedge clk_74a);
		bridge_wr <= 0;
		repeat (4) @(posedge clk_74a);
	end
endtask

// Returns the word the bridge sends for this transaction: the previous read's.
task host_read(input [31:0] off, output [31:0] data);
	begin
		@(posedge clk_74a);
		bridge_addr <= 32'h60000000 + off;
		repeat (4) @(posedge clk_74a);
		data = save_rd_data;
		@(posedge clk_74a);
		bridge_rd <= 1;
		@(posedge clk_74a);
		bridge_rd <= 0;
		repeat (8) @(posedge clk_74a);
	end
endtask

// ---- console side ----
// 32X interface: strobe, wait for ROM_WAIT to rise then fall (both on clock enables), data read
// while the strobe is still held.
task if_access(input wr, input [14:0] a, input [7:0] d, output [7:0] q);
	integer guard;
	begin
		@(posedge clk_sys); while (!ce_f) @(posedge clk_sys);
		sram_a <= a; sram_d <= d;
		if (wr) sram_wr <= 1; else sram_rd <= 1;
		guard = 0;
		do begin @(posedge clk_sys); guard = guard + 1; end while (!(rom_wait_sync && ce_f) && guard < 100);
		if (guard >= 100) begin $display("ERROR: busy never seen rising (a=%h)", a); errors = errors + 1; end
		do begin @(posedge clk_sys); guard = guard + 1; end while (!(!rom_wait_sync && ce_f) && guard < 200);
		q = sram_q;
		sram_wr <= 0; sram_rd <= 0;
		repeat (3) @(posedge clk_sys);
	end
endtask

// Genesis bus arbiter: one wait state, then done as soon as MEM_RDY (= !busy)
task gen_access(input wr, input [14:0] a, input [7:0] d, output [7:0] q);
	begin
		@(posedge clk_sys);
		sram_a <= a; sram_d <= d;
		if (wr) sram_wr <= 1; else sram_rd <= 1;
		@(posedge clk_sys);                     // MBUS_ROM_WAIT
		@(posedge clk_sys);                     // MBUS_ROM_READ
		while (sram_busy) @(posedge clk_sys);
		repeat (2) @(posedge clk_sys);          // 68K samples data a few clocks after DTACK
		q = sram_q;
		sram_wr <= 0; sram_rd <= 0;
		repeat (4) @(posedge clk_sys);
	end
endtask

integer i, k;
reg [31:0] w;
reg [14:0] a;
reg [7:0] b, q;

initial begin
	// 1. Load the save file
	for (i = 0; i < 65536; i = i + 1) model[i] = (i & 1) ? $urandom : 8'hFF;
	for (i = 0; i < 65536; i = i + 4) host_write(i, {model[i], model[i+1], model[i+2], model[i+3]});
	repeat (50) @(posedge clk_sys);
	$display("loaded 64 KB");

	// 2. Cart SRAM through both bus paths
	for (k = 0; k < 400; k = k + 1) begin
		a = $urandom;
		if (k & 1) if_access(0, a, 0, q); else gen_access(0, a, 0, q);
		if (q !== model[{a, 1'b1}]) begin
			$display("ERROR: SRAM read %h = %h, expected %h", a, q, model[{a, 1'b1}]);
			errors = errors + 1;
		end
		a = $urandom; b = $urandom;
		if (k & 2) if_access(1, a, b, q); else gen_access(1, a, b, q);
		model[{a, 1'b1}] = b;
	end
	$display("cart SRAM accesses done, errors=%0d", errors);

	// 3. EEPROM cart (EEPROM_24CXX: address and write strobe for one clock, reads one clock later)
	eeprom_sel = 1;
	for (k = 0; k < 300; k = k + 1) begin
		@(posedge clk_sys);
		eeprom_a <= $urandom; eeprom_d <= $urandom; eeprom_we <= k & 1;
		@(posedge clk_sys);
		eeprom_we <= 0;
		if (k & 1) model[{5'd0, eeprom_a, 1'b1}] = eeprom_d;
		else begin
			@(posedge clk_sys);
			if (eeprom_q !== model[{5'd0, eeprom_a, 1'b1}]) begin
				$display("ERROR: EEPROM read %h = %h, expected %h", eeprom_a, eeprom_q, model[{5'd0, eeprom_a, 1'b1}]);
				errors = errors + 1;
			end
		end
	end
	eeprom_sel = 0;
	$display("EEPROM accesses done, errors=%0d", errors);

	// 4. Read the file back: each read returns the previous one's word, so one extra read
	host_read(0, w);
	for (i = 0; i < 65536; i = i + 4) begin
		host_read((i + 4) & 16'hFFFF, w);
		if (w !== {model[i], model[i+1], model[i+2], model[i+3]}) begin
			if (errors < 20) $display("ERROR: file offset %h = %h, expected %h", i, w,
				{model[i], model[i+1], model[i+2], model[i+3]});
			errors = errors + 1;
		end
	end
	$display("unload done, errors=%0d", errors);

	if (errors == 0) $display("PASS");
	else $display("FAIL: %0d errors", errors);
	$finish;
end

endmodule
