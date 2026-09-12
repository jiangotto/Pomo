//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW1NSR-LV4CQN48PC7/I6
//Device: GW1NSR-4C
//Created Time: Wed May  6 14:34:32 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	MIPI_Byte_to_Pixel_Converter_Top your_instance_name(
		.I_RSTN(I_RSTN), //input I_RSTN
		.I_BYTE_CLK(I_BYTE_CLK), //input I_BYTE_CLK
		.I_PIXEL_CLK(I_PIXEL_CLK), //input I_PIXEL_CLK
		.I_SP_EN(I_SP_EN), //input I_SP_EN
		.I_LP_AV_EN(I_LP_AV_EN), //input I_LP_AV_EN
		.I_DT(I_DT), //input [5:0] I_DT
		.I_WC(I_WC), //input [15:0] I_WC
		.I_PAYLOAD_DV(I_PAYLOAD_DV), //input [1:0] I_PAYLOAD_DV
		.I_PAYLOAD(I_PAYLOAD), //input [15:0] I_PAYLOAD
		.O_VSYNC(O_VSYNC), //output O_VSYNC
		.O_HSYNC(O_HSYNC), //output O_HSYNC
		.O_DE(O_DE), //output O_DE
		.O_PIXEL(O_PIXEL), //output [23:0] O_PIXEL
		.o_dt_err(o_dt_err), //output o_dt_err
		.o_wc_err(o_wc_err), //output o_wc_err
		.o_align_err(o_align_err), //output o_align_err
		.o_fifo_full(o_fifo_full), //output o_fifo_full
		.o_fifo_empty(o_fifo_empty) //output o_fifo_empty
	);

//--------Copy end-------------------
