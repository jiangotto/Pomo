//Copyright (C)2014-2026 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.12 (64-bit) 
//Created Time: 2026-05-17 15:10:57
create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]

# Validation target for the current 1376x709 RGB888 raster at 75 Hz:
#   pixel = 1376 * 709 * 75 = 73.169 MHz
#   two-lane 1:8 byte clock = pixel * 3 / 2 = 109.753 MHz
#   differential D-PHY clock = byte clock * 4 = 439.013 MHz
# The PLL output is dynamically divided, so it cannot be described correctly
# by one static multiply/divide relationship. Constrain the two fabric clocks
# directly at the 75 Hz validation rates.
create_clock -name mipi_hs_clk -period 2.278 -waveform {0 1.139} [get_ports {mipi_clk_p}]
create_clock -name mipi_byte_clk -period 9.111 -waveform {0 4.5555} [get_pins {u_vin_mipi/u_mipi_rx_ip/DPHY_RX_INST/u_idesx8/Inst3_CLKDIV/CLKOUT}]
create_clock -name mipi_pixel_clk -period 13.667 -waveform {0 6.8335} [get_pins {u_vin_mipi/u_pll_v_pclk/pllvr_inst/CLKOUT}]

# The HyperRAM PLL currently runs at 165 MHz. Close its fabric at 185 MHz
# for margin; this constraint does not change the PLL's output frequency.
create_clock -name memory_clk -period 5.405 -waveform {0 2.7025} [get_nets {u_fb_hpram/memory_clk}]
create_generated_clock -name hpram_clk -source [get_nets {u_fb_hpram/memory_clk}] -master_clock memory_clk -divide_by 2 [get_nets {u_fb_hpram/hpram_clk}]

# These boundaries all contain explicit synchronizers or asynchronous FIFOs.
# The MIPI pixel PLL is dynamically reset/redivided, so even its nominal 2/3
# ratio does not guarantee a fixed phase relationship to the byte clock.
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {memory_clk hpram_clk}] -group [get_clocks {mipi_hs_clk mipi_byte_clk}] -group [get_clocks {mipi_pixel_clk}]

# FIFO accesses are held off for four clocks after reset release.  The
# generated FIFO reset fanout is therefore a four-cycle startup path, not a
# single-cycle runtime data path.  Preserve hold analysis with N-1 cycles.
set_multicycle_path 4 -setup -from [get_pins {u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_0_s0/Q u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_1_s0/Q}]
set_multicycle_path 3 -hold  -from [get_pins {u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_0_s0/Q u_vin_mipi/u_pixel_converter/u_fifo/fifo_inst/reset_w_1_s0/Q}]
