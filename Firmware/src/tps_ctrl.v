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

module tps_ctrl #(
	parameter integer vcom_val = 1310
) (
	input  wire        clk,       // 27MHz
	input  wire        rst_n,     // 系统复位
	
	// --- 物理接口 (直接连到芯片引脚) ---
	output wire        tps_wakeup,    
	output reg         tps_pwrup,     
	output wire        tps_vcom_ctrl, 
	inout  wire        tps_sda,       
	inout  wire        tps_scl,       
	
	// --- 状态输出 ---
	output reg         done_flag,     // 配置完成 (内部已连接到 tps_pwrup)
	output reg         error_flag
);

	//================================================================
	// 1. 静态信号与延时控制
	//================================================================
	// Step 1: 上电即拉高 Wakeup和Vcom Ctrl
	assign tps_wakeup = 1'b1;
	assign tps_vcom_ctrl = 1'b1;

	// Step 2: 延时 10ms 后产生启动信号
	reg [19:0] dly_cnt;
	reg        start; // 内部启动信号
	
	always @(posedge clk or negedge rst_n) begin
		if(!rst_n) begin 
			dly_cnt <= 0; 
			start <= 0; 
		end else begin
			if(dly_cnt < 20'd270000) begin
				dly_cnt <= dly_cnt + 1;
			end else begin
				start <= 1; // 延时结束，触发状态机
			end
		end
	end

	//================================================================
	// 2. 内部互联信号 (原 output 接口转为内部信号)
	//================================================================
	reg         I_TX_EN;
	reg  [2:0]  I_WADDR;
	reg  [7:0]  I_WDATA;
	reg         I_RX_EN;
	reg  [2:0]  I_RADDR;
	wire [7:0]  O_RDATA; // 来自 IP 的输出

	//===========================================================================
	// 3. IP 核寄存器地址 (保持不变)
	//===========================================================================
	localparam PRERLO = 3'b000;
	localparam PRERHI = 3'b001;
	localparam CTR    = 3'b010;
	localparam TXR    = 3'b011;
	localparam RXR    = 3'b011;
	localparam CR     = 3'b100;
	localparam SR     = 3'b100;

	//===========================================================================
	// 4. 参数配置
	//===========================================================================
	// 27MHz 分频计算: 27M / (5 * 100k) - 1 = 53 = 0x35
	localparam CLK_Div_L = 8'h35; 
	localparam CLK_Div_H = 8'h00;
	localparam EN_IP     = 8'h80; // Core Enable

	// 命令码
	localparam STA_WR_CR = 8'h90; // Start + Write
	localparam WR_CR     = 8'h10; // Write
	localparam STP_WR_CR = 8'h50; // Stop + Write
	
	localparam WR        = 1'b0;
	localparam DEV_ADDR  = 7'b1101_000; // TPS65185 (0x68)

	//===========================================================================
	// 5. 配置数据表
	//===========================================================================
	// 格式: {RegAddr, Data}
	localparam integer calc_reg = vcom_val / 10;
	reg [15:0] tps_config [0:5];
	initial begin
		tps_config[0] = {8'h09, 8'hB1}; // UPSEQ0: Power Seq
		tps_config[1] = {8'h0A, 8'h00}; // UPSEQ1: Delay
		tps_config[2] = {8'h02, 8'h03}; // VADJ: +/-15V
		tps_config[3] = {8'h03, calc_reg[7:0]}; // VCOM1: -1.31V
		tps_config[4] = {8'h04, {7'd0, calc_reg[8]}}; // VCOM2: 0
		tps_config[5] = {8'h01, 8'h3F}; // ENABLE: Active
	end

	//===========================================================================
	// 6. 状态机逻辑 (原逻辑保持不变，信号名对应即可)
	//===========================================================================
	reg [5:0] wr_index; 
	reg [1:0] wr_reg;   
	reg [1:0] rd_reg0;  
	reg [2:0] reg_addr; 
	reg [7:0] reg_data;
	reg [7:0] sr_data0;
	reg [3:0] config_cnt; 

	// 组合逻辑部分
	always @(*) begin
		case(wr_index)
			// --- 初始化 IP ---
			0: begin reg_addr <= PRERLO; reg_data <= CLK_Div_L; end
			1: begin reg_addr <= PRERHI; reg_data <= CLK_Div_H; end
			2: begin reg_addr <= CTR;    reg_data <= EN_IP;     end
			
			// --- 发送 TPS 配置 (循环体) ---
			// Step 1: Start + Device Address
			3: begin reg_addr <= TXR;    reg_data <= {DEV_ADDR, WR}; end
			4: begin reg_addr <= CR;     reg_data <= STA_WR_CR;      end
			5: begin reg_addr <= SR;     reg_data <= 8'h00;          end 

			// Step 2: Register Address
			6: begin reg_addr <= TXR;    reg_data <= tps_config[config_cnt][15:8]; end
			7: begin reg_addr <= CR;     reg_data <= WR_CR;          end
			8: begin reg_addr <= SR;     reg_data <= 8'h00;          end 

			// Step 3: Register Data + Stop
			9: begin reg_addr <= TXR;    reg_data <= tps_config[config_cnt][7:0]; end
			10:begin reg_addr <= CR;     reg_data <= STP_WR_CR;      end
			11:begin reg_addr <= SR;     reg_data <= 8'h00;          end 

			default: begin reg_addr <= 0; reg_data <= 0; end
		endcase
	end

	// 时序逻辑部分
	always @(posedge clk or negedge rst_n) begin
		if(!rst_n) begin
			I_TX_EN <= 0; I_WADDR <= 0; I_WDATA <= 0;
			I_RX_EN <= 0; I_RADDR <= 0;
			wr_index <= 0; wr_reg <= 0; rd_reg0 <= 0;
			done_flag <= 0; error_flag <= 0;
			config_cnt <= 0;
		end else begin
			// 等待内部 start 信号
			if(start && wr_index == 0 && wr_reg == 0) begin
				// 开始运行
			end else if (!start && wr_index == 0) begin
				// 保持 IDLE
			end 

			// --- 写操作 ---
			if((wr_index <= 2) || (wr_index==3) || (wr_index==4) || 
			   (wr_index==6) || (wr_index==7) || 
			   (wr_index==9) || (wr_index==10)) 
			begin
				case(wr_reg)
					0: begin 
						if(start || wr_index > 0) begin 
							I_TX_EN <= 1; I_WADDR <= reg_addr; I_WDATA <= reg_data; 
							wr_reg <= 1; 
						end
					end
					1: begin I_TX_EN <= 0; wr_reg <= 2; end
					2: begin wr_index <= wr_index + 1; wr_reg <= 0; end
				endcase
			end
			
			// --- 读状态/等待 ---
			else if((wr_index==5) || (wr_index==8) || (wr_index==11)) 
			begin
				case(rd_reg0)
					0: begin I_RX_EN <= 1; I_RADDR <= SR; rd_reg0 <= 1; end
					1: begin I_RX_EN <= 0; rd_reg0 <= 2; end
					2: begin sr_data0 <= O_RDATA; rd_reg0 <= 3; end
//                    3: begin
//                         检查 TIP (Bit 1)
//                        if(~sr_data0[1]) begin
//                            if(sr_data0[7]) error_flag <= 1; 

//                            if(wr_index == 11) begin // 一条指令发完
//                                if(config_cnt == 5) begin // 全部 6 条发完
//                                    done_flag <= 1;
//                                    wr_index <= 12; // 结束
//                                end else begin
//                                    config_cnt <= config_cnt + 1;
//                                    wr_index <= 3; // 回到 Start 发下一条
//                                end
//                            end else begin
//                                wr_index <= wr_index + 1;
//                            end
//                            rd_reg0 <= 0;
//                        end else begin
//                            rd_reg0 <= 0; // 继续等
//                        end
//                    end
					3: begin
						// 检查 TIP (Bit 1): 0 表示当前 I2C 命令完成
						if(~sr_data0[1]) begin

							// 检查 RxACK (Bit 7): 1 表示 NACK
							if(sr_data0[7]) begin
								// NACK：标记错误，但不要停止，重新开始发送 I2C
								error_flag <= 1'b1;
								done_flag  <= 1'b0;

								config_cnt <= 4'd0;    // 从第一条 TPS 配置重新开始
								wr_index   <= 6'd3;    // 回到发送 Device Address
								wr_reg     <= 2'd0;
								rd_reg0    <= 2'd0;
							end else begin
								// ACK 正常，继续执行
								if(wr_index == 11) begin
									// 一条寄存器写入完成
									if(config_cnt == 5) begin
										// 全部 6 条配置完成
										done_flag <= 1'b1;
										wr_index  <= 6'd12;
									end else begin
										config_cnt <= config_cnt + 1'b1;
										wr_index   <= 6'd3;   // 回到 Start，发下一条配置
									end
								end else begin
									wr_index <= wr_index + 1'b1;
								end

								rd_reg0 <= 2'd0;
							end

						end else begin
							// TIP 仍为 1，说明 I2C IP 还忙，继续轮询 SR
							rd_reg0 <= 2'd0;
						end
					end
				endcase
			end
			
			// --- 结束 ---
			else if(wr_index == 12) begin
				// Stay Done
			end
		end
	end

	//================================================================
	// 7. 实例化 I2C IP 核 (内部集成)
	//================================================================
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
		.SCL         (tps_scl),   // 连接外部物理引脚
		.SDA         (tps_sda)    // 连接外部物理引脚
	);

	//================================================================
	// 8. 输出控制
	//================================================================
	// Step 3: 配置完成后，拉高 PWRUP
	always @(posedge clk or negedge rst_n) begin
		if(!rst_n) tps_pwrup <= 0;
		else tps_pwrup <= done_flag; 
	end

endmodule