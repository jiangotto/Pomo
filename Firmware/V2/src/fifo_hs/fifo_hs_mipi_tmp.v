//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW1NSR-LV4CQN48PC7/I6
//Device: GW1NSR-4C
//Created Time: Sat Sep 19 11:01:09 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	FIFO_HS_MIPI_Top your_instance_name(
		.Data(Data), //input [23:0] Data
		.Reset(Reset), //input Reset
		.WrClk(WrClk), //input WrClk
		.RdClk(RdClk), //input RdClk
		.WrEn(WrEn), //input WrEn
		.RdEn(RdEn), //input RdEn
		.Q(Q), //output [23:0] Q
		.Empty(Empty), //output Empty
		.Full(Full) //output Full
	);

//--------Copy end-------------------
