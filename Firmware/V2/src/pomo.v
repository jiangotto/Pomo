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
	wire scan_in_vfp;
	wire scan_in_vsync;
	wire scan_in_vbp;
	wire scan_in_vact;
	wire scan_in_vact_le;
	wire scan_in_hsync;
	wire scan_in_hact;
	wire scan_in_act;

	assign scan_in_vfp   = frame_valid && (scan_v_cnt >= VSYNC + VBP + VACT);
	assign scan_in_vsync = vin_vsync;
	assign scan_in_vbp   = frame_valid && (scan_v_cnt >= VSYNC) && (scan_v_cnt < VSYNC + VBP);
	assign scan_in_vact  = frame_valid && (scan_v_cnt >= VSYNC + VBP) && (scan_v_cnt < VSYNC + VBP + VACT);
	assign scan_in_vact_le  = frame_valid && (scan_v_cnt >= VSYNC + VBP + 1) && (scan_v_cnt < VSYNC + VBP + VACT + 1);
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


`ifdef EPD_CASTER_TIMING
	// ============================================================
	// Caster-style EPD output timing
	// ============================================================
	// Caster does not obtain panel timing by delaying the input raster.  Its
	// Source/Gate interface has its own sequencer and a rate adapter between
	// the processing pipeline and the physical data bus.  Pomo processes one
	// pixel per clock (Caster processes four), so retain one completed line in
	// a small distributed RAM and then transmit 4/8 pixels per Source clock.
	// The single buffer is safe because the output reader is at least twice
	// times faster than the writer after the first word has been captured.
	localparam integer SOURCE_PIXELS_PER_UNIT =
		(`EPD_OUTPUT_WIDTH == 16) ? 8 : 4;
	localparam integer SOURCE_LINE_WORDS = (`EPD_HACT + 7) / 8;
	localparam integer SOURCE_LINE_UNITS =
		(`EPD_HACT + SOURCE_PIXELS_PER_UNIT - 1) /
		 SOURCE_PIXELS_PER_UNIT;
	localparam integer EPD_HTOTAL = `DEFAULT_HFP + `DEFAULT_HSYNC +
	                                 `DEFAULT_HBP + `DEFAULT_HACT;
	localparam integer EPD_VTOTAL = `DEFAULT_VFP + `DEFAULT_VSYNC +
	                                 `DEFAULT_VBP + `DEFAULT_VACT;
	localparam integer EPD_CLK_KHZ =
		((EPD_HTOTAL * EPD_VTOTAL * `DEFAULT_FPS) + 999) / 1000;
	// E0470A01: GCLK <= 200 kHz and both levels >= 1 us. A symmetric
	// 5-us pulse period satisfies both requirements at the maximum target FPS.
	localparam integer GATE_HALF_CYCLES =
		((EPD_CLK_KHZ * 2500) + 999999) / 1000000;
	// Eight clocks provide margin over the 3.5 * tCY requirement when one
	// Source-clock period is two pixel clocks.
	localparam integer SOURCE_LE_ON_CYCLES = 8;
	localparam integer SOURCE_LE_HIGH_CYCLES =
		((EPD_CLK_KHZ * 300) + 999999) / 1000000;
	localparam integer SOURCE_LE_OFF_CYCLES =
		((EPD_CLK_KHZ * 200) + 999999) / 1000000;
	localparam integer GATE_START_PULSES = `EPD_GATE_START_PULSES;
	localparam integer GATE_PREAMBLE_PULSES =
		`EPD_GATE_START_PULSES + `EPD_GATE_SETTLE_PULSES;

	// 1216 pixels require only 2432 bits. Gowin expands a distributed array of
	// this shape into thousands of DFFs, so use the remaining BSRAM explicitly.
	(* RAM_STYLE = "BLOCK" *) reg [15:0] source_line_mem
		[0:SOURCE_LINE_WORDS-1];
	reg [15:0] source_capture_shift;
	reg [11:0] source_capture_pixel;
	reg [10:0] source_capture_word;
	reg        source_line_toggle;
	reg        source_line_frame;
	reg        source_input_frame;
	reg [10:0] source_mem_read_addr;
	reg [15:0] source_mem_read_data;

	function [15:0] source_pad_word;
		input [15:0] raw_word;
		input [2:0]  last_slot;
		begin
			case (last_slot)
				3'd0: source_pad_word = {raw_word[1:0], 14'b0};
				3'd1: source_pad_word = {raw_word[3:0], 12'b0};
				3'd2: source_pad_word = {raw_word[5:0], 10'b0};
				3'd3: source_pad_word = {raw_word[7:0], 8'b0};
				3'd4: source_pad_word = {raw_word[9:0], 6'b0};
				3'd5: source_pad_word = {raw_word[11:0], 4'b0};
				3'd6: source_pad_word = {raw_word[13:0], 2'b0};
				default: source_pad_word = raw_word;
			endcase
		end
	endfunction

	wire [15:0] source_capture_next =
		{source_capture_shift[13:0], pixel_comb};
	wire source_capture_last =
		(source_capture_pixel == (`EPD_HACT - 1));
	wire source_capture_word_last =
		(source_capture_pixel[2:0] == 3'd7);

	always @(posedge clk) begin
		if (rst) begin
			source_capture_shift <= 16'd0;
			source_capture_pixel <= 12'd0;
			source_capture_word  <= 11'd0;
			source_line_toggle   <= 1'b0;
			source_line_frame    <= 1'b0;
			source_input_frame   <= 1'b0;
			source_mem_read_data <= 16'd0;
		end else begin
			// Synchronous read port. Keeping read and write in this one clocked
			// process allows Gowin to infer a simple-dual-port BSRAM.
			source_mem_read_data <= source_line_mem[source_mem_read_addr];
			if (vin_vsync_rise) begin
				source_input_frame   <= ~source_input_frame;
				source_capture_pixel <= 12'd0;
				source_capture_word  <= 11'd0;
			end

			if (s4_active) begin
				source_capture_shift <= source_capture_next;
				if (source_capture_word_last || source_capture_last) begin
					source_line_mem[source_capture_word] <=
						source_pad_word(source_capture_next,
						                source_capture_pixel[2:0]);
					if (!source_capture_last)
						source_capture_word <= source_capture_word + 11'd1;
				end

				if (source_capture_last) begin
					source_capture_pixel <= 12'd0;
					source_capture_word  <= 11'd0;
					source_line_frame    <= source_input_frame;
					source_line_toggle   <= ~source_line_toggle;
				end else begin
					source_capture_pixel <= source_capture_pixel + 12'd1;
				end
			end
		end
	end

	localparam [4:0]
		EPD_OUT_IDLE          = 5'd0,
		EPD_OUT_PRE_LOW       = 5'd1,
		EPD_OUT_PRE_HIGH      = 5'd2,
		EPD_OUT_WAIT_LINE     = 5'd3,
		EPD_OUT_SHIFT_LOAD    = 5'd4,
		EPD_OUT_SHIFT_HIGH    = 5'd5,
		EPD_OUT_SHIFT_FALL    = 5'd6,
		EPD_OUT_DUMMY_HIGH    = 5'd7,
		EPD_OUT_DUMMY_FALL    = 5'd8,
		EPD_OUT_LE_DELAY      = 5'd9,
		EPD_OUT_LE_HIGH       = 5'd10,
		EPD_OUT_LE_OFF        = 5'd11,
		EPD_OUT_GATE_HIGH     = 5'd12,
		EPD_OUT_GATE_LOW      = 5'd13,
		EPD_OUT_WAIT_FRAME    = 5'd14,
		EPD_OUT_SHIFT_WAIT    = 5'd15;

	reg [4:0]  epd_out_state;
	reg [9:0]  epd_out_timer;
	reg [7:0]  epd_preamble_count;
	reg [11:0] epd_source_unit;
	reg [11:0] epd_output_line;
	reg        source_line_consumed;
	reg        epd_drive_frame;
	reg        epd_seen_frame;
	reg        epd_gdclk_r;
	reg        epd_gdsp_r;
	reg        epd_sdclk_r;
	reg        epd_sdle_r;
	reg        epd_sdce_r;
	reg [15:0] epd_data_r;

	wire [15:0] source_read_data =
		(`EPD_OUTPUT_WIDTH == 16) ? source_mem_read_data :
		(epd_source_unit[0] ? {8'd0, source_mem_read_data[7:0]} :
		                      {8'd0, source_mem_read_data[15:8]});
	wire [11:0] source_next_unit = epd_source_unit + 12'd1;
	wire [10:0] source_next_word_addr =
		(`EPD_OUTPUT_WIDTH == 16) ? source_next_unit[10:0] :
		                              source_next_unit[11:1];
	wire [15:0] source_next_data =
		(`EPD_OUTPUT_WIDTH == 16) ? source_mem_read_data :
		(source_next_unit[0] ? {8'd0, source_mem_read_data[7:0]} :
		                       {8'd0, source_mem_read_data[15:8]});
	wire [11:0] source_after_next_unit = epd_source_unit + 12'd2;
	wire [10:0] source_after_next_word_addr =
		(`EPD_OUTPUT_WIDTH == 16) ? source_after_next_unit[10:0] :
		                              source_after_next_unit[11:1];

	always @(posedge clk) begin
		if (rst || !sys_ready_clk) begin
			epd_out_state        <= EPD_OUT_IDLE;
			epd_out_timer        <= 10'd0;
			epd_preamble_count   <= 8'd0;
			epd_source_unit      <= 12'd0;
			source_mem_read_addr <= 11'd0;
			epd_output_line      <= 12'd0;
			source_line_consumed <= 1'b0;
			epd_drive_frame      <= 1'b0;
			epd_seen_frame       <= 1'b0;
			epd_gdclk_r          <= 1'b0;
			epd_gdsp_r           <= 1'b1;
			epd_sdclk_r          <= 1'b0;
			epd_sdle_r           <= 1'b0;
			epd_sdce_r           <= 1'b1;
			epd_data_r           <= 16'd0;
		end else begin
			// The first observed MIPI frame has no preceding HFP/VFP history.
			// Discard it, then start every later panel frame from a complete
			// blanking interval and discard any stale buffered line.
			if (vin_vsync_rise) begin
				if (!epd_seen_frame) begin
					epd_seen_frame <= 1'b1;
				end else begin
					epd_out_state        <= EPD_OUT_PRE_LOW;
					epd_out_timer        <= 10'd0;
					epd_preamble_count   <= 8'd0;
					epd_output_line      <= 12'd0;
					source_line_consumed <= source_line_toggle;
					epd_drive_frame      <= ~source_input_frame;
					epd_gdclk_r          <= 1'b0;
					epd_gdsp_r           <= 1'b0;
					epd_sdclk_r          <= 1'b0;
					epd_sdle_r           <= 1'b0;
					epd_sdce_r           <= 1'b1;
				end
			end else begin
				case (epd_out_state)
				EPD_OUT_IDLE: begin
					epd_gdclk_r <= 1'b0;
					epd_sdclk_r <= 1'b0;
					epd_sdle_r  <= 1'b0;
					epd_sdce_r  <= 1'b1;
				end

				EPD_OUT_PRE_LOW: begin
					epd_gdclk_r <= 1'b0;
					epd_gdsp_r <=
						(epd_preamble_count < GATE_START_PULSES) ?
						1'b0 : 1'b1;
					if (epd_out_timer >= (GATE_HALF_CYCLES - 1)) begin
						epd_out_timer <= 10'd0;
						epd_gdclk_r   <= 1'b1;
						epd_out_state <= EPD_OUT_PRE_HIGH;
					end else begin
						epd_out_timer <= epd_out_timer + 10'd1;
					end
				end

				EPD_OUT_PRE_HIGH: begin
					if (epd_out_timer >= (GATE_HALF_CYCLES - 1)) begin
						epd_out_timer <= 10'd0;
						epd_gdclk_r   <= 1'b0;
						if (epd_preamble_count ==
						    (GATE_PREAMBLE_PULSES - 1)) begin
							epd_gdsp_r   <= 1'b1;
							epd_out_state <= EPD_OUT_WAIT_LINE;
						end else begin
							epd_preamble_count <=
								epd_preamble_count + 8'd1;
							epd_out_state <= EPD_OUT_PRE_LOW;
						end
					end else begin
						epd_out_timer <= epd_out_timer + 10'd1;
					end
				end

				EPD_OUT_WAIT_LINE: begin
					epd_sdclk_r <= 1'b0;
					epd_sdle_r  <= 1'b0;
					epd_sdce_r  <= 1'b1;
					if (source_line_toggle != source_line_consumed) begin
						source_line_consumed <= source_line_toggle;
						if (source_line_frame == epd_drive_frame) begin
							epd_source_unit      <= 12'd0;
							source_mem_read_addr <= 11'd0;
							epd_out_state        <= EPD_OUT_SHIFT_WAIT;
						end
					end
				end

				EPD_OUT_SHIFT_WAIT: begin
					// One cycle for the synchronous BSRAM read port.
					epd_out_state <= EPD_OUT_SHIFT_LOAD;
				end

				EPD_OUT_SHIFT_LOAD: begin
					epd_data_r     <= source_read_data;
					epd_sdce_r     <= 1'b0;
					epd_sdclk_r    <= 1'b0;
					if (SOURCE_LINE_UNITS > 1)
						source_mem_read_addr <= source_next_word_addr;
					epd_out_state  <= EPD_OUT_SHIFT_HIGH;
				end

				EPD_OUT_SHIFT_HIGH: begin
					epd_sdclk_r   <= 1'b1;
					epd_out_state <= EPD_OUT_SHIFT_FALL;
				end

				EPD_OUT_SHIFT_FALL: begin
					epd_sdclk_r <= 1'b0;
					if (epd_source_unit == (SOURCE_LINE_UNITS - 1)) begin
						// Preserve the required extra clock, but issue it with STL/
						// SDCE inactive so it cannot shift a black word into the row.
						epd_sdce_r    <= 1'b1;
						epd_data_r    <= 16'd0;
						epd_out_state <= EPD_OUT_DUMMY_HIGH;
					end else begin
						epd_source_unit      <= source_next_unit;
						epd_data_r            <= source_next_data;
						source_mem_read_addr <= source_after_next_word_addr;
						epd_out_state        <= EPD_OUT_SHIFT_HIGH;
					end
				end

				EPD_OUT_DUMMY_HIGH: begin
					epd_sdclk_r   <= 1'b1;
					epd_out_state <= EPD_OUT_DUMMY_FALL;
				end

				EPD_OUT_DUMMY_FALL: begin
					epd_sdclk_r   <= 1'b0;
					epd_out_timer <= 10'd0;
					epd_out_state <= EPD_OUT_LE_DELAY;
				end

				EPD_OUT_LE_DELAY: begin
					if (epd_out_timer >= (SOURCE_LE_ON_CYCLES - 1)) begin
						epd_out_timer <= 10'd0;
						epd_sdle_r    <= 1'b1;
						epd_out_state <= EPD_OUT_LE_HIGH;
					end else begin
						epd_out_timer <= epd_out_timer + 10'd1;
					end
				end

				EPD_OUT_LE_HIGH: begin
					if (epd_out_timer >= (SOURCE_LE_HIGH_CYCLES - 1)) begin
						epd_out_timer <= 10'd0;
						epd_sdle_r    <= 1'b0;
						epd_out_state <= EPD_OUT_LE_OFF;
					end else begin
						epd_out_timer <= epd_out_timer + 10'd1;
					end
				end

				EPD_OUT_LE_OFF: begin
					if (epd_out_timer >= (SOURCE_LE_OFF_CYCLES - 1)) begin
						epd_out_timer <= 10'd0;
						epd_gdclk_r   <= 1'b1;
						epd_out_state <= EPD_OUT_GATE_HIGH;
					end else begin
						epd_out_timer <= epd_out_timer + 10'd1;
					end
				end

				EPD_OUT_GATE_HIGH: begin
					if (epd_out_timer >= (GATE_HALF_CYCLES - 1)) begin
						epd_out_timer <= 10'd0;
						epd_gdclk_r   <= 1'b0;
						epd_out_state <= EPD_OUT_GATE_LOW;
					end else begin
						epd_out_timer <= epd_out_timer + 10'd1;
					end
				end

				EPD_OUT_GATE_LOW: begin
					if (epd_out_timer >= (GATE_HALF_CYCLES - 1)) begin
						epd_out_timer   <= 10'd0;
						if (epd_output_line == (`EPD_VACT - 1)) begin
							epd_out_state <= EPD_OUT_WAIT_FRAME;
						end else begin
							epd_output_line <= epd_output_line + 12'd1;
							epd_out_state <= EPD_OUT_WAIT_LINE;
						end
					end else begin
						epd_out_timer <= epd_out_timer + 10'd1;
					end
				end

				EPD_OUT_WAIT_FRAME: begin
					epd_gdclk_r <= 1'b0;
					epd_sdclk_r <= 1'b0;
					epd_sdle_r  <= 1'b0;
					epd_sdce_r  <= 1'b1;
				end

				default: epd_out_state <= EPD_OUT_IDLE;
				endcase
			end
		end
	end

	assign epd_gdclk = epd_gdclk_r;
	assign epd_gdsp  = epd_gdsp_r;
	assign epd_sdclk = epd_sdclk_r;
	assign epd_sdle  = epd_sdle_r;
	assign epd_sdce  = epd_sdce_r;
	assign epd_data  = epd_data_r;

`else
	// ============================================================
	// Stage 5 — shift / pack 4 pixels into 1 byte
	// ============================================================

//  reg [1:0] s5_pix_cnt;
//  reg [7:0] s5_shift;
//  reg       s5_active;
//  reg [7:0] epd_data_r;
//  reg       epd_sdclk_r;
//  reg [1:0] clk_delay_cnt; 

//  always @(posedge clk) begin
//      if (rst) begin
//          s5_shift      <= 8'h00;
//          s5_pix_cnt    <= 2'd0;
//          s5_active     <= 1'b0;
//          epd_data_r    <= 8'h00;
//          epd_sdclk_r   <= 1'b0;
//          clk_delay_cnt <= 2'd0;
//      end else begin
//          s5_active   <= s4_active;
//          epd_sdclk_r <= 1'b0;  
//          if (clk_delay_cnt != 2'd0) begin
//              clk_delay_cnt <= clk_delay_cnt - 2'd1;
//              if (clk_delay_cnt <= 2'd2)  
//                  epd_sdclk_r <= 1'b1;
//          end
//          if (s5_active) begin
//              s5_shift <= {s5_shift[5:0], current_pixel};
//              if (s5_pix_cnt == 2'd3) begin
//                  epd_data_r    <= {s5_shift[5:0], current_pixel};
//                  s5_pix_cnt    <= 2'd0;
//                  clk_delay_cnt <= 2'd3;                         
//              end else begin
//                  s5_pix_cnt <= s5_pix_cnt + 2'd1;
//              end
//          end else begin
//              s5_pix_cnt <= 2'd0;
//          end
//      end
//  end




//  reg [1:0] s5_pix_cnt;
//  reg [7:0] s5_shift;
//  reg       s5_active;
//  reg       s5_active_d;
//  reg [7:0] epd_data_r;
//  reg       epd_sdclk_r;
//  reg [1:0] clk_delay_cnt;
//  reg       s5_extra_pending;

//  wire s5_fall = s5_active_d & ~s5_active;

//  always @(posedge clk) begin
//      if (rst) begin
//          s5_shift         <= 8'h00;
//          s5_pix_cnt       <= 2'd0;
//          s5_active        <= 1'b0;
//          s5_active_d      <= 1'b0;
//          epd_data_r       <= 8'h00;
//          epd_sdclk_r      <= 1'b0;
//          clk_delay_cnt    <= 2'd0;
//          s5_extra_pending <= 1'b0;
//      end else begin
//          s5_active_d <= s5_active;
//          s5_active   <= s4_active;
//          epd_sdclk_r <= 1'b0;
//          if (s5_fall) begin
//              if (clk_delay_cnt != 2'd0)
//                  s5_extra_pending <= 1'b1;
//              else
//                  clk_delay_cnt <= 2'd3;
//          end
//          if (clk_delay_cnt != 2'd0) begin
//              clk_delay_cnt <= clk_delay_cnt - 2'd1;
//              if (clk_delay_cnt <= 2'd2)
//                  epd_sdclk_r <= 1'b1;
//              if (clk_delay_cnt == 2'd1 && s5_extra_pending) begin
//                  s5_extra_pending <= 1'b0;
//                  clk_delay_cnt    <= 2'd3;
//              end
//          end
//          if (s5_active) begin
//              s5_shift <= {s5_shift[5:0], current_pixel};
//              if (s5_pix_cnt == 2'd3) begin
//                  epd_data_r    <= {s5_shift[5:0], current_pixel};
//                  s5_pix_cnt    <= 2'd0;
//                  clk_delay_cnt <= 2'd3;
//              end else begin
//                  s5_pix_cnt <= s5_pix_cnt + 2'd1;
//              end
//          end else begin
//              s5_pix_cnt <= 2'd0;
//          end
//      end
//  end

	// Source output is selected statically at synthesis time. Both branches
	// keep active and current_pixel at the same pipeline depth and register
	// SDCLK, so epd_data has the setup interval of the verified implementation.
	wire [15:0] epd_data_r;
	wire        source_sdclk;
	wire        s5_extra_pending;

	generate
	if (`EPD_OUTPUT_WIDTH == 16) begin : gen_source_tx16
		reg [1:0]  pix_count;
		reg [7:0]  shift;
		reg        active;
		reg        active_d;
		reg [7:0]  half_word;
		reg        half_valid;
		reg [15:0] data_r;
		reg [1:0]  clk_delay_count;
		reg        extra_pending;
		reg        sdclk_r;

		wire line_fall = active_d && !active;
		wire [7:0] complete_word = {shift[5:0], current_pixel};
		reg [7:0] partial_word;

		always @(*) begin
			case (pix_count)
				2'd1: partial_word = {shift[1:0], 6'b0};
				2'd2: partial_word = {shift[3:0], 4'b0};
				2'd3: partial_word = {shift[5:0], 2'b0};
				default: partial_word = 8'h00;
			endcase
		end

		always @(posedge clk) begin
			if (rst) begin
				pix_count       <= 2'd0;
				shift           <= 8'h00;
				active          <= 1'b0;
				active_d        <= 1'b0;
				half_word       <= 8'h00;
				half_valid      <= 1'b0;
				data_r          <= 16'h0000;
				clk_delay_count <= 2'd0;
				extra_pending   <= 1'b0;
				sdclk_r         <= 1'b0;
			end else begin
				active_d <= active;
				active   <= s4_active;
				sdclk_r <= (clk_delay_count != 2'd0) &&
				           (clk_delay_count <= 2'd2);

				if (line_fall) begin
`ifdef EPD_AUTO_HPAD
					if (pix_count != 2'd0) begin
						data_r <= half_valid ?
						          {half_word, partial_word} :
						          {partial_word, 8'h00};
						half_valid      <= 1'b0;
						clk_delay_count <= 2'd3;
						extra_pending   <= 1'b1;
					end else if (half_valid) begin
						data_r          <= {half_word, 8'h00};
						half_valid      <= 1'b0;
						clk_delay_count <= 2'd3;
						extra_pending   <= 1'b1;
					end else if (clk_delay_count != 2'd0) begin
						extra_pending <= 1'b1;
					end else begin
						clk_delay_count <= 2'd3;
					end
`else
					if (half_valid) begin
						data_r          <= {half_word, 8'h00};
						half_valid      <= 1'b0;
						clk_delay_count <= 2'd3;
						extra_pending   <= 1'b1;
					end else if (clk_delay_count != 2'd0) begin
						extra_pending <= 1'b1;
					end else begin
						clk_delay_count <= 2'd3;
					end
`endif
				end

				if (clk_delay_count != 2'd0) begin
					clk_delay_count <= clk_delay_count - 2'd1;
					if ((clk_delay_count == 2'd1) && extra_pending) begin
						extra_pending   <= 1'b0;
						clk_delay_count <= 2'd3;
					end
				end

				if (active) begin
					shift <= {shift[5:0], current_pixel};
					if (pix_count == 2'd3) begin
						pix_count <= 2'd0;
						if (half_valid) begin
							data_r          <= {half_word, complete_word};
							half_valid      <= 1'b0;
							clk_delay_count <= 2'd3;
						end else begin
							half_word  <= complete_word;
							half_valid <= 1'b1;
						end
					end else begin
						pix_count <= pix_count + 2'd1;
					end
				end else begin
					pix_count <= 2'd0;
				end
			end
		end

		assign epd_data_r = data_r;
		assign source_sdclk = sdclk_r;
		assign s5_extra_pending = extra_pending;
	end else begin : gen_source_tx8
		reg [1:0]  pix_count;
		reg [7:0]  shift;
		reg        active;
		reg        active_d;
		reg [15:0] data_r;
		reg [1:0]  clk_delay_count;
		reg        extra_pending;
		reg        sdclk_r;

		wire line_fall = active_d && !active;
		wire [7:0] complete_word = {shift[5:0], current_pixel};
		reg [7:0] partial_word;

		always @(*) begin
			case (pix_count)
				2'd1: partial_word = {shift[1:0], 6'b0};
				2'd2: partial_word = {shift[3:0], 4'b0};
				2'd3: partial_word = {shift[5:0], 2'b0};
				default: partial_word = 8'h00;
			endcase
		end

		always @(posedge clk) begin
			if (rst) begin
				pix_count       <= 2'd0;
				shift           <= 8'h00;
				active          <= 1'b0;
				active_d        <= 1'b0;
				data_r          <= 16'h0000;
				clk_delay_count <= 2'd0;
				extra_pending   <= 1'b0;
				sdclk_r         <= 1'b0;
			end else begin
				active_d <= active;
				active   <= s4_active;
				sdclk_r <= (clk_delay_count != 2'd0) &&
				           (clk_delay_count <= 2'd2);

				if (line_fall) begin
`ifdef EPD_AUTO_HPAD
					if (pix_count != 2'd0) begin
						data_r          <= {8'h00, partial_word};
						clk_delay_count <= 2'd3;
						extra_pending   <= 1'b1;
					end else if (clk_delay_count != 2'd0) begin
						extra_pending <= 1'b1;
					end else begin
						clk_delay_count <= 2'd3;
					end
`else
					if (clk_delay_count != 2'd0) begin
						extra_pending <= 1'b1;
					end else begin
						clk_delay_count <= 2'd3;
					end
`endif
				end

				if (clk_delay_count != 2'd0) begin
					clk_delay_count <= clk_delay_count - 2'd1;
					if ((clk_delay_count == 2'd1) && extra_pending) begin
						extra_pending   <= 1'b0;
						clk_delay_count <= 2'd3;
					end
				end

				if (active) begin
					shift <= {shift[5:0], current_pixel};
					if (pix_count == 2'd3) begin
						pix_count       <= 2'd0;
						data_r          <= {8'h00, complete_word};
						clk_delay_count <= 2'd3;
					end else begin
						pix_count <= pix_count + 2'd1;
					end
				end else begin
					pix_count <= 2'd0;
				end
			end
		end

		assign epd_data_r = data_r;
		assign source_sdclk = sdclk_r;
		assign s5_extra_pending = extra_pending;
	end
	endgenerate

	assign epd_sdclk = source_sdclk;

	// ============================================================
	// EPD Drive 
	// ============================================================

	wire epd_vfp;
	delay #(
		.DEPTH(10), 
		.WIDTH(1)
	) u_delay_epd_vfp (
		.clk(clk), 
		.rst(rst),
		.din(scan_in_vfp),
		.dout(epd_vfp)
	);

	wire epd_vsync;
	delay #(
		.DEPTH(10), 
		.WIDTH(1)
	) u_delay_epd_vsync (
		.clk(clk), 
		.rst(rst),
		.din(scan_in_vsync),
		.dout(epd_vsync)
	);

	wire epd_vbp;
	delay #(
		.DEPTH(10), 
		.WIDTH(1)
	) u_delay_epd_vbp (
		.clk(clk), 
		.rst(rst),
		.din(scan_in_vbp),
		.dout(epd_vbp)
	);

	wire epd_vact;
	delay #(
		.DEPTH(10), 
		.WIDTH(1)
	) u_delay_epd_vact (
		.clk(clk), 
		.rst(rst),
		.din(scan_in_vact),
		.dout(epd_vact)
	);  

	wire epd_vact_le;
	delay #(
		.DEPTH(10), 
		.WIDTH(1)
	) u_delay_epd_vact_le (
		.clk(clk), 
		.rst(rst),
		.din(scan_in_vact_le),
		.dout(epd_vact_le)
	);

	wire epd_hsync;
	delay #(
		.DEPTH(10), 
		.WIDTH(1)
	) u_delay_epd_hsync (
		.clk(clk), 
		.rst(rst),
		.din(scan_in_hsync),
		.dout(epd_hsync)
	);

	wire epd_hbp;
	delay #(
		.DEPTH(10), 
		.WIDTH(1)
	) u_delay_epd_hbp (
		.clk(clk), 
		.rst(rst),
		.din(scan_in_hbp),
		.dout(epd_hbp)
	);

	wire epd_act;
	delay #(
		.DEPTH(10), 
		.WIDTH(1)
	) u_delay_epd_act (
		.clk(clk), 
		.rst(rst),
		.din(scan_in_act),
		.dout(epd_act)
	);

	wire epd_gdclk_pre = ((epd_hsync || epd_hbp || epd_act) && (epd_vact || epd_vsync)) ? 1'b1 : 1'b0;
	wire epd_gdclk_dl;
	delay #(
		.DEPTH(1), 
		.WIDTH(1)
	) u_delay_epd_gdclk (
		.clk(clk), 
		.rst(rst),
		.din(epd_gdclk_pre),
		.dout(epd_gdclk_dl)
	);
	assign epd_gdclk = epd_gdclk_dl;
	assign epd_gdsp = epd_vsync ? 1'b0 : 1'b1;
	assign epd_sdle = (epd_hsync && epd_vact_le) ? 1'b1 : 1'b0;
	// A padded partial word is real source data. Keep SDCE selected for it;
	// s5_extra_pending clears before the following dummy SDCLK.
	assign epd_sdce = (epd_act || s5_extra_pending) ? 1'b0 : 1'b1;
	assign epd_data = epd_data_r;

`endif
endmodule
