// Copyright Yuhan Jiang 2025-2026
//
// Stream rearranger for panels whose logical 2W x H image is wired as a
// physical W-source x 2H-gate array (for example ET073TC1).

`timescale 1ns/1ps

module epd_pixel_reorder #(
	parameter integer IN_HFP    = 8,
	parameter integer IN_HSYNC  = 32,
	parameter integer IN_HBP    = 40,
	parameter integer IN_HACT   = 750,
	parameter integer IN_VFP    = 1,
	parameter integer IN_VSYNC  = 8,
	parameter integer IN_VBP    = 6,
	parameter integer IN_VACT   = 200
) (
	input  wire       clk,
	input  wire       rst_n,
	input  wire       in_vsync,
	input  wire       in_hsync,
	input  wire       in_de,
	input  wire [3:0] in_pixel,
	output wire       out_vsync,
	output wire       out_hsync,
	output wire       out_de,
	output wire [3:0] out_pixel
);

	localparam integer PAIR_COUNT = IN_HACT / 2;
	localparam integer IN_HTOTAL  = IN_HSYNC + IN_HBP + IN_HACT + IN_HFP;
	localparam integer OUT_HACT   = PAIR_COUNT;
	localparam integer OUT_HTOTAL = IN_HTOTAL / 2;
	localparam integer OUT_HSYNC  = IN_HSYNC / 2;
	// Keep enough front porch for a padded partial source word and the
	// board-required dummy SDCLK. Horizontal total remains exactly halved.
	localparam integer OUT_HFP    = IN_HFP + 4;
	localparam integer OUT_HBP    = OUT_HTOTAL-OUT_HSYNC-OUT_HACT-OUT_HFP;
	localparam integer OUT_HSTART = OUT_HSYNC + OUT_HBP;

	// Two ping-pong banks share one simple-dual-port BSRAM. Each address holds
	// an adjacent logical pixel pair as {odd, even}.
	(* RAM_STYLE = "BLOCK" *) reg [7:0] line_mem [0:(PAIR_COUNT*2)-1];
	reg [3:0] even_pixel;
	// Twelve-bit horizontal coordinates support logical widths up to 4095.
	// The former 10-bit counters wrapped at 1024 pixels.
	reg [11:0] in_x;
	reg       capture_bank;
	reg       output_bank;
	reg       in_de_d;
	reg       in_vsync_d;
	reg       in_hsync_d;

	wire in_vsync_rise = in_vsync & ~in_vsync_d;
	wire in_hsync_rise = in_hsync & ~in_hsync_d;
	wire in_de_fall     = in_de_d & ~in_de;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			in_x          <= 12'd0;
			capture_bank  <= 1'b0;
			even_pixel    <= 4'd0;
			in_de_d       <= 1'b0;
			in_vsync_d    <= 1'b0;
			in_hsync_d    <= 1'b0;
		end else begin
			in_de_d    <= in_de;
			in_vsync_d <= in_vsync;
			in_hsync_d <= in_hsync;

			if (in_vsync_rise) begin
				in_x         <= 12'd0;
				capture_bank <= 1'b0;
			end else if (in_de) begin
				if (!in_x[0]) begin
					even_pixel <= in_pixel;
				end else begin
					line_mem[(capture_bank ? PAIR_COUNT : 0) + (in_x >> 1)]
						<= {in_pixel, even_pixel};
				end
				in_x <= in_x + 12'd1;
			end else if (in_de_fall) begin
				in_x         <= 12'd0;
				capture_bank <= ~capture_bank;
			end
		end
	end

	// Input frame-line index is used only to delay physical VSYNC by one input
	// line. The final active pair occupies the first input VFP line; the
	// remaining input VFP lines plus input line 0 still produce exactly IN_VFP
	// physical VFP pulses. VFP/VSYNC/VBP counts are therefore not multiplied.
	reg [10:0] in_line_index;
	reg        out_vsync_r;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			in_line_index <= 11'd0;
			out_vsync_r   <= 1'b0;
		end else if (in_vsync_rise) begin
			in_line_index <= 11'd0;
			out_vsync_r   <= 1'b0;
		end else if (in_hsync_rise) begin
			in_line_index <= in_line_index + 11'd1;
			out_vsync_r <= ((in_line_index + 11'd1) >= 1) &&
			                 ((in_line_index + 11'd1) < 1 + IN_VSYNC);
		end
	end

	reg [11:0] out_h_cnt;
	reg       pair_busy;
	reg       second_row;
	reg       blank_hsync;
	reg [7:0] blank_hs_cnt;
	reg [7:0] rd_word;

	// A complete logical row becomes available at in_de_fall. Its two
	// physical rows occupy the following logical-line period. Each subsequent
	// DE fall re-locks the pair boundary, so error cannot accumulate by frame.
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			out_h_cnt    <= 12'd0;
			pair_busy    <= 1'b0;
			second_row   <= 1'b0;
			output_bank  <= 1'b0;
			blank_hsync  <= 1'b0;
			blank_hs_cnt <= 8'd0;
		end else begin
			if (blank_hsync) begin
				if (blank_hs_cnt == OUT_HSYNC-1) begin
					blank_hsync  <= 1'b0;
					blank_hs_cnt <= 8'd0;
				end else begin
					blank_hs_cnt <= blank_hs_cnt + 8'd1;
				end
			end

			if (in_de_fall) begin
				out_h_cnt   <= 12'd0;
				pair_busy   <= 1'b1;
				second_row  <= 1'b0;
				output_bank <= capture_bank;
				blank_hsync <= 1'b0;
			end else if (pair_busy) begin
				if (out_h_cnt == OUT_HTOTAL-1) begin
					if (!second_row) begin
						out_h_cnt  <= 12'd0;
						second_row <= 1'b1;
					end else begin
						// Do not free-run into a third physical line. A slightly
						// longer input line merely stretches the final front porch.
						pair_busy <= 1'b0;
					end
				end else begin
					out_h_cnt <= out_h_cnt + 12'd1;
				end
			end else if (in_hsync_rise) begin
				// During vertical blanking, retain the original number of line
				// pulses. The first active input-line HSYNC is the last VBP line;
				// active output starts only after that row has been captured.
				blank_hsync  <= 1'b1;
				blank_hs_cnt <= 8'd0;
			end
		end
	end

	wire active_read = pair_busy &&
		(out_h_cnt >= OUT_HSTART) &&
		(out_h_cnt < OUT_HSTART + OUT_HACT);
	wire read_prefetch = pair_busy &&
		(out_h_cnt >= OUT_HSTART-1) &&
		(out_h_cnt < OUT_HSTART + OUT_HACT-1);
	wire [11:0] read_pair = out_h_cnt - (OUT_HSTART-1);

	always @(posedge clk) begin
		if (read_prefetch)
			rd_word <= line_mem[(output_bank ? PAIR_COUNT : 0) + read_pair];
	end

	assign out_vsync = out_vsync_r;
	assign out_hsync = pair_busy ? (out_h_cnt < OUT_HSYNC) : blank_hsync;
	assign out_de     = active_read;
	assign out_pixel  = second_row ? rd_word[7:4] : rd_word[3:0];

	// IN_VBP and IN_VACT document the expected input format and are consumed
	// by the downstream physical VACT count; no independent vertical raster
	// counter is required here.
	wire _unused_vertical_params = (IN_VBP == IN_VBP) && (IN_VACT == IN_VACT);

endmodule
