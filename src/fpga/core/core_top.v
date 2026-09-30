//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;


assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
// add your own devices here
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'h6xxxxxxx: begin
        bridge_rd_data <= save_rd_data;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;
    
// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s; 
    wire            status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;
    
    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;
    
    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a

    reg             target_dataslot_read;       
    reg             target_dataslot_write;
    reg             target_dataslot_getfile;    // require additional param/resp structs to be mapped
    reg             target_dataslot_openfile;   // require additional param/resp structs to be mapped
    
    wire            target_dataslot_ack;        
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    reg     [15:0]  target_dataslot_id;
    reg     [31:0]  target_dataslot_slotoffset;
    reg     [31:0]  target_dataslot_bridgeaddr;
    reg     [31:0]  target_dataslot_length;
    
    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands
    
// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),
    
    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    
    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),
    
    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),
    
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    
    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);



////////////////////////////////////////////////////////////////////////////////////////
// Clocks and reset

    wire    clk_sys;        // 53.693181 MHz MCLK
    wire    clk_ram;        // 107.386363 MHz SDRAM
    wire    clk_vid;        // 26.846590 MHz video (MCLK/2)
    wire    clk_vid_90;

    wire    pll_core_locked;
    wire    pll_core_locked_s;
synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);

pll_core mp1 (
    .refclk         ( clk_74a ),
    .rst            ( 0 ),
    .outclk_0       ( clk_sys ),
    .outclk_1       ( clk_ram ),
    .outclk_2       ( clk_vid ),
    .outclk_3       ( clk_vid_90 ),
    .locked         ( pll_core_locked )
);

    wire    reset_n_s;
    wire    pll_locked_sys;
synch_3 s02(reset_n, reset_n_s, clk_sys);
synch_3 s03(pll_core_locked, pll_locked_sys, clk_sys);

////////////////////////////////////////////////////////////////////////////////////////
// ROM loading (data slot 0 at bridge address 0x10000000)

// rom_loading: set when the host starts writing a data slot, cleared when all slots are done.
    reg     rom_loading_74a = 0;
always @(posedge clk_74a) begin
    if (dataslot_requestwrite) rom_loading_74a <= 1;
    else if (dataslot_allcomplete) rom_loading_74a <= 0;
end

    wire    rom_loading_s;
synch_3 s04(rom_loading_74a, rom_loading_s, clk_sys);

// Hold loading (and so reset) a little longer so the loader FIFO drains into SDRAM.
    reg     [11:0]  rom_drain = 0;
    wire            rom_loading = rom_loading_s | (rom_drain != 0);
always @(posedge clk_sys) begin
    if (rom_loading_s) rom_drain <= 12'hFFF;
    else if (rom_drain != 0) rom_drain <= rom_drain - 1'd1;
end

    wire            rom_wr;
    wire    [27:0]  rom_wr_addr;
    wire    [15:0]  rom_wr_data;

data_loader #(
    .ADDRESS_MASK_UPPER_4       ( 4'h1 ),
    .ADDRESS_SIZE               ( 28 ),
    .WRITE_MEM_CLOCK_DELAY      ( 16 ),     // 300 ns per word: SDRAM write + possible refresh
    .WRITE_MEM_EN_CYCLE_LENGTH  ( 2 ),
    .OUTPUT_WORD_SIZE           ( 2 )
) rom_loader (
    .clk_74a                ( clk_74a ),
    .clk_memory             ( clk_sys ),
    .bridge_wr              ( bridge_wr ),
    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_wr_data         ( bridge_wr_data ),
    .write_en               ( rom_wr ),
    .write_addr             ( rom_wr_addr ),
    .write_data             ( rom_wr_data )
);

////////////////////////////////////////////////////////////////////////////////////////
// Save data (non-volatile data slot 10 at bridge address 0x60000000, see data.json)
// The 64 KB save file is loaded while the ROM loads (the console is held in reset until every
// slot is done) and read back by the Pocket when the game is closed. It lives in the console's
// save RAM (s32x_save_ram.sv), whose second port runs on clk_74a and serves the bridge directly.
// Bridge words are big-endian (bridge_endian_little = 0): {FF, data, FF, data}.
//
// Bridge reads: io_bridge_peripheral latches the address, samples bridge_rd_data a few clocks
// later, then pulses bridge_rd; like core_bridge_cmd, the word for the address is latched on
// that pulse (the RAM has been reading that address since it was latched).

    wire    [15:0]  save_q;
    reg     [31:0]  save_rd_data;
    wire            save_sel = bridge_addr[31:28] == 4'h6;
always @(posedge clk_74a) begin
    if (bridge_rd && save_sel) save_rd_data <= {8'hFF, save_q[7:0], 8'hFF, save_q[15:8]};
end

// The save slot's size for the Pocket: data slot index 1 (the second entry in data.json), so
// datatable word 1*2+1.
assign datatable_addr = 10'd3;
assign datatable_wren = 1'b1;
assign datatable_data = 32'd65536;

////////////////////////////////////////////////////////////////////////////////////////
// Settings (interact.json): bridge writes to 0x000000x0 on clk_74a. Reset values match the
// JSON defaults; the Pocket writes the persisted values when the core starts.
//   0x00 Reset (action)          0x10 Region: 0 auto, 1 US, 2 Japan, 3 Europe
//   0x20 6-button pad            0x30 Audio filter: 0 Model 1, 1 Model 2, 2 minimal, 3 none
//   0x40 FM chip: 0 YM2612, 1 YM3438                       0x50 HiFi PCM
//   0x60 Composite blend         0x70 High sprite limit
// Reset, and a region change (which only takes effect at reset), hold the console in reset
// while the Pocket menu is open and for about 1 ms after it closes.

    reg     [1:0]   set_region = 0;
    reg             set_6btn = 0;
    reg     [1:0]   set_lpf = 0;
    reg             set_ym3438 = 0;
    reg             set_hifi = 0;
    reg             set_blend = 0;
    reg             set_spr_high = 0;
    reg     [16:0]  user_reset_cnt = 0;
    wire            user_reset_74a = user_reset_cnt != 0;
always @(posedge clk_74a) begin
    if (user_reset_cnt != 0 && !(osnotify_inmenu && user_reset_cnt == 17'h1FFFF))
        user_reset_cnt <= user_reset_cnt - 1'd1;
    if (bridge_wr && bridge_addr[31:8] == 24'h000000) begin
        case (bridge_addr[7:0])
        8'h00: user_reset_cnt <= 17'h1FFFF;
        8'h10: begin
            set_region <= bridge_wr_data[1:0];
            if (bridge_wr_data[1:0] != set_region) user_reset_cnt <= 17'h1FFFF;
        end
        8'h20: set_6btn      <= bridge_wr_data[0];
        8'h30: set_lpf       <= bridge_wr_data[1:0];
        8'h40: set_ym3438    <= bridge_wr_data[0];
        8'h50: set_hifi      <= bridge_wr_data[0];
        8'h60: set_blend     <= bridge_wr_data[0];
        8'h70: set_spr_high  <= bridge_wr_data[0];
        default: ;
        endcase
    end
end

// Quasi-static: each changes rarely and only matters as a level
    wire    [1:0]   set_region_s, set_lpf_s;
    wire            set_6btn_s, set_ym3438_s, set_hifi_s, set_blend_s, set_spr_high_s, user_reset_s;
synch_3 #(.WIDTH(10)) s07(
    {set_region, set_lpf, set_6btn, set_ym3438, set_hifi, set_blend, set_spr_high, user_reset_74a},
    {set_region_s, set_lpf_s, set_6btn_s, set_ym3438_s, set_hifi_s, set_blend_s, set_spr_high_s, user_reset_s},
    clk_sys);

////////////////////////////////////////////////////////////////////////////////////////
// Controls: Pocket pad -> Genesis pad (same layout as openFPGA-Genesis)
//   Genesis A = Pocket Y, B = B, C = A, X = L, Y = X, Z = R, Start = Start, Mode = Select

    wire    [15:0]  cont1_key_s;
    wire    [15:0]  cont2_key_s;
synch_3 #(.WIDTH(16)) s05(cont1_key[15:0], cont1_key_s, clk_sys);
synch_3 #(.WIDTH(16)) s06(cont2_key[15:0], cont2_key_s, clk_sys);

function [11:0] genesis_pad(input [15:0] k);
    genesis_pad = {
        k[9],   // Z     <- R
        k[6],   // Y     <- X
        k[8],   // X     <- L
        k[14],  // Mode  <- Select
        k[15],  // Start <- Start
        k[4],   // C     <- A
        k[5],   // B     <- B
        k[7],   // A     <- Y
        k[0],   // up
        k[1],   // down
        k[2],   // left
        k[3]    // right
    };
endfunction

////////////////////////////////////////////////////////////////////////////////////////
// Console

    wire    [7:0]   sys_r, sys_g, sys_b;
    wire            sys_ce_pix, sys_hblank, sys_vblank, sys_hs_n, sys_vs_n;
    wire    [1:0]   sys_resolution;
    wire    [15:0]  sys_audio_l, sys_audio_r;
    wire    [35:0]  memtest_status;

s32x_system system (
    .clk_sys        ( clk_sys ),
    .clk_ram        ( clk_ram ),
    .pll_locked     ( pll_locked_sys ),
    .reset          ( ~reset_n_s | ~pll_locked_sys | user_reset_s ),

    .rom_loading    ( rom_loading ),
    .rom_wr         ( rom_wr ),
    .rom_wr_addr    ( rom_wr_addr[23:0] ),
    .rom_wr_data    ( rom_wr_data ),

    .save_clk       ( clk_74a ),
    .save_a         ( bridge_addr[15:2] ),
    .save_d         ( {bridge_wr_data[7:0], bridge_wr_data[23:16]} ),
    .save_we        ( bridge_wr & save_sel ),
    .save_q         ( save_q ),

    .joy_1          ( genesis_pad(cont1_key_s) ),
    .joy_2          ( genesis_pad(cont2_key_s) ),
    .j3but          ( ~set_6btn_s ),

    .region_sel     ( set_region_s ),
    .lpf_mode       ( set_lpf_s ),
    .fm_ym3438      ( set_ym3438_s ),
    .hifi_pcm       ( set_hifi_s ),
    .sprite_high    ( set_spr_high_s ),

    .r              ( sys_r ),
    .g              ( sys_g ),
    .b              ( sys_b ),
    .ce_pix         ( sys_ce_pix ),
    .hblank         ( sys_hblank ),
    .vblank         ( sys_vblank ),
    .hs_n           ( sys_hs_n ),
    .vs_n           ( sys_vs_n ),
    .resolution     ( sys_resolution ),
    .interlace      ( ),
    .field          ( ),
    .pal            ( ),

    .audio_l        ( sys_audio_l ),
    .audio_r        ( sys_audio_r ),

    .SDRAM_DQ       ( dram_dq ),
    .SDRAM_A        ( dram_a ),
    .SDRAM_DQML     ( dram_dqm[0] ),
    .SDRAM_DQMH     ( dram_dqm[1] ),
    .SDRAM_BA       ( dram_ba ),
    .SDRAM_nWE      ( dram_we_n ),
    .SDRAM_nRAS     ( dram_ras_n ),
    .SDRAM_nCAS     ( dram_cas_n ),
    .SDRAM_CLK      ( dram_clk ),
    .SDRAM_CKE      ( dram_cke ),

    .SRAM_A         ( sram_a ),
    .SRAM_DQ        ( sram_dq ),
    .SRAM_OE_N      ( sram_oe_n ),
    .SRAM_WE_N      ( sram_we_n ),
    .SRAM_UB_N      ( sram_ub_n ),
    .SRAM_LB_N      ( sram_lb_n ),

    .memtest_status ( memtest_status )
);

// Memory self-test overlay (MEMTEST builds), over the Genesis picture:
//   Rows y = 8 + 10k (k = 0..7, 8 px tall): SRAM timing setting k (table in memtest.sv).
//   Red = failed at least once, green = passed, yellow = not run yet. A white block at the left
//   edge marks the setting being tested now.
//   Rows 96-111: 32X SDRAM region. Red = failure, green bar length = passes (mod 256), yellow =
//   no pass completed yet.
    reg     [8:0]   ov_x;
    reg     [8:0]   ov_y;
    reg             ov_hbl_prev;
    reg     [23:0]  ov_rgb;
    reg             ov_on;
    reg     [3:0]   ov_k;       // sweep row index (line 8 + 10k), counted per line: no dividers
    reg     [3:0]   ov_ph;      // line within the 10-line row pitch
always @(posedge clk_sys) begin
    if (sys_ce_pix) begin
        ov_hbl_prev <= sys_hblank;
        if (sys_hblank) ov_x <= 0; else ov_x <= ov_x + 1'd1;
        if (sys_vblank) ov_y <= 0;
        else if (sys_hblank & ~ov_hbl_prev) begin
            ov_y <= ov_y + 1'd1;
            if (ov_y + 1'd1 == 9'd8) begin
                ov_k  <= 0;
                ov_ph <= 0;
            end else if (ov_ph == 4'd9) begin
                ov_ph <= 0;
                ov_k  <= ov_k + 1'd1;
            end else begin
                ov_ph <= ov_ph + 1'd1;
            end
        end
    end
end
always @(*) begin
    ov_on  = 0;
    ov_rgb = 24'h000000;
`ifdef MEMTEST
    if (ov_y >= 8 && ov_y < 88 && ov_ph < 4'd8) begin
        ov_on  = 1;
        ov_rgb = (ov_x < 8 && ov_k[2:0] == memtest_status[2:0]) ? 24'hFFFFFF :
                 memtest_status[11 + ov_k[2:0]] ? 24'hFF0000 :
                 memtest_status[3 + ov_k[2:0]]  ? 24'h00FF00 : 24'hFFFF00;
    end
    else if (ov_y >= 96 && ov_y < 112) begin
        ov_on  = 1;
        ov_rgb = memtest_status[35] ? 24'hFF0000 :
                 memtest_status[34:19] == 0 ? 24'hFFFF00 :
                 (ov_x < memtest_status[26:19]) ? 24'h00FF00 : 24'h204020;
    end
`endif
end

////////////////////////////////////////////////////////////////////////////////////////
// Video to the Pocket scaler
//
// clk_vid is MCLK/2 from the same PLL, so the clk_sys -> clk_vid paths below are ordinary
// synchronous paths. Each console pixel (one sys_ce_pix) is latched in the clk_sys domain and
// flagged with a toggle. clk_vid sees each pixel for 4 (H40) or 5 (H32) cycles: the first is
// written (video_skip = 0), the rest are skipped. DE stays high across the whole active line.
// Outside DE, video_rgb[23:13] carries the scaler slot = {V30, H40} (see video.json).

// Composite blend (upstream's cofi): each pixel averaged with the previous one. It delays the
// picture and its sync/blanking by one pixel, with or without blending.
    wire    [7:0]   cf_r, cf_g, cf_b;
    wire            cf_hbl, cf_vbl, cf_hs, cf_vs;
cofi composite_blend (
    .clk        ( clk_sys ),
    .pix_ce     ( sys_ce_pix ),
    .enable     ( set_blend_s ),
    .hblank     ( sys_hblank ),
    .vblank     ( sys_vblank ),
    .hs         ( ~sys_hs_n ),
    .vs         ( ~sys_vs_n ),
    .red        ( sys_r ),
    .green      ( sys_g ),
    .blue       ( sys_b ),
    .hblank_out ( cf_hbl ),
    .vblank_out ( cf_vbl ),
    .hs_out     ( cf_hs ),
    .vs_out     ( cf_vs ),
    .red_out    ( cf_r ),
    .green_out  ( cf_g ),
    .blue_out   ( cf_b )
);

    reg     [23:0]  pix_rgb;
    reg             pix_hs, pix_vs, pix_hbl, pix_vbl;
    reg             pix_tog = 0;
    reg     [1:0]   pix_res;
always @(posedge clk_sys) begin
    if (sys_ce_pix) begin
        pix_rgb <= ov_on ? ov_rgb : {cf_r, cf_g, cf_b};
        pix_hs  <= cf_hs;
        pix_vs  <= cf_vs;
        pix_hbl <= cf_hbl;
        pix_vbl <= cf_vbl;
        pix_res <= sys_resolution;
        pix_tog <= ~pix_tog;
    end
end

    reg     [23:0]  vid_rgb;
    reg             vid_de, vid_skip, vid_hs, vid_vs;
    reg             vid_tog, vid_hs_prev, vid_vs_prev, vid_vbl_line;
always @(posedge clk_vid) begin
    vid_tog <= pix_tog;
    vid_hs  <= 0;
    vid_vs  <= 0;
    vid_skip <= 1;

    if (vid_tog != pix_tog) begin
        // A new console pixel
        vid_skip    <= 0;
        vid_hs_prev <= pix_hs;
        vid_vs_prev <= pix_vs;
        if (pix_hs & ~vid_hs_prev) begin
            vid_hs <= 1;
            // Decide at hsync whether the coming line is visible (vblank toggles mid-line)
            vid_vbl_line <= pix_vbl;
        end
        if (pix_vs & ~vid_vs_prev) vid_vs <= 1;

        vid_de <= ~(pix_hbl | vid_vbl_line);
        vid_rgb <= (pix_hbl | vid_vbl_line) ? {9'd0, pix_res, 13'd0} : pix_rgb;
    end
end

assign video_rgb_clock      = clk_vid;
assign video_rgb_clock_90   = clk_vid_90;
assign video_rgb            = vid_rgb;
assign video_de             = vid_de;
assign video_skip           = vid_de & vid_skip;
assign video_vs             = vid_vs;
assign video_hs             = vid_hs;

////////////////////////////////////////////////////////////////////////////////////////
// Audio

sound_i2s #(
    .CHANNEL_WIDTH  ( 16 ),
    .SIGNED_INPUT   ( 1 )
) sound_i2s (
    .clk_74a        ( clk_74a ),
    .clk_audio      ( clk_sys ),
    .audio_l        ( sys_audio_l ),
    .audio_r        ( sys_audio_r ),
    .audio_mclk     ( audio_mclk ),
    .audio_lrck     ( audio_lrck ),
    .audio_dac      ( audio_dac )
);

endmodule
