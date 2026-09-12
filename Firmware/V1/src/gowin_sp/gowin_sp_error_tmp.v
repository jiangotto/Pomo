//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW1NSR-LV4CQN48PC7/I6
//Device: GW1NSR-4C
//Created Time: Thu Jun 18 00:39:46 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    Gowin_SP_Error your_instance_name(
        .dout(dout), //output [8:0] dout
        .clk(clk), //input clk
        .oce(oce), //input oce
        .ce(ce), //input ce
        .reset(reset), //input reset
        .wre(wre), //input wre
        .ad(ad), //input [9:0] ad
        .din(din) //input [8:0] din
    );

//--------Copy end-------------------
