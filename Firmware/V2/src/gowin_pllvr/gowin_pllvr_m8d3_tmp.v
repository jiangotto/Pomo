//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW1NSR-LV4CQN48PC7/I6
//Device: GW1NSR-4C
//Created Time: Sun Oct  4 22:04:07 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    Gowin_PLLVR_M8D3 your_instance_name(
        .clkout(clkout), //output clkout
        .lock(lock), //output lock
        .reset(reset), //input reset
        .clkin(clkin), //input clkin
        .odsel(odsel) //input [5:0] odsel
    );

//--------Copy end-------------------
