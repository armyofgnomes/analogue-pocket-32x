// Sim-only stub for upstream cheatcodes.sv (Game Genie, tied off in s32x_system). The original
// uses parameters in its port list before declaring them, which Questa rejects.
module CODES #(parameter ADDR_WIDTH = 16, parameter DATA_WIDTH = 8, parameter MAX_CODES = 32)
(
	input  clk,
	input  reset,
	input  enable,
	output available,
	input  [ADDR_WIDTH - 1:0] addr_in,
	input  [DATA_WIDTH - 1:0] data_in,
	input  [128:0] code,
	output genie_ovr,
	output [DATA_WIDTH - 1:0] genie_data
);
assign available  = 1'b0;
assign genie_ovr  = 1'b0;
assign genie_data = '0;
endmodule
