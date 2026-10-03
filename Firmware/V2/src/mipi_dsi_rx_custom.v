// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
//
// Parameterizable MIPI DSI packet parser. Each lane supplies two chronological
// bytes per word. Generate-time specialisation keeps the active 1/2/4-lane
// datapath shallow; there is no run-time lane-width mux or byte-loop FSM.

`timescale 1ns / 1ps

module mipi_dsi_rx_custom #(
	parameter integer LANES = 2
) (
	input  wire                    reset_n,
	input  wire                    clk_word,
	input  wire                    ready,
	input  wire [5:0]              ref_dt,
	input  wire [LANES*16-1:0]     data_in,
	output reg                     sp_en,
	output reg                     lp_en,
	output reg                     lp_av_en,
	output reg                     ecc_ok,
	output reg  [7:0]              ecc,
	output reg  [15:0]             wc,
	output reg  [1:0]              vc,
	output reg  [5:0]              dt,
	output reg  [LANES*16-1:0]     payload,
	output reg  [LANES*2-1:0]      payload_dv,
	output reg                     long_packet_done,
	output reg                     payload_crc_ok
);
	localparam [2:0] ST_SYNC    = 3'd0;
	localparam [2:0] ST_HEADER  = 3'd1;
	localparam [2:0] ST_PAYLOAD = 3'd2;
	localparam [2:0] ST_HOLD    = 3'd3;
	localparam [2:0] ST_CRC     = 3'd4;

	reg [2:0] state;
	reg [1:0] header_count;
	reg [23:0] header_prefix;
	reg [15:0] payload_remaining;
	reg [15:0] crc_reg;
	reg [16:0] crc_bytes_remaining;
	reg        crc_header_ok;

	function [15:0] crc16_byte;
		input [15:0] crc_in;
		input [7:0] data_byte;
		integer bit_index;
		reg [15:0] crc_work;
		begin
			crc_work = crc_in;
			for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
				if (crc_work[0] ^ data_byte[bit_index])
					crc_work = (crc_work >> 1) ^ 16'h8408;
				else
					crc_work = crc_work >> 1;
			end
			crc16_byte = crc_work;
		end
	endfunction

	function [15:0] crc16_bytes;
		input [15:0] crc_in;
		input [63:0] bytes;
		input [3:0] byte_count;
		integer byte_index;
		reg [15:0] crc_work;
		begin
			crc_work = crc_in;
			for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
				if (byte_index < byte_count)
					crc_work = crc16_byte(crc_work,
						bytes[byte_index*8 +: 8]);
			crc16_bytes = crc_work;
		end
	endfunction

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

	function [7:0] valid_mask8;
		input [3:0] count;
		begin
			case (count)
				0: valid_mask8 = 8'h00;
				1: valid_mask8 = 8'h01;
				2: valid_mask8 = 8'h03;
				3: valid_mask8 = 8'h07;
				4: valid_mask8 = 8'h0f;
				5: valid_mask8 = 8'h1f;
				6: valid_mask8 = 8'h3f;
				7: valid_mask8 = 8'h7f;
				default: valid_mask8 = 8'hff;
			endcase
		end
	endfunction

	function [3:0] valid_mask4;
		input [2:0] count;
		begin
			case (count)
				0: valid_mask4 = 4'h0;
				1: valid_mask4 = 4'h1;
				2: valid_mask4 = 4'h3;
				3: valid_mask4 = 4'h7;
				default: valid_mask4 = 4'hf;
			endcase
		end
	endfunction

	// DSI long packets carry WC payload bytes followed by a two-byte CRC.  All
	// other packet types have a four-byte short header and no payload/CRC.
	function is_long_packet;
		input [5:0] packet_dt;
		begin
			case (packet_dt)
				6'h09, 6'h19, 6'h29, 6'h39,
				6'h0c, 6'h1c, 6'h2c, 6'h3c,
				6'h0e, 6'h1e, 6'h2e, 6'h3e:
					is_long_packet = 1'b1;
				default: is_long_packet = 1'b0;
			endcase
		end
	endfunction

	task latch_header;
		input [31:0] h;
		begin
			dt <= h[5:0];
			vc <= h[7:6];
			wc <= h[23:8];
			ecc <= h[31:24];
			ecc_ok <= (h[31:24] == header_ecc(h[23:0]));
		end
	endtask

	generate
		if (LANES == 2) begin : g_parser_2lane
			wire sync_first = (data_in[7:0] == 8'hb8) &&
			                  (data_in[23:16] == 8'hb8);
			wire sync_second = (data_in[15:8] == 8'hb8) &&
			                   (data_in[31:24] == 8'hb8);
			wire [31:0] ordered_word = {
				data_in[31:24], data_in[15:8], data_in[23:16], data_in[7:0]};
			wire [31:0] split_header = {
				ordered_word[15:0], header_prefix[15:0]};
			reg packet_is_ref;
			reg [15:0] crc_next;
			reg [3:0] crc_take;

			always @(posedge clk_word or negedge reset_n) begin
				if (!reset_n || !ready) begin
					state <= ST_SYNC; header_count <= 0; header_prefix <= 0; payload_remaining <= 0;
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0;
					ecc <= 0; wc <= 0; vc <= 0; dt <= 0; payload <= 0; payload_dv <= 0;
					packet_is_ref <= 0;
					crc_reg <= 16'hffff; crc_bytes_remaining <= 0; crc_header_ok <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
				end else begin
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0;
					payload <= 0; payload_dv <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;

					// Once a long header has armed the checker, consume the raw
					// payload and its two CRC bytes independent of DT and WC.
					// A correct transmitted checksum drives the running CRC to zero.
					if (crc_bytes_remaining != 0) begin
						crc_take = (crc_bytes_remaining >= 4) ? 4 :
						           crc_bytes_remaining[3:0];
						crc_next = crc16_bytes(crc_reg, {32'd0, ordered_word}, crc_take);
						crc_reg <= crc_next;
						if (crc_bytes_remaining <= 4) begin
							crc_bytes_remaining <= 0;
							long_packet_done <= 1'b1;
							payload_crc_ok <= crc_header_ok && (crc_next == 16'd0);
						end else begin
							crc_bytes_remaining <= crc_bytes_remaining - 4;
						end
					end
					case (state)
						ST_SYNC, ST_HOLD: begin
							if (sync_first) begin
								header_prefix[15:0] <= ordered_word[31:16];
								header_count <= 2;
								state <= ST_HEADER;
							end else if (sync_second) begin
								header_count <= 0;
								state <= ST_HEADER;
							end
						end

						ST_HEADER: begin
							if (header_count == 0) begin
								latch_header(ordered_word);
								if (ordered_word == 32'h010f0f08) begin
									state <= ST_HOLD;
								end else if (is_long_packet(ordered_word[5:0])) begin
									crc_reg <= 16'hffff;
									crc_bytes_remaining <= {1'b0, ordered_word[23:8]} + 17'd2;
									crc_header_ok <=
										(ordered_word[31:24] == header_ecc(ordered_word[23:0]));
									packet_is_ref <= (ordered_word[5:0] == ref_dt);
									payload_remaining <= ordered_word[23:8];
									if (ordered_word[5:0] == ref_dt) begin
										lp_en <= 1; lp_av_en <= 1;
									end
									state <= (ordered_word[23:8] == 0) ? ST_CRC : ST_PAYLOAD;
								end else begin
									sp_en <= 1;
									state <= ST_HEADER;
								end
							end else begin
								latch_header(split_header);
								if (split_header == 32'h010f0f08) begin
									state <= ST_HOLD;
								end else if (is_long_packet(split_header[5:0])) begin
									crc_header_ok <=
										(split_header[31:24] == header_ecc(split_header[23:0]));
									crc_next = crc16_bytes(16'hffff,
										{48'd0, ordered_word[31:16]},
										4'd2);
									crc_reg <= crc_next;
									if (({1'b0, split_header[23:8]} + 17'd2) <= 2) begin
										crc_bytes_remaining <= 0;
										long_packet_done <= 1'b1;
										payload_crc_ok <=
											(split_header[31:24] == header_ecc(split_header[23:0])) &&
											(crc_next == 16'd0);
									end else begin
										crc_bytes_remaining <=
											{1'b0, split_header[23:8]};
									end
									packet_is_ref <= (split_header[5:0] == ref_dt);
									if (split_header[5:0] == ref_dt) begin
										lp_en <= 1; lp_av_en <= 1;
										payload[15:0] <= ordered_word[31:16];
										if (split_header[23:8] >= 2)
											payload_dv <= 4'b0011;
										else if (split_header[23:8] == 1)
											payload_dv <= 4'b0001;
									end
									if (split_header[23:8] > 2) begin
										payload_remaining <= split_header[23:8] - 16'd2;
										state <= ST_PAYLOAD;
									end else if (split_header[23:8] == 2) begin
										payload_remaining <= 0;
										state <= ST_CRC;
									end else if (split_header[23:8] == 0) begin
										// The high half contains the two CRC bytes.
										payload_remaining <= 0;
										header_count <= 0;
										state <= ST_HEADER;
									end else begin
										// An odd WC shifts every later header by one byte.
										// Wait for the next SoT rather than accept false headers.
										payload_remaining <= 0;
										state <= ST_HOLD;
									end
								end else begin
									sp_en <= 1;
									// The high half is already the first half of the
									// following back-to-back short packet.
									header_prefix[15:0] <= ordered_word[31:16];
									header_count <= 2;
									state <= ST_HEADER;
								end
							end
						end

						ST_PAYLOAD: begin
							if (payload_remaining > 4) begin
								if (packet_is_ref) begin
									payload <= ordered_word;
									payload_dv <= 4'hf;
								end
								payload_remaining <= payload_remaining - 16'd4;
							end else if (payload_remaining == 4) begin
								if (packet_is_ref) begin
									payload <= ordered_word;
									payload_dv <= 4'hf;
								end
								payload_remaining <= 0;
								state <= ST_CRC;
							end else if (payload_remaining == 2) begin
								if (packet_is_ref) begin
									payload[15:0] <= ordered_word[15:0];
									payload_dv <= 4'b0011;
								end
								payload_remaining <= 0;
								// CRC occupies this word's high half; the next
								// word begins with a complete packet header.
								header_count <= 0;
								state <= ST_HEADER;
							end else begin
								if (packet_is_ref && (payload_remaining == 1)) begin
									payload[7:0] <= ordered_word[7:0];
									payload_dv <= 4'b0001;
								end
								payload_remaining <= 0;
								state <= ST_HOLD;
							end
						end

						ST_CRC: begin
							// CRC is the low half; the high half is the first
							// half of the next back-to-back packet header.
							header_prefix[15:0] <= ordered_word[31:16];
							header_count <= 2;
							state <= ST_HEADER;
						end

						default: state <= ST_SYNC;
					endcase
				end
			end
		end else if (LANES == 1) begin : g_parser_1lane
			reg [31:0] completed_header;
			reg [15:0] crc_next;
			reg [3:0] crc_take;
			always @(posedge clk_word or negedge reset_n) begin
				if (!reset_n || !ready) begin
					state <= ST_SYNC; header_count <= 0; header_prefix <= 0; payload_remaining <= 0; completed_header <= 0;
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0;
					ecc <= 0; wc <= 0; vc <= 0; dt <= 0; payload <= 0; payload_dv <= 0;
					crc_reg <= 16'hffff; crc_bytes_remaining <= 0; crc_header_ok <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
				end else begin
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0; payload <= 0; payload_dv <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
					if (crc_bytes_remaining != 0) begin
						crc_take = (crc_bytes_remaining >= 2) ? 2 :
						           crc_bytes_remaining[3:0];
						crc_next = crc16_bytes(crc_reg, {48'd0, data_in}, crc_take);
						crc_reg <= crc_next;
						if (crc_bytes_remaining <= 2) begin
							crc_bytes_remaining <= 0;
							long_packet_done <= 1'b1;
							payload_crc_ok <= crc_header_ok && (crc_next == 16'd0);
						end else
							crc_bytes_remaining <= crc_bytes_remaining - 2;
					end
					case (state)
						ST_SYNC: if (data_in[7:0] == 8'hb8) begin
							header_prefix[7:0] <= data_in[15:8]; header_count <= 1; state <= ST_HEADER;
						end
						ST_HEADER: if (header_count == 1) begin
							header_prefix[23:8] <= data_in; header_count <= 3;
						end else begin
							completed_header = {data_in[7:0], header_prefix};
							latch_header(completed_header);
							if (is_long_packet(completed_header[5:0])) begin
								crc_header_ok <=
									(completed_header[31:24] == header_ecc(completed_header[23:0]));
								crc_next = crc16_byte(16'hffff, data_in[15:8]);
								crc_reg <= crc_next;
								crc_bytes_remaining <= {1'b0, completed_header[23:8]} + 17'd1;
							end
							if (completed_header[5:0] == ref_dt) begin
								lp_en <= 1; lp_av_en <= 1; payload[7:0] <= data_in[15:8];
								if (completed_header[23:8] > 1) begin
									payload_dv <= 2'b01; payload_remaining <= completed_header[23:8] - 1; state <= ST_PAYLOAD;
								end else begin
									payload_dv <= completed_header[23:8] == 1; payload_remaining <= 0; state <= ST_HOLD;
								end
							end else begin sp_en <= 1; state <= ST_HOLD; end
						end
						ST_PAYLOAD: begin
							payload <= data_in;
							if (payload_remaining >= 2) begin
								payload_dv <= 2'b11; payload_remaining <= payload_remaining - 2;
								if (payload_remaining == 2) state <= ST_HOLD;
							end else begin payload_dv <= 2'b01; payload_remaining <= 0; state <= ST_HOLD; end
						end
						ST_HOLD: if (data_in[7:0] == 8'hb8) begin
							header_prefix[7:0] <= data_in[15:8];
							header_count <= 1; state <= ST_HEADER;
						end
						default: state <= ST_SYNC;
					endcase
				end
			end
		end else if (LANES == 4) begin : g_parser_4lane
			wire sync_word = (data_in[7:0] == 8'hb8) && (data_in[23:16] == 8'hb8) &&
			                 (data_in[39:32] == 8'hb8) && (data_in[55:48] == 8'hb8);
			wire [63:0] ordered_word = {
				data_in[63:56], data_in[47:40], data_in[31:24], data_in[15:8],
				data_in[55:48], data_in[39:32], data_in[23:16], data_in[7:0]};
			wire [31:0] first_header = ordered_word[63:32];
			reg [15:0] crc_next;
			reg [3:0] crc_take;
			always @(posedge clk_word or negedge reset_n) begin
				if (!reset_n || !ready) begin
					state <= ST_SYNC; header_count <= 0; header_prefix <= 0; payload_remaining <= 0;
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0;
					ecc <= 0; wc <= 0; vc <= 0; dt <= 0; payload <= 0; payload_dv <= 0;
					crc_reg <= 16'hffff; crc_bytes_remaining <= 0; crc_header_ok <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
				end else begin
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0; payload <= 0; payload_dv <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
					if (crc_bytes_remaining != 0) begin
						crc_take = (crc_bytes_remaining >= 8) ? 8 :
						           crc_bytes_remaining[3:0];
						crc_next = crc16_bytes(crc_reg, ordered_word, crc_take);
						crc_reg <= crc_next;
						if (crc_bytes_remaining <= 8) begin
							crc_bytes_remaining <= 0;
							long_packet_done <= 1'b1;
							payload_crc_ok <= crc_header_ok && (crc_next == 16'd0);
						end else
							crc_bytes_remaining <= crc_bytes_remaining - 8;
					end
					case (state)
						ST_SYNC: if (sync_word) begin
							latch_header(first_header);
							if (is_long_packet(first_header[5:0])) begin
								crc_reg <= 16'hffff;
								crc_bytes_remaining <= {1'b0, first_header[23:8]} + 17'd2;
								crc_header_ok <=
									(first_header[31:24] == header_ecc(first_header[23:0]));
							end
							if (first_header[5:0] == ref_dt) begin
								lp_en <= 1; lp_av_en <= 1; payload_remaining <= first_header[23:8];
								state <= (first_header[23:8] == 0) ? ST_HOLD : ST_PAYLOAD;
							end else begin sp_en <= 1; state <= ST_HOLD; end
						end
						ST_PAYLOAD: begin
							payload <= ordered_word;
							if (payload_remaining >= 8) begin
								payload_dv <= 8'hff; payload_remaining <= payload_remaining - 8;
								if (payload_remaining == 8) state <= ST_HOLD;
							end else begin
								payload_dv <= valid_mask8(payload_remaining[3:0]); payload_remaining <= 0; state <= ST_HOLD;
							end
						end
						ST_HOLD: if (sync_word) begin
							latch_header(first_header);
							if (is_long_packet(first_header[5:0])) begin
								crc_reg <= 16'hffff;
								crc_bytes_remaining <= {1'b0, first_header[23:8]} + 17'd2;
								crc_header_ok <=
									(first_header[31:24] == header_ecc(first_header[23:0]));
							end
							if (first_header[5:0] == ref_dt) begin
								lp_en <= 1; lp_av_en <= 1;
								payload_remaining <= first_header[23:8];
								state <= (first_header[23:8] == 0) ? ST_HOLD : ST_PAYLOAD;
							end else begin sp_en <= 1; state <= ST_HOLD; end
						end
						default: state <= ST_SYNC;
					endcase
				end
			end
		end
	endgenerate

	initial begin
		if ((LANES != 1) && (LANES != 2) && (LANES != 4)) begin
			$display("ERROR: mipi_dsi_rx_custom LANES must be 1, 2, or 4");
			$finish;
		end
	end
endmodule
