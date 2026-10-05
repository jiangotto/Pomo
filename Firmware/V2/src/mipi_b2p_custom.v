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

module mipi_b2p_custom #(
	parameter integer LANES = 2,
	parameter HSYNC_WIDTH  = 32,  // hsync pulse width, in pixel clocks
	parameter VSYNC_LINES  = 8    // vsync duration, in hsync pulses (lines)
) (
	// === byte clock domain inputs (from protocol parser) ===
	input  wire        clk_byte,
	input  wire        rst_n_byte,

	input  wire        i_sp_en,        // o_sp_en & ecc_ok
	input  wire [5:0]  i_sp_dt,        // short-packet DT
	input  wire        i_lp_av_en,     // o_lp_av_en & ecc_ok
	input  wire [5:0]  i_dt,
	input  wire [15:0] i_wc,           // word count (payload bytes)
	input  wire [LANES*16-1:0] i_payload,    // 2 bytes/lane in 1:16 mode
	input  wire [LANES*2-1:0]  i_payload_dv, // byte-valid in stream order
	input  wire        i_stream_reset, // async assertion from stable sys_clk

	// === pixel clock domain outputs ===
	input  wire        clk_pixel,
	input  wire        rst_n_pixel,

	output wire        o_vsync,
	output wire        o_hsync,
	output wire        o_de,
	output wire [23:0] o_pixel,         // RGB888
	output wire        o_stream_fault
);

	// The MIPI clocks can stop while the host sends a command. Assert reset
	// asynchronously so stopped domains are still cleared, then release it
	// through a local three-stage synchronizer in each clock domain.
	wire stream_rst_n_byte_async = rst_n_byte && !i_stream_reset;
	wire stream_rst_n_pixel_async = rst_n_pixel && !i_stream_reset;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] stream_byte_reset_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] stream_pixel_reset_sync;
	always @(posedge clk_byte or negedge stream_rst_n_byte_async) begin
		if (!stream_rst_n_byte_async)
			stream_byte_reset_sync <= 3'b000;
		else
			stream_byte_reset_sync <= {stream_byte_reset_sync[1:0], 1'b1};
	end
	always @(posedge clk_pixel or negedge stream_rst_n_pixel_async) begin
		if (!stream_rst_n_pixel_async)
			stream_pixel_reset_sync <= 3'b000;
		else
			stream_pixel_reset_sync <= {stream_pixel_reset_sync[1:0], 1'b1};
	end
	wire stream_rst_n_byte = stream_byte_reset_sync[2];
	wire stream_rst_n_pixel = stream_pixel_reset_sync[2];

	// =========================================================================
	// byte clock domain --- Sync FSM
	// =========================================================================
	// Burst mode: DT=0x01 is both V Sync Start and the first H Sync.
	// vsync stays high for VSYNC_LINES hsync pulses, then drops.
	reg        vs_level;         // vsync level (set/clear, CDC to pixel clock)
	reg        hs_toggle;        // hsync toggle (flip per line, edge→pulse in px)
	reg [ 7:0] vs_line_cnt;      // count hsync pulses within vsync
	reg        frame_ready_byte; // accept payload only after a clean VSS

	always @(posedge clk_byte or negedge stream_rst_n_byte) begin
		if (!stream_rst_n_byte) begin
			vs_level    <= 1'b0;
			hs_toggle   <= 1'b0;
			vs_line_cnt <= 8'd0;
			frame_ready_byte <= 1'b0;
		end else if (i_sp_en) begin
			if (i_sp_dt == 6'h01) begin           // V Sync Start
				vs_level    <= 1'b1;
				hs_toggle   <= ~hs_toggle;        // first hsync of the frame
				vs_line_cnt <= 8'd1;
				frame_ready_byte <= 1'b1;
			end else if (i_sp_dt == 6'h21) begin   // H Sync Start
				hs_toggle <= ~hs_toggle;
				if (vs_level) begin
					vs_line_cnt <= vs_line_cnt + 8'd1;
					if (vs_line_cnt == VSYNC_LINES - 1)
						vs_level <= 1'b0;
				end
			end
		end
	end

	// =========================================================================
	// byte clock domain --- parameterized 1:16 RGB888 assembler
	// =========================================================================
	// The single 64-bit FIFO is shared by every lane configuration. One and
	// two lanes pack short input beats before writing it. Four lanes instead
	// pass each beat through and skip the first beat's unused bytes on readout.
	wire [63:0] fifo_byte_word;
	wire        fifo_block_wr;
	reg        packet_active;
	reg        payload_seen;
	reg [15:0] received_bytes;
	reg [1:0] received_bytes_mod3;
	reg        packet_error_pulse;

	// RGB888 payload length must be divisible by three. Track the remainder
	// while accepting bytes instead of synthesizing a 16-bit modulo divider.
	function [1:0] modulo3_small;
		input [3:0] value;
		begin
			case (value)
				4'd0, 4'd3, 4'd6, 4'd9: modulo3_small = 2'd0;
				4'd1, 4'd4, 4'd7, 4'd10: modulo3_small = 2'd1;
				default: modulo3_small = 2'd2;
			endcase
		end
	endfunction

	// A line descriptor crosses independently of the pixel data.  It prevents
	// padding in the final 64-bit word from becoming visible pixels, so image
	// width is not required to be a multiple of four.
	reg [15:0] line_bytes_byte;
	reg [3:0] first_count_byte;
	reg        line_desc_toggle;
	reg [1:0]  prefill_blocks;
	reg        line_desc_sent;

	wire payload_valid = |i_payload_dv;
	wire start_packet = frame_ready_byte && i_lp_av_en && (i_dt == 6'h3e);
	wire packet_end = packet_active && payload_seen && !payload_valid;

	// The protocol parser emits a contiguous LSB-first byte-valid mask. Decode
	// its prefix length directly instead of building a general popcount adder;
	// this is both the actual interface contract and substantially smaller for
	// the eight-byte four-lane datapath.
	wire [7:0] payload_dv_8 = {{(8-LANES*2){1'b0}}, i_payload_dv};
	reg [3:0] input_valid_count;
	wire [3:0] received_mod3_sum =
		{2'b00, received_bytes_mod3} + input_valid_count;
	always @* begin
		casex (payload_dv_8)
			8'b1xxxxxxx: input_valid_count = 4'd8;
			8'b01xxxxxx: input_valid_count = 4'd7;
			8'b001xxxxx: input_valid_count = 4'd6;
			8'b0001xxxx: input_valid_count = 4'd5;
			8'b00001xxx: input_valid_count = 4'd4;
			8'b000001xx: input_valid_count = 4'd3;
			8'b0000001x: input_valid_count = 4'd2;
			8'b00000001: input_valid_count = 4'd1;
			default:     input_valid_count = 4'd0;
		endcase
	end
	// Packet bookkeeping is independent of the lane width. fifo_block_wr
	// counts the write accepted by the FIFO on this byte-clock edge.
	always @(posedge clk_byte or negedge stream_rst_n_byte) begin
		if (!stream_rst_n_byte) begin
			packet_active  <= 1'b0;
			payload_seen   <= 1'b0;
			received_bytes <= 16'd0;
			received_bytes_mod3 <= 2'd0;
			line_bytes_byte <= 16'd0;
			first_count_byte <= 4'd0;
			line_desc_toggle <= 1'b0;
			prefill_blocks <= 2'd0;
			line_desc_sent <= 1'b0;
			packet_error_pulse <= 1'b0;
		end else begin
			packet_error_pulse <= 1'b0;

			if (start_packet) begin
				packet_active <= (i_wc != 16'd0);
				payload_seen  <= payload_valid;
				received_bytes <= input_valid_count;
				received_bytes_mod3 <= modulo3_small(input_valid_count);
				line_bytes_byte <= i_wc;
				first_count_byte <= payload_valid ? input_valid_count : 4'd0;
				prefill_blocks <= 2'd0;
				line_desc_sent <= 1'b0;
			end else if (packet_active && payload_valid) begin
				if (!payload_seen)
					first_count_byte <= input_valid_count;
				payload_seen <= 1'b1;
				received_bytes <= received_bytes + input_valid_count;
				received_bytes_mod3 <= modulo3_small(received_mod3_sum);
			end else if (packet_end) begin
				if (!line_desc_sent) begin
					line_desc_toggle <= ~line_desc_toggle;
					line_desc_sent <= 1'b1;
				end
				packet_active <= 1'b0;
				payload_seen  <= 1'b0;
				if ((received_bytes != line_bytes_byte) ||
				    (received_bytes_mod3 != 2'd0))
					packet_error_pulse <= 1'b1;
			end

			if (!start_packet && fifo_block_wr && !line_desc_sent) begin
				if (prefill_blocks == 2'd1) begin
					line_desc_toggle <= ~line_desc_toggle;
					line_desc_sent <= 1'b1;
				end else begin
					prefill_blocks <= prefill_blocks + 2'd1;
				end
			end
		end
	end

	generate
		if (LANES == 4) begin : g_pack_4lane
			assign fifo_byte_word = i_payload;
			assign fifo_block_wr = (start_packet || packet_active) && payload_valid;
		end else if (LANES == 2) begin : g_pack_2lane
			reg [63:0] word_r;
			reg [63:0] buffer_r;
			reg [3:0]  byte_count_r;
			reg         wr_r;

			assign fifo_byte_word = word_r;
			assign fifo_block_wr = wr_r;

			always @(posedge clk_byte or negedge stream_rst_n_byte) begin
				if (!stream_rst_n_byte) begin
					word_r <= 64'd0;
					buffer_r <= 64'd0;
					byte_count_r <= 4'd0;
					wr_r <= 1'b0;
				end else begin
					wr_r <= 1'b0;
					if (start_packet) begin
						buffer_r <= {32'd0, i_payload};
						byte_count_r <= payload_valid ? input_valid_count : 4'd0;
					end else if (packet_active && payload_valid) begin
						case (byte_count_r)
							4'd0: begin
								buffer_r <= {32'd0, i_payload};
								byte_count_r <= input_valid_count;
							end
							4'd2: begin
								buffer_r[47:16] <= i_payload;
								byte_count_r <= 4'd2 + input_valid_count;
							end
							4'd4: begin
								if (input_valid_count == 4'd4) begin
									word_r <= {i_payload, buffer_r[31:0]};
									wr_r <= 1'b1;
									buffer_r <= 64'd0;
									byte_count_r <= 4'd0;
								end else begin
									buffer_r[55:32] <= i_payload[23:0];
									byte_count_r <= 4'd4 + input_valid_count;
								end
							end
							default: begin // six-byte split-header phase
								if (input_valid_count >= 4'd2) begin
									word_r <= {i_payload[15:0], buffer_r[47:0]};
									wr_r <= 1'b1;
									buffer_r <= {48'd0, i_payload[31:16]};
									byte_count_r <= input_valid_count - 4'd2;
								end else begin
									buffer_r[55:48] <= i_payload[7:0];
									byte_count_r <= 4'd7;
								end
							end
						endcase
					end else if (packet_end) begin
						if (byte_count_r != 4'd0) begin
							word_r <= buffer_r;
							wr_r <= 1'b1;
						end
						buffer_r <= 64'd0;
						byte_count_r <= 4'd0;
					end else if (!packet_active) begin
						buffer_r <= 64'd0;
						byte_count_r <= 4'd0;
					end
				end
			end
		end else begin : g_pack_1lane
			reg [63:0] word_r;
			reg [63:0] buffer_r;
			reg [3:0]  byte_count_r;
			reg         wr_r;
			reg [79:0] appended_r;
			reg [4:0]  appended_count_r;

			// One lane can begin at either byte phase after the packet header.
			// Enumerating the eight legal accumulator positions is smaller and
			// shallower than a run-time barrel shifter.
			always @* begin
				appended_r = {16'd0, buffer_r};
				case (byte_count_r)
					4'd0: appended_r[15:0]  = i_payload;
					4'd1: appended_r[23:8]  = i_payload;
					4'd2: appended_r[31:16] = i_payload;
					4'd3: appended_r[39:24] = i_payload;
					4'd4: appended_r[47:32] = i_payload;
					4'd5: appended_r[55:40] = i_payload;
					4'd6: appended_r[63:48] = i_payload;
					default: appended_r[71:56] = i_payload;
				endcase
				appended_count_r = {1'b0, byte_count_r} +
					{1'b0, input_valid_count};
			end

			assign fifo_byte_word = word_r;
			assign fifo_block_wr = wr_r;

			always @(posedge clk_byte or negedge stream_rst_n_byte) begin
				if (!stream_rst_n_byte) begin
					word_r <= 64'd0;
					buffer_r <= 64'd0;
					byte_count_r <= 4'd0;
					wr_r <= 1'b0;
				end else begin
					wr_r <= 1'b0;
					if (start_packet) begin
						buffer_r <= {48'd0, i_payload};
						byte_count_r <= payload_valid ? input_valid_count : 4'd0;
					end else if (packet_active && payload_valid) begin
						if (appended_count_r >= 5'd8) begin
							word_r <= appended_r[63:0];
							wr_r <= 1'b1;
							buffer_r <= {48'd0, appended_r[79:64]};
							byte_count_r <= appended_count_r[3:0] - 4'd8;
						end else begin
							buffer_r <= appended_r[63:0];
							byte_count_r <= appended_count_r[3:0];
						end
					end else if (packet_end) begin
						if (byte_count_r != 4'd0) begin
							word_r <= buffer_r;
							wr_r <= 1'b1;
						end
						buffer_r <= 64'd0;
						byte_count_r <= 4'd0;
					end else if (!packet_active) begin
						buffer_r <= 64'd0;
						byte_count_r <= 4'd0;
					end
				end
			end
		end
	endgenerate

	// =========================================================================
	// Asynchronous FIFO (64-bit write, 32-bit read)
	// =========================================================================
	// Gowin returns the two 32-bit slices from least to most significant.

	wire        fifo_empty;
	wire        fifo_full;
	wire [31:0] fifo_q;

	// Synchronize the per-line byte count separately from the data FIFO.  The
	// source bus is held stable until the next line, so the toggle arrives only
	// after the two-stage bus synchronizer has settled.
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [15:0] line_bytes_meta;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [15:0] line_bytes_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [3:0] first_count_meta;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [3:0] first_count_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] line_desc_sync;
	reg [15:0] bytes_remaining;
	reg [14:0] fifo_words_remaining;
	reg        fifo_words_active;
	reg [15:0] pending_bytes;
	reg [3:0] pending_first_count;
	reg        pending_line;
	reg [3:0] first_count_pixel;
	reg [1:0] first_word_state;
	reg        fifo_q_valid;
	reg [1:0]  pixel_phase;
	reg [23:0] carry_bytes;
	reg [23:0] pixel_out_r;
	reg        pixel_de_r;

	function [14:0] fifo_words_for_line;
		input [15:0] byte_total;
		input [3:0] first_count;
		reg [16:0] word_total;
		begin
			// Four lanes store the initial short beat as one padded 64-bit
			// FIFO entry. Include that one-time gap when counting read words.
			if (LANES == 4)
				word_total = (({1'b0, byte_total} +
					(first_count == 4'd0 ? 17'd0 : 17'd8 - first_count) +
					17'd7) >> 3) << 1;
			else
				word_total = (({1'b0, byte_total} + 17'd7) >> 3) << 1;
			fifo_words_for_line = word_total[14:0];
		end
	endfunction

	// The Gowin FIFO synchronizes its common reset internally in both clock
	// domains.  Keep all accesses disabled for four local clocks after the
	// corresponding domain reset has been released, allowing its reset state
	// and Gray pointers to settle before normal traffic starts.
	reg [3:0] fifo_wr_startup;
	reg [3:0] fifo_rd_startup;
	always @(posedge clk_byte or negedge stream_rst_n_byte) begin
		if (!stream_rst_n_byte)
			fifo_wr_startup <= 4'b0000;
		else
			fifo_wr_startup <= {fifo_wr_startup[2:0], 1'b1};
	end
	always @(posedge clk_pixel or negedge stream_rst_n_pixel) begin
		if (!stream_rst_n_pixel)
			fifo_rd_startup <= 4'b0000;
		else
			fifo_rd_startup <= {fifo_rd_startup[2:0], 1'b1};
	end
	wire fifo_wr_ready = fifo_wr_startup[3];
	wire fifo_rd_ready = fifo_rd_startup[3];
	wire fifo_overflow = fifo_wr_ready && fifo_block_wr && fifo_full;
	wire fifo_rd_en = fifo_rd_ready && !fifo_empty &&
		fifo_words_active && !(fifo_q_valid && (pixel_phase == 2'd2));
	wire line_desc_edge = line_desc_sync[2] ^ line_desc_sync[1];
	wire line_idle = (bytes_remaining == 16'd0) &&
		!fifo_words_active && !fifo_q_valid;

	always @(posedge clk_pixel or negedge stream_rst_n_pixel) begin
		if (!stream_rst_n_pixel) begin
			line_bytes_meta <= 16'd0;
			line_bytes_sync <= 16'd0;
			first_count_meta <= 4'd0;
			first_count_sync <= 4'd0;
			line_desc_sync <= 3'b000;
			bytes_remaining <= 16'd0;
			fifo_words_remaining <= 15'd0;
			fifo_words_active <= 1'b0;
			pending_bytes <= 16'd0;
			pending_first_count <= 4'd0;
			pending_line <= 1'b0;
			first_count_pixel <= 4'd0;
			first_word_state <= 2'd0;
			fifo_q_valid <= 1'b0;
			pixel_phase <= 2'd0;
			carry_bytes <= 24'd0;
			pixel_out_r <= 24'd0;
			pixel_de_r <= 1'b0;
		end else begin
			line_bytes_meta <= line_bytes_byte;
			line_bytes_sync <= line_bytes_meta;
			first_count_meta <= first_count_byte;
			first_count_sync <= first_count_meta;
			line_desc_sync <= {line_desc_sync[1:0], line_desc_toggle};
			fifo_q_valid <= fifo_rd_en;
			pixel_de_r <= 1'b0;

			if (bytes_remaining == 16'd0) begin
				pixel_phase <= 2'd0;
				carry_bytes <= 24'd0;
			end else if (pixel_phase == 2'd3) begin
				pixel_out_r <= carry_bytes;
				pixel_de_r <= 1'b1;
				pixel_phase <= 2'd0;
				carry_bytes <= 24'd0;
				bytes_remaining <= bytes_remaining - 16'd3;
			end else if (fifo_q_valid) begin
				if (LANES == 4 && first_word_state != 2'd2)
					first_word_state <= first_word_state + 2'd1;
				// Only the first FIFO entry may have a gap. Consume its two
				// 32-bit halves using the recorded byte count, then let the
				// ordinary RGB888 assembler handle the rest of the line.
				if (LANES == 4 && first_word_state == 2'd0 && first_count_pixel < 4'd6) begin
					case (first_count_pixel)
						4'd1: begin carry_bytes <= {16'd0, fifo_q[7:0]}; pixel_phase <= 2'd1; end
						4'd2: begin carry_bytes <= {8'd0, fifo_q[15:0]}; pixel_phase <= 2'd2; end
						4'd3: begin
							pixel_out_r <= fifo_q[23:0];
						end
						4'd4, 4'd5: begin
							pixel_out_r <= fifo_q[23:0];
							carry_bytes <= {16'd0, fifo_q[31:24]};
							pixel_phase <= 2'd1;
						end
						default: begin end
					endcase
				end else if (LANES == 4 && first_word_state == 2'd1 &&
				             first_count_pixel < 4'd8) begin
					case (first_count_pixel)
						4'd5: begin
							carry_bytes <= {8'd0, fifo_q[7:0], carry_bytes[7:0]};
							pixel_phase <= 2'd2;
							pixel_de_r <= 1'b1;
							bytes_remaining <= bytes_remaining - 16'd3;
						end
						4'd3, 4'd4: begin
							pixel_de_r <= 1'b1;
							bytes_remaining <= bytes_remaining - 16'd3;
						end
						4'd6, 4'd7: begin
							pixel_out_r <= {fifo_q[15:0], carry_bytes[7:0]};
							pixel_de_r <= 1'b1;
							bytes_remaining <= bytes_remaining - 16'd3;
							carry_bytes <= first_count_pixel == 4'd7 ?
								{16'd0, fifo_q[23:16]} : 24'd0;
							pixel_phase <= first_count_pixel == 4'd7 ? 2'd1 : 2'd0;
						end
						default: begin end // the second word is padding
					endcase
				end else begin
				pixel_de_r <= 1'b1;
				bytes_remaining <= bytes_remaining - 16'd3;
				case (pixel_phase)
					2'd0: begin
						pixel_out_r <= fifo_q[23:0];
						carry_bytes <= {16'd0, fifo_q[31:24]};
						pixel_phase <= 2'd1;
					end
					2'd1: begin
						pixel_out_r <= {fifo_q[15:0], carry_bytes[7:0]};
						carry_bytes <= {8'd0, fifo_q[31:16]};
						pixel_phase <= 2'd2;
					end
					default: begin
						pixel_out_r <= {fifo_q[7:0], carry_bytes[15:0]};
						carry_bytes <= fifo_q[31:8];
						pixel_phase <= 2'd3;
					end
				endcase
				end
			end
			if (fifo_rd_en) begin
				fifo_words_remaining <= fifo_words_remaining - 15'd1;
				if (fifo_words_remaining == 15'd1)
					fifo_words_active <= 1'b0;
			end

			if (line_desc_edge) begin
				if (line_idle) begin
					bytes_remaining <= line_bytes_sync;
					fifo_words_remaining <= fifo_words_for_line(line_bytes_sync, first_count_sync);
					fifo_words_active <= (line_bytes_sync != 16'd0);
					first_count_pixel <= first_count_sync;
					first_word_state <= 2'd0;
					pixel_phase <= 2'd0;
					carry_bytes <= 24'd0;
				end else begin
					pending_bytes <= line_bytes_sync;
					pending_first_count <= first_count_sync;
					pending_line <= 1'b1;
				end
			end else if (line_idle && pending_line) begin
				bytes_remaining <= pending_bytes;
				fifo_words_remaining <= fifo_words_for_line(pending_bytes, pending_first_count);
				fifo_words_active <= (pending_bytes != 16'd0);
				first_count_pixel <= pending_first_count;
				first_word_state <= 2'd0;
				pixel_phase <= 2'd0;
				carry_bytes <= 24'd0;
				pending_line <= 1'b0;
			end
		end
	end

	FIFO_HS_MIPI_Top u_fifo(
		.Data   (fifo_byte_word), //input [63:0] Data
		.Reset  (!stream_rst_n_byte), //input Reset
		.WrClk  (clk_byte), //input WrClk
		.RdClk  (clk_pixel), //input RdClk
		.WrEn   (fifo_wr_ready && fifo_block_wr && !fifo_full), //input WrEn
		.RdEn   (fifo_rd_en), //input RdEn
		.Q      (fifo_q), //output [31:0] Q
		.Empty  (fifo_empty), //output Empty
		.Full   (fifo_full) //output Full
	);

	reg frame_fault_byte;
	always @(posedge clk_byte or negedge stream_rst_n_byte) begin
		if (!stream_rst_n_byte) begin
			frame_fault_byte <= 1'b0;
		end else begin
			if (i_sp_en && (i_sp_dt == 6'h01))
				frame_fault_byte <= 1'b0;
			if (fifo_overflow || packet_error_pulse)
				frame_fault_byte <= 1'b1;
		end
	end

	// =========================================================================
	// pixel clock domain --- CDC → hs pulse, vs level
	// =========================================================================
	// vs_level and hs_toggle change simultaneously on V Sync Start in the
	// byte clock domain. Pack them into a single 2-bit bus with a valid
	// toggle so they stay co-timed through the CDC.

	// --- byte clock: detect changes, pack data, toggle valid ---
	reg        vs_level_d;
	reg        hs_toggle_d;
	reg        cdc_valid;
	reg [1:0]  cdc_data;   // {vs_level, hs_toggle}

	always @(posedge clk_byte or negedge stream_rst_n_byte) begin
		if (!stream_rst_n_byte) begin
			vs_level_d  <= 1'b0;
			hs_toggle_d <= 1'b0;
		end else begin
			vs_level_d  <= vs_level;
			hs_toggle_d <= hs_toggle;
		end
	end

	wire vs_chg = vs_level  ^ vs_level_d;
	wire hs_chg = hs_toggle ^ hs_toggle_d;

	always @(posedge clk_byte or negedge stream_rst_n_byte) begin
		if (!stream_rst_n_byte) begin
			cdc_valid <= 1'b0;
			cdc_data  <= 2'd0;
		end else if (vs_chg || hs_chg) begin
			cdc_data  <= {vs_level, hs_toggle};
			cdc_valid <= ~cdc_valid;
		end
	end

	// --- pixel clock: sync valid (3-stage), sample data on edge ---
	reg [2:0]  cdc_valid_sync;
	reg        px_vs_level;
	reg        px_hs_toggle;
	reg        px_hs_toggle_d;
	reg [1:0]  frame_fault_sync;

	always @(posedge clk_pixel or negedge stream_rst_n_pixel) begin
		if (!stream_rst_n_pixel) begin
			cdc_valid_sync <= 3'd0;
			px_vs_level    <= 1'b0;
			px_hs_toggle   <= 1'b0;
			px_hs_toggle_d <= 1'b0;
			frame_fault_sync <= 2'b00;
		end else begin
			cdc_valid_sync <= {cdc_valid_sync[1:0], cdc_valid};
			px_hs_toggle_d <= px_hs_toggle;
			frame_fault_sync <= {frame_fault_sync[0], frame_fault_byte};
			if (cdc_valid_sync[2] ^ cdc_valid_sync[1])
				{px_vs_level, px_hs_toggle} <= cdc_data;
		end
	end

	wire hs_edge = px_hs_toggle ^ px_hs_toggle_d;

	// hsync pulse generator (HSYNC_WIDTH pixel clocks wide)
	reg [5:0] hs_cnt;
	reg       hs_active;

	always @(posedge clk_pixel or negedge stream_rst_n_pixel) begin
		if (!stream_rst_n_pixel) begin
			hs_cnt    <= 6'd0;
			hs_active <= 1'b0;
		end else begin
			if (hs_edge) begin
				hs_active <= 1'b1;
				hs_cnt    <= HSYNC_WIDTH - 1;
			end else if (hs_active && hs_cnt > 0) begin
				hs_cnt <= hs_cnt - 1'b1;
			end else begin
				hs_active <= 1'b0;
			end
		end
	end

	assign o_vsync = px_vs_level;
	assign o_hsync = hs_active;
	assign o_pixel = pixel_out_r;
	assign o_de = pixel_de_r;
	assign o_stream_fault = frame_fault_sync[1];

	initial begin
		if ((LANES != 1) && (LANES != 2) && (LANES != 4))
			$error("mipi_b2p_custom LANES must be 1, 2, or 4");
	end

endmodule
