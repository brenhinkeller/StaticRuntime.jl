# Cross-compilation: programs for another system or architecture than the host's, made and run here (`GROUP=Cross`, and `All`, which is what `] test` runs; not in CI, where the workflow `cross.yml` tests it).
#
# `here.jl` makes programs for every target that this machine can make and run (Linux, macOS, WebAssembly), runs them, and compares what they do with what the same programs do made for the host. What a target
# needs is fetched where it can be, and a target that cannot be tried is skipped, with the reason in the log (`support.jl`; `host.jl` says what is fetched, and when: `STATIC_RUNTIME_CROSS_FETCH`).
# In CI `cross.yml` is the test: `matrix.jl` makes every program of `programs.jl` for every target of every kind of host, and `run.jl` runs them on the machines of the targets (`check.jl` is what compares).
# `build.jl` and `sysroot.jl` are for making programs for one target by hand, and `survey.jl` and `check_browser.mjs` are tools for WebAssembly, and not tests.
# (The tests of cross-compilation that make nothing to run, the targets and the IR, are in `test/core/cross.jl`: they need no tool, and are Core tests.)
println("\n")
@info "Cross-compilation tests:"

include("support.jl")
include("programs.jl")
include("check.jl") # (`run_program`: what a program prints and its exit status)

@testset verbose=true "Cross-compilation, run here" include_timed("here.jl")
