# One fuzz case, in a process of its own: `julia --project=test test/fuzz/case.jl <kind> <seed>` (`embedfuzz` or `dispatchfuzz`, and a seed as `0x688` or `1234`). This is what `fuzz/harness.jl` runs for
# each seed, with a time limit, and it is how a seed that failed is run again: with no limit, and with all that it says on the terminal. The last lines that it writes say whether the case was right: `FUZZRESULT ok`, or
# `FUZZRESULT fail` and what was wrong.

ENV["TERM"] = "xterm-256color"

using Test, Random, Printf, LinearAlgebra, Libdl, Dates, SparseArrays, Base64, CRC32c, Logging, Statistics
using SHA, UUIDs, Sockets, Unicode, TOML, Markdown, Mmap
using LLVM
using LLVM: @dispose
if Base.find_package("StaticRuntime") === nothing
    include("../../src/StaticRuntime.jl")
    using .StaticRuntime
else
    using StaticRuntime
end
include("../helpers.jl")

length(ARGS) == 2 || error("usage: julia --project=test test/fuzz/case.jl <embedfuzz|dispatchfuzz> <seed>")
kind, seedtext = ARGS
kind in ("embedfuzz", "dispatchfuzz") || error("the kind of fuzzing is `embedfuzz` or `dispatchfuzz`, not `$kind`")
seed = startswith(seedtext, "0x") ? parse(UInt, seedtext) : parse(Int, seedtext)

include(kind * ".jl") # (defines `fuzz_case(seed)`)

ok, msg = try
    fuzz_case(seed)
catch e
    false, string("an exception: ", first(sprint(showerror, e), 600))
end
println()
println("FUZZRESULT ", ok ? "ok" : "fail")
ok || println(msg)
exit(ok ? 0 : 1)
