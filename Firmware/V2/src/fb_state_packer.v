// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.

`timescale 1ns/1ps

// Converts between Pomo's one-state-per-clock stream and the original 16-bit
// VFB. Four 12-bit states are packed into three 16-bit VFB samples, reducing
// memory traffic from 2 bytes/pixel to 1.5 bytes/pixel without relying on the
// VFB IP's 24<->32-bit converter.
module fb_state_packer #(
	parameter [3:0] STATE_MODE = 4'hC
) (
	input  wire        rst_n,
	input  wire        pixel_wr_clk,
	input  wire        pixel_wr_de,
	input  wire [15:0] pixel_wr_data,
	output wire        packed_wr_de,
	output reg  [15:0] packed_wr_data,
	input  wire        pixel_rd_clk,
	input  wire        pixel_rd_de,
	output wire        packed_rd_de,
	input  wire        packed_rd_den,
	input  wire [15:0] packed_rd_data,
	output wire        pixel_rd_den,
	output wire [15:0] pixel_rd_data
);

	reg [1:0]  wr_phase;
	reg [11:0] wr_state_a;
	reg [7:0]  wr_state_b_hi;
	reg [3:0]  wr_state_c_hi;
	always @(posedge pixel_wr_clk or negedge rst_n) begin
		if (!rst_n) begin
			wr_phase      <= 2'd0;
			wr_state_a    <= 12'd0;
			wr_state_b_hi <= 8'd0;
			wr_state_c_hi <= 4'd0;
		end else if (!pixel_wr_de) begin
			wr_phase <= 2'd0;
		end else begin
			case (wr_phase)
			2'd0: wr_state_a    <= pixel_wr_data[11:0];
			2'd1: wr_state_b_hi <= pixel_wr_data[11:4];
			2'd2: wr_state_c_hi <= pixel_wr_data[11:8];
			default: ;
			endcase
			wr_phase <= wr_phase + 1'b1;
		end
	end

	assign packed_wr_de = pixel_wr_de && (wr_phase != 2'd0);
	always @(*) begin
		case (wr_phase)
		2'd1: packed_wr_data = {pixel_wr_data[3:0],  wr_state_a};
		2'd2: packed_wr_data = {pixel_wr_data[7:0],  wr_state_b_hi};
		2'd3: packed_wr_data = {pixel_wr_data[11:0], wr_state_c_hi};
		default: packed_wr_data = 16'd0;
		endcase
	end

	reg [1:0] rd_request_phase;
	always @(posedge pixel_rd_clk or negedge rst_n) begin
		if (!rst_n)
			rd_request_phase <= 2'd0;
		else if (!pixel_rd_de)
			rd_request_phase <= 2'd0;
		else
			rd_request_phase <= rd_request_phase + 1'b1;
	end

	assign packed_rd_de = pixel_rd_de && (rd_request_phase != 2'd3);

	reg [1:0]  rd_response_phase;
	reg [3:0]  rd_state_b_low;
	reg [7:0]  rd_state_c_low;
	reg [11:0] rd_state_d;
	reg        rd_state_d_valid;
	reg        pixel_rd_de_d;
	always @(posedge pixel_rd_clk or negedge rst_n) begin
		if (!rst_n) begin
			rd_response_phase <= 2'd0;
			rd_state_b_low    <= 4'd0;
			rd_state_c_low    <= 8'd0;
			rd_state_d        <= 12'd0;
			rd_state_d_valid  <= 1'b0;
			pixel_rd_de_d     <= 1'b0;
		end else begin
			pixel_rd_de_d <= pixel_rd_de;
			if (pixel_rd_de && !pixel_rd_de_d) begin
			// Horizontal blanking gives the VFB time to drain the previous line.
			// Re-establish the 3-word/4-pixel boundary at each new active line so
			// a response truncated by a clock/rate change cannot rotate all later
			// 12-bit states.  This is a protocol boundary, not a fixed delay.
			rd_response_phase <= 2'd0;
			rd_state_b_low    <= 4'd0;
			rd_state_c_low    <= 8'd0;
			rd_state_d        <= 12'd0;
			rd_state_d_valid  <= 1'b0;
			end else if (packed_rd_den) begin
			case (rd_response_phase)
			2'd0: begin
				rd_state_b_low <= packed_rd_data[15:12];
				rd_response_phase <= 2'd1;
			end
			2'd1: begin
				rd_state_c_low <= packed_rd_data[15:8];
				rd_response_phase <= 2'd2;
			end
			default: begin
				rd_state_d <= packed_rd_data[15:4];
				rd_state_d_valid <= 1'b1;
				rd_response_phase <= 2'd0;
			end
			endcase
			end else if (rd_state_d_valid) begin
				rd_state_d_valid <= 1'b0;
			end
		end
	end

	assign pixel_rd_den = packed_rd_den || rd_state_d_valid;
	assign pixel_rd_data = packed_rd_den ?
		(rd_response_phase == 2'd0 ? {STATE_MODE, packed_rd_data[11:0]} :
		 rd_response_phase == 2'd1 ? {STATE_MODE, packed_rd_data[7:0], rd_state_b_low} :
		                            {STATE_MODE, packed_rd_data[3:0], rd_state_c_low}) :
		{STATE_MODE, rd_state_d};

endmodule
