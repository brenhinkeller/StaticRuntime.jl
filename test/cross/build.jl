# Programs for another system, built here and checked there. `julia --project=test test/cross/build.jl <triple> <outdir> [sysroot]` makes each program of `PROGRAMS` for the
# triple (`target = cross_target(triple; sysroot)`: the sysroot is the `lib` of a glibc for a Linux target, `Glibc_jll`'s artifact for the platform is one) and runs it
# natively (made for the host) to record what it should do: `<outdir>/<name>/{exe,stdout,stderr,status}`. `test/cross/check.jl <outdir>` then runs the programs on a machine of the target
# (a Linux machine, with qemu or a runner of the architecture) and compares. The programs print nothing that depends on the machine or on the time.

using StaticRuntime
using Random

add_dispatch_candidates!(Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128, Float16, Float32, Float64, String, Char, Symbol, Bool, Nothing, Missing)
opaque(x::Int) = x + Int(time_ns() >> 63) # (a number that the compiler does not know: the top bit of the clock is zero)
opaque(x::Float64) = x + Float64(time_ns() >> 63)
opaque(x::String) = time_ns() >> 63 == 0 ? x : x * "!"

const PROGRAMS = [
    "hello"       => () -> (println("hello, world"); 0),
    "arithmetic"  => () -> (s = 0; for i in 1:opaque(1000); s += i * i % 7; end; println(s); 0),
    "floats"      => () -> (x = opaque(2.5); println(sin(x), " ", exp(x), " ", x^3, " ", sqrt(x), " ", log(x), " ", atan(x, 2.0)); 0),
    "strings"     => () -> (s = join(string.(1:opaque(5)), ","); println(uppercase(s), " ", length(s), " ", split(s, ",")); 0),
    "collections" => () -> (d = Dict{Int,String}(i => string(i^2) for i in 1:opaque(5)); println(sort(collect(d))); println(sum(length.(values(d)))); 0),
    "structs"     => () -> (v = [(i, i / 2, "n$i") for i in 1:opaque(3)]; println(v); 0),
    "caught"      => () -> (try; parse(Int, opaque("x")); catch e; showerror(STDERR, e); println(STDERR); end; println("after"); 0),
    "exit status" => () -> (println("bye"); 3),
    "memory"      => () -> (v = [Vector{Int}(undef, opaque(1000)) for _ in 1:opaque(200)]; println(length(v), " ", sum(length, v)); 0),
    "files"       => () -> (f = tempname(); write(f, "abc"); println(read(f, String), " ", filesize(f), " ", isfile(f)); rm(f); println(isfile(f)); 0),
    "directory"   => () -> (d = mktempdir(); write(joinpath(d, "b"), "1"); write(joinpath(d, "a"), "2"); println(readdir(d)); rm(d; recursive = true); 0),
    "environment" => () -> (println(get(ENV, "STATIC_RUNTIME_CROSS_NO_SUCH_VARIABLE", "unset")); 0),
    "process"     => () -> (run(`echo from a process`); println(success(`true`), success(`false`)); 0),
]

function build(triple::AbstractString, outdir::AbstractString, sysroot = nothing)
    target = sysroot === nothing ? cross_target(triple) : cross_target(triple; sysroot)
    mkpath(outdir)
    for (name, f) in PROGRAMS
        dir = joinpath(outdir, replace(name, ' ' => '_'))
        mkpath(dir)
        main = StaticRuntime.make_main(f)
        entry = (Int, Ptr{Ptr{UInt8}})
        exe = Base.invokelatest(compile_executable, main, entry, dir, string(nameof(main)); target, filename = "exe")
        native = Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); filename = "native")
        out, err = joinpath(dir, "stdout"), joinpath(dir, "stderr")
        p = run(ignorestatus(pipeline(`$native`; stdout = out, stderr = err)))
        write(joinpath(dir, "status"), string(p.exitcode))
        println("built ", name, " (", filesize(exe), " bytes)")
    end
end

length(ARGS) >= 2 || error("usage: julia --project=test test/cross/build.jl <triple> <outdir> [sysroot]")
build(ARGS[1], ARGS[2], length(ARGS) >= 3 ? ARGS[3] : nothing)
