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
//   - Shared one noise-ROM read between the 1-bit and 4-bit outputs

`timescale 1ns / 1ps
`default_nettype none
module blue_noise_dithering (
	input  wire       clk,
	input  wire       rst,
	input  wire [7:0] vin,
	output reg        vout_1b,
	output reg  [3:0] vout_4b,
	input  wire [5:0] x_pos,
	input  wire [5:0] y_pos
);

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

	// Preserve the two original attenuation paths exactly, but feed both from
	// the same ROM output instead of instantiating the 4096x8 ROM twice.
	wire [8:0] a_ext = {1'b0, vin};

	wire [7:0] b_signed_1b = bn_data;
	wire [8:0] b_ext_1b = {b_signed_1b[7], b_signed_1b};
	wire [8:0] add_1b = a_ext + b_ext_1b;
	wire [7:0] c_1b = add_1b[8] ?
		(b_signed_1b[7] ? 8'h00 : 8'hFF) : add_1b[7:0];

	wire [7:0] b_signed_4b = {{3{bn_data[7]}}, bn_data[7:4]};
	wire [8:0] b_ext_4b = {b_signed_4b[7], b_signed_4b};
	wire [8:0] add_4b = a_ext + b_ext_4b;
	wire [7:0] c_4b = add_4b[8] ?
		(b_signed_4b[7] ? 8'h00 : 8'hFF) : add_4b[7:0];

	always @(posedge clk) begin
		vout_1b <= c_1b[7];
		vout_4b <= c_4b[7:4];
	end

endmodule
`default_nettype wire
