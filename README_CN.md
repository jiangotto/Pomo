# Pomo

[English](README.md) | [简体中文](README_CN.md)

一款开源 FPGA 墨水屏控制板，可将双通道 MIPI DSI 视频转换为并口墨水屏所需的 Source/Gate 驱动时序。

## 项目简介

Pomo 接收 Linux 开发板或其他 MIPI DSI 主机输出的普通 RGB888 视频，并将其转换为并口墨水屏所需的波形像素状态和扫描信号。两个版本均使用高云 GW1NSR-4C FPGA 和 HyperRAM 帧缓存。

## 版本对比

Pomo 目前包含两套相互对应的硬件和固件版本：

| | V1 | V2 |
|---|---|---|
| 状态 | 初始版本，为已有板卡保留 | 当前版本，后续主要开发对象 |
| EPD Source 总线 | 8位，每个 SDCLK 传输4个2-bit像素 | 16位，每个 SDCLK 传输8个2-bit像素 |
| PMIC | TPS65185 | 默认 SY7636A，也可在固件中切换为 TPS65185 |
| 控制信号 | FPGA 控制 GDOE、SDOE、PMIC WAKEUP 和 VCOM 控制 | GDOE/SDOE及PMIC辅助控制由硬件处理，释放引脚连接D8–D15 |
| 工程路径 | `Firmware/V1`、`Hardware/V1`、`Case/V1` | `Firmware/V2`、`Hardware/V2`、`Case/V2` |

V1 和 V2 的 EPD 数据位宽、管脚分配和 PMIC 控制方式不同，位流不能互换。使用时应选择一个版本，并配套使用对应的固件、硬件和机械文件。

## V2

<div align="center">
  <img src="Assets/Assembly_V2.PNG" alt="Pomo V2 装配图" width="720">
</div>

V2 在一块电路板上集成了 FPGA、HyperRAM、墨水屏电源管理电路和16位并行 Source 接口。新制作的板卡建议从 V2 开始，下面的文档也将以 V2 为重点。

目前已经使用 Luckfox 和微雪开发板测试过 MIPI 输入。根据主机连接器的定义，可能需要使用反面 FPC 排线。

## V2 主要特性

- 双通道 MIPI DSI RGB888 视频输入
- 高云 MIPI 接收器使用双通道 1:16 模式
- 实时测量 MIPI Byte Clock，并动态选择 PLL 输出分频系数
- 使用 HyperRAM 保存当前和目标像素状态，可选12位状态紧凑存储
- 16位 EPD Source 数据总线，每个 SDCLK 装载8个2-bit驱动像素
- 在 FPGA 内生成并口墨水屏 Source 和 Gate 扫描时序
- 支持通过编译宏选择 SY7636A 或 TPS65185，V2 默认使用 SY7636A
- 支持 ET073TC1 一类面板所需的 `2W × H` 到 `W × 2H` 像素重排
- 内置静态和动态测试画面，可以替代外部 MIPI 视频源
- 支持蓝噪声抖动和多种波形/刷新模式
- 提供 MIPI FIFO、帧缓存和整帧异常诊断计数
- 加宽水平时序计数器，支持1216 × 684等高分辨率面板
- 通过 MIPI DSI 视频流内的通用短包在运行期间切换显示模式
- 支持运行时控制 PMIC，并在 MIPI PLL 失锁时对 EPD 输出进行安全钳位

当前1216 × 684配置已实际验证到85 Hz。该结果依赖较短且走线良好的 FPC，以及正确调节的 D-PHY 输入延迟；它不代表任意主机、排线或 PCB 都一定能够达到85 Hz。

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
  <img src="Assets/pinout_V2.jpg" alt="Pomo V2 JTAG 和 IO 排针定义" width="850">
</div>

排针提供3.3 V、VBUS、GND 和四根 JTAG 信号。连接下载器前，请根据 PCB 上的 Pin 1 标记确认方向。

## 显示示例

<div align="center">
  <img src="Assets/example_V2.jpg" alt="Pomo V2 驱动并口墨水屏" width="850">
</div>

<div align="center">
  <img src="Assets/example_V2_2.jpg" alt="Pomo V2 显示16级灰度测试图" width="850">
</div>

## 编译 V2 固件

1. 使用高云 Gowin EDA V1.9.12 打开 [`Firmware/V2/Pomo.gprj`](Firmware/V2/Pomo.gprj)。
2. 在 [`Firmware/V2/src/defines.vh`](Firmware/V2/src/defines.vh) 中配置 PMIC、面板时序、Source 位宽、波形模式和 VCOM 电压。
3. 确认两个生成的 MIPI IP 都使用双通道和相同的 **1:16** D-PHY 模式。仓库中的接收配置启用了 Byte/Lane Alignment，并将两个数据通道的输入延迟设为46；实际使用时应根据板卡和排线重新验证。
4. 依次运行 **Synthesis → Place & Route → Generate Bitstream**，并确认 Setup 和 Hold 时序都通过。
5. 通过 JTAG 排针烧录 FPGA。

工程使用高云生成的 MIPI D-PHY、协议解析、PLL、帧缓存和 FIFO 模块。`Firmware/V2/src` 下的 IP 配置及生成源码必须跟踪，因为在 GUI 中以不同设置重新生成 IP 会改变实际硬件行为。临时综合、仿真和实现输出不会提交到版本库。

## V2 固件配置

主要编译选项位于 [`Firmware/V2/src/defines.vh`](Firmware/V2/src/defines.vh)：

| 选项 | 作用 |
|---|---|
| `PMIC_SY7636A` | 定义时使用 SY7636A；注释后使用 TPS65185 |
| `EPD_OUTPUT_WIDTH` | 选择 EPD Source 输出位宽；V2 硬件使用16位 |
| `EPD_INTERNAL_TEST` | 使用内部视频发生器替代外部 MIPI 输入 |
| `EPD_TEST_PATTERN_MODE` | 选择内部静态或动态测试图案 |
| `EPD_TEST_PATTERN_FPS` | 设置内部测试视频源的帧率 |
| `EPD_PIXEL_REORDER` | 将逻辑 `2W × H` 视频转换成物理 `W × 2H` 面板排列 |
| `EPD_DEFAULT_MODE` | 选择上电默认模式：`8` MONO、`A` MONO + 蓝噪声、`B` GREY、`C` AUTO LUT |
| `EPD_STATE_12BIT` | 将4个12位像素状态紧凑存入3个16位 VFB 样本，相比每像素保存一个16位状态减少25%帧缓存流量 |
| `DEFAULT_*` | 设置期望的 MIPI 有效区、同步和前后肩时序 |
| `EPD_STV_TO_G1_CKV` | 设置从采样 STV 到 G1 选通前一次移位之间的面板 CKV 移位距离 |
| `VCOM_VOL` | 设置面板 VCOM，单位为毫伏；必须根据面板规格书确认 |
| `CLEAR_FRAMES` | 设置启动清屏序列最后一帧的零基序号 |
| `LUT_FRAMES` | 设置波形 LUT 长度 |

当前示例配置采用1216 × 684 MIPI 输入、16位 Source 输出、12位帧缓存状态紧凑存储、SY7636A、MONO 启动模式，并关闭像素重排；内部测试视频源帧率为85 Hz。这只是当前开发面板使用的示例，不是所有墨水屏都能直接使用的通用配置。

#### 为什么需要 `EPD_STATE_12BIT`

该选项只改变通过帧缓存保存的内部状态格式；它**不会**把 RGB888 MIPI 输入改成12位色，不会缩小 EPD 输出总线，也不会减少显示模式或灰阶数量。

处理链路原本为每个像素保存16位状态，其中高4位是显示模式，低12位才是该像素独立的状态。显示模式是全局量，对一帧中的所有像素都相同，因此为每个像素重复保存高4位会浪费 HyperRAM 带宽。启用 `EPD_STATE_12BIT` 后，Pomo 去掉重复的模式字段，将4个12位状态紧凑存入现有16位 VFB 的3个样本，并在读回时根据当前全局模式恢复高4位：

```text
原始存储：4像素 × 16位 = 64位
紧凑存储：4像素 × 12位 = 48位
```

这样会把帧缓存的读、写流量都从每像素2字节降低到1.5字节，即减少25%，从而为当前已经验证的85 Hz等高输入刷新率提供所需的 HyperRAM 带宽余量。

- 需要带宽优化时保持定义 `EPD_STATE_12BIT`。
- 需要对比、调试，或者画面宽度不兼容时，将该宏注释掉，即恢复原始的每像素一个16位状态。
- 帧缓存侧的有效宽度（可选像素重排后的 `EPD_HACT`）必须能被4整除，因为打包会在每一行重新开始，每组包含4个像素。当前宽度1216满足要求；启用 `EPD_PIXEL_REORDER` 后，应检查重排得到的物理宽度，而不能只检查 `DEFAULT_HACT`。
- 不需要24位 VFB IP；该优化有意继续使用已经验证稳定的16位 VFB 配置。

### MIPI 接收配置与信号完整性

两个生成的 MIPI IP 必须使用相互匹配的设置：

- **MIPI RX Advance：** 两个数据通道、1:16 D-PHY、启用 Byte Alignment 和 Lane Alignment。
- **MIPI DSI/CSI-2 Receiver：** DSI 接口、两个 RX Lane、1:16 D-PHY、关闭 I/O Insertion。

Lane 速率较高时，即使 RTL 和时序报告正确，采样眼图过窄仍可能表现为画面分裂、雪花或像素损坏。应尽量使用短 FPC，保证两条数据 Lane 匹配，并用可重复的测试图调节 `HS Data0/1 IO Delay Value`。当前值46只适用于已经测试的 Pomo/RK3506连接，不是墨水屏参数。当前 GW1NSR-4C 配置不能自动训练 IODELAY，因此更换主机、PCB 或排线后可能需要重新调节。

RGB888、1:16 D-PHY 模式下，设启用的数据 Lane 数为 `L`，时钟关系为：

```text
Pixel Clock     = H_TOTAL × V_TOTAL × 刷新率
1:16 Word Clock = Pixel Clock × 3 / (2 × L)
D-PHY Clock     = Pixel Clock × 12 / L
```

在 `defines.vh` 设置 `MIPI_RX_LANES`，并在 `Firmware/V2/Pomo.gprj` 中启用对应的 `Pomo_1lane.sdc` 或 `Pomo_2lane.sdc`。工程默认使用 2 Lane。改变分辨率或最高刷新率时，必须同步更新对应 SDC 的时钟约束，不能通过删除 HS、Word、Pixel 或 HyperRAM 约束来隐藏时序失败。4 Lane 的实现和已禁用的 SDC 暂时保留供后续开发，但不作为受支持的配置：目前上板验证未通过，而且资源占用已接近芯片上限。

### 运行时显示与电源控制

无需重新编译 FPGA，即可通过 MIPI DSI **Generic Short Write, 2 parameters**（`DT = 0x23`）切换显示模式或控制面板电源请求：

| Payload | 模式 |
|---|---|
| `50 08` | MONO |
| `50 0A` | MONO + 蓝噪声 |
| `50 0B` | GREY |
| `50 0C` | AUTO LUT |
| `51 00` | 钳位 EPD 接口并让 PMIC进入待机 |
| `51 01` | 请求面板重新上电，并重新执行初始化清屏 |
| `52 A5` | 不切断面板电源，重新执行初始化清屏，完成后返回当前请求的显示模式 |

这些短包必须使用 HS 发送，同时 DSI 控制器始终保持 Video Mode。不要把 DesignWare DSI Host 的 `MODE_CFG` 临时切到 Command Mode 再切回来：该操作会让视频打包器从任意水平相位重新启动，从而导致画面偏移。Linux 内核面板或 Bridge 驱动通常应通过 `mipi_dsi_generic_write()` 发送。如果使用直接操作寄存器的诊断工具，它必须保持 `MODE_CFG`、`VID_MODE_CFG` 和视频时序不变，只通过通用命令 FIFO 插入 HS 短包。

开机请求默认为开启，但正常 MIPI 固件只有在动态像素 PLL 已经 ready 且保持 lock 后才真正开启面板高压。收到 `51 00` 后，固件先把整套 EPD 接口钳位到无效电平，再让所选 PMIC进入待机：SY7636A 清除 `ON_OFF` 并保持 `EN` 为高，以便继续使用 I2C；TPS65185 则拉低 `PWRUP`。收到 `51 01` 后，Pomo 等待 PMIC 和 HyperRAM 稳定，回到 `INIT_IDLE`，并重新执行 `INIT_CLEARING` 后才恢复正常刷新。`EPD_INTERNAL_TEST` 不依赖 MIPI lock，PMIC由内部测试路径直接请求上电。

`52 A5` 不会关闭 PMIC，也不会复位 MIPI 接收器。它会让面板状态机回到 `INIT_IDLE`，在下一个完整帧边界开始 `INIT_CLEARING`，同时保留当前请求的显示模式。固定使用 `A5` 作为确认值，可降低其他短包被误识别为全屏清除命令的概率。

### 确定 MIPI 扫描时序

`DEFAULT_H*` 和 `DEFAULT_V*` 描述通过 MIPI DSI 接收到的视频时序，必须与主机实际生成的显示模式完全一致。这些参数不是从墨水屏 Gate Driver 的消隐要求中直接抄来的。

1. 打开 [Video Timings Calculator](https://tomverbeure.github.io/video_timings_calculator)。
2. 在 **Horizontal Pixels** 中输入逻辑 MIPI 图像宽度，在 **Vertical Pixels** 中输入逻辑图像高度，在 **Refresh Rate (Hz)** 中输入所需刷新率。除非主机有特殊要求，否则使用逐行扫描并关闭 Margins。
3. 在结果表中只使用 **CVT-RBv2** 一列的参数。不要混用 CVT、CVT-RB、CEA-861 或 DMT 列中的数值。
4. 按照下表将 CVT-RBv2 结果写入 `Firmware/V2/src/defines.vh`：

| CVT-RBv2 结果 | Pomo 配置 | 单位 |
|---|---|---|
| H Active | `DEFAULT_HACT` | 像素 |
| H Front Porch | `DEFAULT_HFP` | 像素 |
| H Sync | `DEFAULT_HSYNC` | 像素 |
| H Back Porch | `DEFAULT_HBP` | 像素 |
| V Active | `DEFAULT_VACT` | 行 |
| V Front Porch | `DEFAULT_VFP` | 行 |
| V Sync | `DEFAULT_VSYNC` | 行 |
| V Back Porch | `DEFAULT_VBP` | 行 |
| Pixel Clock | 主机显示时序 | MHz；主机需要时换算为 Hz |

5. 在 Linux MIPI DSI 面板或显示模式中填写完全相同的有效区、前后肩、同步宽度和像素时钟。典型的设备树时序块如下；外层节点以及同步极性属性取决于具体主机显示驱动：

```dts
display-timings {
    native-mode = <&timing0>;

    timing0: timing0 {
        clock-frequency = <PIXEL_CLOCK_HZ>;
        hactive = <H_ACTIVE>;
        hfront-porch = <H_FRONT_PORCH>;
        hsync-len = <H_SYNC>;
        hback-porch = <H_BACK_PORCH>;
        vactive = <V_ACTIVE>;
        vfront-porch = <V_FRONT_PORCH>;
        vsync-len = <V_SYNC>;
        vback-porch = <V_BACK_PORCH>;
    };
};
```

6. 编译前检查抄入的参数：

```text
H_TOTAL = DEFAULT_HACT + DEFAULT_HFP + DEFAULT_HSYNC + DEFAULT_HBP
V_TOTAL = DEFAULT_VACT + DEFAULT_VFP + DEFAULT_VSYNC + DEFAULT_VBP
刷新率 = 像素时钟 / (H_TOTAL × V_TOTAL)
```

除正常的取整误差外，算出的刷新率应当与输入目标一致。每次改变分辨率或刷新率时，都应重新生成一整套 CVT-RBv2 模式，并同时更新主机和 Pomo；只改变像素时钟或单独修改某个 porch，可能导致 FPGA 重建的 MIPI 扫描位置与实际数据包不一致。

`EPD_STV_TO_G1_CKV` 不属于 CVT-RBv2 视频时序。它表示从 Gate Driver 采样 STV 到 G1 选通前一次移位之间的面板 CKV 移位数，应从面板或 Gate Driver 时序规格中获得，不能根据 MIPI 的 `VFP`、`VSYNC` 或 `VBP` 推导。

启用 `EPD_PIXEL_REORDER` 时，计算器和 `DEFAULT_HACT`/`DEFAULT_VACT` 中应填写主机看到的逻辑 MIPI 分辨率。物理墨水屏分辨率由重排逻辑生成，不能作为计算器输入。

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

驱动并口墨水屏必须使用正确的波形 LUT、VCOM、电源时序和输出使能逻辑。分辨率不匹配或异常的视频流可能将错误数据移入有效区域之外的 Source 驱动。MIPI FIFO、帧缓存和整帧故障信号目前用于诊断，不能单独保证任意异常输入都是安全的。

来自 MIPI 的像素时钟可能突然停止，使同步扫描状态机没有机会执行下一个时钟沿。因此，当原始像素 PLL `LOCK` 丢失、收到关机指令，或者 PMIC/HyperRAM 尚未 ready 时，Pomo 会通过一个不依赖像素时钟的统一输出门立即把物理接口钳位为：

```text
GDCLK=0, GDSP=1, SDCLK=0, SDLE=0, SDCE=1, DATA=0
```

只有钳位生效后，PMIC才进入待机并对高压电源轨放电。恢复时钳位会一直保持，直到电源和存储器稳定；随后视频域复位保证下一帧从初始化清屏流程重新开始。

**不要首先使用有价值的屏幕验证 MIPI 突然断开。** 应在不连接屏幕的情况下使用示波器，确认当前生成的位流在 MIPI 时钟消失时立即将上述六组信号置为安全电平，并且发生在 `VPOS`、`VNEG` 和 `VCOM` 开始放电之前。该保护依赖高云 PLL 在输入时钟消失时确实撤销 `LOCK`。如果主机停止视频数据包但仍保持 DSI Clock Lane运行，PLL失锁保护无法识别这种情况；计划停止这类视频源前应先发送 `51 00`。

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
