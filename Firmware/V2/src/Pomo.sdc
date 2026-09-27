//Copyright (C)2014-2026 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.12 (64-bit) 
//Created Time: 2026-09-27 12:35:28
create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]
create_clock -name mipi_hs_clk -period 2.01 -waveform {0 1.005} [get_ports {mipi_clk_p}]
create_clock -name mipi_byte_clk -period 16.079 -waveform {0 8.04} [get_pins {u_vin_mipi/u_mipi_rx_ip/DPHY_RX_INST/u_idesx8/Inst3_CLKDIV/CLKOUT}]
create_clock -name mipi_pixel_clk -period 12.059 -waveform {0 6.03} [get_pins {u_vin_mipi/u_pll_v_pclk/pllvr_inst/CLKOUT}]
# HyperRAM PLL is 165 MHz; constrain its fabric side at 166 MHz for margin.
create_clock -name memory_clk -period 6.024 -waveform {0 3.012} [get_nets {u_fb_hpram/memory_clk}]
create_generated_clock -name hpram_clk -source [get_nets {u_fb_hpram/memory_clk}] -master_clock memory_clk -divide_by 2 [get_nets {u_fb_hpram/hpram_clk}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {memory_clk hpram_clk}] -group [get_clocks {mipi_hs_clk mipi_byte_clk}] -group [get_clocks {mipi_pixel_clk}]

# DHCEN is the D-PHY's glitchless HS-clock gate. Its CE changes only while
# entering/leaving HS mode, when the serial clock is being stopped or started;
# treating it as a 497 MHz per-bit synchronous data endpoint is not meaningful.
# Keep all actual HS, byte, pixel and payload paths timed.
set_false_path -to [get_pins {u_vin_mipi/u_mipi_rx_ip/DPHY_RX_INST/u_idesx8/u_DHCEN/CE}]

set_multicycle_path -from [get_pins {u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_0_s0/Q u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_1_s0/Q}]  -setup -end 4
set_multicycle_path -from [get_pins {u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_0_s0/Q u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_1_s0/Q}]  -hold -end 3
