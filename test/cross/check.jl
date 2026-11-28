# Runs the programs that `test/cross/build.jl` made, on the machine that they are for, and compares what they do with what the native programs did: `julia test/cross/check.jl <outdir>`.
# It needs only Julia (the standard library): no StaticRuntime. Exits with a status that is not 0 if a program does something else.
# (`check(dir; node)` is also used by `test/cross/run.jl`: `node` is the command that runs Node.js 24 or later, for the programs for WebAssembly.)

# what a program does: what it prints to its standard output and to its standard error, and its exit status (also used by the tests, and by `test/cross/run.jl`)
function run_program(command::Cmd)
    out, err = tempname(), tempname()
    p = run(ignorestatus(pipeline(command; stdout = out, stderr = err)))
    return (read(out, String), read(err, String), p.exitcode)
end

function check(outdir::AbstractString; node = Cmd([get(ENV, "NODE", "node")]))
    failed = String[]
    for name in sort(readdir(outdir))
        dir = joinpath(outdir, name)
        # (a program for WebAssembly is `exe.wasm`, with the host `exe.mjs` that runs it with Node.js 24 or later: `NODE` is the path of `node`)
        command = isfile(joinpath(dir, "exe")) ? `$(joinpath(dir, "exe"))` : isfile(joinpath(dir, "exe.mjs")) ? `$node $(joinpath(dir, "exe.mjs"))` : continue
        got = run_program(command)
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

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 1 || error("usage: julia test/cross/check.jl <outdir>")
    check(ARGS[1]) || exit(1)
end
