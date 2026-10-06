// Copyright Yuhan Jiang 2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.

`timescale 1ns / 1ps

// Receive DSI short-packet headers sent in D-PHY LPDT on data lane 0.
// This is a passive tap on the PHY's LP line-state outputs; the HS data and
// ready pipelines are not involved. clk must remain available before HS starts.
module mipi_lpdt_rx (
	input  wire        clk,
	input  wire        rst_n,
	input  wire [1:0]  lp_data0,
	output reg         sp_en,
	output reg  [5:0]  dt,
	output reg  [15:0] wc
);
	localparam [2:0] STOP       = 3'd0,
	                 ESC_10     = 3'd1,
	                 ESC_00     = 3'd2,
	                 ESC_01     = 3'd3,
	                 MARK       = 3'd4,
	                 SPACE      = 3'd5;

	// LP11 -> LP10 -> LP00 -> LP01 -> LP00 enters Escape mode. Each
	// subsequent bit is a Mark (LP01=0, LP10=1) followed by Space (LP00).
	// The first byte is the LPDT escape command, 0x87, transmitted LSB first.
	(* ASYNC_REG = "TRUE" *) reg [1:0] lp_sync0, lp_sync1;
	reg [1:0] lp_prev;
	reg [2:0] state;
	reg       escape_command;
	reg [2:0] bit_count;
	reg [7:0] shift_byte;
	reg [1:0] header_count;
	reg [23:0] header;

	function [7:0] header_ecc;
		input [23:0] d;
		begin
			header_ecc[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
			header_ecc[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
			header_ecc[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
			header_ecc[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
			header_ecc[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
			header_ecc[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
			header_ecc[7:6] = 2'b00;
		end
	endfunction

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			lp_sync0       <= 2'b11;
			lp_sync1       <= 2'b11;
			lp_prev        <= 2'b11;
			state          <= STOP;
			escape_command <= 1'b0;
			bit_count      <= 3'd0;
			shift_byte     <= 8'd0;
			header_count   <= 2'd0;
			header         <= 24'd0;
			sp_en          <= 1'b0;
			dt             <= 6'd0;
			wc             <= 16'd0;
		end else begin
			lp_sync0 <= lp_data0;
			lp_sync1 <= lp_sync0;
			lp_prev  <= lp_sync1;
			sp_en    <= 1'b0;

			// LPDT is self-clocked: consume a symbol only when the synchronized
			// LP state changes. LP00 may be held indefinitely between bits.
			if (lp_sync1 != lp_prev) begin
				if (lp_sync1 == 2'b11) begin
					state <= STOP;
				end else begin
					case (state)
						STOP: begin
							if (lp_prev == 2'b11 && lp_sync1 == 2'b10)
								state <= ESC_10;
						end
						ESC_10: state <= (lp_sync1 == 2'b00) ? ESC_00 : STOP;
						ESC_00: state <= (lp_sync1 == 2'b01) ? ESC_01 : STOP;
						ESC_01: begin
							if (lp_sync1 == 2'b00) begin
								state          <= MARK;
								escape_command <= 1'b1;
								bit_count      <= 3'd0;
								header_count   <= 2'd0;
							end else state <= STOP;
						end
						MARK: begin
							if (lp_sync1 == 2'b01 || lp_sync1 == 2'b10) begin
								shift_byte <= {lp_sync1 == 2'b10, shift_byte[7:1]};
								state <= SPACE;
							end else state <= STOP;
						end
						SPACE: begin
							if (lp_sync1 == 2'b00) begin
								state <= MARK;
								bit_count <= bit_count + 1'b1;
								if (bit_count == 3'd7) begin
									if (escape_command) begin
										if (shift_byte == 8'h87)
											escape_command <= 1'b0;
										else state <= STOP;
									end else if (header_count == 2'd3) begin
										// Only short packets have a four-byte wire image.
										// Ignore other DTs instead of treating long-packet
										// payload bytes as additional command headers.
										if (header[5:0] == 6'h23 &&
										    shift_byte == header_ecc(header)) begin
											dt <= header[5:0];
											wc <= header[23:8];
											sp_en <= 1'b1;
											header_count <= 2'd0;
										end else begin
											state <= STOP;
										end
									end else begin
										header <= {shift_byte, header[23:8]};
										header_count <= header_count + 1'b1;
									end
								end
							end else state <= STOP;
						end
						default: state <= STOP;
					endcase
				end
			end
		end
	end
endmodule
