// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
//
// Parameterizable Gowin MIPI D-PHY receive front end.  This module intentionally
// contains only the physical receive and D-PHY SoT/lane alignment layers; DSI
// packet decoding belongs in the protocol layer above it.
//
// The implementation is currently for the 1:16 D-PHY mode used by Pomo.  LANES
// may be 1, 2, or 4.  Each lane finds the D-PHY SoT sync byte (8'hB8) from the
// serial bit stream and writes subsequent 16-bit words into a small elastic
// FIFO.  A word is released only when every enabled lane has one available, so
// lane skew is removed without a lane-specific fixed-cycle correction.

`timescale 1ns / 1ps

module mipi_dphy_rx_custom #(
	parameter integer LANES     = 2,
	parameter integer AUTO_TRAIN = 1,
	parameter integer IO_DELAY0 = 0,
	parameter integer IO_DELAY1 = 0,
	parameter integer IO_DELAY2 = 0,
	parameter integer IO_DELAY3 = 0
) (
	input  wire                    reset_n,

	inout  wire                    mipi_clk_p,
	inout  wire                    mipi_clk_n,
	inout  wire [LANES-1:0]        mipi_data_p,
	inout  wire [LANES-1:0]        mipi_data_n,

	input  wire [1:0]              lp_clk_in,
	input  wire                    lp_clk_dir,
	output wire [1:0]              lp_clk_out,
	input  wire [LANES*2-1:0]      lp_data_in,
	input  wire [LANES-1:0]        lp_data_dir,
	output wire [LANES*2-1:0]      lp_data_out,

	input  wire                    hs_en,
	input  wire                    clk_term_en,
	input  wire                    data_term_en,
	input  wire                    train_packet_done,
	input  wire                    train_packet_good,

	output wire                    clk_word,
	output wire [LANES*16-1:0]     data_out,
	output wire                    ready,
	output wire                    trained,
	output wire                    train_failed
);

	wire hs_clk;
	wire hs_clk_gated;
	wire [LANES-1:0] hs_data;
	wire [LANES*16-1:0] raw_words;
	wire [LANES-1:0] lane_locked;
	wire [LANES-1:0] lane_empty;
	wire [LANES*16-1:0] lane_words;
	wire delay_dynamic;
	wire [LANES-1:0] delay_setn;
	wire [LANES-1:0] delay_value;
	wire all_locked = &lane_locked;
	wire all_valid  = ~(|lane_empty);
	wire take_word  = hs_en && all_locked && all_valid;
	// The forwarded HS clock stops at the end of a burst.  Therefore state that
	// is local to one burst cannot wait for another clk_word edge to observe
	// hs_en=0; clear it asynchronously as soon as LP signalling ends the burst.
	wire burst_reset_n = reset_n && hs_en;
	reg [LANES*16-1:0] output_pipe0;
	reg [LANES*16-1:0] output_pipe1;

	// Gowin IO-logic simulation models resolve the device-wide reset through
	// an instance named GSR. The generated IP uses the same always-enabled
	// global-reset primitive.
	GSR GSR (.GSRI(1'b1));

	// P is bit 1 and N is bit 0, matching Gowin's generated MIPI RX port
	// convention. OEN is active low; receive-only operation therefore uses the
	// inverse of the LP direction input.
	MIPI_IBUF u_clk_ibuf (
		.I    (lp_clk_in[1]),
		.IB   (lp_clk_in[0]),
		.OEN  (~lp_clk_dir),
		.OENB (~lp_clk_dir),
		.IO   (mipi_clk_p),
		.IOB  (mipi_clk_n),
		.HSREN(hs_en && clk_term_en),
		.OL   (lp_clk_out[1]),
		.OB   (lp_clk_out[0]),
		.OH   (hs_clk)
	);

	// Reproduce the generated receiver's clean clock-start circuit.  The ring
	// advances from 0001 to its stopped state after HS clock activity begins;
	// DHCEN then admits only complete clock pulses to CLKDIV.
	reg [3:0] open_sync;
	wire open_sync_ce = ~open_sync[2];
	wire clock_stop = open_sync[1] | open_sync[0];

	always @(posedge hs_clk or negedge reset_n) begin
		if (!reset_n)
			open_sync <= 4'b0001;
		else if (open_sync_ce)
			open_sync <= {open_sync[2:0], open_sync[3]};
	end

	DHCEN u_hs_clock_enable (
		.CLKIN (hs_clk),
		.CE    (clock_stop),
		.CLKOUT(hs_clk_gated)
	);

	CLKDIV u_word_clock_divider (
		.HCLKIN(hs_clk_gated),
		.RESETN(reset_n),
		.CALIB (1'b0),
		.CLKOUT(clk_word)
	);
	defparam u_word_clock_divider.GSREN = "false";
	defparam u_word_clock_divider.DIV_MODE = "8";

	function integer lane_delay;
		input integer lane;
		begin
			case (lane)
				0: lane_delay = IO_DELAY0;
				1: lane_delay = IO_DELAY1;
				2: lane_delay = IO_DELAY2;
				3: lane_delay = IO_DELAY3;
				default: lane_delay = 0;
			endcase
		end
	endfunction

	genvar lane;
	generate
		for (lane = 0; lane < LANES; lane = lane + 1) begin : g_lane
			MIPI_IBUF u_data_ibuf (
				.I    (lp_data_in[lane*2+1]),
				.IB   (lp_data_in[lane*2]),
				.OEN  (~lp_data_dir[lane]),
				.OENB (~lp_data_dir[lane]),
				.IO   (mipi_data_p[lane]),
				.IOB  (mipi_data_n[lane]),
				.HSREN(hs_en && data_term_en),
				.OL   (lp_data_out[lane*2+1]),
				.OB   (lp_data_out[lane*2]),
				.OH   (hs_data[lane])
			);

			mipi_dphy_lane_deserializer_custom #(
				.IO_DELAY(lane_delay(lane))
			) u_deserializer (
				.reset_n (reset_n),
				.clk_fast(hs_clk_gated),
				.clk_word(clk_word),
				.hs_data (hs_data[lane]),
				.delay_dynamic(delay_dynamic),
				.delay_setn(delay_setn[lane]),
				.delay_value(delay_value[lane]),
				.raw_word(raw_words[lane*16 +: 16])
			);

			mipi_dphy_lane_aligner_custom #(
				.FIFO_DEPTH(LANES == 4 ? 3 : 2)
			) u_aligner (
				.reset_n (burst_reset_n),
				.clk_word(clk_word),
				.hs_en   (hs_en),
				.raw_word(raw_words[lane*16 +: 16]),
				.pop      (take_word),
				.locked   (lane_locked[lane]),
				.empty    (lane_empty[lane]),
				.data_out (lane_words[lane*16 +: 16])
			);
		end
	endgenerate

	// The Gowin packet receiver expects the generated IP's interface semantics:
	// ready is a persistent "SoT locked" level, not a per-word valid pulse.
	// The two registers also reproduce the aligner's observable delay between
	// ready assertion and the first word containing the sync byte.
	always @(posedge clk_word or negedge burst_reset_n) begin
		if (!burst_reset_n) begin
			output_pipe0 <= {(LANES*16){1'b0}};
			output_pipe1 <= {(LANES*16){1'b0}};
		end else if (take_word) begin
			output_pipe0 <= lane_words;
			output_pipe1 <= output_pipe0;
		end
	end

	assign data_out = output_pipe1;
	assign ready = all_locked;

	generate
		if (AUTO_TRAIN != 0) begin : g_iodelay_training
			mipi_iodelay_packet_trainer_custom #(
				.LANES(LANES),
				.FALLBACK0(IO_DELAY0), .FALLBACK1(IO_DELAY1),
				.FALLBACK2(IO_DELAY2), .FALLBACK3(IO_DELAY3)
			) u_trainer (
				.reset_n(reset_n), .clk_word(clk_word), .hs_en(hs_en),
				.link_ready(all_locked),
				.packet_done(train_packet_done),
				.packet_good(train_packet_good),
				.delay_dynamic(delay_dynamic),
				.delay_setn(delay_setn), .delay_value(delay_value),
				.trained(trained), .failed(train_failed)
			);
		end else begin : g_static_iodelay
			assign delay_dynamic = 1'b0;
			assign delay_setn = {LANES{1'b0}};
			assign delay_value = {LANES{1'b0}};
			assign trained = 1'b1;
			assign train_failed = 1'b0;
		end
	endgenerate

	// Invalid values should fail loudly in simulation and are rejected before
	// this block is ever used in the production project.
	initial begin
		if ((LANES != 1) && (LANES != 2) && (LANES != 4)) begin
			$display("ERROR: mipi_dphy_rx_custom LANES must be 1, 2, or 4");
			$finish;
		end
	end

endmodule


module mipi_dphy_lane_deserializer_custom #(
	parameter integer IO_DELAY = 46
) (
	input  wire        reset_n,
	input  wire        clk_fast,
	input  wire        clk_word,
	input  wire        hs_data,
	input  wire        delay_dynamic,
	input  wire        delay_setn,
	input  wire        delay_value,
	output wire [15:0] raw_word
);
	wire delayed_data;
	wire delay_flag_unused;

	IODELAY u_input_delay (
		.DI   (hs_data),
		.SDTAP(delay_dynamic),
		.SETN (delay_setn),
		.VALUE(delay_value),
		.DO   (delayed_data),
		.DF   (delay_flag_unused)
	);
	defparam u_input_delay.C_STATIC_DLY = IO_DELAY;

	IDES16 u_deserializer (
		.D    (delayed_data),
		.PCLK (clk_word),
		.FCLK (clk_fast),
		.RESET(~reset_n),
		.CALIB(1'b0),
		.Q0(raw_word[0]),   .Q1(raw_word[1]),
		.Q2(raw_word[2]),   .Q3(raw_word[3]),
		.Q4(raw_word[4]),   .Q5(raw_word[5]),
		.Q6(raw_word[6]),   .Q7(raw_word[7]),
		.Q8(raw_word[8]),   .Q9(raw_word[9]),
		.Q10(raw_word[10]), .Q11(raw_word[11]),
		.Q12(raw_word[12]), .Q13(raw_word[13]),
		.Q14(raw_word[14]), .Q15(raw_word[15])
	);
	defparam u_deserializer.GSREN = "false";
	defparam u_deserializer.LSREN = "true";
endmodule


// Boot-time per-lane input-delay calibration.  It scores only SoT acquisition
// close to the beginning of each HS burst; a later 8'hB8 occurring naturally
// in video payload therefore cannot turn a bad tap into a good one.
module mipi_iodelay_trainer_custom #(
	parameter integer LANES = 2,
	parameter integer FALLBACK0 = 46,
	parameter integer FALLBACK1 = 46,
	parameter integer FALLBACK2 = 46,
	parameter integer FALLBACK3 = 46,
	parameter integer TEST_BURSTS = 8,
	parameter integer EARLY_WORDS = 24
) (
	input  wire                    reset_n,
	input  wire                    clk_word,
	input  wire                    hs_en,
	input  wire [LANES-1:0]        lane_locked,
	output reg                     delay_dynamic,
	output reg  [LANES-1:0]        delay_setn,
	output reg  [LANES-1:0]        delay_value,
	output reg                     trained,
	output reg                     failed
);
	localparam [3:0] S_LOAD       = 4'd0;
	localparam [3:0] S_ZERO_HIGH  = 4'd1;
	localparam [3:0] S_ZERO_LOW   = 4'd2;
	localparam [3:0] S_MEASURE    = 4'd3;
	localparam [3:0] S_INC_HIGH   = 4'd4;
	localparam [3:0] S_INC_LOW    = 4'd5;
	localparam [3:0] S_SET_HIGH   = 4'd6;
	localparam [3:0] S_SET_LOW    = 4'd7;
	localparam [3:0] S_DONE       = 4'd8;

	reg [3:0] state;
	reg [1:0] selected_lane;
	reg [6:0] step_count;
	reg [6:0] current_tap;
	reg [6:0] target_tap;
	reg [6:0] run_start;
	reg [7:0] run_length;
	reg [6:0] best_start;
	reg [7:0] best_length;
	reg [3:0] burst_count;
	reg [3:0] success_count;
	reg [5:0] early_count;
	reg       hs_en_d;
	reg       burst_active;
	reg       burst_success;

	wire selected_locked = lane_locked[selected_lane];
	wire tap_good = (success_count + (burst_success ? 1'b1 : 1'b0)) >= (TEST_BURSTS - 1);
	wire [7:0] candidate_length = run_length + 1'b1;
	wire [6:0] candidate_start = (run_length == 0) ? current_tap : run_start;
	wire candidate_is_best = tap_good && (candidate_length > best_length);
	wire [7:0] final_best_length = candidate_is_best ? candidate_length : best_length;
	wire [6:0] final_best_start = candidate_is_best ? candidate_start : best_start;

	function [6:0] fallback_tap;
		input [1:0] lane_number;
		begin
			case (lane_number)
				2'd0: fallback_tap = FALLBACK0[6:0];
				2'd1: fallback_tap = FALLBACK1[6:0];
				2'd2: fallback_tap = FALLBACK2[6:0];
				default: fallback_tap = FALLBACK3[6:0];
			endcase
		end
	endfunction

	// One-cycle setup helpers for a fresh tap measurement.
	task clear_measurement;
		begin
			burst_count <= 0;
			success_count <= 0;
			early_count <= 0;
			burst_active <= 0;
			burst_success <= 0;
		end
	endtask

	always @(posedge clk_word or negedge reset_n) begin
		if (!reset_n) begin
			state <= S_LOAD;
			selected_lane <= 0;
			step_count <= 0;
			current_tap <= 0;
			target_tap <= 0;
			run_start <= 0;
			run_length <= 0;
			best_start <= 0;
			best_length <= 0;
			burst_count <= 0;
			success_count <= 0;
			early_count <= 0;
			hs_en_d <= 0;
			burst_active <= 0;
			burst_success <= 0;
			delay_dynamic <= 0;
			delay_setn <= {LANES{1'b1}};
			delay_value <= 0;
			trained <= 0;
			failed <= 0;
		end else begin
			hs_en_d <= hs_en;
			case (state)
				S_LOAD: begin
					// SDTAP low loads each primitive's C_STATIC_DLY before
					// dynamic stepping is enabled on the following clock.
					delay_dynamic <= 1'b0;
					delay_value <= 0;
					step_count <= 0;
					state <= S_ZERO_HIGH;
				end
				S_ZERO_HIGH: begin
					delay_dynamic <= 1'b1;
					delay_setn <= {LANES{1'b1}};
					delay_value <= {LANES{1'b1}};
					state <= S_ZERO_LOW;
				end
				S_ZERO_LOW: begin
					delay_value <= 0;
					if (step_count == 7'd126) begin
						current_tap <= 0;
						selected_lane <= 0;
						run_length <= 0;
						best_length <= 0;
						clear_measurement;
						state <= S_MEASURE;
					end else begin
						step_count <= step_count + 1'b1;
						state <= S_ZERO_HIGH;
					end
				end
				S_MEASURE: begin
					if (hs_en && !hs_en_d) begin
						burst_active <= 1'b1;
						burst_success <= 1'b0;
						early_count <= 0;
					end else if (burst_active && hs_en && early_count < EARLY_WORDS) begin
						early_count <= early_count + 1'b1;
						if (selected_locked)
							burst_success <= 1'b1;
					end

					if (!hs_en && hs_en_d && burst_active) begin
						burst_active <= 1'b0;
						if (burst_success)
							success_count <= success_count + 1'b1;
						if (burst_count == TEST_BURSTS - 1) begin
							if (tap_good) begin
								if (run_length == 0) run_start <= current_tap;
								run_length <= candidate_length;
								if (candidate_is_best) begin
									best_start <= candidate_start;
									best_length <= candidate_length;
								end
							end else begin
								run_length <= 0;
							end

							if (current_tap == 7'd127) begin
								if (final_best_length != 0)
									target_tap <= final_best_start + final_best_length[7:1];
								else begin
									target_tap <= fallback_tap(selected_lane);
									failed <= 1'b1;
								end
								state <= S_SET_HIGH;
							end else begin
								state <= S_INC_HIGH;
							end
							clear_measurement;
						end else begin
							burst_count <= burst_count + 1'b1;
						end
					end
				end
				S_INC_HIGH: begin
					delay_setn <= 0;
					delay_value <= ({{(LANES-1){1'b0}},1'b1} << selected_lane);
					state <= S_INC_LOW;
				end
				S_INC_LOW: begin
					delay_value <= 0;
					current_tap <= current_tap + 1'b1;
					state <= S_MEASURE;
				end
				S_SET_HIGH: begin
					if (current_tap == target_tap) begin
						if (selected_lane == LANES - 1) begin
							trained <= 1'b1;
							state <= S_DONE;
						end else begin
							selected_lane <= selected_lane + 1'b1;
							current_tap <= 0;
							run_length <= 0;
							best_length <= 0;
							clear_measurement;
							state <= S_MEASURE;
						end
					end else begin
						delay_setn <= {LANES{1'b1}};
						delay_value <= ({{(LANES-1){1'b0}},1'b1} << selected_lane);
						state <= S_SET_LOW;
					end
				end
				S_SET_LOW: begin
					delay_value <= 0;
					current_tap <= current_tap - 1'b1;
					state <= S_SET_HIGH;
				end
				default: begin
					delay_value <= 0;
					trained <= 1'b1;
					state <= S_DONE;
				end
			endcase
		end
	end
endmodule


// Boot-time per-lane eye scan using the DSI protocol decoder as the checker.
// A tap scores only when complete long packets have valid header ECC and
// payload CRC. No pixel format, resolution, or word count is assumed.
//
// Only the selected lane is moved; all other lanes remain at their configured
// fallback (or already trained) tap.  This keeps the combined packet checker
// usable while each lane is scanned independently.
module mipi_iodelay_packet_trainer_custom #(
	parameter integer LANES = 2,
	parameter integer FALLBACK0 = 46,
	parameter integer FALLBACK1 = 46,
	parameter integer FALLBACK2 = 46,
	parameter integer FALLBACK3 = 46,
	parameter integer PACKETS_PER_TAP = 32,
	parameter integer PACKET_TIMEOUT_WORDS = 65535,
	parameter integer MIN_EYE_TAPS = 3
) (
	input  wire                    reset_n,
	input  wire                    clk_word,
	input  wire                    hs_en,
	input  wire                    link_ready,
	input  wire                    packet_done,
	input  wire                    packet_good,
	output reg                     delay_dynamic,
	output reg  [LANES-1:0]        delay_setn,
	output reg  [LANES-1:0]        delay_value,
	output reg                     trained,
	output reg                     failed
);
	localparam [3:0] S_LOAD       = 4'd0;
	localparam [3:0] S_ZERO_HIGH  = 4'd1;
	localparam [3:0] S_ZERO_LOW   = 4'd2;
	localparam [3:0] S_WAIT_LOW   = 4'd3;
	localparam [3:0] S_WAIT_LOCK  = 4'd4;
	localparam [3:0] S_DISCARD    = 4'd5;
	localparam [3:0] S_MEASURE    = 4'd6;
	localparam [3:0] S_INC_HIGH   = 4'd7;
	localparam [3:0] S_INC_LOW    = 4'd8;
	localparam [3:0] S_SET_HIGH   = 4'd9;
	localparam [3:0] S_SET_LOW    = 4'd10;
	localparam [3:0] S_FINAL_LOW  = 4'd11;
	localparam [3:0] S_FINAL_LOCK = 4'd12;
	localparam [3:0] S_DONE       = 4'd13;
	localparam integer PACKET_COUNT_BITS =
		(PACKETS_PER_TAP <= 1) ? 1 : $clog2(PACKETS_PER_TAP);
	localparam [6:0] MIN_EYE_SPAN = MIN_EYE_TAPS - 1;

	reg [3:0] state;
	reg [1:0] selected_lane;
	reg [6:0] current_tap;
	reg [6:0] run_start;
	reg [6:0] best_start;
	reg [6:0] best_span;
	reg [15:0] timeout_count;
	reg [PACKET_COUNT_BITS-1:0] packet_count;
	reg        tap_error;
	reg        in_run;
	reg        best_valid;

	function [6:0] fallback_tap;
		input [1:0] lane_number;
		begin
			case (lane_number)
				2'd0: fallback_tap = FALLBACK0[6:0];
				2'd1: fallback_tap = FALLBACK1[6:0];
				2'd2: fallback_tap = FALLBACK2[6:0];
				default: fallback_tap = FALLBACK3[6:0];
			endcase
		end
	endfunction

	wire [6:0] selected_fallback = fallback_tap(selected_lane);
	wire       sample_complete = packet_done &&
		(packet_count == PACKETS_PER_TAP - 1);
	wire       sample_timeout = timeout_count >= PACKET_TIMEOUT_WORDS - 1;
	wire       current_good = sample_complete && !tap_error && packet_good;
	wire [6:0] candidate_start = in_run ? run_start : current_tap;
	wire [6:0] candidate_span = current_tap - candidate_start;
	wire       candidate_preferred = current_good &&
		(!best_valid || (candidate_span > best_span));
	wire       final_best_valid = candidate_preferred || best_valid;
	wire [6:0] final_best_span = candidate_preferred ?
	                              candidate_span : best_span;
	wire [6:0] final_best_start = candidate_preferred ?
	                               candidate_start : best_start;
	always @(posedge clk_word or negedge reset_n) begin
		if (!reset_n) begin
			state <= S_LOAD;
			selected_lane <= 0;
			current_tap <= 0;
			run_start <= 0;
			best_start <= 0;
			best_span <= 0;
			timeout_count <= 0;
			packet_count <= 0;
			tap_error <= 0;
			in_run <= 0;
			best_valid <= 0;
			delay_dynamic <= 0;
			delay_setn <= {LANES{1'b1}};
			delay_value <= 0;
			trained <= 0;
			failed <= 0;
		end else begin
			delay_value <= 0;
			case (state)
				S_LOAD: begin
					// First load every lane's known-safe static setting.  The
					// selected lane alone is then walked down to tap zero.
					delay_dynamic <= 1'b0;
					current_tap <= selected_fallback;
					state <= S_ZERO_HIGH;
				end

				S_ZERO_HIGH: begin
					delay_dynamic <= 1'b1;
					if (current_tap == 0) begin
						timeout_count <= 0;
						state <= S_WAIT_LOW;
					end else begin
						delay_setn <= {LANES{1'b1}};
						delay_value <=
							({{(LANES-1){1'b0}},1'b1} << selected_lane);
						state <= S_ZERO_LOW;
					end
				end

				S_ZERO_LOW: begin
					current_tap <= current_tap - 1'b1;
					state <= S_ZERO_HIGH;
				end

				// Every new tap must be measured from a freshly acquired SoT.
				// Waiting for ready to drop prevents stale alignment/parser state
				// from being scored as part of the new tap.
				S_WAIT_LOW: begin
					if (!link_ready) begin
						timeout_count <= 0;
						state <= S_WAIT_LOCK;
					end else if (hs_en) begin
						timeout_count <= timeout_count + 1'b1;
					end
				end

				S_WAIT_LOCK: begin
					if (link_ready) begin
						timeout_count <= 0;
						state <= S_DISCARD;
					end else if (hs_en && sample_timeout) begin
						tap_error <= 1'b1;
						state <= S_MEASURE;
					end else if (hs_en) begin
						timeout_count <= timeout_count + 1'b1;
					end
				end

				// The first packet after reacquisition may contain the transition
				// from the previous tap.  It is deliberately never scored.
				S_DISCARD: begin
					if (packet_done) begin
						timeout_count <= 0;
						packet_count <= 0;
						tap_error <= 0;
						state <= S_MEASURE;
					end else if (hs_en && sample_timeout) begin
						tap_error <= 1'b1;
						state <= S_MEASURE;
					end else if (hs_en) begin
						timeout_count <= timeout_count + 1'b1;
					end
				end

				S_MEASURE: begin
					if (packet_done) begin
						timeout_count <= 0;
						if (!packet_good)
							tap_error <= 1'b1;
						if (!sample_complete)
							packet_count <= packet_count + 1'b1;
					end else if (hs_en) begin
						timeout_count <= timeout_count + 1'b1;
					end

					if (sample_complete || sample_timeout) begin
						if (current_good) begin
							if (!in_run)
								run_start <= current_tap;
							in_run <= 1'b1;
							if (candidate_preferred) begin
								best_start <= candidate_start;
								best_span <= candidate_span;
								best_valid <= 1'b1;
							end
						end else begin
							in_run <= 1'b0;
						end

						if (current_tap == 7'd127) begin
							if (!final_best_valid ||
							    (final_best_span < MIN_EYE_SPAN)) begin
								best_start <= selected_fallback;
								failed <= 1'b1;
							end else begin
								best_start <= final_best_start +
								              final_best_span[6:1];
							end
							state <= S_SET_HIGH;
						end else begin
							state <= S_INC_HIGH;
						end
					end
				end

				S_INC_HIGH: begin
					delay_setn <= {LANES{1'b0}};
					delay_value <= ({{(LANES-1){1'b0}},1'b1} << selected_lane);
					state <= S_INC_LOW;
				end

				S_INC_LOW: begin
					current_tap <= current_tap + 1'b1;
					timeout_count <= 0;
					packet_count <= 0;
					tap_error <= 0;
					state <= S_WAIT_LOW;
				end

				S_SET_HIGH: begin
					if (current_tap == best_start) begin
						// Never release downstream logic while ready still belongs
						// to the old tap.  The chosen center must acquire a fresh SoT.
						state <= S_FINAL_LOW;
					end else begin
						delay_setn <= {LANES{1'b1}};
						delay_value <=
							({{(LANES-1){1'b0}},1'b1} << selected_lane);
						state <= S_SET_LOW;
					end
				end

				S_SET_LOW: begin
					current_tap <= current_tap - 1'b1;
					state <= S_SET_HIGH;
				end

				S_FINAL_LOW: begin
					if (!link_ready)
						state <= S_FINAL_LOCK;
				end

				S_FINAL_LOCK: begin
					if (link_ready) begin
						if (selected_lane == LANES - 1) begin
							trained <= 1'b1;
							state <= S_DONE;
						end else begin
							selected_lane <= selected_lane + 1'b1;
							current_tap <=
								fallback_tap(selected_lane + 1'b1);
							run_start <= 0;
							best_start <= 0;
							best_span <= 0;
							timeout_count <= 0;
							packet_count <= 0;
							tap_error <= 0;
							in_run <= 0;
							best_valid <= 0;
							state <= S_ZERO_HIGH;
						end
					end
				end

				default: begin
					trained <= 1'b1;
					state <= S_DONE;
				end
			endcase
		end
	end
endmodule


// Pure digital alignment block. Keeping it separate from the Gowin primitives
// makes its exhaustive and randomized simulation independent of the PHY model.
module mipi_dphy_lane_aligner_custom #(
	parameter integer FIFO_DEPTH = 2
) (
	input  wire        reset_n,
	input  wire        clk_word,
	input  wire        hs_en,
	input  wire [15:0] raw_word,
	input  wire        pop,
	output reg         locked,
	output wire        empty,
	output reg  [15:0] data_out
);
	localparam [7:0] DPHY_SYNC = 8'hB8;

	// Break the fixed I/O-logic-to-fabric path at the word-clock boundary.
	// Acquisition is delayed by one word, but ready and its first aligned word
	// move together, so the protocol-facing ready-relative stream is unchanged.
	reg [15:0] current_word;
	reg [15:0] previous_word;
	reg [3:0]  word_phase;
	wire queue_can_push;

	reg         sync_found;
	reg [3:0]   sync_offset;
	reg         push;
	reg [15:0]  push_data;
	wire [31:0] stream_window = {current_word, previous_word};
	wire [15:0] sync_match;
	wire        sync_match_low = |sync_match[7:0];
	wire [7:0]  sync_match_half = sync_match_low ?
		sync_match[7:0] : sync_match[15:8];
	genvar sync_bit;
	generate
		for (sync_bit = 0; sync_bit < 16; sync_bit = sync_bit + 1) begin : g_sync_match
			// Fixed part-selects are important here. A procedural variable shift
			// makes Gowin build sixteen full barrel shifters for this search.
			assign sync_match[sync_bit] =
				(stream_window[sync_bit +: 8] == DPHY_SYNC);
		end
	endgenerate

	function [15:0] select_aligned_word;
		input [31:0] bits;
		input [3:0] phase;
		begin
			case (phase)
				4'd0:  select_aligned_word = bits[15:0];
				4'd1:  select_aligned_word = bits[16:1];
				4'd2:  select_aligned_word = bits[17:2];
				4'd3:  select_aligned_word = bits[18:3];
				4'd4:  select_aligned_word = bits[19:4];
				4'd5:  select_aligned_word = bits[20:5];
				4'd6:  select_aligned_word = bits[21:6];
				4'd7:  select_aligned_word = bits[22:7];
				4'd8:  select_aligned_word = bits[23:8];
				4'd9:  select_aligned_word = bits[24:9];
				4'd10: select_aligned_word = bits[25:10];
				4'd11: select_aligned_word = bits[26:11];
				4'd12: select_aligned_word = bits[27:12];
				4'd13: select_aligned_word = bits[28:13];
				4'd14: select_aligned_word = bits[29:14];
				default: select_aligned_word = bits[30:15];
			endcase
		end
	endfunction

	// raw_word[0] is the earliest serial bit produced by IDES16.  The D-PHY
	// sync byte is transmitted least-significant bit first, so an aligned eight
	// bit chronological window has the ordinary numeric value 8'hB8.
	always @* begin
		sync_found = |sync_match;
		// 8'hB8 has no self-overlap at shifts 1..7, so each half can contain
		// at most one valid match. Prefer the earlier half, then encode that
		// one-hot match without a sixteen-level priority chain.
		sync_offset[3] = !sync_match_low;
		sync_offset[2] = |sync_match_half[7:4];
		sync_offset[1] = |{sync_match_half[7:6], sync_match_half[3:2]};
		sync_offset[0] = |{sync_match_half[7], sync_match_half[5],
			sync_match_half[3], sync_match_half[1]};

		push = 1'b0;
		push_data = select_aligned_word(stream_window,
			locked ? word_phase : sync_offset);
		if (locked) begin
			push = queue_can_push;
		end else if (hs_en && sync_found) begin
			// Preserve the sync byte. The Gowin DSI/CSI-2 protocol receiver
			// consumes the same {first payload byte, 8'hB8} first word.
			push = 1'b1;
		end
	end

	generate
		if (FIFO_DEPTH == 2) begin : g_fifo2
			reg [15:0] fifo0, fifo1;
			reg read_pointer;
			// 00=empty, 01=one word, 11=full.
			reg [1:0] fifo_occupancy;
			wire write_pointer = read_pointer ^
				(fifo_occupancy[0] && !fifo_occupancy[1]);
			assign empty = (fifo_occupancy == 2'b00);
			assign queue_can_push = !fifo_occupancy[1] || pop;
			always @* data_out = read_pointer ? fifo1 : fifo0;
			always @(posedge clk_word or negedge reset_n) begin
				if (!reset_n) begin
					read_pointer <= 1'b0;
					fifo_occupancy <= 2'b00;
					fifo0 <= 16'd0;
					fifo1 <= 16'd0;
				end else if (!hs_en) begin
					read_pointer <= 1'b0;
					fifo_occupancy <= 2'b00;
				end else begin
					if (push) begin
						if (write_pointer) fifo1 <= push_data;
						else               fifo0 <= push_data;
					end
					if (pop) read_pointer <= ~read_pointer;
					case ({push, pop})
						2'b10: fifo_occupancy <= {fifo_occupancy[0], 1'b1};
						2'b01: fifo_occupancy <= {1'b0, fifo_occupancy[1]};
						default: fifo_occupancy <= fifo_occupancy;
					endcase
				end
			end
		end else begin : g_fifo3
			reg [15:0] fifo0, fifo1, fifo2;
			reg [1:0] read_pointer, write_pointer;
			// Thermometer fill: 000, 001, 011, 111.
			reg [2:0] occupancy;
			assign empty = !occupancy[0];
			assign queue_can_push = !occupancy[2] || pop;
			always @* begin
				case (read_pointer)
					2'd0: data_out = fifo0;
					2'd1: data_out = fifo1;
					default: data_out = fifo2;
				endcase
			end
			always @(posedge clk_word or negedge reset_n) begin
				if (!reset_n) begin
					read_pointer <= 2'd0;
					write_pointer <= 2'd0;
					occupancy <= 3'd0;
					fifo0 <= 16'd0; fifo1 <= 16'd0; fifo2 <= 16'd0;
				end else if (!hs_en) begin
					read_pointer <= 2'd0;
					write_pointer <= 2'd0;
					occupancy <= 3'd0;
				end else begin
					if (push) begin
						case (write_pointer)
							2'd0: fifo0 <= push_data;
							2'd1: fifo1 <= push_data;
							default: fifo2 <= push_data;
						endcase
						write_pointer <= {write_pointer[0],
							~(write_pointer[1] | write_pointer[0])};
					end
					if (pop) read_pointer <= {read_pointer[0],
						~(read_pointer[1] | read_pointer[0])};
					case ({push, pop})
						2'b10: occupancy <= {occupancy[1:0], 1'b1};
						2'b01: occupancy <= {1'b0, occupancy[2:1]};
						default: occupancy <= occupancy;
					endcase
				end
			end
		end
	endgenerate

	always @(posedge clk_word or negedge reset_n) begin
		if (!reset_n) begin
			current_word <= 16'd0;
			previous_word <= 16'd0;
			word_phase <= 4'd0;
			locked <= 1'b0;
		end else if (!hs_en) begin
			current_word <= raw_word;
			previous_word <= current_word;
			word_phase <= 4'd0;
			locked <= 1'b0;
		end else begin
			current_word <= raw_word;
			previous_word <= current_word;

			if (!locked && sync_found) begin
				locked <= 1'b1;
				word_phase <= sync_offset;
			end
		end
	end
endmodule
