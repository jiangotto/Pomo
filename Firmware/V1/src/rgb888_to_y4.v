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
// This file is derived from rgb2y.v from the Caster project
// (CERN-OHL-P v2, Copyright Wenting Zhang 2024).
// A copy of CERN-OHL-P v2 is provided in LICENSE-CERN-OHL-P.
//
// Modified by Yuhan Jiang on 2025-2026:
//   - Adapted from 6-bit RGB to 4-bit Y (luminance-only) output
//   - Replaced DSP multiplier approach with shifter-based calculation
//   - Uses fixed coefficients: Y = (R*2 + G*5 + B*1) / 128

`timescale 1ns / 1ps

module rgb888_to_y4(
	input  wire [7:0] r,
	input  wire [7:0] g,
	input  wire [7:0] b,
	output wire [3:0] y
);

	// Y_8bit ≈ (R*2 + G*5 + B*1) / 8 
	// Y_4bit = Y_8bit / 16 = (R*2 + G*5 + B) / 128
	wire [10:0] g_x5 = {1'b0, g, 2'b00} + {3'd0, g}; 
	wire [10:0] r_x2 = {2'd0, r, 1'b0};
	wire [10:0] sum = g_x5 + r_x2 + {3'd0, b};
	
	assign y = sum[10:7];

endmodule