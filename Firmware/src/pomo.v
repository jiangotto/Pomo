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

	output wire         bo_clk,
	output wire         bo_vsync,
	output wire         bo_de,
	output reg  [15:0]  bo_data,
	output wire         bi_clk,
	output wire         bi_vsync,
	output wire         bi_de,
	input  wire         bi_den,
	input  wire [15:0]  bi_data,

	output wire         epd_gdoe,
	output wire         epd_gdclk,
	output wire         epd_gdsp,
	output wire         epd_sdclk,
	output wire         epd_sdle,
	output wire         epd_sdoe,
	output wire [7:0]   epd_data,
	output wire         epd_sdce
);

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
	localparam [11:0] VACT  = `DEFAULT_VACT;

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
				frame_valid      <= sys_ready;
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
	reg [3:0] noise_x;

	always @(posedge clk) begin
		if (rst)
			noise_x <= 4'd0;
		else if (vin_hsync_rise)
			noise_x <= 4'd0;
		else if (vin_de)
			noise_x <= noise_x + 4'd1;
	end

	wire [5:0] noise_y = scan_v_cnt[5:0];

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
					if (sys_ready && vin_vsync_rise)
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
reg        s4_dith_1b;
	reg [3:0]  s4_dith_4b;

	always @(posedge clk) begin
		if (rst) begin
			s4_active <= 1'b0;
			s4_dith_1b  <= 1'b0;
			s4_dith_4b  <= 4'd0;
		end else begin
			s4_active    <= s3_active;
			s4_bi_pixel  <= s3_bi_pixel;
			s4_vin_pixel <= s3_vin_pixel;
			s4_dith_1b <= s3_dith_1b;
			s4_dith_4b <= s3_dith_4b;
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
		.proc_bi(proc_bi),
		.proc_bo(proc_bo),
		.proc_lut_rd(proc_lut_rd),
		.proc_output(proc_output),
		.al_framecnt(al_framecnt),
		.clear_frame_cnt(clear_frame_cnt),
		.proc_p_n1  (s4_dith_1b),
		.proc_p_n4  (s4_dith_4b)
	);

	// Output
	assign pixel_comb = frame_valid ? proc_output : 2'b00;
	assign bo_pixel_comb = frame_valid ? proc_bo : proc_bi;

	reg [1:0] current_pixel;
	always @(posedge clk) begin
		current_pixel <= (s4_active) ? pixel_comb : 2'b0;
		bo_data <= bo_pixel_comb;
	end

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

	reg [1:0] s5_pix_cnt;
	reg [7:0] s5_shift;
	reg       s5_active;
	reg       s5_active_d;
	reg [7:0] epd_data_r;
	reg [1:0] clk_delay_cnt;
	reg       s5_extra_pending;
	reg       sdclk_r;

	wire s5_fall = s5_active_d & ~s5_active;

	always @(posedge clk) begin
		if (rst) begin
			s5_shift         <= 8'h00;
			s5_pix_cnt       <= 2'd0;
			s5_active        <= 1'b0;
			s5_active_d      <= 1'b0;
			epd_data_r       <= 8'h00;
			clk_delay_cnt    <= 2'd0;
			s5_extra_pending <= 1'b0;
			sdclk_r          <= 1'b0;
		end else begin
			s5_active_d <= s5_active;
			s5_active   <= s4_active;

			// 时钟默认低，条件置高（与第一段完全一致的逻辑）
			sdclk_r <= (clk_delay_cnt != 2'd0 && clk_delay_cnt <= 2'd2);

			if (s5_fall) begin
				if (clk_delay_cnt != 2'd0)
					s5_extra_pending <= 1'b1;
				else
					clk_delay_cnt <= 2'd3;
			end
			if (clk_delay_cnt != 2'd0) begin
				clk_delay_cnt <= clk_delay_cnt - 2'd1;
				if (clk_delay_cnt == 2'd1 && s5_extra_pending) begin
					s5_extra_pending <= 1'b0;
					clk_delay_cnt    <= 2'd3;
				end
			end
			if (s5_active) begin
				s5_shift <= {s5_shift[5:0], current_pixel};
				if (s5_pix_cnt == 2'd3) begin
					epd_data_r    <= {s5_shift[5:0], current_pixel};
					s5_pix_cnt    <= 2'd0;
					clk_delay_cnt <= 2'd3;
				end else begin
					s5_pix_cnt <= s5_pix_cnt + 2'd1;
				end
			end else begin
				s5_pix_cnt <= 2'd0;
			end
		end
	end

	assign epd_sdclk = sdclk_r;

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
	assign epd_gdoe = 1'b1;
//    assign epd_gdoe = (epd_vsync || epd_vbp || epd_vact) ? 1'b1 : 1'b0;
	assign epd_gdsp = (epd_vsync) ? 1'b0 : 1'b1;
	assign epd_sdoe = 1'b1;
//    assign epd_sdoe = (epd_vsync || epd_vbp || epd_vact) ? 1'b1 : 1'b0;
	assign epd_sdle = (epd_hsync && (epd_vact_le)) ? 1'b1 : 1'b0;
	assign epd_sdce = (epd_act) ? 1'b0 : 1'b1;
	assign epd_data  = epd_data_r;
//  assign epd_sdclk = epd_sdclk_r;

endmodule
