# ============================================================================
# run_modelsim.ps1 —— 在 ModelSim SE 上跑这套 UVM 环境（本机没有 VCS）
# ----------------------------------------------------------------------------
# 背景：Makefile 的 vcs / sim / cov 目标都依赖 VCS + -ntb_opts uvm-1.2，
#       本机只有 ModelSim SE 2020.4，跑不了。
#
# 踩过的坑（照顺序）：
#   1. ModelSim 自带的 mtiUvm 库是 uvm-1.1d，但 verilog_src/uvm-1.2/src
#      只有 3 个文件（uvm_pkg.sv 里 `include 的 base/ dpi/ 全不在），
#      直接 -L mtiUvm 编译会报 "Macro `uvm_object_utils is undefined"。
#      → 正确做法：-L mtiUvm 用内置预编译库，同时 +incdir 指向
#        verilog_src/uvm-1.1d/src（那里有完整的 macros/ base/ 等 138 个文件），
#        并且在 package 之前显式 `include "uvm_macros.svh"。
#        VCS 的 -ntb_opts uvm-1.2 会自动做这件事，ModelSim 不会。
#   2. 覆盖率：编译期用 -cover bcesxf（-cover 里 toggle 和 txf 互斥，
#      写 bcestfx 会报 vlog-1913 Ambiguous options）。
#      仿真期用 -coverage 打开统计，且必须加 -onfinish stop，
#      否则 $finish 直接退出，-do 里后续的 coverage save 来不及执行。
#   3. 覆盖率命令只能放在 vsim -do 里，不能当 vsim 的命令行参数。
#
# 用法：
#   pwsh -File sim/run_modelsim.ps1              # 原版 DUT，跑随机测试
#   pwsh -File sim/run_modelsim.ps1 -Fixed       # 修复版 DUT
#   pwsh -File sim/run_modelsim.ps1 -Test freq_directed_test
#   pwsh -File sim/run_modelsim.ps1 -Cov         # 带覆盖率，出 ucdb + 明细
#   pwsh -File sim/run_modelsim.ps1 -Clean       # 清产物
# ============================================================================

param(
    [switch]$Fixed,
    [string]$Test = "freq_random_test",
    [switch]$Cov,
    [switch]$Clean,
    [string]$ModelsimHome = "D:\Program\FPGA\Modelsim_se"
)

$ErrorActionPreference = "Stop"

$repo   = Split-Path -Parent $PSScriptRoot
$bin    = Join-Path $ModelsimHome "win64"
$uvmsrc = Join-Path $ModelsimHome "verilog_src\uvm-1.1d\src"
$wd     = Join-Path $PSScriptRoot "msim"

$workLib = if ($Fixed) { "work_fixed" } else { "work" }
if ($Cov) { $workLib = "${workLib}_cov" }

if ($Clean) {
    if (Test-Path $wd) { Remove-Item $wd -Recurse -Force }
    Write-Host ">>> 已清 $wd"
    exit 0
}

foreach ($exe in @("vlib.exe", "vlog.exe", "vsim.exe")) {
    $p = Join-Path $bin $exe
    if (-not (Test-Path $p)) { throw "找不到 $p，用 -ModelsimHome 指定安装根目录" }
}
if (-not (Test-Path $uvmsrc)) { throw "找不到 UVM 源码 $uvmsrc" }

New-Item -ItemType Directory -Force -Path $wd | Out-Null

# ---- 1. 建库 ----
Push-Location $wd
try {
    if (-not (Test-Path $workLib)) {
        & (Join-Path $bin "vlib.exe") $workLib | Out-Null
    }

    # ---- 2. 编译 ----
    # 包装文件：ModelSim 内置 uvm_pkg 的宏要显式引入
    $wrap = Join-Path $wd "msim_pkg_wrap.sv"
    @'
// 自动生成：ModelSim 内置 uvm_pkg 是 1.1d，宏必须显式 include
`include "uvm_macros.svh"
`include "freq_meter_gclk_pkg.sv"
'@ | Set-Content $wrap -Encoding utf8

    $vlogArgs = @(
        "-sv", "-L", "mtiUvm",
        "+incdir+$uvmsrc",
        "+incdir+$repo/uvm",
        "-work", $workLib
    )
    if ($Cov) { $vlogArgs += @("-cover", "bcesxf") }
    if ($Fixed) { $vlogArgs += "+define+FIXED_DUT" }

    $vlogArgs += @(
        "$repo/rtl/freq_meter_gclk.v",
        "$repo/rtl/freq_meter_gclk_fixed.v",
        "$repo/uvm/freq_meter_gclk_if.sv",
        $wrap,
        "$repo/uvm/freq_meter_gclk_top.sv"
    )

    Write-Host ">>> 编译到 $workLib ..."
    $log = & (Join-Path $bin "vlog.exe") @vlogArgs 2>&1
    $log | Select-String "Error" | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { throw "编译失败" }

    # ---- 3. 仿真 ----
    $doCmds = "run -all;"
    if ($Cov) {
        $doCmds += " coverage report -summary;"
        $doCmds += " coverage save -onexit cov_$Test.ucdb;"
    }
    $doCmds += " quit -f"

    $vsimArgs = @("-c", "-L", "mtiUvm", "-work", $workLib, "freq_meter_gclk_top",
                  "+UVM_TESTNAME=$Test", "+UVM_VERBOSITY=UVM_LOW")
    # ★ -voptargs="+acc" 必须有：
    #   freq_saturation_test 用 uvm_hdl_deposit 改 DUT 内部 cnt，这是层次化路径
    #   访问。ModelSim 默认 vopt 优化时会把内部信号裁掉，不加这个参数
    #   uvm_hdl_deposit 会报 "unable to locate hdl path"。
    #   更阴的是：加了参数但某些信号仍被优化时，deposit 返回 1 却没写进去，
    #   所以用例里还加了 readback 校验，不能只信返回值。
    #   VCS 那边对应的是编译期 -debug_access+all（VCS_OPTS 已带）。
    $vsimArgs += @("-voptargs=+acc")
    if ($Cov) { $vsimArgs += @("-coverage", "-onfinish", "stop") }
    $vsimArgs += @("-do", $doCmds)

    $dutKind = if ($Fixed) { "修复版" } else { "原版(有CDC缺陷)" }
    Write-Host ">>> 仿真 $Test [$dutKind] ..."
    $simLog = & (Join-Path $bin "vsim.exe") @vsimArgs 2>&1
    $simLog | Select-String "SCOREBOARD|EXPECTED=|UVM_ERROR :|UVM_FATAL :|Coverage|Errors:" |
        ForEach-Object { $_.Line }

    # ---- 4. 覆盖率明细 ----
    if ($Cov) {
        $ucdb = Join-Path $wd "cov_$Test.ucdb"
        if (Test-Path $ucdb) {
            Write-Host ""
            Write-Host ">>> 覆盖率明细 ($ucdb)"
            & (Join-Path $bin "vcover.exe") report -details $ucdb 2>&1 |
                Select-String "Total coverage|Covergroups|Coverpoints|Covergroup Bins|Branches\s+\d|Statements\s+\d|Toggles\s+\d" |
                ForEach-Object { $_.Line }
            Write-Host ""
            Write-Host ">>> 完整报告：vcover report -details $ucdb > cov.txt"
        } else {
            Write-Warning "没生成 ucdb，检查 -onfinish stop 是否生效"
        }
    }
}
finally {
    Pop-Location
}
