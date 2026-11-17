# ============================================================================
# alcohol_humidity_uvm —— 验证工程 Makefile
# ----------------------------------------------------------------------------
# 两套入口：
#   1) iverilog 本地基线  ：纯 Verilog（-g2005），无需 UVM / VCS，本地即可跑
#   2) VCS + UVM 1.2 环境 ：需在 RHEL8 EDA 服务器（已装 VCS）上运行
#
# 用法：
#   make iverilog              # 本地基线，应打印 PASS (0 errors)
#   make check_vcs             # 只检查 VCS 环境（VCS_HOME / PATH / 版本）
#   make vcs                   # 仅编译 UVM 环境（生成 simv_uvm）
#   make sim                   # 编译 + 跑随机测试（freq_random_test）
#   make sim TEST=freq_directed_test   # 跑定向测试
#   make cov                   # 覆盖率回归：两个 test 全跑 + urg 出报告（RHEL8）
#   make clean                 # 清产物
#
# 本机（Windows + ModelSim SE，没有 VCS）走另一套入口：
#   make msim                  # 原版 DUT 随机测试，应看到 MISSING>0
#   make msim_fixed            # 修复版 DUT，应 MISSING=0
#   make msim_directed         # 定向测试
#   make msim_cov              # 覆盖率报告
#   make msim_clean            # 清 ModelSim 产物
#
# 注：所有 VCS 调用都显式带 -full64 —— make 的 recipe 在非交互 shell 里
#     不展开 alias，若只靠 alias vcs='vcs -full64' 会退回 32 位模式并报
#     "Cannot find VCS compiler"。
# ============================================================================

# ---- 路径（相对工程根目录）----
RTL      = rtl/freq_meter_gclk.v rtl/gate_timer.v
TB       = tb/tb_freq_meter_gclk_real.v
UVM_FL   = uvm/filelist.f

# ---- iverilog 本地基线 ----
IV_OUT   = sim/iverilog_tb_gclk.out

.PHONY: iverilog
iverilog:
	@mkdir -p sim
	iverilog -g2005 -o $(IV_OUT) $(TB) $(RTL)
	vvp $(IV_OUT)

# ---- 本地 CDC 漏采复现（无需 VCS，iverilog 即可跑）----
#   make cdc_demo     ：原版 DUT，扫频证明 f>50MHz 漏采（100MHz 确定性 100% 丢失）
#   make cdc_fix_demo ：修复版 DUT，同法扫频应全部 0% 漏采
CDC_TB     = tb/tb_cdc_miss_demo.v
CDC_FIX_TB = tb/tb_cdc_fix_demo.v
CDC_RTL    = rtl/freq_meter_gclk.v rtl/gate_timer.v
CDC_FIX_RTL = rtl/freq_meter_gclk_fixed.v rtl/gate_timer.v

.PHONY: cdc_demo
cdc_demo:
	@mkdir -p sim
	iverilog -g2005 -o sim/cdc_demo.out $(CDC_TB) $(CDC_RTL)
	vvp sim/cdc_demo.out

.PHONY: cdc_fix_demo
cdc_fix_demo:
	@mkdir -p sim
	iverilog -g2005 -o sim/cdc_fix.out $(CDC_FIX_TB) $(CDC_FIX_RTL)
	vvp sim/cdc_fix.out

# ---- VCS + UVM 1.2 ----
TEST     ?= freq_random_test
# 注意：必须显式带 -full64。
#   make 通过 /bin/sh -c 执行 recipe，非交互 shell 不展开 alias；
#   若 .bashrc 里写了 alias vcs='vcs -full64'，交互式敲 vcs 正常，
#   但 make 里裸调 vcs 会退回 32 位模式，脚本内部把 VCS_HOME 改成
#   $VCS_HOME/linux，于是报 "Cannot find VCS compiler"（VCS_COM_UNE）。
#
# +incdir+uvm：
#   freq_meter_gclk_pkg.sv 里用 `include "freq_result.sv" 这种裸文件名，
#   VCS 默认只在当前工作目录（以及 +incdir 指定的目录）找，不会自动
#   去被包含文件所在目录找，所以必须把 uvm/ 加进搜索路径。
# ---- 波形（Verdi / FSDB）----
# 装了 Verdi 时，把安装根目录传进来即可启用 FSDB dump：
#   make sim VERDI_HOME=/home/yian/Synopsys/verdi/V-XXXX WAVE=+FSDB
#   verdi -ssf sim/simv_uvm.fsdb &
VERDI_HOME ?=
FSDB_DEF   = $(if $(VERDI_HOME),+define+FSDB)
FSDB_PLI   = $(if $(VERDI_HOME),-P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a)

VCS_OPTS  = -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps +incdir+uvm -debug_access+all $(FSDB_DEF) $(FSDB_PLI)

# ---- 修复版 DUT 开关 ----
#   make sim FIXED=1  → VCS 加 +define+FIXED_DUT，例化 freq_meter_gclk_fixed
#   预期：EXPECTED=GOT，MISSING=0（toggle 握手消除漏采）
FIXED_DEF = $(if $(FIXED),+define+FIXED_DUT)
VCS_OPTS += $(FIXED_DEF)

# ---- VCS 环境预检 ----
# 典型坑：VCS_HOME 多带了平台子目录（.../V-2023.12-SP2/linux），
#         vcs 会报 "Cannot find VCS compiler (VCS_COM_UNE)"。
#         正确值应为版本根目录 .../V-2023.12-SP2
.PHONY: check_vcs
check_vcs:
	@case "$$VCS_HOME" in "") echo "!!! [check_vcs] VCS_HOME is not set."; echo "    run: export VCS_HOME=/home/yian/Synopsys/vcs/V-2023.12-SP2"; exit 1;; esac
	@case "$$VCS_HOME" in */linux|*/linux64|*/amd64) echo "!!! [check_vcs] VCS_HOME points to a platform subdir: $$VCS_HOME"; echo "    correct value is the version root: $$(dirname $$VCS_HOME)"; echo "    fix: export VCS_HOME=$$(dirname $$VCS_HOME)"; exit 1;; esac
	@command -v vcs >/dev/null 2>&1 || { echo "!!! [check_vcs] 'vcs' not found in PATH (add VCS_HOME/bin)"; exit 1; }
	@echo ">>> [check_vcs] VCS_HOME=$$VCS_HOME"
	@vcs -full64 -ID 2>/dev/null | head -6 || true

.PHONY: vcs
vcs: check_vcs
	@mkdir -p sim
	vcs $(VCS_OPTS) -f $(UVM_FL) -o sim/simv_uvm

.PHONY: sim
# WAVE=+DUMP 时导出 VPD 波形（sim/simv_uvm.vpd），用 dve -vpd 打开
WAVE     ?=
sim: vcs
	./sim/simv_uvm +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=UVM_MEDIUM $(WAVE) \
	    -l sim/uvm_$(TEST).log
	@grep -E "SCOREBOARD PASS|EXPECTED=|UVM_ERROR|UVM_FATAL" sim/uvm_$(TEST).log || true
	@echo ">>> 详见 sim/uvm_$(TEST).log"

# ---- VCS + 覆盖率回归（RHEL8 实跑，取简历里的覆盖率数字）----
# 覆盖类型：line + cond + fsm + branch + tgl，另含 UVM covergroup 功能覆盖
# 产物：covdata/<name>.cm.vdb（覆盖率库）、covdata/report/（HTML）、covdata/report_text/（文本）
#
# 三个必须一起满足，否则 urg 报 Error-[UCAPI-DNYL] Design not yet loaded：
#   1) 编译时就要带 -cm 和 -cm_dir —— 设计层次结构写在编译期建的 vdb 里，
#      只给仿真带 -cm 会生成一个没有层次信息的空库，urg 加载不了；
#   2) 编译和所有仿真的 -cm_dir 必须是同一个（这里统一用绝对路径 $(COV_DB)）；
#   3) urg 的 -dir 要指向 <name>.cm.vdb 这个带后缀的目录，不是 .cm 前缀。
COV_CM    = line+cond+fsm+branch+tgl
COV_TESTS = freq_random_test freq_directed_test freq_saturation_test
COV_DB    = $(CURDIR)/covdata/cov.cm
COV_FIXED ?= 0

.PHONY: cov
cov: check_vcs
	@mkdir -p sim covdata
	rm -rf $(COV_DB).vdb
	vcs $(VCS_OPTS) $(if $(filter 1,$(COV_FIXED)),+define+FIXED_DUT) \
	    -cm $(COV_CM) -cm_dir $(COV_DB) -f $(UVM_FL) -o sim/simv_cov
	@for t in $(COV_TESTS); do \
	    echo ">>> [cov] run $$t ..."; \
	    ./sim/simv_cov +UVM_TESTNAME=$$t +UVM_VERBOSITY=UVM_MEDIUM \
	        -cm $(COV_CM) -cm_dir $(COV_DB) -cm_name $$t \
	        -l sim/cov_$$t.log || exit 1; \
	    grep -E "SCOREBOARD PASS|EXPECTED=" sim/cov_$$t.log || true; \
	done
	urg -full64 -dir $(COV_DB).vdb -report covdata/report
	urg -full64 -dir $(COV_DB).vdb -format text -report covdata/report_text
	@echo ""
	@echo ">>> HTML 报告: covdata/report/index.html"
	@echo ">>> 文本报告: covdata/report_text/modinfo.txt（看 DUT 模块那一节）"
	@echo ">>> 简历取数用【功能覆盖率 cg_freq】和【DUT 行/分支覆盖率】，"
	@echo ">>> 不要报 Total Coverage Summary 那个总分——分母含 UVM 库和未选中的 DUT 版本"

.PHONY: clean
clean:
	rm -rf sim simv_uvm csrc DVEfiles *.vpd *.daidir uvm*.log simv.cm covdata simv_cov*

# ---- ModelSim SE 本地跑 UVM（本机没有 VCS 时用这条）----
# 依赖 sim/run_modelsim.ps1，会自动处理三件事：
#   1. ModelSim 内置 uvm_pkg 是 1.1d，宏要显式 include uvm_macros.svh
#      （VCS 的 -ntb_opts uvm-1.2 会自动做，ModelSim 不会）
#   2. 覆盖率编译选项是 -cover bcesxf（toggle 与 txf 互斥）
#   3. 仿真必须 -onfinish stop，否则 $finish 让 coverage save 来不及跑
#
#   make msim              # 原版 DUT，随机测试（应 MISSING>0，暴露 CDC 缺陷）
#   make msim_fixed        # 修复版 DUT（应 EXPECTED=GOT，MISSING=0）
#   make msim_directed     # 定向测试
#   make msim_cov          # 出覆盖率报告（功能覆盖率 100%，DUT 分支 93.33%）
MSIM_PWSH ?= pwsh -NoProfile -File sim/run_modelsim.ps1

.PHONY: msim
msim:
	$(MSIM_PWSH)

.PHONY: msim_fixed
msim_fixed:
	$(MSIM_PWSH) -Fixed

.PHONY: msim_directed
msim_directed:
	$(MSIM_PWSH) -Test freq_directed_test

.PHONY: msim_cov
msim_cov:
	$(MSIM_PWSH) -Cov

.PHONY: msim_clean
msim_clean:
	$(MSIM_PWSH) -Clean
