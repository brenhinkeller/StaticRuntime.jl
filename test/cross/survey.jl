# What of the tests works for WebAssembly: `julia test/cross/survey.jl <report.tsv> <file of test/core or test/packages>...` runs the cases of `check_cases` in those files as programs for
# `wasm64-unknown-unknown` (compiled here, run with Node.js 24 or later: `STATIC_RUNTIME_NODE`), and compares what they do with what they do in Julia, as the tests do for the host.
# A line is added to the report for each case: `file<TAB>case<TAB>status<TAB>detail`, with the status of `static_status` (`ok`, `compile_error`, `link_error`, `runtime_error`, `mismatch`).
# `test/cross/classify.jl <report.tsv>` groups the reasons. (The cases that are not made of `check_cases`, and the tests of the compiler itself, are not run.)

using Test, Random, Printf, Libdl, Unicode, LLVM
using StaticRuntime
const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "helpers.jl"))

const REPORT = ARGS[1]
const FILES = ARGS[2:end]
const CURRENT = Ref("")
const SURVEY_OPTIONS = (; target = "wasm64-unknown-unknown", gc = true)

function check_cases(cases; broken = (), folded_ok = (), batch::Bool = true, chunk::Int = 24, kwargs...)
    named = [c isa Pair ? c : string(nameof(c)) => c for c in cases]
    todo = [i for i in eachindex(named) if !(named[i][1] in broken)]
    for group in Iterators.partition(todo, batch ? chunk : 1)
        fs = Function[named[i][2] for i in group]
        statuses = try
            StaticRuntime.static_status_batch(fs; merge(NamedTuple(kwargs), SURVEY_OPTIONS)...)
        catch e
            [(:survey_error, sprint(showerror, e)) for _ in fs]
        end
        open(REPORT, "a") do io
            for (i, (status, detail)) in zip(group, statuses)
                println(io, join((CURRENT[], named[i][1], status, first(replace(string(detail), r"\s+" => " "), 400)), '\t'))
            end
        end
    end
    return nothing
end

for file in FILES
    CURRENT[] = basename(file)
    @info "survey" file
    try
        @testset "$file" include(abspath(file))
    catch e
        open(REPORT, "a") do io
            println(io, join((CURRENT[], "(the file)", "survey_error", first(replace(sprint(showerror, e), r"\s+" => " "), 400)), '\t'))
        end
    end
end
