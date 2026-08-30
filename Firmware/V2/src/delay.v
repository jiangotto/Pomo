// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2
//
// You may redistribute and modify this source and make products using
// it under the terms of the CERN-OHL-S v2 (https://cern.ch/cern-ohl).
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.

`timescale 1ns/1ps

module delay #(
	parameter integer DEPTH = 1,
	parameter integer WIDTH = 1
)(
	input  wire             clk,
	input  wire             rst,
	input  wire [WIDTH-1:0] din,
	output wire [WIDTH-1:0] dout
);

	reg [WIDTH-1:0] shift [DEPTH-1:0];

	integer i;
	always @(posedge clk) begin
		if (rst) begin
			for (i = 0; i < DEPTH; i = i + 1)
				shift[i] <= {WIDTH{1'b0}};
		end else begin
			shift[0] <= din;
			for (i = 1; i < DEPTH; i = i + 1)
				shift[i] <= shift[i-1];
		end
	end

	assign dout = shift[DEPTH-1];

endmodule