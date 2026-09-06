// Copyright Wenting Zhang 2024
// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2
//
// You may redistribute and modify this source and make products using
// it under the terms of the CERN-OHL-S v2 (https://cern.ch/cern-ohl).
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.
//
// This file incorporates source code from the Caster project
// (CERN-OHL-P v2, Copyright Wenting Zhang 2024).
// A copy of CERN-OHL-P v2 is provided in LICENSE-CERN-OHL-P.
//
// Modified by Yuhan Jiang on 2025-2026:
//   - Adapted for Gowin GW1NSR-4C FPGA platform
//   - Removed external CSR/command interface (simplified for standalone use)
//   - Added SYS_CLEAR mode with panel initialization sequence
//   - Adjusted FAST_MONO timing parameters for EPD panel
//   - Expanded fast_grey lookup tables for 16-level grayscale

`timescale 1ns / 1ps
`include "defines.vh"

module pixel_processing (
	input  wire [3:0]  proc_pixel,            // New pixel from MIPI (Y4)
	input  wire [3:0]  proc_vin,              // Mode-selected/dithered input
	input  wire [15:0] proc_bi,               // Pixel state from framebuffer
	input  wire [1:0]  proc_lut_rd,           // Waveform LUT readout
	input  wire [1:0]  sys_mode,              // SYS_CLEAR / SYS_NORMAL(GC16) / SYS_AUTO_LUT
	input  wire [5:0]  al_framecnt,           // Auto LUT global frame counter
	input  wire [9:0]  clear_frame_cnt,
	output reg  [15:0] proc_bo,               // Pixel state writeback to framebuffer
	output reg  [1:0]  proc_output            // EPD drive output
);

	// Pixel state: 16bits
	// Bit 15-12: Mode
	// Bit 13-12 is shared
	localparam MODE_MANUAL_LUT_NO_DITHER = 2'd0; // 00xx
	localparam MODE_MANUAL_LUT_BLUE_NOISE = 2'd1; // 01xx
	localparam MODE_FAST_MONO_NO_DITHER = 4'd8; // 1000
//    localparam MODE_FAST_MONO_BAYER = 4'd9; // 1001
	localparam MODE_FAST_MONO_BLUE_NOISE = 4'd10; // 1010
	localparam MODE_FAST_GREY = 4'd11; // 1011
	localparam MODE_AUTO_LUT_NO_DITHER = 4'd12; // 1100
	localparam MODE_AUTO_LUT_BLUE_NOISE = 4'd13; // 1101

	localparam FASTM_B2W_FRAMES = 6'd6;
	localparam FASTM_W2B_FRAMES = 6'd6;

	localparam FASTG_HOLDOFF_FRAMES = 6'd1;
	localparam FASTG_B2G_FRAMES = 6'd2;
	localparam FASTG_W2G_FRAMES = 6'd2;
	localparam FASTG_SETTLE_FRAMES = 6'd5;

	localparam AUTOLUT_HOLDOFF_FRAMES = 6'd10;

	wire [5:0] fastg_g2w_frames =
		(pixel_prev == 4'd0) ? 6'd9 : // Black to white
		(pixel_prev == 4'd1) ? 6'd9 :
		(pixel_prev == 4'd2) ? 6'd9 :
		(pixel_prev == 4'd3) ? 6'd9 :
		(pixel_prev == 4'd4) ? 6'd8 :
		(pixel_prev == 4'd5) ? 6'd8 :
		(pixel_prev == 4'd6) ? 6'd8 :
		(pixel_prev == 4'd7) ? 6'd7 :
		(pixel_prev == 4'd8) ? 6'd7 :
		(pixel_prev == 4'd9) ? 6'd6 :
		(pixel_prev == 4'd10) ? 6'd6 :
		(pixel_prev == 4'd11) ? 6'd5 :
		(pixel_prev == 4'd12) ? 6'd4 :
		(pixel_prev == 4'd13) ? 6'd3 :
		(pixel_prev == 4'd14) ? 6'd2 : 6'd1;

	wire [5:0] fastg_g2b_frames =
		(pixel_prev == 4'd0) ? 6'b1 : // Black to black
		(pixel_prev == 4'd1) ? 6'd2 :
		(pixel_prev == 4'd2) ? 6'd2 :
		(pixel_prev == 4'd3) ? 6'd3 :
		(pixel_prev == 4'd4) ? 6'd3 :
		(pixel_prev == 4'd5) ? 6'd4 :
		(pixel_prev == 4'd6) ? 6'd4 :
		(pixel_prev == 4'd7) ? 6'd5 :
		(pixel_prev == 4'd8) ? 6'd6 :
		(pixel_prev == 4'd9) ? 6'd7 :
		(pixel_prev == 4'd10) ? 6'd8 :
		(pixel_prev == 4'd11) ? 6'd9 :
		(pixel_prev == 4'd12) ? 6'd9 :
		(pixel_prev == 4'd13) ? 6'd9 :
		(pixel_prev == 4'd14) ? 6'd9 : 6'd9;

	// In auto LUT mode:
	// Bit 11-10: Stage
	// In MONO stage:
	// Bit 9-4: Frame counter
	// Bit 3-2: Dynamic frame rate cap
	// Bit 1: Reserved, keep at 0
	// Bit 0: Previous frame pixel value (0 black 1 white)
	// In DONE/HOLD stage:
	// Bit 9-4: Frame counter
	// Bit 3-0: Last pixel value
	// In GREY stage:
	// Bit 9-8: Reserved
	// Bit 7-4: Source pixel value
	// Bit 3-0: Target pixel value
	// Auto LUT mode is a hybrid between fast mono mode and dithered LUT mode.
	// The update process of each pixel is divided into 4 stages:
	localparam STAGE_DONE = 2'd0; // Screen already settled. No operation
	localparam STAGE_MONO = 2'd1; // Driving to mono (same as fast mono mode)
	localparam STAGE_HOLD = 2'd2; // Hold off (wait before start driving greyscale)
	localparam STAGE_GREY = 2'd3; // Driving to greyscale (non-cancellable)
	// When change is detected on the DONE pixel, it kicks off the update process
	// immediately similar to the fast mono mode, entering the MONO stage.
	// Once the mono update is done, it enters the HOLD stage.
	// If changes are detected during HOLD stage, it goes back to the MONO stage.
	// If the HOLD stage times out (means no changes are ever detected) and global
	// greyscale counter is at 1 (next round starts the next frame), it updates
	// The source and destination colors and enters GREY stage.
	// In the GREY stage it follows the waveform LUT to drive the screen. Once
	// that's done it goes back to the DONE stage.

	// In manual LUT mode:
	// Bit 13-10: Source pixel value
	// Bit 9-4: Frame counter
	// Bit 3-0: Target pixel value
	// When frame counter is not 0, waveform lookup is in progress.
	// When lookup is in progress, both target and source pixel value are hold
	// still, and the frame counter is decremented.
	// When lookup is not in progress and an external update is request on the
	// region, the input pixel is copied to target pixel value, the old target
	// pixel value (current screen status) is copied to target pixel value, and
	// the frame counter is set to LUT frame length.

	// In fast mono mode:
	// Bit 11-10: Reserved
	// Bit 9-4: Frame counter
	// Bit 3-2: Dynamic frame rate cap
	// Bit 1: Reserved, keep at 0
	// Bit 0: Previous frame pixel value (0 black 1 white)

	// In fast grey 4-level mode:
	// Bit 11-10: Stage
	// Bit 9-4: Frame counter
	// Bit 3-2: Reserved, keep at 0
	// Bit 1-0: Previous frame pixel value

	// Pixel processing
	wire [1:0] pixel_mode_hi = proc_bi[15:14];
	wire [3:0] pixel_mode = proc_bi[15:12];
	wire [1:0] pixel_stage = proc_bi[11:10];
	wire [5:0] pixel_framecnt = proc_bi[9:4];
	wire [3:0] pixel_prev = proc_bi[3:0];
	wire [1:0] pixel_mindrv = proc_bi[3:2];
	wire [5:0] pixel_framecnt_dec = pixel_framecnt - 1;
	wire [1:0] pixel_mindrv_dec = (pixel_mindrv != 2'd0) ? (pixel_mindrv - 2'd1) : 2'd0;
	// Specific to fast mono mode
	wire [5:0] pixel_framecnt_2w = FASTM_B2W_FRAMES - pixel_framecnt + 1;
	wire [5:0] pixel_framecnt_2b = FASTM_W2B_FRAMES - pixel_framecnt + 1;

	// Decode base mode and dither mode
	localparam BASEMODE_MANUAL_LUT = 2'b00;
	localparam BASEMODE_FAST_MONO = 2'b01;
	localparam BASEMODE_FAST_GREY = 2'b10;
	localparam BASEMODE_AUTO_LUT = 2'b11;

	localparam DITHER_NONE = 3'b000;
	localparam DITHER_BN_1BIT = 3'b010;
	localparam DITHER_BN_4BIT = 3'b011;

	reg [1:0] pixel_basemode;
	reg [2:0] pixel_dither;
	always @(*) begin
		case (pixel_mode_hi)
		MODE_MANUAL_LUT_NO_DITHER: begin
			pixel_basemode = BASEMODE_MANUAL_LUT;
			pixel_dither = DITHER_NONE;
		end
		MODE_MANUAL_LUT_BLUE_NOISE: begin
			pixel_basemode = BASEMODE_MANUAL_LUT;
			pixel_dither = DITHER_BN_4BIT;
		end
		default: begin
			case (pixel_mode)
			MODE_FAST_MONO_NO_DITHER: begin
				pixel_basemode = BASEMODE_FAST_MONO;
				pixel_dither = DITHER_NONE;
			end
			MODE_FAST_MONO_BLUE_NOISE: begin
				pixel_basemode = BASEMODE_FAST_MONO;
				pixel_dither = DITHER_BN_1BIT;
			end
			MODE_FAST_GREY: begin
				pixel_basemode = BASEMODE_FAST_GREY;
				pixel_dither = DITHER_NONE;
			end
			MODE_AUTO_LUT_NO_DITHER: begin
				pixel_basemode = BASEMODE_AUTO_LUT;
				pixel_dither = DITHER_NONE;
			end
			MODE_AUTO_LUT_BLUE_NOISE: begin
				pixel_basemode = BASEMODE_AUTO_LUT;
				pixel_dither = DITHER_BN_4BIT;
			end
			default: begin
				// Fallback, todo: report this as an error
				pixel_basemode = BASEMODE_FAST_MONO;
				pixel_dither = DITHER_NONE;
			end
			endcase
		end
		endcase
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// Only 4 MSBs used
	wire [7:0] proc_pixel_linear; // linear
	/* verilator lint_on UNUSEDSIGNAL */
	// Let it optimize, only 4b in and 4b out used
	assign proc_pixel_linear = {proc_pixel, 4'b0};

	wire [3:0] proc_vinnd = proc_pixel;

	`define NO_DRIVE     2'b00
	`define DRIVE_BLACK  2'b01
	`define DRIVE_WHITE  2'b10

	wire [1:0] drive_towards_input = proc_vin[3] ? `DRIVE_WHITE: `DRIVE_BLACK;
	wire [1:0] drive_against_input = proc_vin[3] ? `DRIVE_BLACK: `DRIVE_WHITE;

	always @(*) begin
		// safe default — prevent latches
		proc_output = `NO_DRIVE;
		proc_bo     = proc_bi;

		case (pixel_basemode)
		BASEMODE_MANUAL_LUT: begin
			if (pixel_framecnt != 0) begin
				proc_output = proc_lut_rd;
				proc_bo = {proc_bi[15:10], pixel_framecnt_dec, proc_bi[3:0]};
			end
			else begin
				proc_output = `NO_DRIVE;
				proc_bo = proc_bi;
			end
		end
		BASEMODE_AUTO_LUT: begin
			if (pixel_stage == STAGE_MONO) begin
				if ((proc_vinnd[3] != pixel_prev[0]) && (pixel_mindrv == 2'd0)) begin
					proc_output = drive_towards_input;
					proc_bo = proc_vinnd[3] ?
						{proc_bi[15:10], pixel_framecnt_2w, `DEFAULT_MINDRV, 2'd1} :
						{proc_bi[15:10], pixel_framecnt_2b, `DEFAULT_MINDRV, 2'd0};
				end
				else begin
					proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
					if (pixel_framecnt == 0) begin
						proc_bo = {proc_bi[15:12], STAGE_HOLD, AUTOLUT_HOLDOFF_FRAMES - FASTM_B2W_FRAMES, {4{pixel_prev[0]}}};
					end
					else begin
						proc_bo = {proc_bi[15:10], pixel_framecnt_dec, pixel_mindrv_dec, proc_bi[1:0]};
					end
				end
			end
			else if (pixel_stage == STAGE_HOLD) begin
				if (proc_vinnd[3] != pixel_prev[3]) begin
					proc_output = drive_towards_input;
					proc_bo = proc_vinnd[3] ?
						{proc_bi[15:12], STAGE_MONO, FASTM_B2W_FRAMES, `DEFAULT_MINDRV, 2'd1} :
						{proc_bi[15:12], STAGE_MONO, FASTM_W2B_FRAMES, `DEFAULT_MINDRV, 2'd0};
				end
				else begin
					proc_output = `NO_DRIVE;
					if (pixel_framecnt == 0) begin
						if (al_framecnt == 0) begin
							if (pixel_prev != proc_vin)
								proc_bo = {proc_bi[15:12], STAGE_GREY, 2'b0, pixel_prev, proc_vin};
							else
								proc_bo = {proc_bi[15:12], STAGE_DONE, 6'd0, pixel_prev};
						end
						else begin
							proc_bo = proc_bi;
						end
					end
					else begin
						proc_bo = {proc_bi[15:10], pixel_framecnt_dec, proc_bi[3:0]};
					end
				end
			end
			else if (pixel_stage == STAGE_GREY) begin
				proc_output = proc_lut_rd;
				if (al_framecnt == 0) begin
					proc_bo = {proc_bi[15:12], STAGE_DONE, 6'd0, pixel_prev};
				end
				else begin
					proc_bo = proc_bi;
				end
			end
			else if (pixel_stage == STAGE_DONE) begin
				if (proc_vin[3:0] != pixel_prev[3:0]) begin
					proc_output = drive_towards_input;
					proc_bo = proc_vin[3] ?
						{proc_bi[15:12], STAGE_MONO, fastg_g2w_frames, `DEFAULT_MINDRV, 2'd1} :
						{proc_bi[15:12], STAGE_MONO, fastg_g2b_frames, `DEFAULT_MINDRV, 2'd0};
				end
				else begin
					proc_output = `NO_DRIVE;
					proc_bo = proc_bi;
				end
			end
		end
		BASEMODE_FAST_MONO: begin
			if (pixel_framecnt != 0) begin
				if ((proc_vin[3] != pixel_prev[0]) && (pixel_mindrv == 2'd0)) begin
					proc_output = drive_towards_input;
					proc_bo = proc_vin[3] ?
						{proc_bi[15:10], pixel_framecnt_2w, `DEFAULT_MINDRV, 2'd1} :
						{proc_bi[15:10], pixel_framecnt_2b, `DEFAULT_MINDRV, 2'd0};
				end
				else begin
					proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
					proc_bo = {proc_bi[15:10], pixel_framecnt_dec, pixel_mindrv_dec, proc_bi[1:0]};
				end
			end
			else begin
				if (proc_vin[3] != pixel_prev[0]) begin
					proc_output = drive_towards_input;
					proc_bo = proc_vin[3] ?
						{proc_bi[15:10], FASTM_B2W_FRAMES, `DEFAULT_MINDRV, 2'd1} :
						{proc_bi[15:10], FASTM_W2B_FRAMES, `DEFAULT_MINDRV, 2'd0};
				end
				else begin
					proc_output = `NO_DRIVE;
					proc_bo = proc_bi;
				end
			end
		end
		BASEMODE_FAST_GREY: begin
			if (pixel_stage == STAGE_MONO) begin
				proc_output = drive_towards_input;
				if ((proc_vin[3] != pixel_prev[1]) && (pixel_mindrv == 2'd0)) begin
					proc_bo = proc_vin[3] ?
						{proc_bi[15:12], STAGE_MONO, pixel_framecnt_2w, `DEFAULT_MINDRV, proc_vin[3:2]} :
						{proc_bi[15:12], STAGE_MONO, pixel_framecnt_2b, `DEFAULT_MINDRV, proc_vin[3:2]};
				end
				else begin
					proc_output = pixel_prev[1] ? `DRIVE_WHITE : `DRIVE_BLACK;
					if (pixel_framecnt == 0) begin
						proc_bo = {proc_bi[15:12], STAGE_HOLD, FASTG_HOLDOFF_FRAMES, proc_bi[3:0]};
					end
					else begin
						proc_bo = {proc_bi[15:10], pixel_framecnt_dec, pixel_mindrv_dec, proc_bi[1:0]};
					end
				end
			end
			else if (pixel_stage == STAGE_HOLD) begin
				if (proc_vin[3] != pixel_prev[1]) begin
					proc_output = drive_towards_input;
					proc_bo = proc_vin[3] ?
						{proc_bi[15:12], STAGE_MONO, FASTM_B2W_FRAMES, `DEFAULT_MINDRV, proc_vin[3:2]} :
						{proc_bi[15:12], STAGE_MONO, FASTM_W2B_FRAMES, `DEFAULT_MINDRV, proc_vin[3:2]};
				end
				else begin
					proc_output = `NO_DRIVE;
					if (pixel_framecnt == 0) begin
						proc_bo = (proc_vin[3:2] == 2'b10) ?
							{proc_bi[15:12], STAGE_GREY, FASTG_W2G_FRAMES + FASTG_SETTLE_FRAMES, 2'b00, proc_vin[3:2]} :
							(proc_vin[3:2] == 2'b01) ?
							{proc_bi[15:12], STAGE_GREY, FASTG_B2G_FRAMES + FASTG_SETTLE_FRAMES, 2'b00, proc_vin[3:2]} :
							{proc_bi[15:12], STAGE_DONE, 6'd0, 2'b00, proc_vin[3:2]};
					end
					else begin
						proc_bo = {proc_bi[15:10], pixel_framecnt_dec, proc_bi[3:0]};
					end
				end
			end
			else if (pixel_stage == STAGE_GREY) begin
				if (pixel_framecnt > FASTG_SETTLE_FRAMES) begin
					proc_output = pixel_prev[1] ? `DRIVE_BLACK : `DRIVE_WHITE;
				end
				else begin
					proc_output = `NO_DRIVE;
				end
				if (pixel_framecnt == 0) begin
					proc_bo = {proc_bi[15:12], STAGE_DONE, 6'd0, proc_bi[3:0]};
				end
				else begin
					proc_bo = {proc_bi[15:10], pixel_framecnt_dec, proc_bi[3:0]};
				end
			end
			else if (pixel_stage == STAGE_DONE) begin
				if (proc_vin[3:2] != pixel_prev[1:0]) begin
					proc_output = drive_towards_input;
					proc_bo = ((proc_vin[3] != pixel_prev[1]) || (pixel_prev[1] != pixel_prev[0])) ?
						(proc_vin[3] ?
							{proc_bi[15:12], STAGE_MONO, FASTM_B2W_FRAMES, `DEFAULT_MINDRV, proc_vin[3:2]} :
							{proc_bi[15:12], STAGE_MONO, FASTM_W2B_FRAMES, `DEFAULT_MINDRV, proc_vin[3:2]}) :
						((proc_vin[3:2] == 2'b10) ?
							{proc_bi[15:12], STAGE_GREY, FASTG_W2G_FRAMES + FASTG_SETTLE_FRAMES, 2'b00, proc_vin[3:2]} :
							(proc_vin[3:2] == 2'b01) ?
							{proc_bi[15:12], STAGE_GREY, FASTG_B2G_FRAMES + FASTG_SETTLE_FRAMES, 2'b00, proc_vin[3:2]} :
							{proc_bi[15:12], STAGE_DONE, 6'd0, 2'b00, proc_vin[3:2]});
				end
				else begin
					proc_output = `NO_DRIVE;
					proc_bo = proc_bi;
				end
			end
		end
		endcase

		// CLEAR override - all modes -> white drive + init to selected mode
		if (sys_mode == `SYS_CLEAR) begin
			// Keep the startup waveform DC-balanced. The previous inclusive
			// boundaries produced 15 black frames but only 14 white frames.
			if (clear_frame_cnt < 10'd14)
				proc_output = `DRIVE_BLACK;
			else if (clear_frame_cnt < 10'd16)
				proc_output = `NO_DRIVE;
			else if (clear_frame_cnt < 10'd30)
				proc_output = `DRIVE_WHITE;
			else
				proc_output = `NO_DRIVE;
	`ifdef INIT_MODE_FAST_MONO
			proc_bo = {MODE_FAST_MONO_NO_DITHER, 2'b0, 6'd0, 3'd0, 1'b1};
	`elsif INIT_MODE_FAST_MONO_BN
			proc_bo = {MODE_FAST_MONO_BLUE_NOISE, 2'b0, 6'd0, 3'd0, 1'b1};
	`elsif INIT_MODE_FAST_GREY
			proc_bo = {MODE_FAST_GREY, STAGE_DONE, 6'd0, 2'b0, 2'b11};
	`elsif INIT_MODE_AUTO_LUT
			proc_bo = {MODE_AUTO_LUT_NO_DITHER, STAGE_DONE, 6'd0, 4'hF};
	`elsif INIT_MODE_AUTO_LUT_BN
			proc_bo = {MODE_AUTO_LUT_BLUE_NOISE, STAGE_DONE, 6'd0, 4'hF};
	`elsif INIT_MODE_MANUAL_LUT
			proc_bo = {MODE_MANUAL_LUT_NO_DITHER, 4'hF, 6'd0, 4'hF};
	`elsif INIT_MODE_MANUAL_LUT_BN
			proc_bo = {MODE_MANUAL_LUT_BLUE_NOISE, 4'hF, 6'd0, 4'hF};
	`else
			proc_bo = {MODE_FAST_MONO_NO_DITHER, 2'b0, 6'd0, 3'd0, 1'b1};
	`endif
		end
	end

endmodule
