# alcohol_humidity_uvm —— 酒精/湿度检测 频率计 UVM 验证工程

> 对齐真实集创赛工程「酒精湿度检测系统」的核心测频模块 `freq_meter_gclk`，  
> 用 **SystemVerilog/UVM** 搭一套可复用的验证环境；同时保留一套  
> **本地 iverilog 纯 Verilog 基线**，在没有 VCS 的机器上先确认 DUT 行为正确。

## 关于本工程的说明

本工程的 RTL 与验证环境在 **AI 辅助下完成**。本人负责：
架构理解与设计意图梳理、本地 iverilog 仿真验证与回归、
CDC 缺陷的现象定位与根因分析、验证报告撰写。

工程中所有「本地实跑」结论均可用仓库内命令复现（见 §3、§4）；
UVM 环境的实跑状态见 §6 已知限制，请以该节为准。

---

## 1. 工程定位

真实系统测频思路（分频式频率计）：

```
SAW 433.92MHz ×3 → 片外 ÷4 → 108.48MHz
   → 专用时钟引脚 → 全局时钟网络(GCLK) → 直驱计数器
   50MHz 系统时钟产生 100ms 门控窗口（10Hz）
   门控窗口跨域送进被测域 → 统计窗口内被测上升沿 → 分辨率 40Hz
```

与旧版「系统时钟采样法」（÷256 → 1.69MHz、分辨率 2560Hz）相比，  
GCLK 直驱法把分频比降到 ÷4，分辨率提升 **64 倍**，且被测频率只受  
GCLK 上限（EP4CE10-C8：402MHz）约束，不再受「系统时钟 ≥ 2.5×被测」限制。

本工程**只针对最核心、最易出 CDC 问题的单模块 `freq_meter_gclk`**  
搭建 UVM 环境（端到端 `top_system` 含 UART 回读留作后续扩展）。

---

## 2. 目录结构

```
alcohol_humidity_uvm/
├── Makefile                       # iverilog 基线 + VCS/UVM 入口
├── README.md
├── rtl/                           # 真实集创赛 RTL（14 个模块）
│   ├── freq_meter_gclk.v          # ★ 被测 DUT（GCLK 直驱测频 + CDC）
│   ├── gate_timer.v               # 50MHz 域 100ms/10Hz 门控产生
│   ├── async_fifo.v  bin2gray.v  gray2bin.v  sync_two_stage.v
│   ├── filter_ma.v  freq_restore.v  calib_lut.v  tx_packer.v
│   ├── uart_tx.v  write_arbiter.v  freq_meter.v  top_system.v
├── tb/
│   └── tb_freq_meter_gclk_real.v  # 本地 iverilog 基线（已 PASS）
├── uvm/                           # UVM 验证环境（13 个文件）
│   ├── freq_meter_gclk_if.sv      # 接口（clk_sig 可配周期 / gate_en / count）
│   ├── freq_result.sv             # 结果事务（monitor→scoreboard）
│   ├── freq_item.sv               # 激励事务（sig_freq_mhz × gate_ticks）
│   ├── freq_driver.sv             # 驱动器（设周期 + 驱动 gate_en + 广播）
│   ├── freq_monitor.sv            # 监测器（采 count_valid 上升沿）
│   ├── freq_scoreboard.sv         # 记分板 + 黄金参考模型
│   ├── freq_coverage.sv           # 覆盖率（频率×门控 交叉）
│   ├── freq_agent.sv  freq_env.sv
│   ├── freq_seq.sv  freq_test.sv
│   ├── freq_meter_gclk_pkg.sv     # 组件包（include 顺序）
│   ├── freq_meter_gclk_top.sv     # UVM 顶层（实例化真实 DUT + run_test）
│   └── filelist.f
└── doc/
    ├── 原工程README.md            # 真实集创赛工程说明（含 CDC 论证）
    └── 原工程Makefile
```

---

## 3. 本地 iverilog 基线（无需 VCS）

`tb/tb_freq_meter_gclk_real.v` 实例化**真实** `freq_meter_gclk` + `gate_timer`，  
独立统计「gate_en 高期间 clk_sig 上升沿数」作为参考，与 DUT 输出比对。

```bash
make iverilog
# 或手动：
iverilog -g2005 -o sim/tb.out tb/tb_freq_meter_gclk_real.v \
         rtl/freq_meter_gclk.v rtl/gate_timer.v
vvp sim/tb.out
```

**预期结果：`PASS (0 errors)`**（已验证）。

关键结论（实测日志佐证）：DUT 的 `count` 恒比「窗口内沿数(参考 N)」少 1  
（例：count=1071 vs gate内沿数=1072），这是 DUT 在 gate_s2 上升沿清零、  
其后才累加的必然结果，属设计预期，非 bug。

覆盖用例：4 个频率扫描（37/50/101/18.5ns）+ count_valid 单拍检查 +  
复位清零 + 6bit 饱和度实例封顶 63 不回绕。容差 ±3 覆盖 CDC 同步延迟。

---

## 4. VCS + UVM 环境（需在 RHEL8 EDA 服务器运行）

本地无 VCS，UVM 环境**代码范式已校验、但未实跑**；在装好 VCS 的机器上：

```bash
# 编译 + 跑随机测试（默认 freq_random_test）
make sim

# 跑定向测试（4 频率 × 3 门控）
make sim TEST=freq_directed_test
```

`make sim` 等价于：

```bash
vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -f uvm/filelist.f -o sim/simv_uvm
./sim/simv_uvm +UVM_TESTNAME=freq_random_test +UVM_VERBOSITY=UVM_MEDIUM -l sim/uvm.log
```

### 4.1 组件树

```
freq_random_test / freq_directed_test
└── freq_env
    ├── freq_agent
    │   ├── freq_sequencer
    │   ├── freq_driver   ──ap──> freq_coverage   (激励广播)
    │   └── freq_monitor  ──ap──> freq_scoreboard (结果比对)
    ├── freq_scoreboard  (黄金参考：窗口内 clk_sig 上升沿计数)
    └── freq_coverage    (频率 low/mid/high × 门控 small/med/large 交叉)
```

### 4.2 黄金参考模型（scoreboard）

在 `clk_sig` 域统计 `gate_en` 高电平期间的上升沿数 = N；  
DUT 在 gate_s2 上升沿清零、其后累加 → `count ≈ N-1`。  
比对容差 **±3**，覆盖：

- `gate_en` 异步进入 `clk_sig` 域采样的 ±1 拍抖动；
- 两级同步（gate_s1→gate_s2）引入的 ±1~2 拍偏移。

report_phase 打印：`==== SCOREBOARD PASS=%0d FAIL=%0d ====`  
**预期 PASS 远大于 0、FAIL=0。**

### 4.3 测试计划

| 测试                 | 内容                                                |
| ------------------ | ------------------------------------------------- |
| freq_random_test   | 50 笔随机：sig_freq 10~~110MHz × gate_ticks 200~~5000 |
| freq_directed_test | 4 频率{20,50,80,108}MHz × 3 门控{500,1000,3000}       |

---

## 5. CDC 正确性论证

`freq_meter_gclk` 的全部跨域点：

| 信号      | 方向      | 处理方法                               |
| ------- | ------- | ---------------------------------- |
| gate_en | 系统域→被测域 | 电平信号，两级同步（gate_s1/s2）              |
| done    | 被测域→系统域 | 脉冲，两级同步 + 上升沿检测                    |
| cnt_out | 被测域→系统域 | 准静态（更新率 10Hz ≪ 50MHz），两级同步即可，无需格雷码 |

**为什么 cnt_out 不用格雷码**：它是窗口结束时的锁存值，两次更新间隔  
5,000,000 个系统时钟周期，远大于同步建立所需几拍，不存在「采样到跳变中间态」。

**★ 硬约束**：门控**低电平**持续时间必须 > 2×被测时钟周期，  
否则被测域同步器采不到「关门」→ 窗口边界丢失 → 计数跨窗口翻倍。  
即 `IDLE_CYCLES × T_sys > 2 × T_sig_max`。  
生产配置（IDLE=16×20ns=320ns，T_sig_max=9.22ns）有 34× 余量，安全。  
UVM driver 在两次门控间留 5 个 clk_sys 拍（100ns），对 110MHz（T=9.09ns）  
仍满足 100ns > 18.2ns，不会触发该陷阱。

---

## 6. 已知限制 / 后续扩展

- [ ] UVM 环境尚未在 VCS 实跑（本地无 VCS），仅保证代码范式正确。
- [ ] 当前只验 `freq_meter_gclk` 单模块；可扩展 `top_system` 端到端  
  UVM：激励注入 SAW 三通道 → 比对 UART 回读（`uart_tx`/`tx_packer`）。
- [ ] `async_fifo`（多比特格雷码跨域）可单独加一套 FIFO UVM 环境。
- [ ] 覆盖率报告（urg）可在 VCS 跑完后用 `urg -dir simv_uvm.vdb` 生成。
