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
//   - Adapted for Gowin GW1NSR-4C FPGA platform (Gowin_pROM_LUT16 IP)
//   - Replaced Xilinx dual-port BRAM with single read port
//   - Removed write port (LUT pre-initialized in IP config)
//   - Simplified interface for EPD driver use

`timescale 1ns / 1ps

module wvfmlut(
	input  wire        clk,
	input  wire        rst,
	input  wire        en,
	input  wire [13:0] addr,
	output wire [1:0]  dout
);

	reg  [1:0] bsel;
	wire [7:0] bram_dout;

	always @(posedge clk) begin
		if (en)
			bsel <= addr[1:0];
	end

	Gowin_pROM_LUT16 bram_rom0(
		.dout  (bram_dout),
		.clk   (clk),
		.oce   (1'b1),
		.ce    (en),
		.reset (rst),
		.ad    (addr[13:2])
	);

	assign dout =
		(bsel == 2'd0) ? bram_dout[1:0] :
		(bsel == 2'd1) ? bram_dout[3:2] :
		(bsel == 2'd2) ? bram_dout[5:4] :
						 bram_dout[7:6];

endmodule