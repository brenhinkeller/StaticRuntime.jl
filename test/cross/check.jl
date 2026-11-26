# Runs the programs that `test/cross/build.jl` made, on the machine that they are for, and compares what they do with what the native programs did: `julia test/cross/check.jl <outdir>`.
# It needs only Julia (the standard library): no StaticRuntime. Exits with a status that is not 0 if a program does something else.

function check(outdir::AbstractString)
    failed = String[]
    for name in sort(readdir(outdir))
        dir = joinpath(outdir, name)
        isfile(joinpath(dir, "exe")) || continue
        out, err = tempname(), tempname()
        p = run(ignorestatus(pipeline(`$(joinpath(dir, "exe"))`; stdout = out, stderr = err)))
        got = (read(out, String), read(err, String), p.exitcode)
        want = (read(joinpath(dir, "stdout"), String), read(joinpath(dir, "stderr"), String), parse(Int, read(joinpath(dir, "status"), String)))
        if got == want
            println("ok      ", name)
        else
            println("FAILED  ", name, "\n   got  ", repr(got), "\n   want ", repr(want))
            push!(failed, name)
        end
    end
    println(isempty(failed) ? "all programs did what the native ones did" : string(length(failed), " failed: ", join(failed, ", ")))
    return isempty(failed)
end

length(ARGS) == 1 || error("usage: julia test/cross/check.jl <outdir>")
check(ARGS[1]) || exit(1)
