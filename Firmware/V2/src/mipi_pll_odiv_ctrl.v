// Measure the MIPI 1:16 word clock against the 27 MHz system clock and select
// the PLLVR ODIV for the active lane count.  RGB888 carries 24 bits/pixel, so
// pixel clock = word clock * LANES * 16 / 24 = word clock * 2*LANES/3.
module mipi_pll_odiv_ctrl #(
	parameter integer LANES = 2
) (
	input  wire       clk_ref,
	input  wire       clk_byte,
	input  wire       rst_n,
	input  wire       pll_lock,
	output reg  [5:0] odsel,
	output reg        pll_reset,
	output reg        pll_ready
);
	// The asynchronous edge counter is intentionally wider than one measurement
	// window so subtraction remains valid across counter wrap.
	reg [23:0] byte_count;
	wire [23:0] byte_count_gray = byte_count ^ (byte_count >> 1);

	always @(posedge clk_byte or negedge rst_n) begin
		if (!rst_n)
			byte_count <= 24'd0;
		else
			byte_count <= byte_count + 24'd1;
	end

	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [23:0] gray_meta;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg [23:0] gray_sync;
	reg [15:0] measure_timer;
	reg [23:0] count_previous;
	reg [23:0] count_now;
	reg        configured;
	reg [5:0]  reset_hold;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg lock_meta;
	(* ASYNC_REG = "TRUE", syn_preserve = 1 *) reg lock_sync;
	reg        lock_window_seen;
	reg [5:0]  candidate_odsel;
	reg [3:0]  candidate_stable_count;

	// Gray-to-binary conversion for the asynchronously sampled counter.
	integer i;
	always @* begin
		count_now[23] = gray_sync[23];
		for (i = 22; i >= 0; i = i - 1)
			count_now[i] = count_now[i+1] ^ gray_sync[i];
	end

	// Normalize the measured word-clock rate to its 2-lane equivalent.  This
	// lets one set of UG286 VCO thresholds serve the M2D3, M4D3 and M8D3 PLLs:
	// the feedback multiplier and aggregate lane throughput scale together.
	wire [23:0] measured_delta = count_now - count_previous;
	wire [23:0] normalized_delta =
		(LANES == 1) ? (measured_delta >> 1) :
		(LANES == 4) ? (measured_delta << 1) :
		                measured_delta;

	// PLLVR ODSEL encoding from UG286 table 5-6. Thresholds correspond to a
	// 65536-cycle measurement window at 27 MHz after lane normalization. Match
	// the Gowin IP Generator by selecting the smallest supported ODIV that puts
	// the VCO at or above 600 MHz.
	function [5:0] choose_odsel;
		input [23:0] byte_edges;
		begin
			if      (byte_edges >= 24'd546134) choose_odsel = 6'b111111; // /2
			else if (byte_edges >= 24'd273067) choose_odsel = 6'b111110; // /4
			else if (byte_edges >= 24'd136534) choose_odsel = 6'b111100; // /8
			else if (byte_edges >= 24'd68267)  choose_odsel = 6'b111000; // /16
			else if (byte_edges >= 24'd34134)  choose_odsel = 6'b110000; // /32
			else if (byte_edges >= 24'd22756)  choose_odsel = 6'b101000; // /48
			else if (byte_edges >= 24'd17067)  choose_odsel = 6'b100000; // /64
			else if (byte_edges >= 24'd13654)  choose_odsel = 6'b011000; // /80
			else if (byte_edges >= 24'd11378)  choose_odsel = 6'b010000; // /96
			else if (byte_edges >= 24'd9753)   choose_odsel = 6'b001000; // /112
			else                                choose_odsel = 6'b000000; // /128
		end
	endfunction
	wire [5:0]  measured_odsel = choose_odsel(normalized_delta);
	wire window_tick = (measure_timer == 16'hffff);
	// Initial lock requires three agreeing windows. A live rate change must be
	// stable for eight windows before disturbing a working display pipeline.
	wire initial_candidate_ready = !configured &&
		(measured_odsel == candidate_odsel) &&
		(candidate_stable_count >= 4'd2);
	wire change_candidate_ready = configured &&
		(measured_odsel != odsel) &&
		(measured_odsel == candidate_odsel) &&
		(candidate_stable_count >= 4'd7);
	wire reconfigure = window_tick &&
	                   (initial_candidate_ready || change_candidate_ready);

	always @(posedge clk_ref or negedge rst_n) begin
		if (!rst_n) begin
			gray_meta         <= 24'd0;
			gray_sync         <= 24'd0;
			measure_timer     <= 16'd0;
			count_previous    <= 24'd0;
			odsel             <= (LANES == 1) ? 6'b110000 : // ODIV=32
			                     (LANES == 4) ? 6'b111100 : // ODIV=8
			                                    6'b111000;  // ODIV=16
			configured        <= 1'b0;
			reset_hold        <= 6'd0;
			pll_reset         <= 1'b1;
			lock_meta         <= 1'b0;
			lock_sync         <= 1'b0;
			lock_window_seen  <= 1'b0;
			pll_ready         <= 1'b0;
			candidate_odsel   <= (LANES == 1) ? 6'b110000 :
			                     (LANES == 4) ? 6'b111100 :
			                                    6'b111000;
			candidate_stable_count <= 4'd0;
		end else begin
			gray_meta <= byte_count_gray;
			gray_sync <= gray_meta;
			lock_meta <= pll_lock;
			lock_sync <= lock_meta;
			measure_timer <= measure_timer + 16'd1;

			if (window_tick) begin
				count_previous <= count_now;
				if (measured_odsel != candidate_odsel) begin
					candidate_odsel <= measured_odsel;
					candidate_stable_count <= 4'd1;
				end else if (candidate_stable_count != 4'hf) begin
					candidate_stable_count <= candidate_stable_count + 4'd1;
				end
				if (reconfigure) begin
					odsel      <= measured_odsel;
					configured <= 1'b1;
					reset_hold <= 6'd31;
					pll_reset  <= 1'b1;
					pll_ready  <= 1'b0;
					candidate_stable_count <= 4'd0;
				end
			end

			if (reconfigure) begin
				pll_reset <= 1'b1;
			end else if (reset_hold != 0) begin
				reset_hold <= reset_hold - 6'd1;
				pll_reset  <= 1'b1;
			end else if (configured) begin
				pll_reset <= 1'b0;
			end

			// UG286 requires LOCK to remain continuously asserted for at least
			// 2 ms. Two successive measurement-window boundaries guarantee one
			// complete 65536-cycle interval (2.43 ms at 27 MHz) without a second
			// wide counter and terminal-count comparator.
			if (reconfigure || pll_reset || !lock_sync) begin
				lock_window_seen  <= 1'b0;
				pll_ready         <= 1'b0;
			end else if (!pll_ready && window_tick) begin
				if (lock_window_seen)
					pll_ready <= 1'b1;
				else
					lock_window_seen <= 1'b1;
			end
		end
	end
endmodule
