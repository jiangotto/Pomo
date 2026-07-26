//Copyright (C)2014-2026 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.12 (64-bit) 
//Created Time: 2026-05-17 15:10:57
create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]
create_generated_clock -name memory_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 6 [get_nets {u_fb_hpram/memory_clk}]
create_generated_clock -name hpram_clk -source [get_nets {u_fb_hpram/memory_clk}] -master_clock memory_clk -divide_by 2 [get_nets {u_fb_hpram/hpram_clk}]
