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
`include "defines.vh"

module pomo (
	input  wire         clk,
	input  wire         sys_ready,
	input  wire         rst,

	input  wire         vin_vsync,
	input  wire         vin_hsync,
	input  wire         vin_de,
	input  wire [3:0]   vin_pixel,
	input  wire         vin_stream_fault,
	input  wire         fb_wr_full,
	input  wire         fb_rd_empty,

	output wire         bo_clk,
	output wire         bo_vsync,
	output wire         bo_de,
	output reg  [15:0]  bo_data,
	output wire         bi_clk,
	output wire         bi_vsync,
	output wire         bi_de,
	input  wire         bi_den,
	input  wire [15:0]  bi_data,

	output wire         epd_gdclk,
	output wire         epd_gdsp,
	output wire         epd_sdclk,
	output wire         epd_sdle,
	output wire [15:0]  epd_data,
	output wire         epd_sdce
);
	// sys_ready combines PMIC state from sys_clk with HyperRAM calibration
	// state from the memory domain.  Synchronize the resulting stable level
	// before it controls any state in this pixel-clock domain.
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [1:0] sys_ready_sync;
	always @(posedge clk) begin
		if (rst)
			sys_ready_sync <= 2'b00;
		else
			sys_ready_sync <= {sys_ready_sync[0], sys_ready};
	end
	wire sys_ready_clk = sys_ready_sync[1];

	// ============================================================
	// Scan Control
	//
	// Vertical:   counter-based. Frame line counts match defines.
	// Horizontal: signal-based. MIPI actual hsync/de timing may differ.
	// ============================================================

	// vertical timing (from defines, frame line counts are reliable)
	localparam [7:0]  VFP   = `DEFAULT_VFP;
	localparam [7:0]  VSYNC = `DEFAULT_VSYNC;
	localparam [7:0]  VBP   = `DEFAULT_VBP;
	localparam [11:0] VACT  = `EPD_VACT;

	// input edge detect
	reg vin_vsync_d;
	reg vin_hsync_d;

	always @(posedge clk) begin
		if (rst) begin
			vin_vsync_d <= 1'b0;
			vin_hsync_d <= 1'b0;
		end else begin
			vin_vsync_d <= vin_vsync;
			vin_hsync_d <= vin_hsync;
		end
	end

	wire vin_vsync_rise = vin_vsync & ~vin_vsync_d;
	wire vin_hsync_rise = vin_hsync & ~vin_hsync_d;

	// -------------------------------------------------------------------------
	// Streaming safety monitor
	// -------------------------------------------------------------------------
	// The framebuffer interface has no backpressure toward the MIPI source.
	// Track requests which have not produced a response for diagnostics. These
	// flags must never gate an active EPD scan because a partial Source/Gate
	// transfer is more harmful than reporting the fault at the frame boundary.
	localparam [11:0] MEM_OUTSTANDING_LIMIT = 12'd512;
	reg [11:0] mem_outstanding;
	(* syn_keep = 1 *) reg frame_fault;
	(* syn_keep = 1 *) reg [15:0] frame_fault_count;
	(* syn_keep = 1 *) reg [15:0] fb_wr_full_count;
	(* syn_keep = 1 *) reg [15:0] fb_rd_empty_count;

	always @(posedge clk) begin
		if (rst) begin
			mem_outstanding  <= 12'd0;
			frame_fault      <= 1'b0;
			frame_fault_count <= 16'd0;
			fb_wr_full_count <= 16'd0;
			fb_rd_empty_count <= 16'd0;
		end else begin
			if (vin_vsync_rise) begin
				mem_outstanding <= 12'd0;
				// Sample upstream state at the frame boundary for diagnostics.
				frame_fault     <= vin_stream_fault || fb_wr_full;
			end else begin
				case ({bi_de, bi_den})
					2'b10: if (mem_outstanding != 12'hfff)
						mem_outstanding <= mem_outstanding + 12'd1;
					2'b01: if (mem_outstanding != 12'd0)
						mem_outstanding <= mem_outstanding - 12'd1;
					default: ;
				endcase
			end

			if (bi_de && fb_rd_empty && (fb_rd_empty_count != 16'hffff))
				fb_rd_empty_count <= fb_rd_empty_count + 16'd1;
			if (bo_de && fb_wr_full && (fb_wr_full_count != 16'hffff))
				fb_wr_full_count <= fb_wr_full_count + 16'd1;

			if (!frame_fault &&
			    (vin_stream_fault ||
			     (bo_de && fb_wr_full) ||
			     (mem_outstanding >= MEM_OUTSTANDING_LIMIT))) begin
				frame_fault <= 1'b1;
				if (frame_fault_count != 16'hffff)
					frame_fault_count <= frame_fault_count + 16'd1;
			end
		end
	end

	// frame_valid: high from first hsync after vsync to last line of frame
	// vertical line counter
	reg        frame_valid;
	reg        frame_first_line;
	reg        vsync_just_hit;
	reg [10:0] scan_v_cnt;
	reg [5:0]  al_framecnt;

	always @(posedge clk) begin
		if (rst) begin
			frame_valid      <= 1'b0;
			frame_first_line <= 1'b0;
			vsync_just_hit   <= 1'b0;
			scan_v_cnt       <= 11'd0;
			al_framecnt      <= `LUT_FRAMES;
		end else begin
			vsync_just_hit <= vin_vsync_rise;

			if (vin_vsync_rise) begin
				frame_valid      <= 1'b0;
				frame_first_line <= 1'b1;
				scan_v_cnt       <= 11'd0;
				if (al_framecnt == 6'd0)
					al_framecnt <= `LUT_FRAMES;
				else
					al_framecnt <= al_framecnt - 6'd1;
			end else if ((frame_first_line && vin_hsync_rise) || (vsync_just_hit && vin_hsync)) begin
				frame_valid      <= sys_ready_clk;
				frame_first_line <= 1'b0;
				scan_v_cnt       <= 11'd0;
			end else if (frame_valid && vin_hsync_rise) begin
				frame_first_line <= 1'b0;
				if (scan_v_cnt == (VFP + VSYNC + VBP + VACT - 1'b1)) begin
					scan_v_cnt  <= 11'd0;
					frame_valid <= 1'b0;
				end else begin
					scan_v_cnt <= scan_v_cnt + 11'd1;
				end
			end else if (frame_valid) begin
				frame_first_line <= 1'b0;
			end else begin
				scan_v_cnt       <= 11'd0;
				frame_valid      <= 1'b0;
				frame_first_line <= 1'b0;
			end
		end
	end

	// scan region signals
	// vertical: counter-based
	// horizontal: signal-based (vin_hsync, vin_de)
	wire scan_in_vsync;
	wire scan_in_vbp;
	wire scan_in_vact;
	wire scan_in_vact_le;
	wire scan_in_hsync;
	wire scan_in_hact;
	wire scan_in_act;

	assign scan_in_vsync = vin_vsync;
	assign scan_in_vbp   = frame_valid && (scan_v_cnt >= VSYNC) && (scan_v_cnt < VSYNC + VBP);
	assign scan_in_vact  = frame_valid && (scan_v_cnt >= VSYNC + VBP) && (scan_v_cnt < VSYNC + VBP + VACT);
	// Pomo streams a completed Source row into the panel one line before it is
	// latched.  Keep the established next-line window; Caster obtains the same
	// relationship from the phase of its own free-running scan counter.
	assign scan_in_vact_le = frame_valid &&
		(scan_v_cnt >= VSYNC + VBP + 1) &&
		(scan_v_cnt < VSYNC + VBP + VACT + 1);
	assign scan_in_hsync = vin_hsync;
	assign scan_in_hact  = vin_de;
	assign scan_in_act   = scan_in_vact && scan_in_hact;

	reg after_hact;
	always @(posedge clk) begin
		if (rst)
			after_hact <= 1'b0;
		else if (vin_de)         
			after_hact <= 1'b1;  
		else if (vin_hsync)      
			after_hact <= 1'b0; 
	end
	wire scan_in_hbp = !vin_hsync && !vin_de && !after_hact;  
	wire scan_in_hfp = !vin_hsync && !vin_de &&  after_hact; 

	// ============================================================
	// Blue noise coordinates
	// ============================================================
	// Count the physical source coordinate at the reordered stream. The blue
	// noise ROM is 64x64, so both coordinates must retain six address bits.
	reg [5:0] noise_phys_x;

	always @(posedge clk) begin
		if (rst)
			noise_phys_x <= 6'd0;
		else if (vin_hsync_rise)
			noise_phys_x <= 6'd0;
		else if (vin_de)
			noise_phys_x <= noise_phys_x + 6'd1;
	end

	// Remove the vertical blanking offset before addressing the noise tile.
	// In reorder mode, convert the physical W x 2H scan coordinate back to
	// the original logical 2W x H coordinate so adjacent logical pixels use
	// adjacent entries of the blue-noise pattern:
	//   logical_x = 2*physical_x + physical_y[0]
	//   logical_y = physical_y / 2
	wire [10:0] noise_phys_y = scan_v_cnt - (VSYNC + VBP);
`ifdef EPD_PIXEL_REORDER
	wire [5:0] noise_x = {noise_phys_x[4:0], noise_phys_y[0]};
	wire [5:0] noise_y = noise_phys_y[6:1];
`else
	wire [5:0] noise_x = noise_phys_x;
	wire [5:0] noise_y = noise_phys_y[5:0];
`endif

	// ============================================================
	// Auto clear timer
	// ============================================================



	// ============================================================
	// Init state machine
	// ============================================================

	localparam INIT_IDLE     = 2'd0;
	localparam INIT_CLEARING = 2'd1;
	localparam INIT_NORMAL   = 2'd2;

	reg [1:0] init_state;
	reg [9:0] clear_frame_cnt;

	always @(posedge clk) begin
		if (rst) begin
			init_state      <= INIT_IDLE;
			clear_frame_cnt <= 10'd0;
		end else begin
			case (init_state)
				INIT_IDLE: begin
					if (sys_ready_clk && vin_vsync_rise)
						init_state <= INIT_CLEARING;
				end
				INIT_CLEARING: begin
					if (vin_vsync_rise) begin
						if (clear_frame_cnt == `CLEAR_FRAMES) begin
							init_state <= INIT_NORMAL;
							clear_frame_cnt <= 10'd0;
						end else begin
							clear_frame_cnt <= clear_frame_cnt + 10'd1;
						end
					end
				end
				INIT_NORMAL: begin
					;
				end
			endcase
		end
	end

	wire [1:0] sys_mode;
	assign sys_mode = (init_state == INIT_CLEARING) ? `SYS_CLEAR : `SYS_NORMAL;

	// ============================================================
	// BI & BO
	// ============================================================

	assign bi_clk   = clk;
	assign bi_vsync = ~scan_in_vsync;
	assign bi_de    = scan_in_act;

	wire bi_vsync_dl;
	delay #(
		.DEPTH(6), 
		.WIDTH(1)
	) u_delay_bi_vsync (
		.clk(clk), 
		.rst(rst),
		.din(bi_vsync),
		.dout(bi_vsync_dl)
	);

	wire bi_de_dl;
	delay #(
		.DEPTH(6), 
		.WIDTH(1)
	) u_delay_bi_de (
		.clk(clk), 
		.rst(rst),
		.din(bi_de),
		.dout(bi_de_dl)
	);

	assign bo_clk   = clk;
	assign bo_vsync = bi_vsync_dl;
	assign bo_de    = bi_de_dl;

	// ============================================================
	// Stage 1 — 2-cycle delay, align vin_pixel with HyperRAM read
	// ============================================================

//  wire s1_active;
//  delay #(
//      .DEPTH(2), 
//      .WIDTH(1)
//  ) u_delay_s1_active (
//      .clk(clk), 
//      .rst(rst),
//      .din(bi_de),
//      .dout(s1_active)
//  );

	wire [3:0] s1_vin_pixel;
	delay #(
		.DEPTH(2), 
		.WIDTH(4)
	) u_delay_s1p (
		.clk(clk), 
		.rst(rst),
		.din(vin_pixel),
		.dout(s1_vin_pixel)
	);

	// ============================================================
	// Stage 2 — latch framebuffer read + aligned input pixel
	// ============================================================
	reg        s2_active;
	reg [15:0] s2_bi_pixel;
	reg [3:0]  s2_vin_pixel;

	always @(posedge clk) begin
		if (rst) begin
			s2_active <= 1'b0;
		end else begin
			s2_active <= bi_den;
			if (bi_den) begin
				s2_bi_pixel  <= bi_data;
				s2_vin_pixel <= s1_vin_pixel;
			end
		end
	end

		// ============================================================
		// Blue noise dithering
		// ============================================================
		wire [7:0] s2_vin_linear = {s2_vin_pixel, 4'b0};
		wire       s3_dith_1b;
		wire [3:0] s3_dith_4b;

		blue_noise_dithering #(.OUTPUT_BITS(1)) u_dith_1b (
			.clk   (clk),
			.rst   (rst),
			.vin   (s2_vin_linear),
			.vout  (s3_dith_1b),
			.x_pos (noise_x),
			.y_pos (noise_y)
		);

		blue_noise_dithering #(.OUTPUT_BITS(4)) u_dith_4b (
			.clk   (clk),
			.rst   (rst),
			.vin   (s2_vin_linear),
			.vout  (s3_dith_4b),
			.x_pos (noise_x),
			.y_pos (noise_y)
		);

	// ============================================================
	// Stage 3 — LUT address generation & wvfmlut
	// ============================================================

	reg        s3_active;
	reg [15:0] s3_bi_pixel;
	reg [3:0]  s3_vin_pixel;

	always @(posedge clk) begin
		if (rst) begin
			s3_active <= 1'b0;
		end else begin
			s3_active    <= s2_active;
			s3_bi_pixel  <= s2_bi_pixel;
			s3_vin_pixel <= s2_vin_pixel;
		end
	end

	// Waveform lookup here
	// Waveform structure:
	// 14 bit address input
	//   6 bit sequence ID
	//   4 bit source grayscale
	//   4 bit destination grayscale
	// 2 bit data output
	// 32 Kb
	wire [13:0] ram_addr_rd;
	wire [1:0]  s4_lut_rd; // 1 cycle latency

	// See pixel_processing.v comments for more details
	// Only used for LUT modes.
	// Local counter (per pixel counter) is used for manual LUT modes
	// Global counter is used for auto LUT modes
	/*verilator lint_off UNUSEDSIGNAL */
	wire [15:0] wvfm_bi = s3_bi_pixel;
	/*verilator lint_on UNUSEDSIGNAL */
	wire use_local_counter =  wvfm_bi[15];
	wire [5:0] wvfm_fcnt_global_counter = wvfm_bi[9:4];
	wire [5:0] wvfm_fcnt_local_counter = al_framecnt;
	wire [5:0] wvfm_fcnt = use_local_counter ?
			wvfm_fcnt_local_counter : wvfm_fcnt_global_counter;
	wire [5:0] wvfm_fseq = `LUT_FRAMES - wvfm_fcnt;
	wire [3:0] wvfm_src_global_counter = wvfm_bi[13:10];
	wire [3:0] wvfm_src_local_counter = wvfm_bi[7:4];
	wire [3:0] wvfm_src = use_local_counter ?
			wvfm_src_local_counter : wvfm_src_global_counter;
	wire [3:0] wvfm_tgt = wvfm_bi[3:0];
	assign ram_addr_rd = {wvfm_fseq, wvfm_tgt, wvfm_src};

	wvfmlut u_wcfmlut (
		.clk    (clk),
		.rst    (rst),
		.en     (s3_active),
		.addr   (ram_addr_rd),
		.dout   (s4_lut_rd)
	);

	// ============================================================
	// Stage 4 — pixel_processing 
	// ============================================================

	reg        s4_active;
	reg [15:0] s4_bi_pixel;
	reg [3:0]  s4_vin_pixel;
	reg [3:0]  s4_proc_vin;

	// Select the dithered value before the Stage 4 register boundary.  The
	// original pixel is retained separately because Auto-LUT also needs the
	// undithered input.  This moves the mode/dither mux out of the long pixel
	// state-machine path without adding a pipeline cycle.
	wire [3:0] s3_pixel_mode = s3_bi_pixel[15:12];
	wire       s3_use_dither_1b = (s3_pixel_mode == 4'hA);
	wire       s3_use_dither_4b =
		(s3_bi_pixel[15:14] == 2'b01) || (s3_pixel_mode == 4'hD);
	wire [3:0] s3_proc_vin = s3_use_dither_1b ? {4{s3_dith_1b}} :
	                            s3_use_dither_4b ? s3_dith_4b : s3_vin_pixel;

	always @(posedge clk) begin
		if (rst) begin
			s4_active <= 1'b0;
			s4_proc_vin <= 4'd0;
		end else begin
			s4_active    <= s3_active;
			s4_bi_pixel  <= s3_bi_pixel;
			s4_vin_pixel <= s3_vin_pixel;
			s4_proc_vin  <= s3_proc_vin;
		end
	end

	wire [1:0]  pixel_comb;
	wire [15:0] bo_pixel_comb;

	wire [3:0] proc_pixel = s4_vin_pixel;
	wire [15:0] proc_bi = s4_bi_pixel;
	wire [15:0] proc_bo;
	wire [1:0] proc_lut_rd = s4_lut_rd;
	wire [1:0] proc_output;

	pixel_processing u_pixel_processing(
		.sys_mode(sys_mode),
		.proc_pixel(proc_pixel),
		.proc_vin(s4_proc_vin),
		.proc_bi(proc_bi),
		.proc_bo(proc_bo),
		.proc_lut_rd(proc_lut_rd),
		.proc_output(proc_output),
		.al_framecnt(al_framecnt),
		.clear_frame_cnt(clear_frame_cnt)
	);

	// Output
	// Fault signals are diagnostic only. Never truncate an EPD scan in the
	// middle of a line or frame; doing so leaves the Source/Gate ICs partially
	// loaded and can corrupt the visible image.
	assign pixel_comb = frame_valid ? proc_output : 2'b00;
	assign bo_pixel_comb = frame_valid ? proc_bo : proc_bi;

	reg [1:0] current_pixel;
	always @(posedge clk) begin
		current_pixel <= (s4_active) ? pixel_comb : 2'b0;
		bo_data <= bo_pixel_comb;
	end

	// ============================================================
	// Caster Source/Gate output, adapted only for one pixel per clock
	// ============================================================
	// The existing Pomo path delays bi_de/bi_vsync by six clocks to align
	// framebuffer writeback with current_pixel. Apply that same established
	// structural latency to the scan regions; it is not a panel timing value.
	localparam [3:0] OUTPUT_PIPELINE_DELAY = 4'd6;
	wire [7:0] epd_scan_regions;
	delay #(
		.DEPTH(OUTPUT_PIPELINE_DELAY),
		.WIDTH(8)
	) u_delay_epd_scan_regions (
		.clk(clk),
		.rst(rst),
		.din({scan_in_vsync, scan_in_vbp, scan_in_vact,
		      scan_in_vact_le,
		      scan_in_hfp, scan_in_hsync, scan_in_hbp, scan_in_hact}),
		.dout(epd_scan_regions)
	);

	wire epd_vsync;
	wire epd_vbp;
	wire epd_vact;
	wire epd_vact_le;
	wire epd_hfp;
	wire epd_hsync;
	wire epd_hbp;
	wire epd_hact;
	assign {epd_vsync, epd_vbp, epd_vact, epd_vact_le,
	        epd_hfp, epd_hsync, epd_hbp, epd_hact} = epd_scan_regions;
	wire epd_act = epd_vact && epd_hact;

	// Caster consumes four 2-bit pixels per core clock. Pomo consumes one,
	// therefore a half Source word is collected over a bus-width-derived number
	// of clocks. The rising/falling edge roles and blanking enables are unchanged.
	localparam integer SOURCE_HALF_BITS = `EPD_OUTPUT_WIDTH / 2;
	localparam integer SOURCE_HALF_PIXELS = `EPD_OUTPUT_WIDTH / 4;
	wire source_clk_en = epd_hfp || epd_hsync || epd_hact;
	reg [2:0] source_half_pixel_count;
	reg [SOURCE_HALF_BITS-1:0] source_half_shift;
	reg [SOURCE_HALF_BITS-1:0] source_last_half;
	reg [15:0] source_data;
	reg source_clk;
	reg source_sdce;
	wire [SOURCE_HALF_BITS-1:0] source_half_next =
		{source_half_shift[SOURCE_HALF_BITS-3:0], current_pixel};

	always @(posedge clk) begin
		if (rst) begin
			source_half_pixel_count <= 3'd0;
			source_half_shift <= {SOURCE_HALF_BITS{1'b0}};
			source_last_half <= {SOURCE_HALF_BITS{1'b0}};
			source_data <= 16'd0;
			source_clk <= 1'b0;
			source_sdce <= 1'b1;
		end else if (!source_clk_en) begin
			// Caster forces SDCLK low during HBP to establish line phase.
			source_half_pixel_count <= 3'd0;
			source_half_shift <= {SOURCE_HALF_BITS{1'b0}};
			source_last_half <= {SOURCE_HALF_BITS{1'b0}};
			source_clk <= 1'b0;
			source_sdce <= 1'b1;
		end else begin
			source_half_shift <= source_half_next;
			if (source_half_pixel_count == SOURCE_HALF_PIXELS - 1) begin
				source_half_pixel_count <= 3'd0;
				source_clk <= ~source_clk;
				if (source_clk) begin
					// Falling edge: publish a complete word. The following
					// rising edge is the Source-driver sampling edge.
					source_data <=
						{{(16-`EPD_OUTPUT_WIDTH){1'b0}},
						 source_last_half, source_half_next};
					source_sdce <= !epd_act;
				end else begin
					source_last_half <= source_half_next;
				end
			end else begin
				source_half_pixel_count <= source_half_pixel_count + 3'd1;
			end
		end
	end

	assign epd_sdclk = source_clk;
	assign epd_sdce = source_sdce;
	assign epd_data = source_data;

	// Caster's CKV is one cycle per scan line and is derived from contiguous
	// horizontal regions.  Pomo's DE comes from an asynchronous MIPI FIFO, so it
	// may contain short gaps and must not be used directly as the CKV level.
	// Hold CKV high from the first active pixel through the end of the line, and
	// low through the configured HSYNC + HBP interval.  This preserves the
	// one-cycle-per-line relationship without a panel-specific pulse constant.
	reg epd_gate_line_high;
	always @(posedge clk) begin
		if (rst)
			epd_gate_line_high <= 1'b0;
		else if (epd_vsync)
			epd_gate_line_high <= 1'b1;
		else if (epd_hsync)
			epd_gate_line_high <= 1'b0;
		else if (epd_vact && epd_hact)
			epd_gate_line_high <= 1'b1;
	end
	wire epd_gdclk_pre = epd_gate_line_high;
	reg epd_gdclk_delay;
	always @(posedge clk) begin
		if (rst)
			epd_gdclk_delay <= 1'b0;
		else
			epd_gdclk_delay <= epd_gdclk_pre;
	end

	assign epd_gdclk = epd_gdclk_delay;
	assign epd_gdsp = epd_vsync ? 1'b0 : 1'b1;
	assign epd_sdle = epd_hsync && epd_vact_le;

endmodule
