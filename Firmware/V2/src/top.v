// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2
//
// You may redistribute and modify this source and make products using
// it under the terms of the CERN-OHL-S v2 (https://cern.ch/cern-ohl).
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.

`timescale 1ns/1ps

module top (
	input  wire       sys_clk,

	output wire       pmic_pwrup,
	inout  wire       pmic_sda,
	inout  wire       pmic_scl,

	output wire       epd_gdclk,
	output wire       epd_gdsp,
	output wire       epd_sdclk,
	output wire       epd_sdle,
	output wire       epd_sdce,
	output wire [15:0] epd_data,

	inout  wire       mipi_clk_p,
	inout  wire       mipi_clk_n,
	inout  wire       mipi_lane0_p,
	inout  wire       mipi_lane0_n,
	inout  wire       mipi_lane1_p,
	inout  wire       mipi_lane1_n,

	output wire [0:0] O_hpram_ck,
	output wire [0:0] O_hpram_ck_n,
	output wire [0:0] O_hpram_cs_n,
	output wire [0:0] O_hpram_reset_n,
	inout  wire [7:0] IO_hpram_dq,
	inout  wire [0:0] IO_hpram_rwds
);

	// =========================================================================
	// Wires
	// =========================================================================
	wire [15:0] bi_data;
	wire        bi_clk;
	wire        bi_vsync;
	wire        bi_de;
	wire        bi_den;
	wire [15:0] bo_data;
	wire        bo_clk;
	wire        bo_vsync;
	wire        bo_de;
	wire        init_done;
	wire        sys_ready;

	// =========================================================================
	// Power-on reset
	// =========================================================================
	reg [5:0] por_cnt = 6'd0;
	wire      sys_rst_n = por_cnt[5];

	always @(posedge sys_clk) begin
		if (!sys_rst_n) begin
			por_cnt <= por_cnt + 6'd1;
		end
	end

	// =========================================================================
	// PMIC control
	// =========================================================================
	wire pmic_ready;
	assign sys_ready = pmic_ready & init_done;

	pmic_ctrl #(
		.vcom_val      (`VCOM_VOL)
	) u_pmic_ctrl (
		.clk           (sys_clk),
		.rst_n         (sys_rst_n),
		.pmic_pwrup    (pmic_pwrup),
		.pmic_sda      (pmic_sda),
		.pmic_scl      (pmic_scl),
		.done_flag     (pmic_ready),
		.error_flag    ()
	);

	// =========================================================================
	// Selectable video input stream
	// =========================================================================
	wire        vin_pclk;
	wire        vin_vsync;
	wire        vin_hsync;
	wire        vin_de;
	wire [3:0]  vin_pixel;
	wire        source_pclk;
	wire        source_vsync;
	wire        source_hsync;
	wire        source_de;
	wire [3:0]  source_pixel;
	wire        mipi_pclk;
	wire        mipi_vsync;
	wire        mipi_hsync;
	wire        mipi_de;
	wire [3:0]  mipi_pixel;
	(* syn_keep = 1 *) wire        mipi_stream_fault;
	(* syn_keep = 1 *) wire [15:0] mipi_fifo_overflow_count;
	(* syn_keep = 1 *) wire [15:0] mipi_fifo_empty_count;
	wire        fb_vin_fifo_full;
	wire        fb_vout_fifo_empty;

	// Keep the D-PHY instance in both builds: Gowin's MIPI pin constraints are
	// only legal while the corresponding MIPI primitive exists in the netlist.
	// In test mode none of these outputs clock or feed the display pipeline.
	vin_mipi u_vin_mipi (
		.clk         (sys_clk),
		.rst_n       (sys_rst_n),
		.mipi_clk_p  (mipi_clk_p),
		.mipi_clk_n  (mipi_clk_n),
		.mipi_lane0_p(mipi_lane0_p),
		.mipi_lane0_n(mipi_lane0_n),
		.mipi_lane1_p(mipi_lane1_p),
		.mipi_lane1_n(mipi_lane1_n),
		.v_pclk      (mipi_pclk),
		.v_vsync     (mipi_vsync),
		.v_hsync     (mipi_hsync),
		.v_de        (mipi_de),
		.v_pixel     (mipi_pixel),
		.v_stream_fault(mipi_stream_fault),
		.v_fifo_overflow_count(mipi_fifo_overflow_count),
		.v_fifo_empty_count(mipi_fifo_empty_count)
	);

`ifdef EPD_INTERNAL_TEST
	wire selected_stream_fault = 1'b0;
	wire [31:0] test_frame_count;

	internal_video_gen #(
		.H_ACTIVE      (`DEFAULT_HACT),
		.H_SYNC        (`DEFAULT_HSYNC),
		.H_BACK_PORCH  (`DEFAULT_HBP),
		.H_FRONT_PORCH (`DEFAULT_HFP),
		.V_ACTIVE      (`DEFAULT_VACT),
		.V_SYNC        (`DEFAULT_VSYNC),
		.V_BACK_PORCH  (`DEFAULT_VBP),
		.V_FRONT_PORCH (`DEFAULT_VFP),
		.PATTERN_MODE  (`EPD_TEST_PATTERN_MODE),
		.TOGGLE_FRAMES (`EPD_TEST_CHANGE_FRAMES),
		.CLK_HZ        (`EPD_TEST_SYS_CLK_HZ),
		.TARGET_FPS    (`EPD_TEST_PATTERN_FPS)
	) u_internal_video_gen (
		.clk         (sys_clk),
		.rst_n       (sys_rst_n),
		.enable      (1'b1),
		.pclk        (source_pclk),
		.vsync       (source_vsync),
		.hsync       (source_hsync),
		.de          (source_de),
		.pixel       (source_pixel),
		.frame_count (test_frame_count)
	);
`else
	wire selected_stream_fault = mipi_stream_fault;
	assign source_pclk  = mipi_pclk;
	assign source_vsync = mipi_vsync;
	assign source_hsync = mipi_hsync;
	assign source_de    = mipi_de;
	assign source_pixel = mipi_pixel;
`endif

	assign vin_pclk = source_pclk;

`ifdef EPD_PIXEL_REORDER
	epd_pixel_reorder #(
		.IN_HFP   (`DEFAULT_HFP),
		.IN_HSYNC (`DEFAULT_HSYNC),
		.IN_HBP   (`DEFAULT_HBP),
		.IN_HACT  (`DEFAULT_HACT),
		.IN_VFP   (`DEFAULT_VFP),
		.IN_VSYNC (`DEFAULT_VSYNC),
		.IN_VBP   (`DEFAULT_VBP),
		.IN_VACT  (`DEFAULT_VACT)
	) u_epd_pixel_reorder (
		.clk       (vin_pclk),
		.rst_n     (sys_rst_n),
		.in_vsync  (source_vsync),
		.in_hsync  (source_hsync),
		.in_de     (source_de),
		.in_pixel  (source_pixel),
		.out_vsync (vin_vsync),
		.out_hsync (vin_hsync),
		.out_de    (vin_de),
		.out_pixel (vin_pixel)
	);
`else
	assign vin_vsync = source_vsync;
	assign vin_hsync = source_hsync;
	assign vin_de    = source_de;
	assign vin_pixel = source_pixel;
`endif

	// =========================================================================
	// Pomo
	// =========================================================================

	pomo u_pomo (
		.clk        (vin_pclk),
		.sys_ready  (sys_ready),
		.rst        (~sys_rst_n),
		.vin_vsync  (vin_vsync),
		.vin_hsync  (vin_hsync),
		.vin_de     (vin_de),
		.vin_pixel  (vin_pixel),
		.vin_stream_fault(selected_stream_fault),
		.fb_wr_full (fb_vin_fifo_full),
		.fb_rd_empty(fb_vout_fifo_empty),
		.bo_clk     (bo_clk),
		.bo_vsync   (bo_vsync),
		.bo_de      (bo_de),
		.bo_data    (bo_data),
		.bi_clk     (bi_clk),
		.bi_vsync   (bi_vsync),
		.bi_de      (bi_de),
		.bi_den     (bi_den),
		.bi_data    (bi_data),
		.epd_gdclk  (epd_gdclk),
		.epd_gdsp   (epd_gdsp),
		.epd_sdclk  (epd_sdclk),
		.epd_sdle   (epd_sdle),
		.epd_data   (epd_data),
		.epd_sdce   (epd_sdce)
	);

	// =========================================================================
	// Framebuffer HyperRAM
	// =========================================================================

	fb_hpram #(
		.ADDR_WIDTH     (22),  
		.DATA_WIDTH     (32),  
		.WR_VIDEO_WIDTH (16),  
		.RD_VIDEO_WIDTH (16)
	) u_fb_hpram (
		.clk            (sys_clk),
		.rst_n          (sys_rst_n),
		.O_hpram_ck     (O_hpram_ck),
		.O_hpram_ck_n   (O_hpram_ck_n),
		.O_hpram_cs_n   (O_hpram_cs_n),
		.O_hpram_reset_n(O_hpram_reset_n),
		.IO_hpram_dq    (IO_hpram_dq),
		.IO_hpram_rwds  (IO_hpram_rwds),
		.bo_clk         (bo_clk),
		.bo_vsync       (bo_vsync),
		.bo_de          (bo_de),
		.bo_data        (bo_data),
		.bi_clk         (bi_clk),
		.bi_vsync       (bi_vsync),
		.bi_de          (bi_de),
		.bi_den         (bi_den),
		.bi_data        (bi_data),
		.init_done      (init_done),
		.vin_fifo_full  (fb_vin_fifo_full),
		.vout_fifo_empty(fb_vout_fifo_empty)
	);











	// =========================================================================
	// Debug: measure sys_clk frequency using vin_pclk as reference
	// vin_pclk is assumed to be 29 MHz
	//
	// sys_clk_freq = sys_clk_cnt_latched * 29 MHz / 1_000_000
	// =========================================================================

//    localparam [23:0] REF_VIN_CNT_MAX = 24'd1_000_000;

	// -------------------------------------------------------------------------
	// vin_pclk domain: generate a toggle every 1,000,000 vin_pclk cycles
	// -------------------------------------------------------------------------
//    reg [23:0] ref_vin_cnt = 24'd0;
//    reg        ref_toggle_vin = 1'b0;

//    always @(posedge vin_pclk or negedge sys_rst_n) begin
//        if (!sys_rst_n) begin
//            ref_vin_cnt    <= 24'd0;
//            ref_toggle_vin <= 1'b0;
//        end else begin
//            if (ref_vin_cnt == REF_VIN_CNT_MAX - 1'b1) begin
//                ref_vin_cnt    <= 24'd0;
//                ref_toggle_vin <= ~ref_toggle_vin;
//            end else begin
//                ref_vin_cnt <= ref_vin_cnt + 1'b1;
//            end
//        end
//    end

	// -------------------------------------------------------------------------
	// sys_clk domain: synchronize toggle
	// -------------------------------------------------------------------------
//    reg ref_toggle_sys_d1 = 1'b0;
//    reg ref_toggle_sys_d2 = 1'b0;
//    reg ref_toggle_sys_d3 = 1'b0;

//    always @(posedge sys_clk or negedge sys_rst_n) begin
//        if (!sys_rst_n) begin
//            ref_toggle_sys_d1 <= 1'b0;
//            ref_toggle_sys_d2 <= 1'b0;
//            ref_toggle_sys_d3 <= 1'b0;
//        end else begin
//            ref_toggle_sys_d1 <= ref_toggle_vin;
//            ref_toggle_sys_d2 <= ref_toggle_sys_d1;
//            ref_toggle_sys_d3 <= ref_toggle_sys_d2;
//        end
//    end

//    wire ref_toggle_edge_sys = ref_toggle_sys_d2 ^ ref_toggle_sys_d3;

	// -------------------------------------------------------------------------
	// sys_clk domain: count sys_clk cycles between two toggle events
	// -------------------------------------------------------------------------
//    (* syn_keep = 1 *) reg [31:0] sys_clk_cnt = 32'd0;
//    (* syn_keep = 1 *) reg [31:0] sys_clk_cnt_latched = 32'd0;
//    (* syn_keep = 1 *) reg        sys_clk_measure_done = 1'b0;

//    always @(posedge sys_clk or negedge sys_rst_n) begin
//        if (!sys_rst_n) begin
//            sys_clk_cnt          <= 32'd0;
//            sys_clk_cnt_latched  <= 32'd0;
//            sys_clk_measure_done <= 1'b0;
//        end else begin
//            sys_clk_measure_done <= 1'b0;

//            sys_clk_cnt <= sys_clk_cnt + 1'b1;

//            if (ref_toggle_edge_sys) begin
//                sys_clk_cnt_latched  <= sys_clk_cnt;
//                sys_clk_cnt          <= 32'd0;
//                sys_clk_measure_done <= 1'b1;
//            end
//        end
//    end

endmodule
