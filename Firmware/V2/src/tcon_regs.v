// Copyright Yuhan Jiang 2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2

`timescale 1ns / 1ps

// Runtime TCON register map carried by DSI Generic Short Write, 2 parameters
// (DT 0x23). The first parameter is the register address and the second is the
// value. The protocol parser presents Param0 in wc[7:0] and Param1 in
// wc[15:8], matching the DSI short-packet wire order.
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
	// LPDT receiver has already checked the DSI header ECC. These fields
	// arrive in the always-on system-clock domain, before HS training.
	input  wire        lp_sp_en,
	input  wire [5:0]  lp_dt,
	input  wire [15:0] lp_wc,

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
	wire mode_packet = sp_en && ecc_ok && (dt == 6'h23) &&
		(wc[7:0] == REG_DISPLAY_MODE) &&
		is_display_mode(wc[11:8]);

	wire power_packet = sp_en && ecc_ok && (dt == 6'h23) &&
		(wc[7:0] == REG_PANEL_POWER) &&
		((wc[15:8] == 8'h00) || (wc[15:8] == 8'h01));

	wire reinit_packet = sp_en && ecc_ok && (dt == 6'h23) &&
		(wc[7:0] == REG_REINITIALIZE) &&
		(wc[15:8] == REINITIALIZE_KEY);
	wire lp_mode_packet = lp_sp_en && (lp_dt == 6'h23) &&
		(lp_wc[7:0] == REG_DISPLAY_MODE) && is_display_mode(lp_wc[11:8]);
	wire lp_power_packet = lp_sp_en && (lp_dt == 6'h23) &&
		(lp_wc[7:0] == REG_PANEL_POWER) &&
		((lp_wc[15:8] == 8'h00) || (lp_wc[15:8] == 8'h01));
	wire lp_reinit_packet = lp_sp_en && (lp_dt == 6'h23) &&
		(lp_wc[7:0] == REG_REINITIALIZE) &&
		(lp_wc[15:8] == REINITIALIZE_KEY);

	// Byte-clock register bank. Mode and power are retained values; writing the
	// reinitialize key toggles an event bit rather than storing the key.
	reg [3:0] mode_byte;
	reg       mode_toggle_byte;
	reg       power_byte;
	reg       power_toggle_byte;
	reg       reinit_toggle_byte;

	always @(posedge byte_clk or negedge rst_n) begin
		if (!rst_n) begin
			mode_byte          <= 4'h0;
			mode_toggle_byte   <= 1'b0;
			power_byte         <= 1'b1;
			power_toggle_byte  <= 1'b0;
			reinit_toggle_byte <= 1'b0;
		end else if (mode_packet) begin
			mode_byte <= wc[11:8];
			mode_toggle_byte <= ~mode_toggle_byte;
		end else if (power_packet) begin
			power_byte <= wc[8];
			power_toggle_byte <= ~power_toggle_byte;
		end else if (reinit_packet) begin
			reinit_toggle_byte <= ~reinit_toggle_byte;
		end
	end

	// Merge the HS and LP command sources in the always-on system domain.
	// Toggle CDC preserves HS writes even when the same value is written after
	// an LP command. The LP path needs neither the byte clock nor HS training.
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] hs_mode_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [3:0] hs_mode_data0, hs_mode_data1;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] hs_power_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [1:0] hs_power_data;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] hs_reinit_sync;
	reg hs_mode_seen, hs_power_seen, hs_reinit_seen;
	reg [3:0] mode_sys;
	reg mode_valid_sys, mode_toggle_sys;
	reg power_sys, reinit_toggle_sys;
	always @(posedge sys_clk or negedge rst_n) begin
		if (!rst_n) begin
			hs_mode_sync <= 3'b000;
			hs_mode_data0 <= 4'h0;
			hs_mode_data1 <= 4'h0;
			hs_power_sync <= 3'b000;
			hs_power_data <= 2'b11;
			hs_reinit_sync <= 3'b000;
			hs_mode_seen <= 1'b0;
			hs_power_seen <= 1'b0;
			hs_reinit_seen <= 1'b0;
			mode_sys <= 4'h0;
			mode_valid_sys <= 1'b0;
			mode_toggle_sys <= 1'b0;
			power_sys <= 1'b1;
			reinit_toggle_sys <= 1'b0;
		end else begin
			hs_mode_sync <= {hs_mode_sync[1:0], mode_toggle_byte};
			hs_mode_data0 <= mode_byte;
			hs_mode_data1 <= hs_mode_data0;
			hs_power_sync <= {hs_power_sync[1:0], power_toggle_byte};
			hs_power_data <= {hs_power_data[0], power_byte};
			hs_reinit_sync <= {hs_reinit_sync[1:0], reinit_toggle_byte};
			if (hs_mode_sync[2] != hs_mode_seen)
				hs_mode_seen <= hs_mode_sync[2];
			if (hs_power_sync[2] != hs_power_seen)
				hs_power_seen <= hs_power_sync[2];
			if (hs_reinit_sync[2] != hs_reinit_seen)
				hs_reinit_seen <= hs_reinit_sync[2];

			if (lp_mode_packet) begin
				mode_sys <= lp_wc[11:8];
				mode_valid_sys <= 1'b1;
				mode_toggle_sys <= ~mode_toggle_sys;
			end else if (hs_mode_sync[2] != hs_mode_seen) begin
				mode_sys <= hs_mode_data1;
				mode_valid_sys <= 1'b1;
				mode_toggle_sys <= ~mode_toggle_sys;
			end
			if (lp_power_packet)
				power_sys <= lp_wc[8];
			else if (hs_power_sync[2] != hs_power_seen)
				power_sys <= hs_power_data[1];
			if (lp_reinit_packet || hs_reinit_sync[2] != hs_reinit_seen)
				reinit_toggle_sys <= ~reinit_toggle_sys;
		end
	end
	assign panel_power = power_sys;

	// Mode writes cross with stable bundled data and become a one-cycle pulse
	// in the pixel domain.
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] mode_toggle_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [2:0] mode_valid_sync;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [3:0] mode_data_sync_0;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [3:0] mode_data_sync_1;
	reg       mode_toggle_seen;
	reg       mode_initialized;
	reg       mode_write_pixel;
	reg [3:0] mode_value_pixel;

	always @(posedge pixel_clk or negedge pixel_rst_n) begin
		if (!pixel_rst_n) begin
			mode_toggle_sync <= 3'b000;
			mode_valid_sync <= 3'b000;
			mode_data_sync_0 <= 4'h0;
			mode_data_sync_1 <= 4'h0;
			mode_toggle_seen <= 1'b0;
			mode_initialized <= 1'b0;
			mode_write_pixel <= 1'b0;
			mode_value_pixel <= 4'h0;
		end else begin
			mode_toggle_sync <= {mode_toggle_sync[1:0], mode_toggle_sys};
			mode_valid_sync <= {mode_valid_sync[1:0], mode_valid_sys};
			mode_data_sync_0 <= mode_sys;
			mode_data_sync_1 <= mode_data_sync_0;
			mode_write_pixel <= mode_valid_sync[2] &&
				(!mode_initialized || mode_toggle_sync[2] != mode_toggle_seen);
			if (mode_valid_sync[2] &&
			    (!mode_initialized || mode_toggle_sync[2] != mode_toggle_seen)) begin
				mode_initialized <= 1'b1;
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
			reinit_toggle_sync <= {reinit_toggle_sync[1:0], reinit_toggle_sys};
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
