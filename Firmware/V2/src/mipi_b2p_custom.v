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
	input  wire [15:0] i_payload,      // 2 bytes per beat (2-lane 1:8)
	input  wire [1:0]  i_payload_dv,   // byte-valid per payload byte

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
	// byte clock domain --- Byte Assembler (3 bytes → 1 pixel)
	// =========================================================================
	// 2 bytes/beat on a 2-lane 1:8 link.
	// 3 bytes = 1 RGB888 pixel → 3 beats produce 2 pixels.
	reg [23:0] pixel_buf;
	reg [23:0] fifo_pixel;
	reg [1:0]  byte_pos;       // 0,1,2 bytes toward next pixel
	reg        fifo_wr;
	reg [15:0] wc_remain;      // bytes remaining in current long packet
	reg        i_lp_av_en_d;   // edge detect for WC load

	wire lane0_vld = i_payload_dv[0];
	wire lane1_vld = i_payload_dv[1];

	wire [7:0] b0 = i_payload[7:0];     // lane0 byte
	wire [7:0] b1 = i_payload[15:8];    // lane1 byte

	wire        in_pkt = i_lp_av_en || (wc_remain > 0);

	always @(posedge clk_byte) begin
		i_lp_av_en_d <= i_lp_av_en;
	end

	always @(posedge clk_byte or negedge rst_n_byte) begin
		if (!rst_n_byte) begin
			pixel_buf  <= 24'd0;
			fifo_pixel <= 24'd0;
			byte_pos   <= 2'd0;
			fifo_wr    <= 1'b0;
			wc_remain  <= 16'd0;
		end else begin
			fifo_wr <= 1'b0;

			// Load WC at start of new long packet
			if (i_lp_av_en && !i_lp_av_en_d) begin
				wc_remain <= i_wc;
				byte_pos  <= 2'd0;
				pixel_buf <= 24'd0;
			end

			if (in_pkt && (lane0_vld || lane1_vld)) begin
				// PAYLOAD_DV already qualifies each byte from the protocol parser.
				// Rechecking WC here was redundant and put the 16-bit packet word
				// count comparator on every pixel_buf/fifo_wr data path.
				if (lane0_vld && lane1_vld) begin
					// 2 bytes this beat
					wc_remain <= i_lp_av_en ? (i_wc - 16'd2) : (wc_remain - 16'd2);
					case (byte_pos)
					2'd0: begin
						pixel_buf[7:0]   <= b0;
						pixel_buf[15:8]  <= b1;
						byte_pos <= 2'd2;
					end
					2'd1: begin
						pixel_buf[15:8]  <= b0;
						pixel_buf[23:16] <= b1;
						fifo_pixel <= {b1, b0, pixel_buf[7:0]};
						fifo_wr  <= 1'b1;
						byte_pos <= 2'd0;
					end
					2'd2: begin
						pixel_buf[23:16] <= b0;
						fifo_pixel <= {b0, pixel_buf[15:0]};
						fifo_wr  <= 1'b1;
						pixel_buf[7:0]   <= b1;
						byte_pos <= 2'd1;
					end
					endcase
				end else if (lane0_vld) begin
					// 1 byte: lane0 only (last beat of packet)
					wc_remain <= i_lp_av_en ? (i_wc - 16'd1) : (wc_remain - 16'd1);
					case (byte_pos)
					2'd0: begin pixel_buf[7:0]   <= b0; byte_pos <= 2'd1; end
					2'd1: begin pixel_buf[15:8]  <= b0; byte_pos <= 2'd2; end
					2'd2: begin pixel_buf[23:16] <= b0; fifo_pixel <= {b0, pixel_buf[15:0]}; fifo_wr <= 1'b1; byte_pos <= 2'd0; end
					endcase
				end else begin
					// 1 byte: lane1 only (last beat of packet)
					wc_remain <= i_lp_av_en ? (i_wc - 16'd1) : (wc_remain - 16'd1);
					case (byte_pos)
					2'd0: begin pixel_buf[7:0]   <= b1; byte_pos <= 2'd1; end
					2'd1: begin pixel_buf[15:8]  <= b1; byte_pos <= 2'd2; end
					2'd2: begin pixel_buf[23:16] <= b1; fifo_pixel <= {b1, pixel_buf[15:0]}; fifo_wr <= 1'b1; byte_pos <= 2'd0; end
					endcase
				end
			end else if (!in_pkt) begin
				// between packets — reset, safe to drop partial bytes
				byte_pos  <= 2'd0;
			end
		end
	end

	// =========================================================================
	// Pixel-pair packer and async FIFO (48-bit write, 24-bit read)
	// =========================================================================
	// A two-lane 1:8 RGB888 stream completes two pixels every three byte
	// clocks.  Pair those two pixels before crossing the clock boundary so the
	// FIFO write pointer advances once per three byte clocks instead of on two
	// consecutive byte clocks.  The asymmetric Gowin FIFO returns Data[23:0]
	// first and Data[47:24] second, preserving the original pixel order.
	reg [23:0] pixel_pair_first;
	reg [47:0] fifo_pixel_pair;
	reg        pixel_pair_pending;
	reg        fifo_pair_wr;

	always @(posedge clk_byte or negedge rst_n_byte) begin
		if (!rst_n_byte) begin
			pixel_pair_first   <= 24'd0;
			fifo_pixel_pair    <= 48'd0;
			pixel_pair_pending <= 1'b0;
			fifo_pair_wr       <= 1'b0;
		end else begin
			fifo_pair_wr <= 1'b0;
			if (fifo_wr) begin
				if (!pixel_pair_pending) begin
					pixel_pair_first   <= fifo_pixel;
					pixel_pair_pending <= 1'b1;
				end else begin
					fifo_pixel_pair    <= {fifo_pixel, pixel_pair_first};
					pixel_pair_pending <= 1'b0;
					fifo_pair_wr       <= 1'b1;
				end
			end else if (!in_pkt) begin
				// RGB888 line packets contain an even 1216 pixels.  Dropping an
				// unmatched pixel here prevents a truncated packet from rotating
				// the next line's pair boundary.
				pixel_pair_pending <= 1'b0;
			end
		end
	end

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
