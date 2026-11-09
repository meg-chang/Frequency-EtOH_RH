// ============================================================================
// freq_meter_gclk_pkg.sv —— 验证环境包
// ----------------------------------------------------------------------------
// 按依赖顺序 include 各组件文件（freq_result / freq_item 必须最先，因被引用）。
// ============================================================================
`timescale 1ns/1ps

package freq_meter_gclk_pkg;
    import uvm_pkg::*;

    `include "freq_result.sv"
    `include "freq_item.sv"
    `include "freq_driver.sv"
    `include "freq_monitor.sv"
    `include "freq_scoreboard.sv"
    `include "freq_coverage.sv"
    `include "freq_agent.sv"
    `include "freq_env.sv"
    `include "freq_seq.sv"
    `include "freq_test.sv"

endpackage
