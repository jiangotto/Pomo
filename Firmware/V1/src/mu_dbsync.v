// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2
//
// You may redistribute and modify this source and make products using
// it under the terms of the CERN-OHL-S v2 (https://cern.ch/cern-ohl).
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.

`timescale 1ns / 1ps

module mu_dbsync #(
	parameter W = 8
) (
	input  wire         iclk,
	input  wire         oclk,
	input  wire [W-1:0] in,
	output wire [W-1:0] out
);

	genvar i;
	generate
		for (i = 0; i < W; i = i + 1) begin
			mu_dsync dsync (
				.iclk(iclk),
				.oclk(oclk),
				.in(in[i]),
				.out(out[i])
			);
		end
	endgenerate

endmodule
