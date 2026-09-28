# MCLK, NTSC: 53.693175 MHz, same as S32X_MiSTer's clk_sys.
create_clock -name clk_sys -period 18.624 [get_ports clk_sys]
derive_clock_uncertainty
