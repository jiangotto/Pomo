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
//   - Adapted for Gowin GW1NSR-4C FPGA platform (Gowin_pROM_Noise IP)
//   - Removed Xilinx-specific COLORMODE parameter
//   - Simplified interface for EPD driver use

`timescale 1ns / 1ps
`default_nettype none
module blue_noise_dithering #(
	parameter OUTPUT_BITS = 1   // 1 or 4
) (
	input  wire                      clk,
	input  wire                      rst,
	input  wire [7:0]                vin,       // 8-bit input pixel
	output reg  [OUTPUT_BITS-1:0]    vout,      // dithered output
	input  wire [5:0]                x_pos,     // 0-63
	input  wire [5:0]                y_pos      // 0-63
);

	localparam NOISE_ATTEN = (OUTPUT_BITS == 1) ? 0 : 4;

	wire [11:0] bn_addr = {y_pos, x_pos};
	wire [7:0]  bn_data;

	Gowin_pROM_Noise u_noise_rom (
		.dout  (bn_data),
		.clk   (clk),
		.oce   (1'b1),
		.ce    (1'b1),
		.reset (rst),
		.ad    (bn_addr[11:0])
	);

	wire [7:0] b_signed = {{3{bn_data[7]}}, bn_data[7:NOISE_ATTEN]};
	wire [8:0] a_ext = {1'b0, vin};
	wire [8:0] b_ext = {b_signed[7], b_signed};
	wire [8:0] add   = a_ext + b_ext;
	wire [7:0] c     = add[8] ? (b_signed[7] ? 8'h00 : 8'hFF) : add[7:0];

	wire [OUTPUT_BITS-1:0] vo_dithered = c[7 -: OUTPUT_BITS];

	always @(posedge clk) begin
		vout <= vo_dithered;
	end

endmodule
`default_nettype wire
