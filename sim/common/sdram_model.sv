// Behavioral SDR SDRAM model (x16, 4 banks, 13-bit row, 10-bit column), enough to run
// upstream sdram.sv: MRS, ACTIVE, READ/WRITE (with auto-precharge), PRECHARGE, REFRESH, burst
// length 1 or 2, CAS latency from the mode register. Commands are sampled on the rising edge of
// `clk` (the SDRAM_CLK pin). Checks tRCD and use of a row that isn't open.
`timescale 1ns/1ps

module sdram_model #(parameter real T_RCD = 18.0)
(
	input             clk,
	input             cke,
	input      [12:0] a,
	input       [1:0] ba,
	inout      [15:0] dq,
	input       [1:0] dqm,
	input             ras_n,
	input             cas_n,
	input             we_n
);

reg [15:0] mem [bit [24:0]];
reg [12:0] row [4];
bit        open_ [4];
realtime   t_act [4];
int        cl = 3, bl = 1;
int        errors = 0;

// Read pipeline: data appears cl clocks after the READ command
reg [15:0] rd_q  [0:7];
bit        rd_v  [0:7];
reg [15:0] dq_out;
reg        dq_oe = 0;
assign #(5.4) dq = dq_oe ? dq_out : 16'hZZZZ;   // tAC ~5.4 ns (CL3)

wire [2:0] cmd = {ras_n, cas_n, we_n};

always @(posedge clk) if (cke) begin
	// shift the read pipeline
	for (int i = 0; i < 7; i++) begin rd_q[i] <= rd_q[i+1]; rd_v[i] <= rd_v[i+1]; end
	rd_v[7] <= 0;
	dq_oe  <= rd_v[1];
	dq_out <= rd_q[1];

	case (cmd)
		3'b000: begin // MRS
			cl = a[6:4]; bl = 1 << a[2:0];
			if (cl != 2 && cl != 3) begin $display("%t SDRAM ERROR: bad CAS latency %0d", $realtime, cl); errors++; end
		end
		3'b011: begin // ACTIVE
			row[ba] = a; open_[ba] = 1; t_act[ba] = $realtime;
		end
		3'b101, 3'b100: begin // READ / WRITE
			automatic bit [24:0] base = {ba, row[ba], a[9:0]};
			if (!open_[ba]) begin $display("%t SDRAM ERROR: %s to bank %0d with no open row", $realtime, cmd[0] ? "READ" : "WRITE", ba); errors++; end
			if ($realtime - t_act[ba] < T_RCD) begin $display("%t SDRAM ERROR: tRCD %0.1f ns", $realtime, $realtime - t_act[ba]); errors++; end
			for (int i = 0; i < bl; i++) begin
				if (cmd == 3'b101) begin
					rd_q[cl - 1 + i] <= mem.exists(base + i) ? mem[base + i] : 16'hDEAD;
					rd_v[cl - 1 + i] <= 1;
				end else if (i == 0) begin
					automatic logic [15:0] old = mem.exists(base) ? mem[base] : 16'h0;
					mem[base] = {dqm[1] ? old[15:8] : dq[15:8], dqm[0] ? old[7:0] : dq[7:0]};
				end
			end
			if (a[10]) open_[ba] = 0;   // auto-precharge
		end
		3'b010: begin // PRECHARGE
			if (a[10]) for (int b = 0; b < 4; b++) open_[b] = 0; else open_[ba] = 0;
		end
		default: ; // NOP, REFRESH (001), BURST TERMINATE
	endcase
end

endmodule
