// Copyright Yuhan Jiang 2025-2026
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.

`timescale 1ns/1ps

// Unified EPD PMIC initialization controller.
// Define PMIC_SY7636A in defines.vh for SY7636A; leave it undefined for
// TPS65185. The external signal names describe the shared package pins.
module pmic_ctrl #(
	parameter integer vcom_val = 1310
) (
	input  wire clk,                 // 27 MHz
	input  wire rst_n,

	output reg  pmic_pwrup,          // pin 21: TPS PWRUP / SY EN
	inout  wire pmic_sda,
	inout  wire pmic_scl,

	output reg  done_flag,
	output reg  error_flag
);

`ifdef PMIC_SY7636A
	localparam [6:0] DEV_ADDR = 7'h62;
	localparam [2:0] LAST_CONFIG = 3'd4;
`else
	localparam [6:0] DEV_ADDR = 7'h68;
	localparam [2:0] LAST_CONFIG = 3'd5;
`endif

	// Both devices retain the board's original 10 ms startup delay. SY7636A
	// additionally requires EN high for 2.5 ms before accepting I2C commands.
	localparam integer PRE_EN_CYCLES  = 270000; // 10 ms at 27 MHz
	localparam integer EN_WAIT_CYCLES =  67500; // 2.5 ms at 27 MHz
	localparam integer READY_CYCLES   = 540000; // 20 ms at 27 MHz

	reg [19:0] startup_cnt;
	reg        start;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			startup_cnt <= 20'd0;
			start       <= 1'b0;
			pmic_pwrup  <= 1'b0;
		end else begin
`ifdef PMIC_SY7636A
			if (startup_cnt < PRE_EN_CYCLES + EN_WAIT_CYCLES) begin
				startup_cnt <= startup_cnt + 20'd1;
				if (startup_cnt >= PRE_EN_CYCLES - 1)
					pmic_pwrup <= 1'b1;
			end else begin
				pmic_pwrup <= 1'b1;
				start      <= 1'b1;
			end
`else
			if (startup_cnt < PRE_EN_CYCLES)
				startup_cnt <= startup_cnt + 20'd1;
			else
				start <= 1'b1;
			pmic_pwrup <= done_flag;
`endif
		end
	end

	reg         I_TX_EN;
	reg  [2:0]  I_WADDR;
	reg  [7:0]  I_WDATA;
	reg         I_RX_EN;
	reg  [2:0]  I_RADDR;
	wire [7:0]  O_RDATA;

	localparam [2:0] PRERLO = 3'b000;
	localparam [2:0] PRERHI = 3'b001;
	localparam [2:0] CTR    = 3'b010;
	localparam [2:0] TXR    = 3'b011;
	localparam [2:0] CR     = 3'b100;
	localparam [2:0] SR     = 3'b100;

	// 27 MHz / (5 * 100 kHz) - 1 = 53.
	localparam [7:0] CLK_DIV_L = 8'h35;
	localparam [7:0] CLK_DIV_H = 8'h00;
	localparam [7:0] EN_IP     = 8'h80;
	localparam [7:0] STA_WR_CR = 8'h90;
	localparam [7:0] WR_CR     = 8'h10;
	localparam [7:0] STP_WR_CR = 8'h50;
	localparam       WR        = 1'b0;

	localparam integer VCOM_RAW = vcom_val / 10;
`ifdef PMIC_SY7636A
	localparam integer VCOM_CODE = (VCOM_RAW > 500) ? 500 :
	                               ((VCOM_RAW < 0) ? 0 : VCOM_RAW);
`else
	localparam integer VCOM_CODE = (VCOM_RAW > 511) ? 511 :
	                               ((VCOM_RAW < 0) ? 0 : VCOM_RAW);
`endif

	// {register address, register data}. Six entries cover the larger TPS table.
	reg [15:0] pmic_config [0:5];
	initial begin
`ifdef PMIC_SY7636A
		pmic_config[0] = {8'h06, 8'hAA}; // 2 ms between power rails
		pmic_config[1] = {8'h03, 8'h66}; // VPOS/VNEG = +/-15.00 V
		pmic_config[2] = {8'h01, VCOM_CODE[7:0]};
		pmic_config[3] = {8'h02, {VCOM_CODE[8], 7'h14}};
		pmic_config[4] = {8'h00, 8'hC0}; // ON, external VCOM_EN, discharge enabled
		pmic_config[5] = 16'h0000;       // unused
`else
		pmic_config[0] = {8'h09, 8'hB1}; // UPSEQ0
		pmic_config[1] = {8'h0A, 8'h00}; // UPSEQ1
		pmic_config[2] = {8'h02, 8'h03}; // VADJ = +/-15 V
		pmic_config[3] = {8'h03, VCOM_CODE[7:0]};
		pmic_config[4] = {8'h04, {7'd0, VCOM_CODE[8]}};
		pmic_config[5] = {8'h01, 8'h3F}; // ENABLE
`endif
	end

	reg [5:0]  wr_index;
	reg [1:0]  wr_reg;
	reg [1:0]  rd_reg0;
	reg [2:0]  reg_addr;
	reg [7:0]  reg_data;
	reg [7:0]  sr_data0;
	reg [2:0]  config_cnt;
	reg [19:0] ready_cnt;

	always @(*) begin
		case (wr_index)
			6'd0:  begin reg_addr = PRERLO; reg_data = CLK_DIV_L; end
			6'd1:  begin reg_addr = PRERHI; reg_data = CLK_DIV_H; end
			6'd2:  begin reg_addr = CTR;    reg_data = EN_IP; end
			6'd3:  begin reg_addr = TXR;    reg_data = {DEV_ADDR, WR}; end
			6'd4:  begin reg_addr = CR;     reg_data = STA_WR_CR; end
			6'd5:  begin reg_addr = SR;     reg_data = 8'h00; end
			6'd6:  begin reg_addr = TXR;    reg_data = pmic_config[config_cnt][15:8]; end
			6'd7:  begin reg_addr = CR;     reg_data = WR_CR; end
			6'd8:  begin reg_addr = SR;     reg_data = 8'h00; end
			6'd9:  begin reg_addr = TXR;    reg_data = pmic_config[config_cnt][7:0]; end
			6'd10: begin reg_addr = CR;     reg_data = STP_WR_CR; end
			6'd11: begin reg_addr = SR;     reg_data = 8'h00; end
			default: begin reg_addr = 3'd0; reg_data = 8'h00; end
		endcase
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			I_TX_EN    <= 1'b0;
			I_WADDR    <= 3'd0;
			I_WDATA    <= 8'd0;
			I_RX_EN    <= 1'b0;
			I_RADDR    <= 3'd0;
			wr_index   <= 6'd0;
			wr_reg     <= 2'd0;
			rd_reg0    <= 2'd0;
			sr_data0   <= 8'd0;
			config_cnt <= 3'd0;
			ready_cnt  <= 20'd0;
			done_flag  <= 1'b0;
			error_flag <= 1'b0;
		end else begin
			if ((wr_index <= 6'd4) || (wr_index == 6'd6) ||
			    (wr_index == 6'd7) || (wr_index == 6'd9) ||
			    (wr_index == 6'd10)) begin
				case (wr_reg)
					2'd0: begin
						if (start || (wr_index != 6'd0)) begin
							I_TX_EN <= 1'b1;
							I_WADDR <= reg_addr;
							I_WDATA <= reg_data;
							wr_reg  <= 2'd1;
						end
					end
					2'd1: begin I_TX_EN <= 1'b0; wr_reg <= 2'd2; end
					default: begin wr_index <= wr_index + 6'd1; wr_reg <= 2'd0; end
				endcase
			end else if ((wr_index == 6'd5) || (wr_index == 6'd8) ||
			             (wr_index == 6'd11)) begin
				case (rd_reg0)
					2'd0: begin I_RX_EN <= 1'b1; I_RADDR <= SR; rd_reg0 <= 2'd1; end
					2'd1: begin I_RX_EN <= 1'b0; rd_reg0 <= 2'd2; end
					2'd2: begin sr_data0 <= O_RDATA; rd_reg0 <= 2'd3; end
					default: begin
						if (!sr_data0[1]) begin
							if (sr_data0[7]) begin
								error_flag <= 1'b1;
								done_flag  <= 1'b0;
								config_cnt <= 3'd0;
								wr_index   <= 6'd3;
								wr_reg     <= 2'd0;
								ready_cnt  <= 20'd0;
							end else if (wr_index == 6'd11) begin
								if (config_cnt == LAST_CONFIG) begin
									wr_index  <= 6'd12;
									ready_cnt <= 20'd0;
								end else begin
									config_cnt <= config_cnt + 3'd1;
									wr_index   <= 6'd3;
								end
							end else begin
								wr_index <= wr_index + 6'd1;
							end
							rd_reg0 <= 2'd0;
						end else begin
							rd_reg0 <= 2'd0;
						end
					end
				endcase
			end else if (wr_index == 6'd12) begin
`ifdef PMIC_SY7636A
				if (ready_cnt < READY_CYCLES)
					ready_cnt <= ready_cnt + 20'd1;
				else
					done_flag <= 1'b1;
`else
				done_flag <= 1'b1;
`endif
			end
		end
	end

	I2C_MASTER_Top u_i2c_ip (
		.I_CLK       (clk),
		.I_RESETN    (rst_n),
		.I_TX_EN     (I_TX_EN),
		.I_WADDR     (I_WADDR),
		.I_WDATA     (I_WDATA),
		.I_RX_EN     (I_RX_EN),
		.I_RADDR     (I_RADDR),
		.O_RDATA     (O_RDATA),
		.O_IIC_INT   (),
		.SCL         (pmic_scl),
		.SDA         (pmic_sda)
	);

endmodule
