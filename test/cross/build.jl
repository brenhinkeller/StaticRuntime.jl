# Programs for another system, built here and checked there. `julia --project=. test/cross/build.jl <triple> <outdir> [sysroot]` makes each program of `PROGRAMS` for the
# triple (`target = cross_target(triple; sysroot)`: the sysroot is the `lib` of a glibc for a Linux target, `Glibc_jll`'s artifact for the platform is one) and runs it
# natively (made for the host) to record what it should do: `<outdir>/<name>/{exe,stdout,stderr,status}`. `test/cross/check.jl <outdir>` then runs the programs on a machine of the target
# (a Linux machine, with qemu or a runner of the architecture) and compares. The programs print nothing that depends on the machine or on the time.

using StaticRuntime, LinearAlgebra

add_dispatch_candidates!(Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128, Float16, Float32, Float64, String, Char, Symbol, Bool, Nothing, Missing)
opaque(x::Int) = x + Int(time_ns() >> 63) # (a number that the compiler does not know: the top bit of the clock is zero)
opaque(x::Float64) = x + Float64(time_ns() >> 63)
opaque(x::Float32) = x + Float32(time_ns() >> 63)
opaque(x::String) = time_ns() >> 63 == 0 ? x : x * "!"

const PROGRAMS = [
    "hello"       => () -> (println("hello, world"); 0),
    "arithmetic"  => () -> (s = 0; for i in 1:opaque(1000); s += i * i % 7; end; println(s); 0),
    "floats"      => () -> (x = opaque(2.5); println(sin(x), " ", exp(x), " ", x^3, " ", sqrt(x), " ", log(x), " ", atan(x, 2.0)); 0),
    "strings"     => () -> (s = join(string.(1:opaque(5)), ","); println(uppercase(s), " ", length(s), " ", split(s, ",")); 0),
    "collections" => () -> (d = Dict{Int,String}(i => string(i^2) for i in 1:opaque(5)); println(sort(collect(d))); println(sum(length.(values(d)))); 0),
    "structs"     => () -> (v = [(i, i / 2, "n$i") for i in 1:opaque(3)]; println(v); 0),
    "caught"      => () -> (try; parse(Int, opaque("x")); catch e; showerror(STDERR, e); println(STDERR); end; println("after"); 0),
    "churn"       => () -> (keep = Vector{Vector{Int}}(); s = 0; for i in 1:opaque(20000); x = fill(i, 100); s += x[50]; i % 1000 == 0 && push!(keep, x); end; println(s, " ", length(keep), " ", sum(sum, keep)); 0),
    "int128"      => () -> (x = UInt128(opaque(123456789)) * UInt128(0x9e3779b97f4a7c15); y = x * x + UInt128(opaque(7)); z = Int128(y >> 3) * Int128(opaque(-5)); h = UInt64(0); for i in 1:opaque(1000); h = UInt64((UInt128(h + i) * 0xff51afd7ed558ccd) >> 64) ⊻ h; end; println(x, " ", y, " ", z, " ", h, " ", div(y, UInt128(opaque(1000003))), " ", rem(z, Int128(opaque(97)))); 0),
    "half"        => () -> (n = opaque(5); h = [Float16(Float32(i) * 0.1f0 + 1f-6 * i^3) for i in 0:n*400]; println(sum(Float32, h), " ", reinterpret(UInt16, h[end]), " ", [reinterpret(UInt16, Float16(x)) for x in (1f-8, 6f-8, 6.1f-5, 65504f0, 65520f0, Inf32, -0f0, 3.1415927f0)], " ", Float32(Float16(opaque(65519f0)))); 0),
    "exit status" => () -> (println("bye"); 3),
    "memory"      => () -> (v = [Vector{Int}(undef, opaque(1000)) for _ in 1:opaque(200)]; println(length(v), " ", sum(length, v)); 0),
    "files"       => () -> (f = tempname(); write(f, "abc"); println(read(f, String), " ", filesize(f), " ", isfile(f)); rm(f); println(isfile(f)); 0),
    "file io"     => () -> (d = mktempdir(); f = joinpath(d, "lines.txt"); open(f, "w") do io; for i in 1:opaque(5); println(io, "line ", i, " ", i^2); end; end; open(f, "a") do io; print(io, "tail"); end; println(readlines(f)); println(filesize(f), " ", count(==('\n'), read(f, String))); g = joinpath(d, "moved.txt"); mv(f, g); println(isfile(f), isfile(g)); open(g) do io; println(readline(io)); seek(io, 5); println(read(io, 6)); println(position(io), " ", eof(io)); end; println(sort(readdir(d))); rm(d; recursive = true); println(ispath(d)); 0),
    "file errors" => () -> (d = mktempdir(); for f in (() -> open(joinpath(d, "missing")), () -> read(joinpath(d, "missing"), String), () -> mkdir(d), () -> rm(joinpath(d, "missing"))); try; f(); println("no error"); catch e; println(typeof(e), " ", sprint(showerror, e) == "" ? "empty" : "message"); end; end; try; open(joinpath(d, "missing")); catch e; println(e isa SystemError ? e.errnum : -1, " ", e isa SystemError ? Base.Libc.strerror(e.errnum) : ""); end; rm(d; recursive = true); 0),
    "libm"        => () -> (x = opaque(0.5); println(round(ccall(:erfc, Float64, (Float64,), x), digits = 9), " ", round(ccall(:erf, Float64, (Float64,), x + 1.0), digits = 9), " ", round(ccall(:tgamma, Float64, (Float64,), x + 2.5), digits = 8), " ", round(ccall(:lgamma, Float64, (Float64,), x + 10.0), digits = 8), " ", round(ccall(:erfc, Float64, (Float64,), x + 3.0), sigdigits = 8)); 0),
    "vectors"     => () -> (v = UInt8[(i * 37) % 251 for i in 1:opaque(1000)]; h = UInt32(0); for b in v; h = (h << 5 | h >> 27) ⊻ UInt32(b); end; println(sum(Int, v), " ", h, " ", round(sum(abs2, Float64.(v) ./ 7); digits = 6), " ", maximum(v), " ", count(>(100), v)); 0),
    "linear algebra" => () -> (A = [4.0 3 2; 6 3 opaque(1.0); 2 1 5]; b = [1.0, 2, 3]; S = [4.0 2 1; 2 5 3; 1 3 6]; r(x) = round.(x; digits = 9) .+ 0.0;
                               println(r(A \ b), " ", r(inv(A)), " ", round(det(A); digits = 9), " ", r(cholesky(S) \ b), " ", r(A * S), " ", r(A' * b), " ", round(dot(b, A * b); digits = 9), " ", round(norm(A); digits = 9)); 0),
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
        exe = try
            Base.invokelatest(compile_executable, main, entry, dir, string(nameof(main)); target, filename = "exe")
        catch e
            # (what the target does not have is refused when making the program: it is not one to check)
            e isa ArgumentError || rethrow()
            println("refused ", name, ": ", first(split(e.msg, '\n')))
            rm(dir; recursive = true)
            continue
        end
        native = Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); filename = "native")
        out, err = joinpath(dir, "stdout"), joinpath(dir, "stderr")
        p = run(ignorestatus(pipeline(`$native`; stdout = out, stderr = err)))
        write(joinpath(dir, "status"), string(p.exitcode))
        println("built ", name, " (", filesize(exe), " bytes)")
    end
end

length(ARGS) >= 2 || error("usage: julia --project=. test/cross/build.jl <triple> <outdir> [sysroot]")
build(ARGS[1], ARGS[2], length(ARGS) >= 3 ? ARGS[3] : nothing)
