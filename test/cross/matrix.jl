# What programs of StaticRuntime can be made from this machine, for each target: `julia --project=test/cross test/cross/matrix.jl [outdir]`.
# For each target of `CROSS_TARGETS` (`test/cross/support.jl` says which can be made here, and what is fetched for it) it makes every program of `CrossPrograms.PROGRAMS` (`test/cross/programs.jl`) and records what
# the same program does natively. The table says how many were made, and why a target was not tried; it is printed, and written to `$GITHUB_STEP_SUMMARY` where there is one. With `outdir`, the programs are kept as
# `outdir/<host>/<triple>/<program>/{exe,stdout,stderr,status}`, for `test/cross/run.jl` to run on a machine of the target (the workflow `.github/workflows/cross.yml` does this on every kind of host).

using StaticRuntime
include("support.jl")
include("programs.jl")

host = string(host_arch(), "-", host_system())
outdir = length(ARGS) >= 1 ? abspath(ARGS[1]) : nothing

rows = NamedTuple[]
for triple in CROSS_TARGETS
    println("\n## ", triple)
    target, why = target_for(triple)
    if target === nothing
        println("   not tried: ", why)
        push!(rows, (; triple, made = "-", note = why))
        continue
    end
    dir = outdir === nothing ? mktempdir() : joinpath(outdir, host, triple)
    mkpath(dir)
    status = try
        built, refused = CrossPrograms.build_programs(target, dir)
        for (name, reason) in refused; println("   refused ", name, ": ", reason); end
        (; made = "$(length(built)) of $(length(CrossPrograms.PROGRAMS))", note = isempty(refused) ? "" : "refused: " * join(first.(refused), ", "))
    catch e
        msg = first(split(sprint(showerror, e), '\n'))
        println("   fails: ", msg)
        (; made = "fails", note = first(msg, 120))
    end
    println("   made: ", status.made, isempty(status.note) ? "" : " (" * status.note * ")")
    push!(rows, (; triple, status...))
end

table = string("| host `", host, "` makes for | programs made | note |\n|:--|:--|:--|\n",
               join(("| `$(r.triple)` | $(r.made) | $(r.note) |" for r in rows), "\n"), "\n")
println("\n", table)
haskey(ENV, "GITHUB_STEP_SUMMARY") && open(io -> println(io, "\n### Programs made, host ", host, ", Julia ", VERSION, "\n\n", table), ENV["GITHUB_STEP_SUMMARY"], "a")
# (a target that was tried and failed in a way that is not a program that the target refuses is a failure of the job; one that could not be tried is not)
any(r -> r.made == "fails", rows) && exit(1)
