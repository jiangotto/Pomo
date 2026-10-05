// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
//
// Parameterizable MIPI DSI packet parser. Each lane supplies two chronological
// bytes per word. Generate-time specialisation keeps the active 1/2/4-lane
// datapath shallow; there is no run-time lane-width mux or byte-loop FSM.

`timescale 1ns / 1ps

module mipi_dsi_rx_custom #(
	parameter integer LANES = 2,
	parameter integer CHECK_CRC = 1
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
	output reg  [15:0]             sp_wc,
	output reg  [5:0]              sp_dt,
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
		input        header_valid;
		begin
			dt <= h[5:0];
			vc <= h[7:6];
			wc <= h[23:8];
			sp_dt <= h[5:0];
			sp_wc <= h[23:8];
			ecc <= h[31:24];
			ecc_ok <= header_valid;
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
					ecc <= 0; wc <= 0; vc <= 0; dt <= 0; sp_wc <= 0; sp_dt <= 0; payload <= 0; payload_dv <= 0;
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
					if ((CHECK_CRC != 0) && (crc_bytes_remaining != 0)) begin
						crc_take = (crc_bytes_remaining >= 17'd4) ? 4'd4 :
						           crc_bytes_remaining[3:0];
						crc_next = crc16_bytes(crc_reg, {32'd0, ordered_word}, crc_take);
						crc_reg <= crc_next;
						if (crc_bytes_remaining <= 17'd4) begin
							crc_bytes_remaining <= 0;
							long_packet_done <= 1'b1;
							payload_crc_ok <= crc_header_ok && (crc_next == 16'd0);
						end else begin
							crc_bytes_remaining <= crc_bytes_remaining - 17'd4;
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
								latch_header(ordered_word,
									ordered_word[31:24] == header_ecc(ordered_word[23:0]));
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
								latch_header(split_header,
									split_header[31:24] == header_ecc(split_header[23:0]));
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
					ecc <= 0; wc <= 0; vc <= 0; dt <= 0; sp_wc <= 0; sp_dt <= 0; payload <= 0; payload_dv <= 0;
					crc_reg <= 16'hffff; crc_bytes_remaining <= 0; crc_header_ok <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
				end else begin
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0; payload <= 0; payload_dv <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
					if ((CHECK_CRC != 0) && (crc_bytes_remaining != 0)) begin
						crc_take = (crc_bytes_remaining >= 17'd2) ? 4'd2 :
						           crc_bytes_remaining[3:0];
						crc_next = crc16_bytes(crc_reg, {48'd0, data_in}, crc_take);
						crc_reg <= crc_next;
						if (crc_bytes_remaining <= 17'd2) begin
							crc_bytes_remaining <= 0;
							long_packet_done <= 1'b1;
							payload_crc_ok <= crc_header_ok && (crc_next == 16'd0);
						end else
							crc_bytes_remaining <= crc_bytes_remaining - 17'd2;
					end
					case (state)
						ST_SYNC: if (data_in[7:0] == 8'hb8) begin
							header_prefix[7:0] <= data_in[15:8]; header_count <= 1; state <= ST_HEADER;
						end
						ST_HEADER: if (header_count == 1) begin
							header_prefix[23:8] <= data_in; header_count <= 3;
						end else begin
							completed_header = {data_in[7:0], header_prefix};
							latch_header(completed_header,
								completed_header[31:24] == header_ecc(completed_header[23:0]));
							if (is_long_packet(completed_header[5:0])) begin
								crc_header_ok <=
									(completed_header[31:24] == header_ecc(completed_header[23:0]));
								crc_next = crc16_byte(16'hffff, data_in[15:8]);
								crc_reg <= crc_next;
								crc_bytes_remaining <= {1'b0, completed_header[23:8]} + 17'd1;
							end
							if (completed_header[5:0] == ref_dt) begin
								lp_en <= 1; lp_av_en <= 1; payload[7:0] <= data_in[15:8];
								if (completed_header[23:8] > 16'd1) begin
									payload_dv <= 2'b01; payload_remaining <= completed_header[23:8] - 16'd1; state <= ST_PAYLOAD;
								end else begin
									payload_dv <= completed_header[23:8] == 16'd1; payload_remaining <= 0; state <= ST_HOLD;
								end
							end else begin sp_en <= 1; state <= ST_HOLD; end
						end
						ST_PAYLOAD: begin
							payload <= data_in;
							if (payload_remaining >= 16'd2) begin
								payload_dv <= 2'b11; payload_remaining <= payload_remaining - 16'd2;
								if (payload_remaining == 16'd2) state <= ST_HOLD;
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
		end else if ((LANES == 4) && (CHECK_CRC == -1)) begin : g_parser_4lane_unrolled_reference
			wire [63:0] ordered_word = {
				data_in[63:56], data_in[47:40], data_in[31:24], data_in[15:8],
				data_in[55:48], data_in[39:32], data_in[23:16], data_in[7:0]};

			// Four lanes deliver eight chronological bytes per word.  Packet and
			// CRC boundaries are not required to coincide with that word: the two
			// CRC bytes rotate the following header by two byte positions on every
			// line.  Process all eight bytes as one continuous stream so no bytes
			// after CRC are discarded.
			reg [2:0] sync_count;
			reg [1:0] crc_count;
			reg       packet_is_ref_4;

			reg [2:0]  state_n;
			reg [1:0]  header_count_n;
			reg [23:0] header_prefix_n;
			reg [15:0] payload_remaining_n;
			reg [2:0]  sync_count_n;
			reg [1:0]  crc_count_n;
			reg        packet_is_ref_n;
			reg [15:0] crc_reg_n;
			reg        crc_header_ok_n;

			reg        sp_en_n, lp_en_n, lp_av_en_n, ecc_ok_n;
			reg [7:0]  ecc_n;
			reg [15:0] wc_n, sp_wc_n;
			reg [1:0]  vc_n;
			reg [5:0]  dt_n, sp_dt_n;
			reg [63:0] payload_n;
			reg [7:0]  payload_dv_n;
			reg [3:0]  payload_count_n;
			reg        long_packet_done_n, payload_crc_ok_n;

			reg [7:0]  stream_byte;
			reg [31:0] completed_header;
			reg        completed_header_ok;
			reg [15:0] crc_byte_result;
			integer byte_index;

			always @* begin
				state_n = state;
				header_count_n = header_count;
				header_prefix_n = header_prefix;
				payload_remaining_n = payload_remaining;
				sync_count_n = sync_count;
				crc_count_n = crc_count;
				packet_is_ref_n = packet_is_ref_4;
				crc_reg_n = crc_reg;
				crc_header_ok_n = crc_header_ok;

				sp_en_n = 1'b0;
				lp_en_n = 1'b0;
				lp_av_en_n = 1'b0;
				ecc_ok_n = 1'b0;
				ecc_n = ecc;
				wc_n = wc;
				vc_n = vc;
				dt_n = dt;
				sp_wc_n = sp_wc;
				sp_dt_n = sp_dt;
				payload_n = 64'd0;
				payload_dv_n = 8'd0;
				payload_count_n = 4'd0;
				long_packet_done_n = 1'b0;
				payload_crc_ok_n = 1'b0;
				stream_byte = 8'd0;
				completed_header = 32'd0;
				completed_header_ok = 1'b0;
				crc_byte_result = crc_reg_n;

				for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin
					stream_byte = ordered_word[byte_index*8 +: 8];
					case (state_n)
						ST_SYNC: begin
							if (stream_byte == 8'hb8) begin
								if (sync_count_n == 3'd3) begin
									state_n = ST_HEADER;
									header_count_n = 2'd0;
									header_prefix_n = 24'd0;
									sync_count_n = 3'd0;
								end else
									sync_count_n = sync_count_n + 1'b1;
							end else
								sync_count_n = 3'd0;
						end

						ST_HEADER: begin
							// At a packet boundary, B8 cannot be a valid first
							// Data-ID byte.  Treat it as the start of the next SoT.
							if ((header_count_n == 0) && (stream_byte == 8'hb8)) begin
								state_n = ST_SYNC;
								sync_count_n = 3'd1;
							end else if (header_count_n != 2'd3) begin
								case (header_count_n)
									2'd0: header_prefix_n[7:0]   = stream_byte;
									2'd1: header_prefix_n[15:8]  = stream_byte;
									default: header_prefix_n[23:16] = stream_byte;
								endcase
								header_count_n = header_count_n + 1'b1;
								state_n = ST_HEADER;
							end else begin
								completed_header = {stream_byte, header_prefix_n};
								completed_header_ok =
									(stream_byte == header_ecc(header_prefix_n));
								header_count_n = 2'd0;
								header_prefix_n = 24'd0;

								if (completed_header == 32'h010f0f08) begin
									state_n = ST_SYNC;
									sync_count_n = 3'd0;
								end else if (!completed_header_ok) begin
									state_n = ST_SYNC;
									sync_count_n = 3'd0;
								end else begin
									ecc_ok_n = 1'b1;
									ecc_n = completed_header[31:24];
									wc_n = completed_header[23:8];
									vc_n = completed_header[7:6];
									dt_n = completed_header[5:0];

									if (is_long_packet(completed_header[5:0])) begin
										packet_is_ref_n =
											(completed_header[5:0] == ref_dt);
										payload_remaining_n = completed_header[23:8];
										crc_reg_n = 16'hffff;
										crc_header_ok_n = 1'b1;
										crc_count_n = 2'd0;
										if (completed_header[5:0] == ref_dt) begin
											lp_en_n = 1'b1;
											lp_av_en_n = 1'b1;
										end
										state_n = (completed_header[23:8] == 0) ?
											ST_CRC : ST_PAYLOAD;
									end else begin
										// Keep short-packet metadata separate from the
										// long header that may follow in this same word.
										if (!sp_en_n) begin
											sp_en_n = 1'b1;
											sp_dt_n = completed_header[5:0];
											sp_wc_n = completed_header[23:8];
										end
										state_n = ST_HEADER;
									end
								end
							end
						end

						ST_PAYLOAD: begin
							if (packet_is_ref_n && (payload_count_n < 8)) begin
								case (payload_count_n)
									4'd0: payload_n[7:0]   = stream_byte;
									4'd1: payload_n[15:8]  = stream_byte;
									4'd2: payload_n[23:16] = stream_byte;
									4'd3: payload_n[31:24] = stream_byte;
									4'd4: payload_n[39:32] = stream_byte;
									4'd5: payload_n[47:40] = stream_byte;
									4'd6: payload_n[55:48] = stream_byte;
									default: payload_n[63:56] = stream_byte;
								endcase
								payload_dv_n[payload_count_n] = 1'b1;
								payload_count_n = payload_count_n + 1'b1;
							end
							if (CHECK_CRC != 0)
								crc_reg_n = crc16_byte(crc_reg_n, stream_byte);
							if (payload_remaining_n == 16'd1) begin
								payload_remaining_n = 16'd0;
								crc_count_n = 2'd0;
								state_n = ST_CRC;
							end else
								payload_remaining_n = payload_remaining_n - 1'b1;
						end

						ST_CRC: begin
							crc_byte_result = (CHECK_CRC != 0) ?
								crc16_byte(crc_reg_n, stream_byte) : crc_reg_n;
							crc_reg_n = crc_byte_result;
							if (crc_count_n == 2'd1) begin
								long_packet_done_n = 1'b1;
								payload_crc_ok_n = crc_header_ok_n &&
									((CHECK_CRC == 0) || (crc_byte_result == 16'd0));
								crc_count_n = 2'd0;
								state_n = ST_HEADER;
							end else
								crc_count_n = crc_count_n + 1'b1;
						end

						default: begin
							state_n = ST_SYNC;
							sync_count_n = 3'd0;
						end
					endcase
				end
			end

			always @(posedge clk_word or negedge reset_n) begin
				if (!reset_n || !ready) begin
					state <= ST_SYNC; header_count <= 0; header_prefix <= 0; payload_remaining <= 0;
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0;
					ecc <= 0; wc <= 0; vc <= 0; dt <= 0; sp_wc <= 0; sp_dt <= 0; payload <= 0; payload_dv <= 0;
					crc_reg <= 16'hffff; crc_bytes_remaining <= 0; crc_header_ok <= 0;
					sync_count <= 0; crc_count <= 0; packet_is_ref_4 <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
				end else begin
					state <= state_n;
					header_count <= header_count_n;
					header_prefix <= header_prefix_n;
					payload_remaining <= payload_remaining_n;
					sync_count <= sync_count_n;
					crc_count <= crc_count_n;
					packet_is_ref_4 <= packet_is_ref_n;
					crc_reg <= crc_reg_n;
					crc_bytes_remaining <= 0;
					crc_header_ok <= crc_header_ok_n;
					sp_en <= sp_en_n;
					lp_en <= lp_en_n;
					lp_av_en <= lp_av_en_n;
					ecc_ok <= ecc_ok_n;
					ecc <= ecc_n;
					wc <= wc_n;
					vc <= vc_n;
					dt <= dt_n;
					sp_wc <= sp_wc_n;
					sp_dt <= sp_dt_n;
					payload <= payload_n;
					payload_dv <= payload_dv_n;
					long_packet_done <= long_packet_done_n;
					payload_crc_ok <= payload_crc_ok_n;
				end
			end
		end else if (LANES == 4) begin : g_parser_4lane
			wire sync_word = (data_in[7:0] == 8'hb8) &&
			                 (data_in[23:16] == 8'hb8) &&
			                 (data_in[39:32] == 8'hb8) &&
			                 (data_in[55:48] == 8'hb8);
			wire [63:0] ordered_word = {
				data_in[63:56], data_in[47:40], data_in[31:24], data_in[15:8],
				data_in[55:48], data_in[39:32], data_in[23:16], data_in[7:0]};
			wire [31:0] sync_header = ordered_word[63:32];

			reg [1:0] crc_count;
			reg       packet_is_ref_4;
			reg [31:0] header2;
			reg [55:0] after_header;
			reg [3:0]  payload_take;
			reg [15:0] crc_next;
			reg [15:0] crc_pair;
			reg [31:0] primary_header;
			wire [15:0] payload_available = payload_remaining;

			// These header locations belong to mutually exclusive parser states.
			// Select one candidate before the ECC network so synthesis can share
			// one checker instead of replicating it for every packet phase.
			always @* begin
				primary_header = 32'd0;
				case (state)
					ST_SYNC: primary_header = sync_header;
					ST_HEADER: begin
						case (header_count)
							2'd0: primary_header = ordered_word[31:0];
							2'd1: primary_header = {ordered_word[23:0], header_prefix[7:0]};
							2'd2: primary_header = {ordered_word[15:0], header_prefix[15:0]};
							default: primary_header = {ordered_word[7:0], header_prefix};
						endcase
					end
					ST_PAYLOAD: begin
						if (payload_available == 16'd1)
							primary_header = ordered_word[55:24];
						else if (payload_available == 16'd2)
							primary_header = ordered_word[63:32];
					end
					ST_CRC: primary_header = (crc_count == 0) ?
						ordered_word[47:16] : ordered_word[39:8];
					default: primary_header = 32'd0;
				endcase
			end
			wire primary_header_ok =
				(primary_header[31:24] == header_ecc(primary_header[23:0]));

			always @(posedge clk_word or negedge reset_n) begin
				if (!reset_n || !ready) begin
					state <= ST_SYNC;
					header_count <= 0;
					header_prefix <= 0;
					payload_remaining <= 0;
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0;
					ecc <= 0; wc <= 0; vc <= 0; dt <= 0;
					sp_wc <= 0; sp_dt <= 0;
					payload <= 0; payload_dv <= 0;
					crc_reg <= 16'hffff; crc_bytes_remaining <= 0;
					crc_header_ok <= 0; crc_count <= 0;
					packet_is_ref_4 <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;
				end else begin
					// Blocking temporaries are fully assigned every cycle; they describe
					// combinational selections inside this clocked process, not storage.
					header2 = 32'd0;
					after_header = 56'd0;
					payload_take = 4'd0;
					crc_next = crc_reg;
					crc_pair = 16'd0;
					sp_en <= 0; lp_en <= 0; lp_av_en <= 0; ecc_ok <= 0;
					payload <= 0; payload_dv <= 0;
					long_packet_done <= 0; payload_crc_ok <= 0;

					case (state)
						ST_SYNC: begin
							if (sync_word) begin
								latch_header(sync_header,
									primary_header_ok);
								if (sync_header == 32'h010f0f08) begin
									state <= ST_SYNC;
								end else if (primary_header_ok) begin
									if (is_long_packet(sync_header[5:0])) begin
										packet_is_ref_4 <= (sync_header[5:0] == ref_dt);
										payload_remaining <= sync_header[23:8];
										crc_reg <= 16'hffff;
										crc_header_ok <= 1'b1;
										if (sync_header[5:0] == ref_dt) begin
											lp_en <= 1'b1; lp_av_en <= 1'b1;
										end
										state <= (sync_header[23:8] == 0) ? ST_CRC : ST_PAYLOAD;
									end else begin
										sp_en <= 1'b1;
										sp_dt <= sync_header[5:0];
										sp_wc <= sync_header[23:8];
										state <= ST_HEADER;
										header_count <= 0;
									end
								end
							end
						end

						ST_HEADER: begin
							case (header_count)
								2'd0: after_header = {24'd0, ordered_word[63:32]};
								2'd1: after_header = {16'd0, ordered_word[63:24]};
								2'd2: after_header = {8'd0, ordered_word[63:16]};
								default: after_header = ordered_word[63:8];
							endcase
							header_count <= 0;
							header_prefix <= 0;

							if (primary_header == 32'h010f0f08) begin
								state <= ST_SYNC;
							end else if (!primary_header_ok) begin
								state <= ST_SYNC;
							end else if (is_long_packet(primary_header[5:0])) begin
								latch_header(primary_header, 1'b1);
								packet_is_ref_4 <= (primary_header[5:0] == ref_dt);
								payload_take = (primary_header[23:8] < {2'b01, header_count}) ?
									primary_header[11:8] : {2'b01, header_count};
								if (primary_header[5:0] == ref_dt) begin
									lp_en <= 1'b1; lp_av_en <= 1'b1;
									payload <= after_header;
									payload_dv <= valid_mask8(payload_take);
								end
								crc_next = (CHECK_CRC != 0) ?
									crc16_bytes(16'hffff, after_header, payload_take) : 16'hffff;
								crc_reg <= crc_next;
								crc_header_ok <= 1'b1;
								if (primary_header[23:8] > payload_take) begin
									payload_remaining <= primary_header[23:8] - payload_take;
									state <= ST_PAYLOAD;
								end else begin
									payload_remaining <= 0;
									state <= ST_CRC;
								end
								crc_count <= 0;
							end else begin
								// header1 is short. The same beat always contains a
								// complete second header; keep their metadata separate.
								sp_en <= 1'b1; sp_dt <= primary_header[5:0]; sp_wc <= primary_header[23:8];
								header2 = after_header[31:0];
								if ((header2[31:24] == header_ecc(header2[23:0])) &&
								    is_long_packet(header2[5:0])) begin
									latch_header(header2, 1'b1);
									sp_dt <= primary_header[5:0]; sp_wc <= primary_header[23:8];
									packet_is_ref_4 <= (header2[5:0] == ref_dt);
									payload_take = {2'b00, header_count};
									if (header2[23:8] < payload_take)
										payload_take = header2[11:8];
									if (header2[5:0] == ref_dt) begin
										lp_en <= 1'b1; lp_av_en <= 1'b1;
										payload <= after_header[55:32];
										payload_dv <= valid_mask8(payload_take);
									end
									crc_next = (CHECK_CRC != 0) ?
										crc16_bytes(16'hffff, {32'd0, after_header[55:32]}, payload_take) : 16'hffff;
									crc_reg <= crc_next; crc_header_ok <= 1'b1;
									payload_remaining <= header2[23:8] - payload_take;
									state <= (header2[23:8] > payload_take) ? ST_PAYLOAD : ST_CRC;
									crc_count <= 0;
								end else begin
									// A second short packet cannot be represented by the
									// legacy single-SP port; retain following prefix bytes.
									header_count <= header_count;
									header_prefix <= after_header[55:32];
									state <= ST_HEADER;
								end
							end
						end

						ST_PAYLOAD: begin
							header_count <= 0;
							if (payload_available >= 16'd8) begin
								if (packet_is_ref_4) begin payload <= ordered_word; payload_dv <= 8'hff; end
								crc_reg <= (CHECK_CRC != 0) ? crc16_bytes(crc_reg, ordered_word, 8) : crc_reg;
								payload_remaining <= payload_available - 16'd8;
								if (payload_available == 8) begin
									state <= ST_CRC; crc_count <= 0;
								end else begin
									state <= ST_PAYLOAD;
								end
							end else begin
								payload_take = payload_available[3:0];
								if (packet_is_ref_4) begin payload <= ordered_word; payload_dv <= valid_mask8(payload_take); end
								crc_next = (CHECK_CRC != 0) ? crc16_bytes(crc_reg, ordered_word, payload_take) : crc_reg;
								payload_remaining <= 0;
								case (payload_take)
									4'd1: begin crc_pair=ordered_word[23:8];  header_count<=1; header_prefix[7:0]<=ordered_word[63:56]; end
									4'd2: begin crc_pair=ordered_word[31:16]; header_count<=0; end
									4'd3: begin crc_pair=ordered_word[39:24]; header_count<=3; header_prefix<=ordered_word[63:40]; end
									4'd4: begin crc_pair=ordered_word[47:32]; header_count<=2; header_prefix[15:0]<=ordered_word[63:48]; end
									4'd5: begin crc_pair=ordered_word[55:40]; header_count<=1; header_prefix[7:0]<=ordered_word[63:56]; end
									4'd6: begin crc_pair=ordered_word[63:48]; header_count<=0; end
									4'd7: begin crc_pair={8'd0,ordered_word[63:56]}; header_count<=0; end
									default: begin crc_pair=0; header_count<=0; end
								endcase
								if (payload_take <= 6) begin
									crc_next = (CHECK_CRC != 0) ? crc16_bytes(crc_next,{48'd0,crc_pair},2) : crc_next;
									crc_reg <= crc_next; long_packet_done <= 1'b1;
									payload_crc_ok <= crc_header_ok && ((CHECK_CRC == 0) || (crc_next == 0));
									if (payload_take <= 2) begin
										if (primary_header_ok) begin
											sp_en<=!is_long_packet(primary_header[5:0]); sp_dt<=primary_header[5:0]; sp_wc<=primary_header[23:8];
										end
									end
									state <= ST_HEADER;
								end else begin
									crc_reg <= (CHECK_CRC != 0) ? crc16_byte(crc_next,crc_pair[7:0]) : crc_next;
									crc_count <= 1; state <= ST_CRC;
								end
							end
						end

						ST_CRC: begin
							if (crc_count == 0) begin
								crc_next = (CHECK_CRC != 0) ? crc16_bytes(crc_reg,ordered_word,2) : crc_reg;
								header_count <= 2; header_prefix[15:0] <= ordered_word[63:48];
							end else begin
								crc_next = (CHECK_CRC != 0) ? crc16_byte(crc_reg,ordered_word[7:0]) : crc_reg;
								header_count <= 3; header_prefix <= ordered_word[63:40];
							end
							crc_reg <= crc_next; long_packet_done <= 1'b1;
							payload_crc_ok <= crc_header_ok && ((CHECK_CRC == 0) || (crc_next == 0));
							if (primary_header_ok) begin
								sp_en <= !is_long_packet(primary_header[5:0]); sp_dt <= primary_header[5:0]; sp_wc <= primary_header[23:8];
							end
							state <= ST_HEADER; crc_count <= 0;
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
