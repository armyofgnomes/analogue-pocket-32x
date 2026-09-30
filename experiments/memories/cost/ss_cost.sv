// Synthetic measurement of save-state logic cost (Memories exploration).
// N_WORDS x 32-bit registers, each updated every enabled clock by typical datapath logic
// (add/xor/select from neighbours and inputs). With SS=1, every register also gets:
//  - restore: when ss_wr and ss_addr selects it, it loads ss_din instead of its next value
//  - readout: ss_dout = the addressed register (a read mux across all of them)
// With SS=2 instead: a scan chain; ss_wr shifts every register one word along (in at word 0,
// out at the last), so save and restore are serial and there's no read mux.
// Compile both and compare ALMs: the difference is the per-bit cost of a save-state bus.
module ss_cost #(parameter N_WORDS = 64, parameter int SS = 0) (
    input               clk,
    input               en,
    input        [31:0] din,
    input         [5:0] sel,
    output logic [31:0] dout,
    input         [9:0] ss_addr,
    input        [31:0] ss_din,
    input               ss_wr,
    output logic [31:0] ss_dout
);
    (* preserve *) logic [31:0] r [N_WORDS];   // keep all registers in both variants
    always_ff @(posedge clk) begin
        for (int i = 0; i < N_WORDS; i++) begin
            if (SS == 1 && ss_wr && ss_addr == i) r[i] <= ss_din;
            else if (SS == 2 && ss_wr) r[i] <= (i == 0) ? ss_din : r[i - 1];   // scan chain: shift
            else if (en) begin
                case ((sel + i) & 3)
                0: r[i] <= r[(i + 1) % N_WORDS] + din;
                1: r[i] <= r[(i + 3) % N_WORDS] ^ {r[i][30:0], r[i][31]};
                2: r[i] <= (r[i] & din) | r[(i + 7) % N_WORDS];
                3: r[i] <= r[i] - r[(i + 5) % N_WORDS];
                endcase
            end
        end
        dout <= r[sel] ^ r[N_WORDS - 1 - sel];
        ss_dout <= SS == 1 ? r[ss_addr] : SS == 2 ? r[N_WORDS - 1] : 32'd0;
    end
endmodule
