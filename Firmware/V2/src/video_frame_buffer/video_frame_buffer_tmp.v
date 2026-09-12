//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW1NSR-LV4CQN48PC6/I5
//Device: GW1NSR-4C
//Created Time: Sun Jul 26 11:11:15 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	Video_Frame_Buffer_Top your_instance_name(
		.I_rst_n(I_rst_n), //input I_rst_n
		.I_dma_clk(I_dma_clk), //input I_dma_clk
		.I_vin0_clk(I_vin0_clk), //input I_vin0_clk
		.I_vin0_vs_n(I_vin0_vs_n), //input I_vin0_vs_n
		.I_vin0_de(I_vin0_de), //input I_vin0_de
		.I_vin0_data(I_vin0_data), //input [15:0] I_vin0_data
		.O_vin0_fifo_full(O_vin0_fifo_full), //output O_vin0_fifo_full
		.I_vout0_clk(I_vout0_clk), //input I_vout0_clk
		.I_vout0_vs_n(I_vout0_vs_n), //input I_vout0_vs_n
		.I_vout0_de(I_vout0_de), //input I_vout0_de
		.O_vout0_den(O_vout0_den), //output O_vout0_den
		.O_vout0_data(O_vout0_data), //output [15:0] O_vout0_data
		.O_vout0_fifo_empty(O_vout0_fifo_empty), //output O_vout0_fifo_empty
		.O_cmd(O_cmd), //output O_cmd
		.O_cmd_en(O_cmd_en), //output O_cmd_en
		.O_addr(O_addr), //output [21:0] O_addr
		.O_wr_data(O_wr_data), //output [31:0] O_wr_data
		.O_data_mask(O_data_mask), //output [3:0] O_data_mask
		.I_rd_data_valid(I_rd_data_valid), //input I_rd_data_valid
		.I_rd_data(I_rd_data), //input [31:0] I_rd_data
		.I_init_calib(I_init_calib) //input I_init_calib
	);

//--------Copy end-------------------
