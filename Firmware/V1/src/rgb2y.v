`timescale 1ns / 1ps

module rgb2y(
    input wire [5:0] r,
    input wire [5:0] g,
    input wire [5:0] b,
    output wire [7:0] y
    );

    // Pretty much overkill.
    // Could just use simple shifter to save some DSP blocks.
    wire [13:0] r_mult = {8'd0, r} * 14'd77;
    wire [13:0] g_mult = {8'd0, g} * 14'd150;
    wire [13:0] b_mult = {8'd0, b} * 14'd29;

    wire [13:0] acc = r_mult + g_mult + b_mult;

    assign y = acc[13:6];

endmodule