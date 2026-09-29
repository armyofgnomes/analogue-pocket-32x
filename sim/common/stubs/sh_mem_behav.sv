// Sim-only behavioral models of upstream SH_mem.v's SH-2 memories, matching what the Cyclone V
// hardware does (compiled after SH_mem.v, so these definitions replace the altsyncram/altdpram
// based ones in simulation):
//   CACHE_RAM  M10K, DUAL_PORT: write on the rising edge; read address registered on the rising
//              edge, unregistered output (a same-edge write to that address returns the old data)
//   CACHE_TAG, CACHE_LRU, SH_regram  MLAB: write address/data/enable registered on the rising edge,
//              unregistered (asynchronous) read of the current contents
module CACHE_RAM (
	input        wrclock, input [9:0] wraddress, input [7:0] data, input wren,
	input        rdclock, input [9:0] rdaddress, output [7:0] q
);
reg [7:0] mem [0:1023];
reg [7:0] q_r;
initial for (int i = 0; i < 1024; i++) mem[i] = 0;
always @(posedge wrclock) if (wren) mem[wraddress] <= data;
always @(posedge rdclock) q_r <= mem[rdaddress];
assign q = q_r;
endmodule

module CACHE_TAG (
	input clock, input [19:0] data, input [5:0] rdaddress, input [5:0] wraddress, input wren,
	output [19:0] q
);
reg [19:0] mem [0:63];
initial for (int i = 0; i < 64; i++) mem[i] = 0;
always @(posedge clock) if (wren) mem[wraddress] <= data;
assign q = mem[rdaddress];
endmodule

module CACHE_LRU (
	input clock, input [5:0] data, input [5:0] rdaddress, input [5:0] wraddress, input wren,
	output [5:0] q
);
reg [5:0] mem [0:63];
initial for (int i = 0; i < 64; i++) mem[i] = 0;
always @(posedge clock) if (wren) mem[wraddress] <= data;
assign q = mem[rdaddress];
endmodule

module SH_regram (
	input clock, input [31:0] data, input [3:0] rdaddress, input [3:0] wraddress, input wren,
	output [31:0] q
);
reg [31:0] mem [0:15];
initial for (int i = 0; i < 16; i++) mem[i] = 0;
always @(posedge clock) if (wren) mem[wraddress] <= data;
assign q = mem[rdaddress];
endmodule
