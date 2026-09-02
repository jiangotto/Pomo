`timescale 1ns/1ps

// Internal video timing and test-pattern generator for Pomo.
//
// Output convention matches the current Pomo pipeline:
//   - VSYNC: active high
//   - HSYNC: active high
//   - DE:    active high
//   - PIXEL: 4-bit grayscale, 4'h0 = black, 4'hF = white
//
// PATTERN_MODE:
//   0: static white
//   1: central rectangle toggles black/white
//   2: vertical stripes inside central rectangle, inverted periodically
//   3: checkerboard inside central rectangle, inverted periodically
//   4: full screen toggles black/white
//   5: black reference background + central vertical stripes invert
//   6: black reference background + central rectangle toggles black/white
//   7: comprehensive EPD test: 16 gray levels, moving bar and dynamic checker
//   8: static full-screen 16-level grayscale bars (black to white)
//
// Recommended diagnostic use:
//   1) Clock this module from mipi_pclk to bypass MIPI data lanes/parser
//      while retaining the MIPI-derived pixel clock.
//   2) Clock it from sys_clk to bypass the complete MIPI RX path.
//
// H/V timing should match the parameters used by pomo.v.
// For about 85 Hz with a ~37.33 MHz pixel clock, use H_FRONT_PORCH=20.
// For a 27 MHz system clock, H_FRONT_PORCH=16 gives about 62 Hz.

module internal_video_gen #(
    parameter integer H_ACTIVE          = 800,
    parameter integer H_SYNC            = 32,
    parameter integer H_BACK_PORCH      = 40,
    parameter integer H_FRONT_PORCH     = 20,

    parameter integer V_ACTIVE          = 480,
    parameter integer V_SYNC            = 8,
    parameter integer V_BACK_PORCH      = 6,
    parameter integer V_FRONT_PORCH     = 1,

    parameter integer PATTERN_MODE      = 2,
    parameter integer TOGGLE_FRAMES     = 1,

    // When TARGET_FPS is non-zero, horizontal blanking is automatically
    // extended to approach this frame rate. It is never shortened below the
    // requested timing. H_TOTAL is rounded up to an even value so the same
    // source can also feed epd_pixel_reorder.
    parameter integer CLK_HZ            = 27000000,
    parameter integer TARGET_FPS        = 0,

    parameter integer RECT_X0           = 120,
    parameter integer RECT_X1           = 680,
    parameter integer RECT_Y0           = 80,
    parameter integer RECT_Y1           = 400,

    // Vertical stripe/checker cell size = 2^PATTERN_BLOCK_LOG2 pixels.
    parameter integer PATTERN_BLOCK_LOG2 = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    output wire        pclk,
    output wire        vsync,
    output wire        hsync,
    output wire        de,
    output reg  [3:0]  pixel,

    output reg  [31:0] frame_count
);

    localparam integer V_TOTAL = V_SYNC + V_BACK_PORCH +
                                 V_ACTIVE + V_FRONT_PORCH;
    localparam integer H_TOTAL_MIN = H_SYNC + H_BACK_PORCH +
                                     H_ACTIVE + H_FRONT_PORCH;
    localparam integer H_TOTAL_RATE = (TARGET_FPS > 0) ?
                                      (CLK_HZ / (TARGET_FPS * V_TOTAL)) :
                                      H_TOTAL_MIN;
    localparam integer H_TOTAL_RAW = (H_TOTAL_RATE > H_TOTAL_MIN) ?
                                     H_TOTAL_RATE : H_TOTAL_MIN;
    localparam integer H_TOTAL = (H_TOTAL_RAW + 1) & ~1;

    localparam integer H_ACTIVE_START = H_SYNC + H_BACK_PORCH;
    localparam integer H_ACTIVE_END   = H_ACTIVE_START + H_ACTIVE;

    localparam integer V_ACTIVE_START = V_SYNC + V_BACK_PORCH;
    localparam integer V_ACTIVE_END   = V_ACTIVE_START + V_ACTIVE;

    // Fixed counter widths are used for compatibility with Gowin Verilog flow.
    // They are sufficient for the intended 800x480 timing.
    reg [11:0] h_cnt;
    reg [10:0] v_cnt;
    reg [15:0] toggle_count;
    reg phase;
    reg [11:0] motion_x;

    assign pclk  = clk;
    assign hsync = enable && (h_cnt < H_SYNC);
    assign vsync = enable && (v_cnt < V_SYNC);

    assign de = enable &&
                (h_cnt >= H_ACTIVE_START) &&
                (h_cnt <  H_ACTIVE_END) &&
                (v_cnt >= V_ACTIVE_START) &&
                (v_cnt <  V_ACTIVE_END);

    wire [11:0] x_pos = h_cnt - H_ACTIVE_START;
    wire [10:0] y_pos = v_cnt - V_ACTIVE_START;

    wire in_rect = de &&
                   (x_pos >= RECT_X0) &&
                   (x_pos <  RECT_X1) &&
                   (y_pos >= RECT_Y0) &&
                   (y_pos <  RECT_Y1);

    wire stripe_phase =
        x_pos[PATTERN_BLOCK_LOG2] ^ phase;

    wire checker_phase =
        x_pos[PATTERN_BLOCK_LOG2] ^
        y_pos[PATTERN_BLOCK_LOG2] ^
        phase;

    // Keep the intermediate explicitly wide so Gowin does not report the
    // intentional 4-bit grayscale result as an implicit truncation.
    wire [31:0] grayscale_level = (x_pos * 16) / H_ACTIVE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt        <= 12'd0;
            v_cnt        <= 11'd0;
            toggle_count <= 16'd0;
            phase        <= 1'b0;
            motion_x     <= 12'd0;
            frame_count  <= 32'd0;
        end else if (!enable) begin
            h_cnt        <= 12'd0;
            v_cnt        <= 11'd0;
            toggle_count <= 16'd0;
            phase        <= 1'b0;
            motion_x     <= 12'd0;
            frame_count  <= 32'd0;
        end else begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 12'd0;

                if (v_cnt == V_TOTAL - 1) begin
                    v_cnt       <= 11'd0;
                    frame_count <= frame_count + 32'd1;

                    if (TOGGLE_FRAMES <= 1) begin
                        phase <= ~phase;
                        if (motion_x + (1 << PATTERN_BLOCK_LOG2) >=
                            (H_ACTIVE >> 1))
                            motion_x <= 12'd0;
                        else
                            motion_x <= motion_x + (1 << PATTERN_BLOCK_LOG2);
                    end else if (toggle_count == TOGGLE_FRAMES - 1) begin
                        toggle_count <= 16'd0;
                        phase        <= ~phase;
                        if (motion_x + (1 << PATTERN_BLOCK_LOG2) >=
                            (H_ACTIVE >> 1))
                            motion_x <= 12'd0;
                        else
                            motion_x <= motion_x + (1 << PATTERN_BLOCK_LOG2);
                    end else begin
                        toggle_count <= toggle_count + 1'b1;
                    end
                end else begin
                    v_cnt <= v_cnt + 1'b1;
                end
            end else begin
                h_cnt <= h_cnt + 1'b1;
            end
        end
    end

    always @(*) begin
        // Blanking data is irrelevant; white is a safe debug value.
        pixel = 4'hF;

        if (de) begin
            case (PATTERN_MODE)
                0: begin
                    pixel = 4'hF;
                end

                1: begin
                    // The entire central rectangle changes every phase.
                    pixel = in_rect ?
                            (phase ? 4'h0 : 4'hF) :
                            4'hF;
                end

                2: begin
                    // Inverting vertical bars. Best for finding column,
                    // packing, lane, and horizontal-address errors.
                    pixel = in_rect ?
                            (stripe_phase ? 4'h0 : 4'hF) :
                            4'hF;
                end

                3: begin
                    pixel = in_rect ?
                            (checker_phase ? 4'h0 : 4'hF) :
                            4'hF;
                end

                4: begin
                    pixel = phase ? 4'h0 : 4'hF;
                end

                5: begin
                    // Static black outside the test region provides an
                    // optical black reference. The central vertical stripes
                    // keep inverting. During their black phase, compare them
                    // directly with the surrounding black border.
                    pixel = in_rect ?
                            (stripe_phase ? 4'h0 : 4'hF) :
                            4'h0;
                end

                6: begin
                    // Static black border + a large toggling rectangle.
                    pixel = in_rect ?
                            (phase ? 4'h0 : 4'hF) :
                            4'h0;
                end

                7: begin
                    // Top half: 16 equal-width grayscale bars. This exercises
                    // every 4-bit input level and makes gamma/dither errors
                    // immediately visible.
                    if (y_pos < (V_ACTIVE >> 1)) begin
                        pixel = (x_pos * 16) / H_ACTIVE;
                    end
                    // Bottom-left: a black/white bar moving one block per
                    // TOGGLE_FRAMES, useful for update latency and ghosting.
                    else if (x_pos < (H_ACTIVE >> 1)) begin
                        if ((x_pos >= motion_x) &&
                            (x_pos < motion_x + (1 << PATTERN_BLOCK_LOG2)))
                            pixel = phase ? 4'hF : 4'h0;
                        else
                            pixel = 4'h8;
                    end
                    // Bottom-right: an inverting checkerboard for dynamic
                    // edge response and residual-image inspection.
                    else begin
                        pixel = checker_phase ? 4'h0 : 4'hF;
                    end
                end

                8: begin
                    // Full-screen 16-level grayscale reference. Each vertical
                    // bar covers approximately 1/16 of the active width, with
                    // black at the left and white at the right. This pattern
                    // is static and therefore does not depend on phase or
                    // TOGGLE_FRAMES.
                    pixel = grayscale_level[3:0];
                end

                default: begin
                    pixel = 4'hF;
                end
            endcase
        end
    end

endmodule
