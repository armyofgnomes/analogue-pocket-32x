//
// Memory self-test (REQ-MEM-06), enabled with the MEMTEST build macro.
//
// Exercises the 32X memories through the same controllers and protocols the 32X will use:
//   - framebuffers: fb_sram.sv, driven like the VDP's draw side (A/D/WE held 6 cycles, RD held
//     6 cycles before sampling). FB_FS alternates so both framebuffers get tested. The display
//     side keeps reading a moving address, as the VDP does, to load the arbiter.
//   - 32X SDRAM: upstream sdram.sv port 0 (0x1000000-0x103FFFF), edge-triggered requests with
//     busy, as S32X's SDR_* port uses it.
// Each pass writes a pattern over the whole region, reads it back and compares, then repeats
// with a different pattern (including byte-lane writes on the SRAM).
//
// All in clk_sys.
//

module memtest
(
	input             clk,
	input             reset,

	// fb_sram VDP-side ports
	output reg [15:0] FB0_A,
	output reg [15:0] FB0_DO,
	output reg  [1:0] FB0_WE,
	output reg        FB0_RD,
	input      [15:0] FB0_DI,
	output reg [15:0] FB1_A,
	output reg [15:0] FB1_DO,
	output reg  [1:0] FB1_WE,
	output reg        FB1_RD,
	input      [15:0] FB1_DI,
	output reg        FB_FS,

	// sdram.sv port 0
	output reg [24:1] sdr_addr,
	output reg        sdr_rd,
	output reg  [1:0] sdr_wr,
	output reg [15:0] sdr_din,
	input      [15:0] sdr_dout,
	input             sdr_busy,

	// Status (for the on-screen overlay)
	output reg [15:0] sram_passes,
	output reg        sram_fail,
	output reg [15:0] sdram_passes,
	output reg        sdram_fail
);

// Pattern: a mix of address and pass number, so stuck/shorted address or data lines show up.
function automatic [15:0] pattern(input [16:0] a, input [15:0] pass);
	pattern = {a[15:0]} ^ {a[7:0], a[15:8]} ^ (pass * 16'h9E37) ^ {15'd0, a[16]};
endfunction

///////////////////////////////////////////////////////////////////////////////
// SRAM via fb_sram

localparam S_WRITE = 2'd0, S_BYTES = 2'd1, S_READ = 2'd2;
reg  [1:0] s_phase;
reg [15:0] s_addr;
reg  [2:0] s_cnt;
reg        s_busy;
reg  [3:0] disp_div;

// FB_FS = 1: FB0 is the draw buffer (tested), FB1 is displayed; and vice versa.
wire [16:0] s_full = {~FB_FS, s_addr};   // SRAM word being tested

always @(posedge clk) begin
	if (reset) begin
		s_phase <= S_WRITE; s_addr <= 0; s_cnt <= 0; s_busy <= 0;
		FB_FS <= 1;
		sram_passes <= 0; sram_fail <= 0;
		FB0_WE <= 0; FB1_WE <= 0; FB0_RD <= 0; FB1_RD <= 0;
		disp_div <= 0;
	end
	else begin
		// Display side: RD held, address stepping every 8 cycles (H40 dot rate).
		disp_div <= disp_div + 1'd1;
		if (FB_FS) begin
			FB1_RD <= 1;
			if (disp_div[2:0] == 0) FB1_A <= FB1_A + 1'd1;
		end else begin
			FB0_RD <= 1;
			if (disp_div[2:0] == 0) FB0_A <= FB0_A + 1'd1;
		end

		if (!s_busy) begin
			s_busy <= 1;
			s_cnt  <= 3'd6;
			case (s_phase)
				S_WRITE, S_BYTES: begin
					// S_WRITE: full words. S_BYTES: overwrite one byte lane with the next pass's
					// pattern, alternating lanes by address.
					if (FB_FS) begin
						FB0_A  <= s_addr;
						FB0_DO <= pattern(s_full, s_phase == S_BYTES ? sram_passes + 1'd1 : sram_passes);
						FB0_WE <= s_phase == S_BYTES ? (s_addr[0] ? 2'b10 : 2'b01) : 2'b11;
						FB0_RD <= 0;
					end else begin
						FB1_A  <= s_addr;
						FB1_DO <= pattern(s_full, s_phase == S_BYTES ? sram_passes + 1'd1 : sram_passes);
						FB1_WE <= s_phase == S_BYTES ? (s_addr[0] ? 2'b10 : 2'b01) : 2'b11;
						FB1_RD <= 0;
					end
				end
				S_READ: begin
					if (FB_FS) begin FB0_A <= s_addr; FB0_RD <= 1; end
					else       begin FB1_A <= s_addr; FB1_RD <= 1; end
				end
			endcase
		end
		else begin
			s_cnt <= s_cnt - 1'd1;
			if (s_cnt == 1) begin
				// End of the 6-cycle hold: drop the strobes (1-cycle gap, like the VDP FIFO).
				FB0_WE <= 0; FB1_WE <= 0;
				if (FB_FS) FB0_RD <= 0; else FB1_RD <= 0;
			end
			if (s_cnt == 0) begin
				s_busy <= 0;
				if (s_phase == S_READ) begin
					// Expected: S_BYTES replaced one lane with the next pass's pattern.
					automatic logic [15:0] p0 = pattern(s_full, sram_passes);
					automatic logic [15:0] p1 = pattern(s_full, sram_passes + 1'd1);
					automatic logic [15:0] exp = s_addr[0] ? {p1[15:8], p0[7:0]} : {p0[15:8], p1[7:0]};
					if ((FB_FS ? FB0_DI : FB1_DI) != exp) sram_fail <= 1;
				end
				s_addr <= s_addr + 1'd1;
				if (s_addr == 16'hFFFF) begin
					case (s_phase)
						S_WRITE: s_phase <= S_BYTES;
						S_BYTES: s_phase <= S_READ;
						default: begin
							s_phase <= S_WRITE;
							FB_FS <= ~FB_FS;
							if (!FB_FS) sram_passes <= sram_passes + 1'd1;
						end
					endcase
				end
			end
		end
	end
end

///////////////////////////////////////////////////////////////////////////////
// 32X SDRAM via sdram.sv port 0 (128K words at 0x1000000)

localparam D_WRITE = 1'b0, D_READ = 1'b1;
reg        d_phase;
reg [16:0] d_addr;
reg  [2:0] d_state;   // 0 issue, 1 wait for busy, 2 wait for idle

always @(posedge clk) begin
	if (reset) begin
		d_phase <= D_WRITE; d_addr <= 0; d_state <= 0;
		sdr_rd <= 0; sdr_wr <= 0;
		sdram_passes <= 0; sdram_fail <= 0;
	end
	else begin
		case (d_state)
			0: begin
				sdr_addr <= {7'b1000000, d_addr};
				if (d_phase == D_WRITE) begin
					sdr_din <= pattern(d_addr, sdram_passes);
					sdr_wr  <= 2'b11;
				end else begin
					sdr_rd  <= 1;
				end
				d_state <= 1;
			end
			1: d_state <= 2;           // sdram.sv registers the request edge; busy rises after
			2: begin
				if (!sdr_busy) begin
					sdr_rd <= 0;
					sdr_wr <= 0;
					if (d_phase == D_READ && sdr_dout != pattern(d_addr, sdram_passes)) sdram_fail <= 1;
					d_addr  <= d_addr + 1'd1;
					if (d_addr == 17'h1FFFF) begin
						d_phase <= ~d_phase;
						if (d_phase == D_READ) sdram_passes <= sdram_passes + 1'd1;
					end
					d_state <= 3;
				end
			end
			default: d_state <= 0;     // one idle cycle so the next request is a fresh edge
		endcase
	end
end

endmodule
