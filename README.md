# Pomo

FPGA-based EPD (e-ink display) driver board.

<div align="center">
  <img src="Assets/Assembly.PNG" alt="Pomo assembly" width="600">
</div>

## Overview

Pomo is an open-source hardware project that drives E-Ink panels via MIPI DSI input. It uses a Gowin GW1NSR-4C FPGA and HyperRAM framebuffer. The MIPI input has been tested with **Luckfox** and **Waveshare** development boards, connected via a reverse FPC cable.

The firmware is based on the [Caster](https://gitlab.com/zephray/Glider) EPDC design by Wenting Zhang, ported to the Gowin platform. The original Caster RTL was written for Xilinx Spartan-6 — key changes include replacing Xilinx IP cores (PLL, BRAM, FIFO) with Gowin equivalents, simplifying the pixel processing pipeline for standalone use without a CSR interface, and adding HyperRAM-based framebuffer support.

## Pinout

<div align="center">
  <img src="Assets/pinout.jpg" alt="PCB 12-pin header pinout" width="500">
</div>

## Example

<div align="center">
  <img src="Assets/example.jpg" alt="Pomo driving an EPD panel" width="500">
</div>

## Project Structure

```
Pomo_DriverBoard/
├── Firmware/
│   ├── src/                   Verilog source
│   ├── waveform/              EPD waveform LUT files (.mi)
│   ├── noise/                 Blue noise texture data
│   ├── scripts/               Panel config headers and waveform conversion tools
│   ├── Pomo.gprj              Gowin EDA project file
│   └── LICENSE-CERN-OHL-P     Original Caster license (upstream)
├── Hardware/                  Schematic (Altium .SchDoc) and PCB (.PcbDoc)
├── Case/                      Enclosure CAD files (SolidWorks / STEP)
├── Assets/                    Images
└── LICENSE                    CERN-OHL-S v2
```

## Building the Firmware

Open `Firmware/Pomo.gprj` in Gowin EDA (V1.9.12). Run Synthesis → Place & Route → Generate Bitstream.

## Adapting for Your Panel

Edit `src/defines.vh`:

| Parameter | Description |
|-----------|-------------|
| `DEFAULT_VFP`, `DEFAULT_VSYNC`, `DEFAULT_VBP`, `DEFAULT_VACT` | Vertical timing |
| `DEFAULT_HFP`, `DEFAULT_HSYNC`, `DEFAULT_HBP`, `DEFAULT_HACT` | Horizontal timing |
| `VCOM_VOL` | VCOM voltage (check panel datasheet) |
| `CLEAR_FRAMES` | Clear sequence frame count on init |
| `LUT_FRAMES` | Number of frames in the waveform LUT |

Select the waveform `.mi` file that matches your panel in the project settings. Panel configuration headers and waveform conversion scripts are in `Firmware/scripts/`.

## Future Work

- Support different MIPI lane counts (currently 2-lane)
- Support additional EPD panels
- Add non-MIPI input interfaces (e.g. SPI), using the 4 spare I/O pins on the board

## License

Hardware and Firmware are licensed under the **CERN Open Hardware Licence Version 2 - Strongly Reciprocal (CERN-OHL-S v2)**. See [LICENSE](LICENSE).

Portions of the firmware are derived from the Caster project, originally released under CERN-OHL-P v2. See [LICENSE-CERN-OHL-P](Firmware/LICENSE-CERN-OHL-P).

## Acknowledgments

- [Wenting Zhang](https://gitlab.com/zephray) — Original Caster EPDC design
- [CERN](https://cern.ch/cern-ohl) — CERN Open Hardware Licence
