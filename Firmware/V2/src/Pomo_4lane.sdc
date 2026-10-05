# MIPI_RX_LANES=4. Select this file in Pomo.gprj with defines.vh set to 4.
# 1306 x 714 total pixels at 85 Hz: pixel 79.261 MHz,
# lane bit rate 475.567 Mbps (RGB888), HS clock 237.783 MHz,
# 1:16 word clock 29.723 MHz. Clocks below include about 1% margin.
create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]
create_clock -name mipi_hs_clk -period 4.160 -waveform {0 2.080} [get_ports {mipi_clk_p}]
create_clock -name mipi_byte_clk -period 33.280 -waveform {0 16.640} [get_pins {u_vin_mipi/u_mipi_rx_custom/u_word_clock_divider/CLKOUT}]
create_clock -name mipi_pixel_clk -period 12.500 -waveform {0 6.250} [get_pins {u_vin_mipi/g_pixel_pll_4lane.u_pll_v_pclk/pllvr_inst/CLKOUT}]
# HyperRAM PLL is 165 MHz; constrain its fabric side at 166 MHz.
create_clock -name memory_clk -period 6.024 -waveform {0 3.012} [get_nets {u_fb_hpram/memory_clk}]
create_generated_clock -name hpram_clk -source [get_nets {u_fb_hpram/memory_clk}] -master_clock memory_clk -divide_by 2 [get_nets {u_fb_hpram/hpram_clk}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {memory_clk hpram_clk}] -group [get_clocks {mipi_hs_clk mipi_byte_clk}] -group [get_clocks {mipi_pixel_clk}]

# DHCEN's CE changes only at HS burst start/stop, not on every HS bit.
set_false_path -to [get_pins {u_vin_mipi/u_mipi_rx_custom/u_hs_clock_enable/CE}]
set_multicycle_path -from [get_pins {u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_0_s0/Q u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_1_s0/Q}] -setup -end 4
set_multicycle_path -from [get_pins {u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_0_s0/Q u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_1_s0/Q}] -hold -end 3
