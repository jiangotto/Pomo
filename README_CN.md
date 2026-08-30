# Pomo DriverBoard V2

[English](README.md) | [简体中文](README_CN.md)

一款开源 FPGA 墨水屏控制板，可将双通道 MIPI DSI 视频转换为裸墨水屏所需的 Source/Gate 驱动时序。

<div align="center">
  <img src="Assets/Assembly_V2.PNG" alt="Pomo DriverBoard V2 装配图" width="720">
</div>

## 项目简介

Pomo V2 是当前主要维护的硬件和固件版本。它在一块电路板上集成了高云 GW1NSR-4C FPGA、HyperRAM 帧缓存、墨水屏电源管理电路以及16位并行 Source 接口。Linux 开发板或其他 MIPI DSI 主机只需输出普通 RGB888 视频，FPGA 会将其转换为墨水屏需要的波形像素状态和面板扫描时序。

目前已经使用 Luckfox 和微雪开发板测试过 MIPI 输入。根据主机连接器的定义，可能需要使用同面或反面 FPC 排线。

仓库中仍然保留最初的8位 V1 设计，但后续开发以 V2 为主。

## V2 主要特性

- 双通道 MIPI DSI RGB888 视频输入
- 实时测量 MIPI Byte Clock，并动态选择 PLL 输出分频系数
- 使用 HyperRAM 保存当前和目标像素状态
- 16位 EPD Source 数据总线，每个 SDCLK 装载8个2-bit驱动像素
- 在 FPGA 内生成裸墨水屏 Source 和 Gate 扫描时序
- 支持通过编译宏选择 SY7636A 或 TPS65185，V2 默认使用 SY7636A
- 支持 ET073TC1 一类面板所需的 `2W × H` 到 `W × 2H` 像素重排
- 内置静态和动态测试画面，可以替代外部 MIPI 视频源
- 支持蓝噪声抖动和多种波形/刷新模式
- 检测 MIPI FIFO、帧缓存和整帧异常，并在故障帧中安全关闭 EPD 输出
- 加宽水平时序计数器，支持1216 × 684等高分辨率面板

## 数据链路

```text
双通道 MIPI DSI
       │
       ▼
高云 D-PHY RX ──► DSI 数据包解析 ──► RGB888 Byte-to-Pixel 转换
                                            │
                         可选像素重排 / 内部测试视频源
                                            │
                                            ▼
                              灰度转换 + 抖动 + 波形处理
                                            │
                                            ▼
                                      HyperRAM 帧缓存
                                            │
                                            ▼
                         16位 Source 时序 + Gate 时序 ──► 墨水屏
```

本项目固件基于 Wenting Zhang 的 [Caster EPDC 设计](https://gitlab.com/zephray/Glider)。原始设计运行在 Xilinx Spartan-6 上，本项目将其移植到高云 FPGA，并增加了 HyperRAM 帧缓存、MIPI 输入和独立墨水屏驱动能力。

## 硬件

V2 提供16位 EPD 数据总线，以及 `SDCLK`、`SDLE`、`SDCE`、`GDCLK` 和 `GDSP`。V2 硬件通过上拉处理 `GDOE` 和 `SDOE`，不再占用 FPGA 引脚。PMIC WAKEUP/VCOM 控制同样由 V2 硬件处理，从而腾出 FPGA 引脚连接 `EPD_D8` 到 `EPD_D15`。

Altium 原理图、原理图 PDF、PCB、BOM 和贴片坐标文件位于 [`Hardware/V2`](Hardware/V2)。V1 和 V2 的 EPD 数据位宽、管脚分配及 PMIC 控制方式不同，不能混用两版固件。

### JTAG / IO 排针

<div align="center">
  <img src="Assets/pinout_V2.jpg" alt="Pomo DriverBoard V2 JTAG 和 IO 排针定义" width="850">
</div>

排针提供3.3 V、VBUS、GND 和四根 JTAG 信号。连接下载器前，请根据 PCB 上的 Pin 1 标记确认方向。

## 显示示例

<div align="center">
  <img src="Assets/example_V2.jpg" alt="Pomo DriverBoard V2 驱动墨水屏" width="850">
</div>

## 编译 V2 固件

1. 使用高云 Gowin EDA V1.9.12 打开 [`Firmware/V2/Pomo.gprj`](Firmware/V2/Pomo.gprj)。
2. 在 [`Firmware/V2/src/defines.vh`](Firmware/V2/src/defines.vh) 中配置 PMIC、面板时序、Source 位宽、波形模式和 VCOM 电压。
3. 依次运行 **Synthesis → Place & Route → Generate Bitstream**。
4. 通过 JTAG 排针烧录 FPGA。

工程使用高云生成的 MIPI D-PHY 和异步 FIFO 模块。`impl/` 下的综合、布局布线和位流输出不会提交到版本库。

## V2 固件配置

主要编译选项位于 [`Firmware/V2/src/defines.vh`](Firmware/V2/src/defines.vh)：

| 选项 | 作用 |
|---|---|
| `PMIC_SY7636A` | 定义时使用 SY7636A；注释后使用 TPS65185 |
| `EPD_OUTPUT_WIDTH` | 选择 EPD Source 输出位宽；V2 硬件使用16位 |
| `EPD_INTERNAL_TEST` | 使用内部视频发生器替代外部 MIPI 输入 |
| `EPD_TEST_PATTERN_MODE` | 选择内部静态或动态测试图案 |
| `EPD_PIXEL_REORDER` | 将逻辑 `2W × H` 视频转换成物理 `W × 2H` 面板排列 |
| `DEFAULT_*` | 设置期望的 MIPI 有效区、同步和前后肩时序 |
| `DEFAULT_FPS` | 设置 EPD 控制逻辑采用的输入帧率 |
| `VCOM_VOL` | 设置面板 VCOM，单位为毫伏；必须根据面板规格书确认 |
| `CLEAR_FRAMES` | 设置启动清屏序列最后一帧的零基序号 |
| `LUT_FRAMES` | 设置波形 LUT 长度 |

当前示例配置为1216 × 684、85 Hz、16位 Source 输出、SY7636A、FAST MONO 启动模式，并关闭像素重排。这只是当前开发面板使用的示例，不是所有墨水屏都能直接使用的通用配置。

### 像素重排

部分长条形墨水屏的物理像素排列与主机看到的视频分辨率不同。启用 `EPD_PIXEL_REORDER` 后，Pomo 使用以下映射：

```text
physical(x, 2y)     = logical(2x,     y)
physical(x, 2y + 1) = logical(2x + 1, y)
```

例如，750 × 200 的 MIPI 图像会转换为375 × 400的物理墨水屏图像。重排模式要求输入宽度为偶数、输入水平总周期为偶数，并且 VFP 至少为一行。当重排后的 Source 行不能填满最后一个输出字时，固件会自动进行水平补齐。

### 内部测试视频源

定义 `EPD_INTERNAL_TEST` 后，无需运行 MIPI 视频源即可测试屏幕。生成的画面仍会经过正常的像素重排、抖动、波形处理、帧缓存和 EPD 时序链路。测试模式包括灰阶、色条、棋盘格和移动区域，可用于检查16级灰度和动态刷新效果。

### 面板安全

驱动裸墨水屏必须使用正确的波形 LUT、VCOM、电源时序和输出使能逻辑。分辨率不匹配或异常的视频流可能将错误数据移入有效区域之外的 Source 驱动。V2 会检测 MIPI FIFO 溢出和帧缓存异常，并在故障帧中关闭 Source/Gate 活动，但这些保护不能替代对面板规格书和驱动时序的核对。

## 仓库结构

```text
Pomo_DriverBoard/
├── Firmware/
│   ├── V2/                    当前16位高云固件
│   └── V1/                    原始8位固件归档
├── Hardware/
│   ├── V2/                    当前 Altium 工程和生产文件
│   └── V1/                    原始硬件归档
├── Case/
│   ├── V2/                    当前外壳和模型文件
│   └── V1/                    原始外壳和模型归档
├── Assets/                    README 图片
└── LICENSE                    CERN-OHL-S v2
```

## V1 兼容说明

V1 保存在 [`Firmware/V1`](Firmware/V1)、[`Hardware/V1`](Hardware/V1) 和 [`Case/V1`](Case/V1) 中。为原始8位硬件编译固件时，请打开 `Firmware/V1/Pomo.gprj`。V1 和 V2 位流不能互换。

## 许可证

Pomo 硬件和固件采用 **CERN Open Hardware Licence Version 2 – Strongly Reciprocal（CERN-OHL-S v2）**，详见 [LICENSE](LICENSE)。

来自 Caster 的部分仍采用 CERN-OHL-P v2，详见 [`Firmware/V2/LICENSE-CERN-OHL-P`](Firmware/V2/LICENSE-CERN-OHL-P)。

## 致谢

- [Wenting Zhang](https://gitlab.com/zephray) — Caster EPDC 原始设计
- [CERN](https://cern.ch/cern-ohl) — CERN 开放硬件许可证
