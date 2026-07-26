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

module fb_hpram #(
	parameter ADDR_WIDTH      = 22,  
	parameter DATA_WIDTH      = 32,  
	parameter WR_VIDEO_WIDTH  = 16,  
	parameter RD_VIDEO_WIDTH  = 16
) (
	input wire clk,
	input wire rst_n,

	// ============================================================
	// HyperRAM physical interface
	// ============================================================
	output wire [0:0]              O_hpram_ck,
	output wire [0:0]              O_hpram_ck_n,
	output wire [0:0]              O_hpram_cs_n,
	output wire [0:0]              O_hpram_reset_n,
	inout  wire [DATA_WIDTH/4-1:0] IO_hpram_dq,
	inout  wire [0:0]              IO_hpram_rwds,

	// ============================================================
	// Framebuffer IO
	// ============================================================
	input  wire                      bo_clk,
	input  wire                      bo_vsync,
	input  wire                      bo_de,
	input  wire [WR_VIDEO_WIDTH-1:0] bo_data,

	input  wire                      bi_clk,
	input  wire                      bi_vsync,
	input  wire                      bi_de,
	output wire                      bi_den,
	output wire [RD_VIDEO_WIDTH-1:0] bi_data,

	// ============================================================
	// Status / clocks
	//
	// o_hpram_clk is the command/data clock exported by the Gowin
	// HyperRAM IP. The burst scheduler below runs in this domain.
	// Any upstream controller should also use o_hpram_clk.
	// ============================================================
	output wire init_done
);

	// ============================================================
	// Framebuffer
	// ============================================================
	
	wire                    cmd;
	wire                    cmd_en;
	wire [ADDR_WIDTH-1:0]   addr;
	wire [DATA_WIDTH-1:0]   wr_data;
	wire [DATA_WIDTH/8-1:0] data_mask;
	wire                    rd_data_valid;
	wire [DATA_WIDTH-1:0]   rd_data;

	Video_Frame_Buffer_Top u_framebuffer(
		.I_rst_n           (init_done), //input I_rst_n
		.I_dma_clk         (hpram_clk), //input I_dma_clk
//		.I_wr_halt         (1'd0), //input [0:0] I_wr_halt
//		.I_rd_halt         (1'd0), //input [0:0] I_rd_halt
		.I_vin0_clk        (bo_clk), //input I_vin0_clk
		.I_vin0_vs_n       (bo_vsync), //input I_vin0_vs_n
		.I_vin0_de         (bo_de), //input I_vin0_de
		.I_vin0_data       (bo_data), //input [15:0] I_vin0_data
		.O_vin0_fifo_full  (), //output O_vin0_fifo_full
		.I_vout0_clk       (bi_clk), //input I_vout0_clk
		.I_vout0_vs_n      (bi_vsync), //input I_vout0_vs_n
		.I_vout0_de        (bi_de), //input I_vout0_de
		.O_vout0_den       (bi_den), //output O_vout0_den
		.O_vout0_data      (bi_data), //output [15:0] O_vout0_data
		.O_vout0_fifo_empty(), //output O_vout0_fifo_empty
		.O_cmd             (cmd), //output O_cmd
		.O_cmd_en          (cmd_en), //output O_cmd_en
		.O_addr            (addr), //output [21:0] O_addr
		.O_wr_data         (wr_data), //output [31:0] O_wr_data
		.O_data_mask       (data_mask), //output [3:0] O_data_mask
		.I_rd_data_valid   (rd_data_valid), //input I_rd_data_valid
		.I_rd_data         (rd_data), //input [31:0] I_rd_data
		.I_init_calib      (init_done) //input I_init_calib
	);

	// ============================================================
	// HyperRAM
	// ============================================================
	wire        pll_lock;
	wire        memory_clk;

	Gowin_PLLVR_HYPERRAM u_pll_hpram (
		.clkout(memory_clk),
		.lock  (pll_lock),
		.reset (~rst_n),
		.clkin (clk)
	);

	HyperRAM_Memory_Interface_Top u_hpram_ip (
		.clk            (clk),
		.memory_clk     (memory_clk),
		.pll_lock       (pll_lock),
		.rst_n          (rst_n),
		.O_hpram_ck     (O_hpram_ck),
		.O_hpram_ck_n   (O_hpram_ck_n),
		.IO_hpram_dq    (IO_hpram_dq),
		.IO_hpram_rwds  (IO_hpram_rwds),
		.O_hpram_cs_n   (O_hpram_cs_n),
		.O_hpram_reset_n(O_hpram_reset_n),
		.wr_data        (wr_data),
		.rd_data        (rd_data),
		.rd_data_valid  (rd_data_valid),
		.addr           (addr),
		.cmd            (cmd),
		.cmd_en         (cmd_en),
		.init_calib     (init_done),
		.clk_out        (hpram_clk),
		.data_mask      (data_mask)
	);

endmodule
