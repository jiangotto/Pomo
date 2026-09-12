//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW1NSR-LV4CQN48PC6/I5
//Device: GW1NSR-4C
//Created Time: Wed Sep  9 20:52:15 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	HyperRAM_Memory_Interface_Top your_instance_name(
		.clk(clk), //input clk
		.memory_clk(memory_clk), //input memory_clk
		.pll_lock(pll_lock), //input pll_lock
		.rst_n(rst_n), //input rst_n
		.O_hpram_ck(O_hpram_ck), //output [0:0] O_hpram_ck
		.O_hpram_ck_n(O_hpram_ck_n), //output [0:0] O_hpram_ck_n
		.IO_hpram_dq(IO_hpram_dq), //inout [7:0] IO_hpram_dq
		.IO_hpram_rwds(IO_hpram_rwds), //inout [0:0] IO_hpram_rwds
		.O_hpram_cs_n(O_hpram_cs_n), //output [0:0] O_hpram_cs_n
		.O_hpram_reset_n(O_hpram_reset_n), //output [0:0] O_hpram_reset_n
		.wr_data(wr_data), //input [31:0] wr_data
		.rd_data(rd_data), //output [31:0] rd_data
		.rd_data_valid(rd_data_valid), //output rd_data_valid
		.addr(addr), //input [21:0] addr
		.cmd(cmd), //input cmd
		.cmd_en(cmd_en), //input cmd_en
		.init_calib(init_calib), //output init_calib
		.clk_out(clk_out), //output clk_out
		.data_mask(data_mask) //input [3:0] data_mask
	);

//--------Copy end-------------------
