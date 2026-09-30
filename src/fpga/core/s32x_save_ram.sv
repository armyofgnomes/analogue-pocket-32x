//
// Cartridge save memory (REQ-SAVE-01): battery-backed SRAM and serial EEPROM storage in one
// 32 KB dual-clock block RAM, which the Pocket loads and saves through a non-volatile data slot.
//
// Port A (clk_sys): the console. A cart with an EEPROM mapper (eeprom_sel) gets the RAM for its
// EEPROM (the first 1 KB; patch 0010 moves that storage out of cart.sv). Every other cart gets
// it for SRAM (cart.sv's SRAM_A is a 68K word address, one byte per word).
// Port B (clk_74a): the APF bridge, 16 bits wide, driven from core_top.v. Port B word k holds
// port A bytes 2k (bits 7:0) and 2k+1 (bits 15:8). The dual-clock RAM is the clock crossing.
//
// Save file layout, the same as MiSTer's Genesis and 32X cores: 64 KB, 2 bytes per 68K SRAM
// word, the data in the odd byte (the 68K's view: SRAM on odd addresses) and 0xFF in the even
// byte. A 32-bit bridge word at file offset 4k is {FF, A[2k], FF, A[2k+1]} (big-endian).
//
// Cart SRAM used to sit on sdram.sv port 2, and the 32X interface (IF.sv) waits for its busy to
// rise and then fall, so the RAM still answers each access with a short busy pulse. Reads return
// the RAM output for the current address continuously (valid one clock after the address
// settles); writes are applied on every clock the write strobe is held, so the value written is
// the one present at its end.
//
module s32x_save_ram
(
	input             clk,

	// Cart SRAM (upstream cart.sv)
	input      [14:0] sram_a,
	input       [7:0] sram_d,
	input             sram_rd,
	input             sram_wr,
	output      [7:0] sram_q,
	output            sram_busy,

	// Cart EEPROM storage (cart.sv with patch 0010)
	input             eeprom_sel,     // the cart has an EEPROM mapper; static while running
	input       [9:0] eeprom_a,
	input       [7:0] eeprom_d,
	input             eeprom_we,
	output      [7:0] eeprom_q,

	// APF bridge side
	input             b_clk,
	input      [13:0] b_a,
	input      [15:0] b_d,
	input             b_we,
	output     [15:0] b_q
);

wire [14:0] a_addr = eeprom_sel ? {5'd0, eeprom_a} : sram_a;
wire  [7:0] a_din  = eeprom_sel ? eeprom_d : sram_d;
wire        a_we   = eeprom_sel ? eeprom_we : sram_wr;
wire  [7:0] a_q;

altsyncram #(
	.operation_mode                     ( "BIDIR_DUAL_PORT" ),
	.intended_device_family             ( "Cyclone V" ),
	.lpm_type                           ( "altsyncram" ),
	.ram_block_type                     ( "M10K" ),
	.width_a                            ( 8 ),
	.widthad_a                          ( 15 ),
	.numwords_a                         ( 32768 ),
	.width_b                            ( 16 ),
	.widthad_b                          ( 14 ),
	.numwords_b                         ( 16384 ),
	.width_byteena_a                    ( 1 ),
	.width_byteena_b                    ( 1 ),
	.address_reg_b                      ( "CLOCK1" ),
	.indata_reg_b                       ( "CLOCK1" ),
	.wrcontrol_wraddress_reg_b          ( "CLOCK1" ),
	.outdata_reg_a                      ( "UNREGISTERED" ),
	.outdata_reg_b                      ( "UNREGISTERED" ),
	.outdata_aclr_a                     ( "NONE" ),
	.outdata_aclr_b                     ( "NONE" ),
	.clock_enable_input_a               ( "BYPASS" ),
	.clock_enable_input_b               ( "BYPASS" ),
	.clock_enable_output_a              ( "BYPASS" ),
	.clock_enable_output_b              ( "BYPASS" ),
	.read_during_write_mode_port_a      ( "NEW_DATA_NO_NBE_READ" ),
	.read_during_write_mode_port_b      ( "NEW_DATA_NO_NBE_READ" ),
	.power_up_uninitialized             ( "FALSE" )
) mem (
	.clock0         ( clk ),
	.address_a      ( a_addr ),
	.data_a         ( a_din ),
	.wren_a         ( a_we ),
	.q_a            ( a_q ),

	.clock1         ( b_clk ),
	.address_b      ( b_a ),
	.data_b         ( b_d ),
	.wren_b         ( b_we ),
	.q_b            ( b_q ),

	.aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
	.byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
	.clocken2(1'b1), .clocken3(1'b1), .rden_a(1'b1), .rden_b(1'b1),
	.eccstatus()
);

assign sram_q   = a_q;
assign eeprom_q = a_q;

// Busy: high for 4 clocks, starting the clock after a read or write strobe rises (as sdram.sv's
// busy did). IF.sv looks at it only on SH-2 clock enables, about every 2.3 clocks.
reg       req_d = 0;
reg [2:0] busy_cnt = 0;
always @(posedge clk) begin
	req_d <= sram_rd | sram_wr;
	if ((sram_rd | sram_wr) & ~req_d) busy_cnt <= 3'd4;
	else if (busy_cnt != 0) busy_cnt <= busy_cnt - 1'd1;
end
assign sram_busy = busy_cnt != 0;

endmodule
