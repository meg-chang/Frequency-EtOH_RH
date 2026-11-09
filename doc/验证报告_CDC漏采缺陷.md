# 验证报告：UVM 环境发现 DUT 跨时钟域（CDC）单周期脉冲漏采缺陷

| 项 | 内容 |
|---|---|
| 被测设计 (DUT) | `freq_meter_gclk`（门控计数测频，被测信号直驱 GCLK） |
| 验证方法 | UVM 1.2 随机/定向测试 + iverilog 本地基线；RHEL8 上 VCS 2023.12-SP2 实跑 |
| 缺陷级别 | **严重（silent data loss）**——不报任何 UVM_ERROR，结果静默丢失 |
| 修复方法 | `done` 脉冲 → toggle 握手（已实跑验证，100MHz 工况由 100% 丢失降至 0%） |
| 报告日期 | 2026-10-23 |

---

## 1. 验证环境

- **仿真器**：RHEL8 EDA 服务器 VCS `V-2023.12-SP2_Full64`（`-ntb_opts uvm-1.2`）；本地 `iverilog 11.0` 作基线。
- **时钟**：系统域 `clk_sys` = 50MHz（周期 20ns）；被测域 `clk_sig` 由 SV 接口按配置周期生成，覆盖 **10–110MHz**（生产目标 ÷4 → 108.48MHz）。
- **UVM 结构**：
  - `freq_agent`（driver + monitor，均走 clocking block 避免采样竞争）
  - `freq_scoreboard`：**双 analysis imp**——`result_imp` 收 DUT `count` 做容差比对；`item_imp` 收 driver 发出的激励做**笔数对账**（抓静默漏检）。
  - `freq_coverage`：频率 × 门控 交叉覆盖（`bins` 已避开 Verilog 保留字 `small/medium/large`）。
  - `freq_test`：`freq_random_test`（sig_period 10–110MHz 随机）、`freq_directed_test`。

---

## 2. 缺陷是怎样被发现的

`make sim TEST=freq_random_test` 实跑结果：

```
UVM_ERROR = 0   UVM_FATAL = 0
==== SCOREBOARD PASS=38 FAIL=0 ====
==== EXPECTED=50 GOT=38 MISSING=12 ====
[UVM_WARNING] 有 12 笔激励没有收到 count_valid：DUT 的 done 是被测域单周期脉冲，
当 T_clk_sig < T_clk_sys（f>50MHz）时两级同步器会漏采，属 DUT 跨域缺陷
```

**关键认知**：`SCOREBOARD PASS=38 FAIL=0` 是**假象**。传统的"数值比对"记分板只检查
*收到的*结果对不对，无法发现"根本没收到结果"。本环境额外引入的**笔数对账**
（driver 每发 1 笔激励 `exp_cnt++`，最后与 `pass+fail` 比对）才暴露出：50 笔激励只
回收 38 笔，**12 笔窗口整窗无 `count_valid`**，且无任何 error。

---

## 3. 根因分析

### 3.1 机制

`freq_meter_gclk` 的窗口结束信号 `done` 是在**被测域**产生的**单周期脉冲**
（脉宽 = 1 个 `clk_sig` 周期）：

```verilog
if (!gate_s2 && gate_d) begin   // 窗口刚结束（被测域）
    cnt_out <= cnt;
    done    <= 1'b1;            // 仅当拍置 1，下一拍 default 拉回 0
end
```

回传系统域时，用 **两级同步 + 上升沿检测** 把它变回 1 周期脉冲：

```verilog
always @(posedge clk_sys ...) begin
    done_s1 <= done;  done_s2 <= done_s1;  done_d <= done_s2;
end
assign count_valid = done_s2 & ~done_d;
```

**致命点**：两级同步器要"采到" `done`，必须有一个 `clk_sys` 上升沿**落在 `done`
的高电平窗口内**。当 `T_clk_sig < T_clk_sys`（即 `f > 50MHz`）时，`done` 脉宽 < 20ns，
可能**整段夹在两个 `clk_sys` 边沿之间** → 同步器第一级永远采样到 0 → `count_valid`
永不产生 → 整窗结果静默丢失。

### 3.2 频率/相位依赖（实测修正了"均匀漏采"的直觉误区）

直觉上容易以为"漏采率 = 1 − T_sig/20ns"（约 54%），但**实测表明漏采是
相位/频率相关的，不是均匀随机的**：

| 被测频率 | T_sig | 漏采率（原版） | 说明 |
|---|---|---|---|
| ≤ 50MHz | ≥ 20ns | **0%** | `done` 脉宽 ≥ 1 个系统周期，必被某个 sys 边沿覆盖 |
| 70 / 90 / 108 / 110 / 120 MHz | 8–14ns | **0%（本相位对齐下）** | 当前门控相位恰好安全 |
| **100MHz（= 2× f_sys）** | 10ns | **100%** | `done` 恰为半个系统周期且与 sys 边沿反相，**确定性全丢** |

> 这比"均匀 54%"更危险：它是一个**相位敏感、间歇性、PVT 漂移会恶化**的缺陷——
> 实验室某频率"恰好安全"，量产后温度/电压一变相位漂移，就可能变成 100% 丢失。
> 这正是"板子能跑、现场失效"类 CDC bug 的典型特征。

### 3.3 为什么数值比对发现不了

`count_valid` 不出现 → `write_result` 不被调用 → 那笔结果既不 PASS 也不 FAIL，
只是"不存在"。传统记分板只统计 `PASS+FAIL`，自然显示 `FAIL=0`。**只有显式做
"发出笔数 vs 收回笔数"的对账**，才能把这种"静默漏检"暴露成 warning。

---

## 4. 本地可复现证据（iverilog，无需 VCS）

工程内置两个本地 demo，任何装了 iverilog 的机器都能复现：

```bash
make cdc_demo       # 原版 DUT，扫频打印漏采率
make cdc_fix_demo   # 修复版 DUT，同法应全部 0%
```

原版 `make cdc_demo`（节选）：

```
 f= 20.00MHz  T_sig=50.000ns  窗口=100  捕获=100  漏采=0     漏采率=  0.0%
 f= 50.00MHz  T_sig=20.000ns  窗口=100  捕获=100  漏采=0     漏采率=  0.0%
 f=100.00MHz  T_sig=10.000ns  窗口=100  捕获=0    漏采=100   漏采率=100.0%   ← 确定性全丢
 f=107.99MHz  T_sig= 9.260ns  窗口=100  捕获=100  漏采=0     漏采率=  0.0%
```

> 注：`f>50MHz` 的非 100MHz 点在本相位对齐下为 0%，正说明缺陷的**间歇性**——
> 它不会在每一个高频点都炸，但一旦相位恶化（见 §3.2）就 100% 丢失。RHEL 上
> UVM 随机测试（10–110MHz + 门控相位随机）综合呈现为 **12/50 静默丢失**，与此一致。

---

## 5. 修复方案：toggle 握手（已验证）

把"单周期脉冲"改成"电平翻转握手"——被测域每次窗口结束**翻转**一个
`done_toggle` 寄存器；该电平在两次窗口之间**长期保持**（≥ 一个完整门控周期，
远大于 2 个系统周期），故同步器必然采到；系统域对同步后的翻转做边沿检测
（`done_t2 ^ done_d3`）重新得到 1 周期 `count_valid`。

```verilog
// 被测域：脉冲 → 电平翻转（替代单周期脉冲）
if (!gate_s2 && gate_d) begin
    cnt_out     <= cnt;
    done_toggle <= ~done_toggle;   // 保持到下一窗口
    cnt         <= {COUNT_WIDTH{1'b0}};
end
// 系统域：2-FF 同步 + 边沿检测，与脉宽无关
always @(posedge clk_sys ...)
    {done_t3, done_t2, done_t1} <= {done_t2, done_t1, done_toggle};
assign count_valid = done_t2 ^ done_t3;
```

**修复后 `make cdc_fix_demo`**（节选，全部频率 0% 漏采）：

```
 f= 20.00MHz  T_sig=50.000ns  窗口=100  捕获=100  漏采=0
 f= 50.00MHz  T_sig=20.000ns  窗口=100  捕获=100  漏采=0
 f=100.00MHz  T_sig=10.000ns  窗口=100  捕获=100  漏采=0   ← 原来 100% 丢失，现已修复
 f=107.99MHz  T_sig= 9.260ns  窗口=100  捕获=100  漏采=0
 f=120.05MHz  T_sig= 8.330ns  窗口=100  捕获=100  漏采=0
```

RHEL 上可端到端验证：

```bash
make sim FIXED=1 TEST=freq_random_test      # 应 EXPECTED=GOT，MISSING=0
```

---

## 6. 教训

1. **单周期脉冲禁止直接 2-FF 同步**。跨域脉冲必须用：① 脉冲→电平（toggle）握手 +
   边沿检测；② 或脉冲同步器（展宽到 ≥ 2 个接收域周期）。本 DUT 的 `done` 正是踩了这条。
2. **同步器是"边沿采样"设备，不是"脉冲捕获"设备**。能否采到取决于接收域时钟边沿
   是否落在脉冲窗口内——频率/相位相关，且 PVT 敏感。
3. **记分板要做"完整性对账"，不能只做"数值比对"**。`FAIL=0` 不等于"全对"，
   没收到的结果才是更隐蔽的 bug。本环境靠 `exp_cnt` vs `pass+fail` 才抓到。
4. **`f = N × f_sys` 是 CDC 雷区**。本工程 100MHz = 2×50MHz 即确定性全丢，是
   最该在规格书里标红的约束。

---

## 7. 复现步骤

```bash
# 本地（iverilog）
make cdc_demo          # 原版漏采证据
make cdc_fix_demo      # 修复版 0% 漏采

# RHEL8（VCS + UVM，FSDB 波形）
tar -xzf /mnt/hgfs/IC/share/alcohol_humidity_uvm.tar.gz
cd alcohol_humidity_uvm
make sim VERDI_HOME=$VERDI_HOME WAVE=+FSDB        # 原版：EXPECTED=50 GOT=38 MISSING=12
verdi -ssf sim/simv_uvm.fsdb &
make sim FIXED=1 VERDI_HOME=$VERDI_HOME WAVE=+FSDB  # 修复版：MISSING=0
```
