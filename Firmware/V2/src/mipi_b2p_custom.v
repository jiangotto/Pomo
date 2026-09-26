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
	parameter HSYNC_WIDTH  = 32,  // hsync pulse width, in pixel clocks
	parameter VSYNC_LINES  = 8    // vsync duration, in hsync pulses (lines)
) (
	// === byte clock domain inputs (from protocol parser) ===
	input  wire        clk_byte,
	input  wire        rst_n_byte,

	input  wire        i_sp_en,        // o_sp_en & ecc_ok
	input  wire        i_lp_av_en,     // o_lp_av_en & ecc_ok
	input  wire [5:0]  i_dt,
	input  wire [15:0] i_wc,           // word count (payload bytes)
	input  wire [31:0] i_payload,      // 4 bytes per beat (2-lane 1:16)
	input  wire [3:0]  i_payload_dv,   // byte-valid per payload byte

	// === pixel clock domain outputs ===
	input  wire        clk_pixel,
	input  wire        rst_n_pixel,

	output wire        o_vsync,
	output wire        o_hsync,
	output wire        o_de,
	output wire [23:0] o_pixel,         // RGB888
	output wire        o_stream_fault,
	output reg  [15:0] o_overflow_count,
	output reg  [15:0] o_empty_count
);

	// =========================================================================
	// byte clock domain --- Sync FSM
	// =========================================================================
	// Burst mode: DT=0x01 is both V Sync Start and the first H Sync.
	// vsync stays high for VSYNC_LINES hsync pulses, then drops.
	reg        vs_level;         // vsync level (set/clear, CDC to pixel clock)
	reg        hs_toggle;        // hsync toggle (flip per line, edge→pulse in px)
	reg [ 7:0] vs_line_cnt;      // count hsync pulses within vsync

	always @(posedge clk_byte or negedge rst_n_byte) begin
		if (!rst_n_byte) begin
			vs_level    <= 1'b0;
			hs_toggle   <= 1'b0;
			vs_line_cnt <= 8'd0;
		end else if (i_sp_en) begin
			if (i_dt == 6'h01) begin              // V Sync Start
				vs_level    <= 1'b1;
				hs_toggle   <= ~hs_toggle;        // first hsync of the frame
				vs_line_cnt <= 8'd1;
			end else if (i_dt == 6'h21) begin      // H Sync Start
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
	// byte clock domain --- 1:16 byte assembler
	// =========================================================================
	// The parser presents up to four ordered bytes per beat. Accumulate them in
	// stream order and write two complete RGB888 pixels (six bytes) per FIFO
	// entry. Since fewer than six bytes remain after each write, no beat can
	// require more than one FIFO write.
	reg [71:0] byte_buffer;
	reg [3:0]  byte_count;
	reg [47:0] fifo_pixel_pair;
	reg        fifo_pair_wr;
	reg        packet_active;
	reg        payload_seen;

	wire payload_valid = |i_payload_dv;
	wire in_pkt = i_lp_av_en || packet_active;

	reg [71:0] appended_bytes;
	reg [3:0]  appended_count;
	integer append_index;
	always @* begin
		appended_bytes = byte_buffer;
		appended_count = byte_count;
		for (append_index = 0; append_index < 4; append_index = append_index + 1) begin
			if (i_payload_dv[append_index]) begin
				appended_bytes[appended_count * 8 +: 8] =
					i_payload[append_index * 8 +: 8];
				appended_count = appended_count + 1'b1;
			end
		end
	end

	always @(posedge clk_byte or negedge rst_n_byte) begin
		if (!rst_n_byte) begin
			byte_buffer    <= 72'd0;
			byte_count     <= 4'd0;
			fifo_pixel_pair <= 48'd0;
			fifo_pair_wr   <= 1'b0;
			packet_active  <= 1'b0;
			payload_seen   <= 1'b0;
		end else begin
			fifo_pair_wr <= 1'b0;

			if (i_lp_av_en) begin
				packet_active <= 1'b1;
				payload_seen  <= 1'b0;
				byte_buffer   <= 72'd0;
				byte_count    <= 4'd0;
			end else if (packet_active && payload_valid) begin
				payload_seen <= 1'b1;
				if (appended_count >= 4'd6) begin
					fifo_pixel_pair <= appended_bytes[47:0];
					fifo_pair_wr    <= 1'b1;
					byte_buffer     <= appended_bytes >> 48;
					byte_count      <= appended_count - 4'd6;
				end else begin
					byte_buffer <= appended_bytes;
					byte_count  <= appended_count;
				end
			end else if (packet_active && payload_seen) begin
				packet_active <= 1'b0;
				payload_seen  <= 1'b0;
				byte_buffer   <= 72'd0;
				byte_count    <= 4'd0;
			end else if (!packet_active) begin
				byte_count <= 4'd0;
			end
		end
	end

	// =========================================================================
	// Asynchronous FIFO (48-bit write, 24-bit read)
	// =========================================================================
	// Gowin returns Data[23:0] before Data[47:24], preserving stream order.

	wire        fifo_empty;
	wire        fifo_full;
	wire [23:0] fifo_q;

	// The Gowin FIFO synchronizes its common reset internally in both clock
	// domains.  Keep all accesses disabled for four local clocks after the
	// corresponding domain reset has been released, allowing its reset state
	// and Gray pointers to settle before normal traffic starts.
	reg [3:0] fifo_wr_startup;
	reg [3:0] fifo_rd_startup;
	always @(posedge clk_byte or negedge rst_n_byte) begin
		if (!rst_n_byte)
			fifo_wr_startup <= 4'b0000;
		else
			fifo_wr_startup <= {fifo_wr_startup[2:0], 1'b1};
	end
	always @(posedge clk_pixel or negedge rst_n_pixel) begin
		if (!rst_n_pixel)
			fifo_rd_startup <= 4'b0000;
		else
			fifo_rd_startup <= {fifo_rd_startup[2:0], 1'b1};
	end
	wire fifo_wr_ready = fifo_wr_startup[3];
	wire fifo_rd_ready = fifo_rd_startup[3];
	wire fifo_overflow = fifo_wr_ready && fifo_pair_wr && fifo_full;

	FIFO_HS_MIPI_Top u_fifo(
		.Data   (fifo_pixel_pair), //input [47:0] Data
		.Reset  (!rst_n_byte), //input Reset
		.WrClk  (clk_byte), //input WrClk
		.RdClk  (clk_pixel), //input RdClk
		.WrEn   (fifo_wr_ready && fifo_pair_wr && !fifo_full), //input WrEn
		.RdEn   (fifo_rd_ready && !fifo_empty), //input RdEn
		.Q      (fifo_q), //output [23:0] Q
		.Empty  (fifo_empty), //output Empty
		.Full   (fifo_full) //output Full
	);

	reg frame_fault_byte;
	always @(posedge clk_byte or negedge rst_n_byte) begin
		if (!rst_n_byte) begin
			frame_fault_byte <= 1'b0;
			o_overflow_count <= 16'd0;
		end else begin
			if (i_sp_en && (i_dt == 6'h01))
				frame_fault_byte <= 1'b0;
			if (fifo_overflow) begin
				frame_fault_byte <= 1'b1;
				if (o_overflow_count != 16'hffff)
					o_overflow_count <= o_overflow_count + 16'd1;
			end
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

	always @(posedge clk_byte) begin
		vs_level_d  <= vs_level;
		hs_toggle_d <= hs_toggle;
	end

	wire vs_chg = vs_level  ^ vs_level_d;
	wire hs_chg = hs_toggle ^ hs_toggle_d;

	always @(posedge clk_byte or negedge rst_n_byte) begin
		if (!rst_n_byte) begin
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
	reg [1:0]  packet_active_sync;
	reg [1:0]  frame_fault_sync;

	always @(posedge clk_pixel or negedge rst_n_pixel) begin
		if (!rst_n_pixel) begin
			cdc_valid_sync <= 3'd0;
			px_vs_level    <= 1'b0;
			px_hs_toggle   <= 1'b0;
			px_hs_toggle_d <= 1'b0;
			packet_active_sync <= 2'b00;
			frame_fault_sync   <= 2'b00;
		end else begin
			cdc_valid_sync <= {cdc_valid_sync[1:0], cdc_valid};
			px_hs_toggle_d <= px_hs_toggle;
			packet_active_sync <= {packet_active_sync[0], in_pkt};
			frame_fault_sync   <= {frame_fault_sync[0], frame_fault_byte};
			if (cdc_valid_sync[2] ^ cdc_valid_sync[1])
				{px_vs_level, px_hs_toggle} <= cdc_data;
		end
	end

	wire hs_edge = px_hs_toggle ^ px_hs_toggle_d;

	// hsync pulse generator (HSYNC_WIDTH pixel clocks wide)
	reg [5:0] hs_cnt;
	reg       hs_active;

	always @(posedge clk_pixel or negedge rst_n_pixel) begin
		if (!rst_n_pixel) begin
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
	assign o_pixel = fifo_q;
	assign o_stream_fault = frame_fault_sync[1];

	// Diagnostic only: count one event for each empty interval observed while
	// a long packet is active. The active-level CDC can extend slightly beyond
	// the packet boundary, so this counter does not directly kill a frame.
	reg empty_seen;
	always @(posedge clk_pixel or negedge rst_n_pixel) begin
		if (!rst_n_pixel) begin
			o_empty_count <= 16'd0;
			empty_seen    <= 1'b0;
		end else if (!fifo_rd_ready || !packet_active_sync[1] || !fifo_empty) begin
			empty_seen <= 1'b0;
		end else if (!empty_seen) begin
			empty_seen <= 1'b1;
			if (o_empty_count != 16'hffff)
				o_empty_count <= o_empty_count + 16'd1;
		end
	end

	// o_de must align with o_pixel: fifo_q is valid one cycle after rd_en.
	// Delay o_de by one pixel clock to match.
	reg o_de_r;
	always @(posedge clk_pixel or negedge rst_n_pixel) begin
		if (!rst_n_pixel)
			o_de_r <= 1'b0;
		else
			o_de_r <= fifo_rd_ready && !fifo_empty;
	end
	assign o_de = o_de_r;

endmodule
