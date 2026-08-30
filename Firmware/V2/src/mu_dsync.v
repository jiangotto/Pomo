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

module mu_dsync (
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire iclk,
	/* verilator lint_on UNUSEDSIGNAL */
	input  wire oclk,
	input  wire in,
	output wire out
);

	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg sync_0;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg sync_1;

	always @(posedge oclk) begin
		sync_0 <= in;
		sync_1 <= sync_0;
	end

	assign out = sync_1;

endmodule