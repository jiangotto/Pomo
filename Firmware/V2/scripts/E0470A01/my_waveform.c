/* Single translation unit for custom waveform LUT + MY_WAVEFORM table. */
#include "my_waveform.h"
#include "my_waveform_du.h"
#include "my_waveform_gc.h"
#include "my_waveform_gl.h"

static const EpdWaveformMode* my_waveform_modes[] = {
    &my_wm_du,
    &my_wm_gc,
    &my_wm_gl,
};

static const EpdWaveformTempInterval my_waveform_intervals[] = {
    { .min = 0, .max = 50 },
};

const EpdWaveform MY_WAVEFORM = {
    .num_modes = 3,
    .num_temp_ranges = 1,
    .mode_data = my_waveform_modes,
    .temp_intervals = my_waveform_intervals,
};
