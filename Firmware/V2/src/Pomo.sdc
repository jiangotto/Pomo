//Copyright (C)2014-2026 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.12 (64-bit) 
//Created Time: 2026-05-17 15:10:57
create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]

# Worst-case clocks for 1216x684 RGB888 at 85 Hz:
#   pixel = 1296 * 699 * 85 = 77.000 MHz
#   two-lane byte clock = pixel * 3 / 2 = 115.500 MHz
#   differential D-PHY clock = byte clock * 4 = 462.000 MHz
# The PLL output is dynamically divided, so it cannot be described correctly
# by one static multiply/divide relationship. Constrain the two fabric clocks
# directly at their maximum supported target rates.
create_clock -name mipi_hs_clk -period 2.165 -waveform {0 1.0825} [get_ports {mipi_clk_p}]
create_clock -name mipi_byte_clk -period 8.658 -waveform {0 4.329} [get_pins {u_vin_mipi/u_mipi_rx_ip/DPHY_RX_INST/u_idesx8/Inst3_CLKDIV/CLKOUT}]
create_clock -name mipi_pixel_clk -period 12.987 -waveform {0 6.4935} [get_pins {u_vin_mipi/u_pll_v_pclk/pllvr_inst/CLKOUT}]

create_generated_clock -name memory_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 6 [get_nets {u_fb_hpram/memory_clk}]
create_generated_clock -name hpram_clk -source [get_nets {u_fb_hpram/memory_clk}] -master_clock memory_clk -divide_by 2 [get_nets {u_fb_hpram/hpram_clk}]

# These boundaries all contain explicit synchronizers or asynchronous FIFOs.
# The MIPI pixel PLL is dynamically reset/redivided, so even its nominal 2/3
# ratio does not guarantee a fixed phase relationship to the byte clock.
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {memory_clk hpram_clk}] -group [get_clocks {mipi_hs_clk mipi_byte_clk}] -group [get_clocks {mipi_pixel_clk}]
