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

// === EPD PMIC selection ===
// V2 boards are assembled with SY7636A by default. Comment this line out to
// build the pin-compatible TPS65185 control path instead.
`define PMIC_SY7636A

// === EPD source bus width ===
// The processing pipeline produces one 2-bit pixel per clock. The Source
// adapter derives its half-word cadence from this physical bus width.
`define EPD_OUTPUT_WIDTH    16

// === Internal video test source ===
// Uncomment EPD_INTERNAL_TEST to build a self-contained test bitstream which
// does not require a MIPI clock or data source. The generated raster still
// passes through pixel reorder (when enabled), dithering, waveform processing,
// framebuffer and the normal EPD output path.
//`define EPD_INTERNAL_TEST
`define EPD_TEST_PATTERN_MODE       9
`define EPD_TEST_PATTERN_FPS        85
`define EPD_TEST_CHANGE_FRAMES      85
`define EPD_TEST_SYS_CLK_HZ         27000000

// Number of CKV shifts from sampling STV through the shift immediately before
// G1 is selected. Unlike the MIPI vertical porches, this is a panel property.
`define EPD_STV_TO_G1_CKV  4

`define DEFAULT_VFP         8'd3
`define DEFAULT_VSYNC       8'd8
`define DEFAULT_VBP         8'd6
`define DEFAULT_VACT        10'd684
`define DEFAULT_HFP         8'd48
`define DEFAULT_HSYNC       8'd32
`define DEFAULT_HBP         8'd160
`define DEFAULT_HACT        12'd1216

// ET073TC1-style array mapping:
//   logical 2W x H MIPI image -> physical W x 2H source/gate array
//   physical(x, 2*y)     = logical(2*x,     y)
//   physical(x, 2*y + 1) = logical(2*x + 1, y)
// DEFAULT_* always describes the MIPI input. Comment this line out for a
// conventional panel whose logical and physical raster are identical.
// Reorder mode requires an even DEFAULT_HACT, even input HTOTAL and VFP >= 1.
//`define EPD_PIXEL_REORDER

`ifdef EPD_PIXEL_REORDER
`define EPD_HACT            (`DEFAULT_HACT / 2)
`define EPD_VACT            (`DEFAULT_VACT * 2)
`else
`define EPD_HACT            `DEFAULT_HACT
`define EPD_VACT            `DEFAULT_VACT
`endif

// === 系统运行模式（pomo.v → pixel_processing.v）===
`define SYS_NORMAL          2'b00
`define SYS_CLEAR           2'b01

// 32 startup frames: 14 black, 2 no-drive, 14 white, 2 no-drive.
// CLEAR_FRAMES is the final zero-based frame index.
`define CLEAR_FRAMES        10'd31
`define LUT_FRAMES          6'd48

// === 默认启动模式（选一个取消注释）===
//`define INIT_MODE_FAST_MONO
//`define INIT_MODE_FAST_MONO_BN
//`define INIT_MODE_FAST_GREY
`define INIT_MODE_AUTO_LUT
//`define INIT_MODE_AUTO_LUT_BN
//`define INIT_MODE_MANUAL_LUT
//`define INIT_MODE_MANUAL_LUT_BN

// === DYFRC ===
`define DEFAULT_MINDRV      2'd2    // DYFRC 默认值（caster CSR_MINDVR）

`define VCOM_VOL            13'd1330 // 1310; 2250;
