// Copyright Wenting Zhang 2024
// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2
//
// You may redistribute and modify this source and make products using
// it under the terms of the CERN-OHL-S v2 (https://cern.ch/cern-ohl).
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.
//
// This file incorporates source code from the Caster project
// (CERN-OHL-P v2, Copyright Wenting Zhang 2024).
// A copy of CERN-OHL-P v2 is provided in LICENSE-CERN-OHL-P.
//
// Modified by Yuhan Jiang on 2025-2026:
//   - Adapted for Pomo EPD driver board display timing parameters
//   - Added SYS_NORMAL/SYS_CLEAR system modes
//   - Added auto-clear and LUT frame configurations
//   - Added VCOM voltage configuration

`define DEFAULT_VFP         8'd1
`define DEFAULT_VSYNC       8'd8
`define DEFAULT_VBP         8'd6
`define DEFAULT_VACT        10'd480
`define DEFAULT_HFP         8'd8
`define DEFAULT_HSYNC       8'd32
`define DEFAULT_HBP         8'd40
`define DEFAULT_HACT        10'd800

`define DEFAULT_FPS         85
`define AUTO_CLEAR_PERIOD   5
`define AUTO_CLEAR_FRAMES   (`DEFAULT_FPS * `AUTO_CLEAR_PERIOD)

// === 系统运行模式（pomo.v → pixel_processing.v）===
`define SYS_NORMAL          2'b00
`define SYS_CLEAR           2'b01

`define CLEAR_FRAMES        10'd32 
`define LUT_FRAMES          6'd43

// === 默认启动模式（选一个取消注释）===
`define INIT_MODE_FAST_MONO
//`define INIT_MODE_FAST_MONO_BN
//`define INIT_MODE_FAST_GREY
//`define INIT_MODE_AUTO_LUT
//`define INIT_MODE_AUTO_LUT_BN
//`define INIT_MODE_MANUAL_LUT
//`define INIT_MODE_MANUAL_LUT_BN

// === DYFRC ===
`define DEFAULT_MINDRV      2'd1    // DYFRC 默认值（caster CSR_MINDVR）

`define VCOM_VOL            13'd2250 // 1310; 2250;