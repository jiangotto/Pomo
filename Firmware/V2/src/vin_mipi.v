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
	inout  wire         mipi_lane2_p,
	inout  wire         mipi_lane2_n,
	inout  wire         mipi_lane3_p,
	inout  wire         mipi_lane3_n,

	// Video output: 1 pixel per beat, Y4
	output wire         v_pclk,
	output wire         v_vsync,
	output wire         v_hsync,
	output wire         v_de,     // filtered active-video region
	output wire [3:0]   v_pixel,
	output wire         v_ready,
	output wire         v_mode_cmd_valid,
	output wire [3:0]   v_mode_cmd_value,
	output wire         v_reinit_cmd_valid,
	output wire         v_power_request,
	output wire         v_stream_fault
);

	// =========================================================================
	// PHY / protocol / pixel-converter internal signals
	// =========================================================================
	wire [1:0] lp_clk_out;
	wire [1:0] lp_data0_out;
	wire       clk_byte_out;
	wire       ready;
	wire       receiver_trained;
	wire       receiver_train_failed;
	wire [3:0] mipi_data_p_all = {
		mipi_lane3_p, mipi_lane2_p, mipi_lane1_p, mipi_lane0_p};
	wire [3:0] mipi_data_n_all = {
		mipi_lane3_n, mipi_lane2_n, mipi_lane1_n, mipi_lane0_n};
	wire [`MIPI_RX_LANES-1:0] mipi_data_p_bus =
		mipi_data_p_all[`MIPI_RX_LANES-1:0];
	wire [`MIPI_RX_LANES-1:0] mipi_data_n_bus =
		mipi_data_n_all[`MIPI_RX_LANES-1:0];
	wire [`MIPI_RX_LANES*2-1:0] lp_data_out_bus;
	wire [`MIPI_RX_LANES*16-1:0] dphy_data_bus;

	assign lp_data0_out = lp_data_out_bus[1:0];
	reg        hs_en_reg;
	reg [3:0]  hs_tail_cnt;

	// Protocol layer outputs
	wire        o_sp_en;
	wire        o_lp_av_en;
	wire [5:0]  o_dt;
	wire [15:0] o_wc;
	wire [5:0]  o_sp_dt;
	wire [15:0] o_sp_wc;
	wire [`MIPI_RX_LANES*16-1:0] o_payload;
	wire [`MIPI_RX_LANES*2-1:0]  o_payload_dv;
	wire        ecc_ok;
	wire        long_packet_done;
	wire        payload_crc_ok;

	// Runtime commands are inserted into the continuing video stream.  They
	// must not reset the receiver: doing so resets the destination side of the
	// toggle CDC while its source state survives, which can discard the first
	// command after a reset.  Only the board reset resets the MIPI chain.
	wire stream_reset_request = 1'b0;
	wire rx_stream_rst_n = rst_n;

	// Pixel converter outputs
	wire        clk_pixel_out;
	wire        conv_vsync;
	wire        conv_hsync;
	wire        conv_de;
	wire [23:0] conv_pixel;  // 1 pixel x RGB888

	// =========================================================================
	// MIPI PHY
	// =========================================================================
	mipi_dphy_rx_custom #(
		.LANES    (`MIPI_RX_LANES),
		.AUTO_TRAIN(`MIPI_RX_AUTO_TRAIN),
		.IO_DELAY0(`MIPI_RX_IO_DELAY0),
		.IO_DELAY1(`MIPI_RX_IO_DELAY1),
		.IO_DELAY2(`MIPI_RX_IO_DELAY2),
		.IO_DELAY3(`MIPI_RX_IO_DELAY3)
	) u_mipi_rx_custom (
		.reset_n     (rx_stream_rst_n),
		.mipi_clk_p  (mipi_clk_p),
		.mipi_clk_n  (mipi_clk_n),
		.mipi_data_p (mipi_data_p_bus),
		.mipi_data_n (mipi_data_n_bus),
		.lp_clk_out  (lp_clk_out),
		.lp_clk_in   (2'b00),
		.lp_clk_dir  (1'b0),
		.lp_data_out (lp_data_out_bus),
		.lp_data_in  ({(`MIPI_RX_LANES*2){1'b0}}),
		.lp_data_dir ({`MIPI_RX_LANES{1'b0}}),
		.clk_word    (clk_byte_out),
		.data_out    (dphy_data_bus),
		.hs_en       (hs_en_reg),
		.clk_term_en (1'b1),
		.data_term_en(hs_en_reg),
		.train_packet_done(long_packet_done),
		.train_packet_good(long_packet_done && payload_crc_ok),
		.ready       (ready),
		.trained     (receiver_trained),
		.train_failed(receiver_train_failed)
	);

	// Gowin only accepts IO_TYPE=MIPI on a pin backed by a MIPI primitive.
	// Keep the PCB's unused lanes electrically configured as receive-only MIPI
	// inputs without instantiating their deserializers or alignment logic.  The
	// generate conditions disappear automatically when a lane becomes active.
	generate
		if (`MIPI_RX_LANES < 2) begin : g_unused_lane1
			wire unused_lp_p;
			wire unused_lp_n;
			reg [1:0] lp_monitor /* synthesis syn_dont_touch = 1 */;
			MIPI_IBUF u_unused_lane_ibuf (
				.I(1'b0), .IB(1'b0), .OEN(1'b1), .OENB(1'b1),
				.IO(mipi_lane1_p), .IOB(mipi_lane1_n), .HSREN(1'b0),
				.OL(unused_lp_p), .OB(unused_lp_n), .OH()
			);
			always @(posedge clk or negedge rst_n)
				if (!rst_n) lp_monitor <= 2'b00;
				else        lp_monitor <= {unused_lp_p, unused_lp_n};
		end
		if (`MIPI_RX_LANES < 4) begin : g_unused_lane2
			wire unused_lp_p;
			wire unused_lp_n;
			reg [1:0] lp_monitor /* synthesis syn_dont_touch = 1 */;
			MIPI_IBUF u_unused_lane_ibuf (
				.I(1'b0), .IB(1'b0), .OEN(1'b1), .OENB(1'b1),
				.IO(mipi_lane2_p), .IOB(mipi_lane2_n), .HSREN(1'b0),
				.OL(unused_lp_p), .OB(unused_lp_n), .OH()
			);
			always @(posedge clk or negedge rst_n)
				if (!rst_n) lp_monitor <= 2'b00;
				else        lp_monitor <= {unused_lp_p, unused_lp_n};
		end
		if (`MIPI_RX_LANES < 4) begin : g_unused_lane3
			wire unused_lp_p;
			wire unused_lp_n;
			reg [1:0] lp_monitor /* synthesis syn_dont_touch = 1 */;
			MIPI_IBUF u_unused_lane_ibuf (
				.I(1'b0), .IB(1'b0), .OEN(1'b1), .OENB(1'b1),
				.IO(mipi_lane3_p), .IOB(mipi_lane3_n), .HSREN(1'b0),
				.OL(unused_lp_p), .OB(unused_lp_n), .OH()
			);
			always @(posedge clk or negedge rst_n)
				if (!rst_n) lp_monitor <= 2'b00;
				else        lp_monitor <= {unused_lp_p, unused_lp_n};
		end
	endgenerate

	// The D-PHY receiver uses MIPI IO, so the HS input and termination
	// follow the data-lane LP state. LP01 -> LP00 is the D-PHY request to enter
	// high-speed reception; returning to LP11 marks the end of the burst.
	reg [1:0] lp_data0_d0;
	reg [1:0] lp_data0_d1;
	reg [1:0] lp_data0_d2;

	always @(posedge clk_byte_out or negedge rx_stream_rst_n) begin
		if (!rx_stream_rst_n) begin
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

	always @(posedge clk_byte_out or negedge rx_stream_rst_n) begin
		if (!rx_stream_rst_n) begin
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
	mipi_dsi_rx_custom #(
		.LANES    (`MIPI_RX_LANES),
		.CHECK_CRC(`MIPI_RX_AUTO_TRAIN)
	) u_mipi_protocol (
		.reset_n   (rx_stream_rst_n),
		.clk_word  (clk_byte_out),
		.ready     (ready),
		.ref_dt    (6'h3e),
		.data_in   (dphy_data_bus),
		.sp_en     (o_sp_en),
		.lp_en     (),
		.lp_av_en  (o_lp_av_en),
		.ecc_ok    (ecc_ok),
		.ecc       (),
		.wc        (o_wc),
		.vc        (),
		.dt        (o_dt),
		.sp_wc     (o_sp_wc),
		.sp_dt     (o_sp_dt),
		.payload   (o_payload),
		.payload_dv(o_payload_dv),
		.long_packet_done(long_packet_done),
		.payload_crc_ok(payload_crc_ok)
	);

	reg o_sp_en_dl;
	reg o_lp_av_en_dl;
	reg [5:0]  o_dt_dl;
	reg [15:0] o_wc_dl;
	reg [5:0]  o_sp_dt_dl;
	reg [`MIPI_RX_LANES*16-1:0] o_payload_dl;
	reg [`MIPI_RX_LANES*2-1:0]  o_payload_dv_dl;

	always @(posedge clk_byte_out or negedge rx_stream_rst_n) begin
		if (!rx_stream_rst_n) begin
			o_sp_en_dl      <= 1'b0;
			o_lp_av_en_dl   <= 1'b0;
			o_dt_dl         <= 6'd0;
			o_wc_dl         <= 16'd0;
			o_sp_dt_dl      <= 6'd0;
			o_payload_dl    <= {(`MIPI_RX_LANES*16){1'b0}};
			o_payload_dv_dl <= {(`MIPI_RX_LANES*2){1'b0}};
		end else begin
			o_sp_en_dl      <= o_sp_en & ecc_ok;
			o_lp_av_en_dl   <= o_lp_av_en & ecc_ok;
			o_dt_dl         <= o_dt;
			o_wc_dl         <= o_wc;
			o_sp_dt_dl      <= o_sp_dt;
			o_payload_dl    <= o_payload;
			o_payload_dv_dl <= o_payload_dv;
		end
	end

	//wire w_sp_en    = o_sp_en    & ecc_ok;
	//wire w_lp_av_en = o_lp_av_en & ecc_ok;

	// =========================================================================
	// Pixel clock generation
	// =========================================================================

	wire lock;
	wire [5:0] pixel_pll_odsel;
	wire       pixel_pll_reset;
	wire       pixel_pll_ready;
	// The requested default is ON, but never energize the panel rails until
	// the physical MIPI clock chain is valid. This leaves both supported PMICs
	// in STANDBY at boot when no source is connected.
	wire tcon_power_request;
	assign v_power_request = tcon_power_request && receiver_trained && pixel_pll_ready && lock;

	mipi_pll_odiv_ctrl #(
		.LANES (`MIPI_RX_LANES)
	) u_pixel_pll_ctrl (
		.clk_ref   (clk),
		.clk_byte  (clk_byte_out),
		.rst_n     (rst_n),
		.pll_lock  (lock),
		.odsel     (pixel_pll_odsel),
		.pll_reset (pixel_pll_reset),
		.pll_ready (pixel_pll_ready)
	);


	// The 1:16 word clock transports 16 bits per lane each cycle.  Select the
	// compile-time PLL ratio that converts aggregate link throughput to one
	// RGB888 pixel per pixel-clock cycle.  Only one branch is elaborated, so the
	// three supported configurations still consume one physical PLLVR.
	generate
		if (`MIPI_RX_LANES == 1) begin : g_pixel_pll_1lane
			Gowin_PLLVR_M2D3 u_pll_v_pclk(
				.clkout (clk_pixel_out), .lock (lock),
				.reset (pixel_pll_reset), .clkin (clk_byte_out),
				.odsel (pixel_pll_odsel)
			);
		end else if (`MIPI_RX_LANES == 2) begin : g_pixel_pll_2lane
			Gowin_PLLVR_M4D3 u_pll_v_pclk(
				.clkout (clk_pixel_out), .lock (lock),
				.reset (pixel_pll_reset), .clkin (clk_byte_out),
				.odsel (pixel_pll_odsel)
			);
		end else begin : g_pixel_pll_4lane
			Gowin_PLLVR_M8D3 u_pll_v_pclk(
				.clkout (clk_pixel_out), .lock (lock),
				.reset (pixel_pll_reset), .clkin (clk_byte_out),
				.odsel (pixel_pll_odsel)
			);
		end
	endgenerate

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
	wire domain_reset_n_async = rst_n & receiver_trained & pixel_pll_ready;
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
	assign v_ready = rst_n_pixel_sync;

	// Runtime TCON register bank. vin_mipi only supplies validated protocol
	// fields; register meanings and clock-domain transfers live in one place.
	tcon_regs u_tcon_regs (
		.rst_n         (rst_n),
		.sys_clk       (clk),
		.byte_clk      (clk_byte_out),
		.pixel_clk     (clk_pixel_out),
		.pixel_rst_n   (rst_n_pixel_sync),
		.sp_en         (o_sp_en),
		.ecc_ok        (ecc_ok),
		.dt            (o_sp_dt),
		.wc            (o_sp_wc),
		.mode_write    (v_mode_cmd_valid),
		.mode_value    (v_mode_cmd_value),
		.panel_power   (tcon_power_request),
		.reinit_request(v_reinit_cmd_valid)
	);

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
		.LANES        (`MIPI_RX_LANES),
		.HSYNC_WIDTH (`DEFAULT_HSYNC),   // hsync pulse width in pixel clocks
		.VSYNC_LINES (`DEFAULT_VSYNC)    // vsync pulse width in pixel clocks
	) u_pixel_converter (
		.clk_byte       (clk_byte_out),
		.rst_n_byte     (rst_n_byte_sync),
		.i_sp_en        (o_sp_en_dl),        // o_sp_en & ecc_ok
		.i_sp_dt        (o_sp_dt_dl),
		.i_lp_av_en     (o_lp_av_en_dl),     // o_lp_av_en & ecc_ok
		.i_dt           (o_dt_dl),
		.i_wc           (o_wc_dl),           // word count (payload bytes)
		.i_payload      (o_payload_dl),      // two bytes per enabled lane
		.i_payload_dv   (o_payload_dv_dl),   // byte-valid per payload byte
		.i_stream_reset (stream_reset_request),
		.clk_pixel      (clk_pixel_out),
		.rst_n_pixel    (rst_n_pixel_sync),
		.o_vsync        (conv_vsync),
		.o_hsync        (conv_hsync),
		.o_de           (conv_de),
		.o_pixel        (conv_pixel),         // RGB888
		.o_stream_fault (v_stream_fault)
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
