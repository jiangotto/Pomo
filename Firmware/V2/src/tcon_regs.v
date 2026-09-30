// Copyright Yuhan Jiang 2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2

`timescale 1ns / 1ps

// Runtime TCON register map carried by DSI Generic Short Write, 2 parameters
// (DT 0x23). The first parameter is the register address and the second is the
// value. Both observed receiver byte orders are accepted at this boundary.
module tcon_regs (
	input  wire        rst_n,
	input  wire        sys_clk,
	input  wire        byte_clk,
	input  wire        pixel_clk,
	input  wire        pixel_rst_n,

	input  wire        sp_en,
	input  wire        ecc_ok,
	input  wire [5:0]  dt,
	input  wire [15:0] wc,

	output wire        mode_write,
	output wire [3:0]  mode_value,
	output wire        panel_power,
	output wire        reinit_request
);
	localparam [7:0] REG_DISPLAY_MODE = 8'h50;
	localparam [7:0] REG_PANEL_POWER  = 8'h51;
	localparam [7:0] REG_REINITIALIZE = 8'h52;
	localparam [7:0] REINITIALIZE_KEY = 8'hA5;

	function is_display_mode;
		input [3:0] mode;
		begin
			is_display_mode = (mode == 4'h8) || (mode == 4'hA) ||
			                  (mode == 4'hB) || (mode == 4'hC);
		end
	endfunction

	// Decode each register explicitly. This keeps the externally visible map
	// readable and prevents unsupported values from changing TCON state.
	wire mode_low_first = (wc[7:0] == REG_DISPLAY_MODE) &&
		is_display_mode(wc[11:8]);
	wire mode_high_first = (wc[15:8] == REG_DISPLAY_MODE) &&
		is_display_mode(wc[3:0]);
	wire mode_packet = sp_en && ecc_ok && (dt == 6'h23) &&
		(mode_low_first || mode_high_first);

	wire power_low_first = (wc[7:0] == REG_PANEL_POWER) &&
		((wc[15:8] == 8'h00) || (wc[15:8] == 8'h01));
	wire power_high_first = (wc[15:8] == REG_PANEL_POWER) &&
		((wc[7:0] == 8'h00) || (wc[7:0] == 8'h01));
	wire power_packet = sp_en && ecc_ok && (dt == 6'h23) &&
		(power_low_first || power_high_first);

	wire reinit_low_first = (wc[7:0] == REG_REINITIALIZE) &&
		(wc[15:8] == REINITIALIZE_KEY);
	wire reinit_high_first = (wc[15:8] == REG_REINITIALIZE) &&
		(wc[7:0] == REINITIALIZE_KEY);
	wire reinit_packet = sp_en && ecc_ok && (dt == 6'h23) &&
		(reinit_low_first || reinit_high_first);

	// Byte-clock register bank. Mode and power are retained values; writing the
	// reinitialize key toggles an event bit rather than storing the key.
	reg [3:0] mode_byte;
	reg       mode_toggle_byte;
	reg       power_byte;
	reg       reinit_toggle_byte;

	always @(posedge byte_clk or negedge rst_n) begin
		if (!rst_n) begin
			mode_byte          <= 4'h0;
			mode_toggle_byte   <= 1'b0;
			power_byte         <= 1'b1;
			reinit_toggle_byte <= 1'b0;
		end else if (mode_packet) begin
			mode_byte <= mode_low_first ? wc[11:8] : wc[3:0];
			mode_toggle_byte <= ~mode_toggle_byte;
		end else if (power_packet) begin
			power_byte <= power_low_first ? wc[8] : wc[0];
		end else if (reinit_packet) begin
			reinit_toggle_byte <= ~reinit_toggle_byte;
		end
	end

	// The PMIC controller uses the stable system clock. panel_power is a level,
	// so repeated writes of the same value are naturally idempotent.
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [1:0] power_sync;
	always @(posedge sys_clk or negedge rst_n) begin
		if (!rst_n)
			power_sync <= 2'b11;
		else
			power_sync <= {power_sync[0], power_byte};
	end
	assign panel_power = power_sync[1];

	// Mode writes cross with stable bundled data and become a one-cycle pulse
	// in the pixel domain.
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] mode_toggle_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [3:0] mode_data_sync_0;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [3:0] mode_data_sync_1;
	reg       mode_toggle_seen;
	reg       mode_write_pixel;
	reg [3:0] mode_value_pixel;

	always @(posedge pixel_clk or negedge pixel_rst_n) begin
		if (!pixel_rst_n) begin
			mode_toggle_sync <= 3'b000;
			mode_data_sync_0 <= 4'h0;
			mode_data_sync_1 <= 4'h0;
			mode_toggle_seen <= 1'b0;
			mode_write_pixel <= 1'b0;
			mode_value_pixel <= 4'h0;
		end else begin
			mode_toggle_sync <= {mode_toggle_sync[1:0], mode_toggle_byte};
			mode_data_sync_0 <= mode_byte;
			mode_data_sync_1 <= mode_data_sync_0;
			mode_write_pixel <= (mode_toggle_sync[2] != mode_toggle_seen);
			if (mode_toggle_sync[2] != mode_toggle_seen) begin
				mode_toggle_seen <= mode_toggle_sync[2];
				mode_value_pixel <= mode_data_sync_1;
			end
		end
	end

	// Reinitialize is an action register, so only its one-cycle event crosses.
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] reinit_toggle_sync;
	reg reinit_toggle_seen;
	reg reinit_request_pixel;

	always @(posedge pixel_clk or negedge pixel_rst_n) begin
		if (!pixel_rst_n) begin
			reinit_toggle_sync  <= 3'b000;
			reinit_toggle_seen  <= 1'b0;
			reinit_request_pixel <= 1'b0;
		end else begin
			reinit_toggle_sync <= {reinit_toggle_sync[1:0], reinit_toggle_byte};
			reinit_request_pixel <=
				(reinit_toggle_sync[2] != reinit_toggle_seen);
			if (reinit_toggle_sync[2] != reinit_toggle_seen)
				reinit_toggle_seen <= reinit_toggle_sync[2];
		end
	end

	assign mode_write     = mode_write_pixel;
	assign mode_value     = mode_value_pixel;
	assign reinit_request = reinit_request_pixel;
endmodule
