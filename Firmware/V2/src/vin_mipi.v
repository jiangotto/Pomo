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
`include "defines.vh"

module vin_mipi (
	input  wire         clk,
	input  wire         rst_n,

	// MIPI PHY pins
	inout  wire         mipi_clk_p,
	inout  wire         mipi_clk_n,
	inout  wire         mipi_lane0_p,
	inout  wire         mipi_lane0_n,
	inout  wire         mipi_lane1_p,
	inout  wire         mipi_lane1_n,

	// Video output: 1 pixel per beat, Y4
	output wire         v_pclk,
	output wire         v_vsync,
	output wire         v_hsync,
	output wire         v_de,     // filtered active-video region
	output wire [3:0]   v_pixel,
	output wire         v_stream_fault,
	output wire [15:0]  v_fifo_overflow_count,
	output wire [15:0]  v_fifo_empty_count
);

	// =========================================================================
	// PHY / protocol / pixel-converter internal signals
	// =========================================================================
	wire [1:0] lp_clk_out;
	wire [1:0] lp_data0_out;
	wire [1:0] lp_data1_out;
	wire       clk_byte_out;
	wire [15:0] data_out0;
	wire [15:0] data_out1;
	wire       ready;

	reg        hs_en_reg;
	reg [3:0]  hs_tail_cnt;

	// Protocol layer outputs
	wire        o_sp_en;
	wire        o_lp_av_en;
	wire [5:0]  o_dt;
	wire [15:0] o_wc;
	wire [31:0] o_payload;
	wire [3:0]  o_payload_dv;
	wire        ecc_ok;

	// Pixel converter outputs
	wire        clk_pixel_out;
	wire        conv_vsync;
	wire        conv_hsync;
	wire        conv_de;
	wire [23:0] conv_pixel;  // 1 pixel x RGB888

	// =========================================================================
	// MIPI PHY
	// =========================================================================
	MIPI_RX_Advance_Top u_mipi_rx_ip(
		.reset_n     (rst_n),
		.MIPI_CLK_P  (mipi_clk_p),
		.MIPI_CLK_N  (mipi_clk_n),
		.lp_clk_out  (lp_clk_out),
		.lp_clk_in   (),
		.lp_clk_dir  (1'b0),
		.clk_byte_out(clk_byte_out),
		.MIPI_LANE1_P(mipi_lane1_p),
		.MIPI_LANE1_N(mipi_lane1_n),
		.data_out1   (data_out1),
		.lp_data1_out(lp_data1_out),
		.lp_data1_in (),
		.lp_data1_dir(1'b0),
		.MIPI_LANE0_P(mipi_lane0_p),
		.MIPI_LANE0_N(mipi_lane0_n),
		.data_out0   (data_out0),
		.lp_data0_out(lp_data0_out),
		.lp_data0_in (),
		.lp_data0_dir(1'b0),
		.hs_en       (hs_en_reg),
		.clk_term_en (1'b1),
		.data_term_en(hs_en_reg),
		.ready       (ready)
	);

	// The generated receiver uses MIPI IO, so the HS input and termination
	// follow the data-lane LP state. LP01 -> LP00 is the D-PHY request to enter
	// high-speed reception; returning to LP11 marks the end of the burst.
	reg [1:0] lp_data0_d0;
	reg [1:0] lp_data0_d1;
	reg [1:0] lp_data0_d2;

	always @(posedge clk_byte_out or negedge rst_n) begin
		if (!rst_n) begin
			lp_data0_d0 <= 2'b11;
			lp_data0_d1 <= 2'b11;
			lp_data0_d2 <= 2'b11;
		end else begin
			lp_data0_d0 <= lp_data0_out;
			lp_data0_d1 <= lp_data0_d0;
			lp_data0_d2 <= lp_data0_d1;
		end
	end

	wire enter_hs = (lp_data0_d2 == 2'b01) && (lp_data0_d1 == 2'b00);
	wire leave_hs = (lp_data0_d2 != 2'b11) && (lp_data0_d1 == 2'b11);

	always @(posedge clk_byte_out or negedge rst_n) begin
		if (!rst_n) begin
			hs_en_reg   <= 1'b0;
			hs_tail_cnt <= 4'd0;
		end else if (enter_hs) begin
			hs_en_reg   <= 1'b1;
			hs_tail_cnt <= 4'd0;
		end else if (leave_hs) begin
			// The former 1:8 path used 16 byte-clock cycles to drain the RX
			// alignment pipeline. A 1:16 word clock carries twice as many bits,
			// so eight cycles preserve exactly the same physical drain time.
			hs_tail_cnt <= 4'd8;
		end else if (hs_tail_cnt != 0) begin
			hs_tail_cnt <= hs_tail_cnt - 1'b1;
			if (hs_tail_cnt == 4'd1)
				hs_en_reg <= 1'b0;
		end
	end

//  reg ready_dl;
//  reg [7:0] data_out0_dl;
//  reg [7:0] data_out1_dl;

//  always @(posedge clk_byte_out) begin
//      ready_dl <= ready;
//      data_out0_dl <= data_out0;
//      data_out1_dl <= data_out1;
//  end

	// =========================================================================
	// Protocol parser
	// =========================================================================
	MIPI_DSI_CSI2_RX_Top u_mipi_protocol(
		.I_RSTN      (rst_n),
		.I_BYTE_CLK  (clk_byte_out),
		.I_REF_DT    (6'h3E),      // RGB888
		.I_READY     (ready),
		.I_DATA0     (data_out0),
		.I_DATA1     (data_out1),
		.O_SP_EN     (o_sp_en),
		.O_LP_EN     (),
		.O_LP_AV_EN  (o_lp_av_en),
		.O_ECC_OK    (ecc_ok),
		.O_ECC       (),
		.O_WC        (o_wc),
		.O_VC        (),
		.O_DT        (o_dt),
		.O_PAYLOAD   (o_payload),
		.O_PAYLOAD_DV(o_payload_dv)
	);

	reg o_sp_en_dl;
	reg o_lp_av_en_dl;
	reg [5:0]  o_dt_dl;
	reg [15:0] o_wc_dl;
	reg [31:0] o_payload_dl;
	reg [3:0]  o_payload_dv_dl;

	always @(posedge clk_byte_out) begin
		o_sp_en_dl <= o_sp_en & ecc_ok;
		o_lp_av_en_dl <= o_lp_av_en & ecc_ok;
		o_dt_dl <= o_dt;
		o_wc_dl <= o_wc;
		o_payload_dl <= o_payload;
		o_payload_dv_dl <= o_payload_dv;
	end

	//wire w_sp_en    = o_sp_en    & ecc_ok;
	//wire w_lp_av_en = o_lp_av_en & ecc_ok;

	// =========================================================================
	// Per-frame event counters. Reset on V Sync Start.
	// =========================================================================
	reg [10:0] frm_sp_cnt;     // short packets per frame
	reg [10:0] frm_ecc_cnt;    // ecc_ok pulses per frame
	reg [10:0] frm_lp_cnt;     // RGB long packets per frame
	reg [10:0] last_frm_sp_cnt; // completed frame, for debug
	reg [10:0] last_frm_lp_cnt; // completed frame, for debug
	wire       frm_rst = o_sp_en && ecc_ok && (o_dt == 6'h01);

	always @(posedge clk_byte_out or negedge rst_n) begin
		if (!rst_n) begin
			frm_sp_cnt  <= 11'd0;
			frm_ecc_cnt <= 11'd0;
			frm_lp_cnt  <= 11'd0;
			last_frm_sp_cnt <= 11'd0;
			last_frm_lp_cnt <= 11'd0;
		end else if (frm_rst) begin
			last_frm_sp_cnt <= frm_sp_cnt;
			last_frm_lp_cnt <= frm_lp_cnt;
			frm_sp_cnt  <= 11'd1;
			frm_ecc_cnt <= 11'd1;
			frm_lp_cnt  <= 11'd0;
		end else begin
			if (o_sp_en    && ecc_ok) frm_sp_cnt  <= frm_sp_cnt  + 11'd1;
			if (ecc_ok)               frm_ecc_cnt <= frm_ecc_cnt + 11'd1;
			if (o_lp_av_en && ecc_ok) frm_lp_cnt  <= frm_lp_cnt  + 11'd1;
		end
	end

	// =========================================================================
	// Pixel clock generation
	// =========================================================================

	wire lock;
	wire [5:0] pixel_pll_odsel;
	wire       pixel_pll_reset;
	wire       pixel_pll_ready;

	mipi_pll_odiv_ctrl u_pixel_pll_ctrl (
		.clk_ref   (clk),
		.clk_byte  (clk_byte_out),
		.rst_n     (rst_n),
		.pll_lock  (lock),
		.odsel     (pixel_pll_odsel),
		.pll_reset (pixel_pll_reset),
		.pll_ready (pixel_pll_ready)
	);

	Gowin_PLLVR_M4D3 u_pll_v_pclk(
		.clkout (clk_pixel_out),
		.lock   (lock),
		.reset  (pixel_pll_reset),
		.clkin  (clk_byte_out),
		.odsel  (pixel_pll_odsel)
	);

	assign v_pclk = clk_pixel_out;

	// =========================================================================
	// Byte/pixel-domain reset release
	// =========================================================================
	// pixel_pll_ready is generated in the 27 MHz reference-clock domain.  It
	// may assert or deassert at any phase of clk_byte_out and clk_pixel_out.
	// Assert reset asynchronously so loss of PLL readiness takes effect at
	// once, but release it through a separate three-stage synchronizer in each
	// destination domain.  Downstream logic therefore never observes an
	// asynchronous reset release edge.
	wire domain_reset_n_async = rst_n & pixel_pll_ready;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] byte_reset_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] pixel_reset_sync;

	always @(posedge clk_byte_out or negedge domain_reset_n_async) begin
		if (!domain_reset_n_async)
			byte_reset_sync <= 3'b000;
		else
			byte_reset_sync <= {byte_reset_sync[1:0], 1'b1};
	end

	always @(posedge clk_pixel_out or negedge domain_reset_n_async) begin
		if (!domain_reset_n_async)
			pixel_reset_sync <= 3'b000;
		else
			pixel_reset_sync <= {pixel_reset_sync[1:0], 1'b1};
	end

	wire rst_n_byte_sync  = byte_reset_sync[2];
	wire rst_n_pixel_sync = pixel_reset_sync[2];

	// =========================================================================
	// Byte stream -> 1-pixel RGB888 stream
	// =========================================================================
//  wire o_dt_err;
//  wire o_wc_err;
//  wire o_align_err;
//  wire o_fifo_full;
//  wire o_fifo_empty;

//    MIPI_Byte_to_Pixel_Converter_Top u_pixel_converter(
//        .I_RSTN      (rst_n & lock),
//        .I_BYTE_CLK  (clk_byte_out),
//        .I_PIXEL_CLK (clk_pixel_out),
//        .I_SP_EN     (o_sp_en_dl),
//        .I_LP_AV_EN  (o_lp_av_en_dl),
//        .I_DT        (o_dt_dl),
//        .I_WC        (o_wc_dl),
//        .I_PAYLOAD_DV(o_payload_dv_dl),
//        .I_PAYLOAD   (o_payload_dl),
//        .O_VSYNC     (conv_vsync),
//        .O_HSYNC     (conv_hsync),
//        .O_DE        (conv_de),
//        .O_PIXEL     (conv_pixel),
//      .o_dt_err    (o_dt_err), //output o_dt_err
//      .o_wc_err    (o_wc_err), //output o_wc_err
//      .o_align_err (o_align_err), //output o_align_err
//      .o_fifo_full (o_fifo_full), //output o_fifo_full
//      .o_fifo_empty(o_fifo_empty) //output o_fifo_empty
//    );

	mipi_b2p_custom #(
		.HSYNC_WIDTH (`DEFAULT_HSYNC),   // hsync pulse width in pixel clocks
		.VSYNC_LINES (`DEFAULT_VSYNC)    // vsync pulse width in pixel clocks
	) u_pixel_converter (
		.clk_byte       (clk_byte_out),
		.rst_n_byte     (rst_n_byte_sync),
		.i_sp_en        (o_sp_en_dl),        // o_sp_en & ecc_ok
		.i_lp_av_en     (o_lp_av_en_dl),     // o_lp_av_en & ecc_ok
		.i_dt           (o_dt_dl),
		.i_wc           (o_wc_dl),           // word count (payload bytes)
		.i_payload      (o_payload_dl),      // 4 bytes per beat (2-lane 1:16)
		.i_payload_dv   (o_payload_dv_dl),   // byte-valid per payload byte
		.clk_pixel      (clk_pixel_out),
		.rst_n_pixel    (rst_n_pixel_sync),
		.o_vsync        (conv_vsync),
		.o_hsync        (conv_hsync),
		.o_de           (conv_de),
		.o_pixel        (conv_pixel),         // RGB888
		.o_stream_fault (v_stream_fault),
		.o_overflow_count(v_fifo_overflow_count),
		.o_empty_count  (v_fifo_empty_count)
	);

	// =========================================================================
	// RGB888 -> Y4
	// =========================================================================
	wire [7:0] r_pix = conv_pixel[23:16];
	wire [7:0] g_pix = conv_pixel[15:8];
	wire [7:0] b_pix = conv_pixel[7:0];
	wire [3:0] y_pix;

	rgb888_to_y4 u_rgb888_to_y4 (
		.r(r_pix),
		.g(g_pix),
		.b(b_pix),
		.y(y_pix)
	);

	reg [3:0]  v_pixel_dl;
	reg        v_vsync_dl;
	reg        v_hsync_dl;
	reg        v_de_dl;

	// =========================================================================
	// Per-frame conv_de rising-edge counter (reset on conv_vsync rising)
	// =========================================================================
	reg [9:0]  frm_de_cnt;
	reg        prev_conv_vsync;
	reg        prev_conv_de;

	always @(posedge clk_pixel_out or negedge rst_n_pixel_sync) begin
		if (!rst_n_pixel_sync) begin
			prev_conv_vsync <= 1'b0;
			prev_conv_de    <= 1'b0;
			frm_de_cnt      <= 10'd0;
		end else begin
			prev_conv_vsync <= conv_vsync;
			prev_conv_de    <= conv_de;

			if (conv_vsync && !prev_conv_vsync)
				frm_de_cnt <= (conv_de && !prev_conv_de) ? 10'd1 : 10'd0;
			else if (conv_de && !prev_conv_de)
				frm_de_cnt <= frm_de_cnt + 10'd1;
		end
	end

	always @(posedge clk_pixel_out or negedge rst_n_pixel_sync) begin
		if (!rst_n_pixel_sync) begin
			v_pixel_dl <= 4'd0;
			v_vsync_dl <= 1'b0;
			v_hsync_dl <= 1'b0;
			v_de_dl    <= 1'b0;
		end else begin
			v_pixel_dl <= y_pix;
			v_vsync_dl <= conv_vsync;
			v_hsync_dl <= conv_hsync;
			v_de_dl    <= conv_de;
		end
	end

	assign v_pixel = v_pixel_dl;
	assign v_vsync = v_vsync_dl;
	assign v_hsync = v_hsync_dl;
	assign v_de    = v_de_dl;

endmodule
