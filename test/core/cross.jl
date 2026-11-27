# Cross-compilation (src/cross.jl): programs made for another architecture than the host's do what they do when made for the host. Which targets can be tried here depends on what the machine
# can run, and on an `llc` of the version of Julia's LLVM that has the code generator for the target (next to the `clang` of `STATIC_RUNTIME_CROSS_CLANG`, or `STATIC_RUNTIME_CROSS_LLC`); without them these are not run. Today: x86-64 macOS from an
# Apple Silicon Mac (run by Rosetta).

cross_triple() = Sys.isapple() && Sys.ARCH === :aarch64 ? "x86_64-apple-macosx11.0.0" : Sys.isapple() && Sys.ARCH === :x86_64 ? "aarch64-apple-macosx11.0.0" : nothing

function cross_available(triple)
    triple === nothing && return false
    Sys.isapple() || return false
    # (a program for x86-64 runs on Apple Silicon with Rosetta; there is nothing that runs a program for Apple Silicon on an Intel Mac)
    triple_arch = first(split(triple, '-'))
    triple_arch == "x86_64" && Sys.ARCH === :aarch64 || return false
    haskey(ENV, "STATIC_RUNTIME_CROSS_CLANG") || return false
    llc = joinpath(dirname(ENV["STATIC_RUNTIME_CROSS_CLANG"]), "llc")
    ok = isfile(llc) && first(StaticRuntime.llc_supports(Cmd([llc]), "x86_64"))
    ok || return false
    return success(pipeline(`arch -x86_64 /usr/bin/true`; stderr = devnull))
end

@testset "Cross-compilation" begin
    triple = cross_triple()
    if !cross_available(triple)
        @info "Cross-compilation tests are skipped (they need an Apple Silicon Mac with Rosetta and an llc of Julia's LLVM version for x86-64, `STATIC_RUNTIME_CROSS_CLANG`)"
    else
        cases = [
            "hello"       => () -> (println("hello, world"); 0),
            "arithmetic"  => () -> (s = 0; for i in 1:opaque(1000); s += i * i % 7; end; println(s); 0),
            "floats"      => () -> (x = opaque(2.5); println(sin(x), " ", exp(x), " ", x^3, " ", sqrt(x), " ", round(x * 1e6) / 1e6); 0),
            "strings"     => () -> (s = join(string.(1:opaque(5)), ","); println(uppercase(s), " ", length(s), " ", split(s, ",")); 0),
            "collections" => () -> (d = Dict{Int,String}(i => string(i^2) for i in 1:opaque(5)); println(sort(collect(d))); println(sum(values(d) .|> length)); 0),
            "structs"     => () -> (v = [(i, i / 2, "n$i") for i in 1:opaque(3)]; println(v); 0),
            "caught"      => () -> (try; parse(Int, opaque("x")); catch e; showerror(STDERR, e); println(STDERR); end; println("after"); 0),
            "exit status" => () -> (println("bye"); 3),
        ]
        for (name, f) in cases
            @testset "$name" begin
                main = StaticRuntime.make_main(f)
                native = compile_executable(main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
                crossed = compile_executable(main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)); target = triple)
                run_one(exe) = (out = tempname(); err = tempname(); p = run(ignorestatus(pipeline(`$exe`; stdout = out, stderr = err))); (read(out, String), read(err, String), p.exitcode))
                @test run_one(crossed) == run_one(native)
                @test occursin("x86_64", read(`file $crossed`, String))
            end
        end
    end
    # a program for Linux, made on any host: the IR has the names that Linux's C library has (on a macOS host, the code of the program for macOS is replaced by that for Linux), and the object, where Julia's
    # LLVM has the code generator for it (AArch64, on an Apple Silicon Mac), is an ELF file for it. These need no tools but Julia.
    @testset "A program for Linux" begin
        host_triple = LLVM.triple(StaticRuntime.default_target().tm)
        main = StaticRuntime.make_main(() -> (println("hello"); try; parse(Int, opaque("x")); catch e; showerror(STDERR, e); end; 0))
        entry = (Int, Ptr{Ptr{UInt8}})
        for triple in ("aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu")
            dir = mktempdir()
            ll = Base.invokelatest(compile_executable, main, entry, dir, string(nameof(main)); target = triple, output = :llvmir)
            text = read(ll, String)
            has(pattern) = occursin(pattern, text) # (so that a failure does not print all of the IR)
            # (a triple of the host's own system is the host's, spelled as LLVM does: `aarch64-linux-gnu`)
            @test LLVM.normalize(String(match(r"target triple = \"([^\"]+)\"", text)[1])) == LLVM.normalize(triple)
            @test !has("target datalayout") || LLVM.normalize(triple) == LLVM.normalize(host_triple)
            @test has(r"define i32 @main\(i32")
            if Sys.isapple()
                @test has("@stdout") && !has("__stdoutp") && has("@stderr")
                @test has("@__sigsetjmp") && !has(r"@sigsetjmp\b")
                @test !has("pthread_get_stack") && !has(r"@__error\b")
            end
        end
        if StaticRuntime.julia_llvm_has("aarch64-unknown-linux-gnu")
            obj = Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); target = "aarch64-unknown-linux-gnu", output = :object)
            bytes = read(obj)
            @test bytes[1:4] == UInt8[0x7f, 0x45, 0x4c, 0x46] # ELF
            @test reinterpret(UInt16, bytes[19:20])[1] == 183 # EM_AARCH64
        end
    end

    # a program for WebAssembly (wasm64): the module and its host are made with Julia's own LLVM and its `lld`; what it does is checked with Node.js 24 or later (`STATIC_RUNTIME_NODE`, the path of `node`) where there is one
    @testset "A program for WebAssembly" begin
        entry = (Int, Ptr{Ptr{UInt8}})
        main = StaticRuntime.make_main(() -> (println("hello, ", opaque(6) * 7); try; parse(Int, opaque("x")); catch e; showerror(STDERR, e); println(STDERR); end; println(sin(opaque(2.5))); 3))
        dir = mktempdir()
        wasm = Base.invokelatest(compile_executable, main, entry, dir, string(nameof(main)); target = "wasm64-unknown-unknown", filename = "prog", gc = false)
        @test endswith(wasm, "prog.wasm") && isfile(wasm) && isfile(joinpath(dir, "prog.mjs"))
        @test read(wasm)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d] # \0asm
        if haskey(ENV, "STATIC_RUNTIME_NODE")
            native = Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); filename = "native")
            run_one(cmd) = (out = tempname(); err = tempname(); p = run(ignorestatus(pipeline(cmd; stdout = out, stderr = err))); (read(out, String), read(err, String), p.exitcode))
            @test run_one(`$(ENV["STATIC_RUNTIME_NODE"]) $(joinpath(dir, "prog.mjs"))`) == run_one(`$native`)
        end
        # files and directories are the host's (Node's `fs`): a program that uses them does what the native one does
        if haskey(ENV, "STATIC_RUNTIME_NODE")
            fileio = StaticRuntime.make_main(() -> (d = mktempdir(); f = joinpath(d, "a.txt"); open(f, "w") do io; for i in 1:opaque(3); println(io, "line ", i); end; end; open(f, "a") do io; print(io, "tail"); end; println(readlines(f), " ", filesize(f)); mkdir(joinpath(d, "sub")); println(sort(readdir(d))); try; open(joinpath(d, "missing")); catch e; println(e isa SystemError ? e.errnum : -1); end; rm(d; recursive = true); println(ispath(d)); 0))
            dir = mktempdir()
            Base.invokelatest(compile_executable, fileio, entry, dir, string(nameof(fileio)); target = "wasm64-unknown-unknown", filename = "fileio", gc = false)
            native = Base.invokelatest(compile_executable, fileio, entry, mktempdir(), string(nameof(fileio)); filename = "native", gc = false)
            run_one(cmd) = (out = tempname(); err = tempname(); p = run(ignorestatus(pipeline(cmd; stdout = out, stderr = err))); (read(out, String), read(err, String), p.exitcode))
            @test run_one(`$(ENV["STATIC_RUNTIME_NODE"]) $(joinpath(dir, "fileio.mjs"))`) == run_one(`$native`)
        end
        # what the host does not have is refused when the program is made, with what it is (starting a process, here)
        spawn = StaticRuntime.make_main(() -> (run(`echo hi`); 0))
        err = try; Base.invokelatest(compile_executable, spawn, entry, mktempdir(), string(nameof(spawn)); target = "wasm64-unknown-unknown", gc = false); nothing; catch e; e; end
        @test err isa ArgumentError && occursin(r"`posix_spawn", err.msg) && occursin("a program for WebAssembly does not have", err.msg)
        # memory: the collector of the runtime is in a program for WebAssembly that needs it (one that allocates in a loop), and finds what is in use in the frames of the functions, where the
        # pointers that functions keep in locals are stored before a call that can collect (`spill_gc_roots!`)
        churn = StaticRuntime.make_main(() -> (keep = Vector{Vector{Int}}(); s = 0; for i in 1:opaque(20000); x = fill(i, 100); s += x[50]; i % 1000 == 0 && push!(keep, x); end; println(s, " ", length(keep), " ", sum(sum, keep)); 0))
        collected = Base.invokelatest(compile_executable, churn, entry, mktempdir(), string(nameof(churn)); target = "wasm64-unknown-unknown", gc = true)
        @test read(collected)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
        if haskey(ENV, "STATIC_RUNTIME_NODE")
            native = Base.invokelatest(compile_executable, churn, entry, mktempdir(), string(nameof(churn)); filename = "native", gc = false)
            run_one(cmd) = (out = tempname(); err = tempname(); p = run(ignorestatus(pipeline(cmd; stdout = out, stderr = err))); (read(out, String), read(err, String), p.exitcode))
            expected = run_one(`$native`)
            # (in stress mode: a collection every 3 allocations, and what is freed is overwritten, so a pointer that the collector does not find shows)
            for gc in (true, 3)
                dir = mktempdir()
                Base.invokelatest(compile_executable, churn, entry, dir, string(nameof(churn)); target = "wasm64-unknown-unknown", filename = "churn", gc)
                @test run_one(`$(ENV["STATIC_RUNTIME_NODE"]) $(joinpath(dir, "churn.mjs"))`) == expected
            end
            # (the memory has a limit: with the collector a program that allocates 180 MB in all fits in 32 MiB, and without it the program does not)
            long = StaticRuntime.make_main(() -> (keep = Vector{Vector{Int}}(); s = 0; for i in 1:opaque(200000); x = fill(i, 100); s += x[50]; i % 1000 == 0 && push!(keep, x); end; println(s, " ", length(keep), " ", sum(sum, keep)); 0))
            long_native = Base.invokelatest(compile_executable, long, entry, mktempdir(), string(nameof(long)); filename = "native", gc = false)
            long_expected = run_one(`$long_native`)
            for (gc, ok) in ((true, true), (false, false))
                dir = mktempdir()
                Base.invokelatest(compile_executable, long, entry, dir, string(nameof(long)); target = cross_target("wasm64-unknown-unknown"; cflags = `--max-memory=33554432`), filename = "long", gc)
                out, err, code = run_one(`$(ENV["STATIC_RUNTIME_NODE"]) $(joinpath(dir, "long.mjs"))`)
                @test ok ? (out, err, code) == long_expected : (code == 1 && occursin("Out of memory error", err))
            end
        end
        # (the memory has a limit, which the program meets as a native one does when the system has no more: "Out of memory error", status 1)
        if haskey(ENV, "STATIC_RUNTIME_NODE")
            big = StaticRuntime.make_main(() -> (v = [zeros(UInt8, 10_000_000) for _ in 1:opaque(100)]; println(length(v)); 0))
            dir = mktempdir()
            Base.invokelatest(compile_executable, big, entry, dir, string(nameof(big)); target = cross_target("wasm64-unknown-unknown"; cflags = `--max-memory=67108864`), filename = "big", gc = false)
            out, err = tempname(), tempname()
            p = run(ignorestatus(pipeline(`$(ENV["STATIC_RUNTIME_NODE"]) $(joinpath(dir, "big.mjs"))`; stdout = out, stderr = err)))
            @test p.exitcode == 1 && occursin("Out of memory error", read(err, String)) && isempty(read(out, String))
        end
    end

    # `output = :llvmir` and `:object` are for any target, the host's own too (and none: the default), where there is no other system to be made for
    @testset "Output for the host's own target" begin
        # (what is made for a target that is not the host's has no vectors that only the host's CPU has, as the scalable ones of SVE)
        generic = StaticRuntime.generic_host_target()
        @test LLVM.cpu(generic.tm) == "generic" && LLVM.triple(generic.tm) == LLVM.triple(StaticRuntime.default_target().tm)
        main = StaticRuntime.make_main(() -> (println("hello"); 0))
        entry = (Int, Ptr{Ptr{UInt8}})
        host = LLVM.triple(StaticRuntime.default_target().tm)
        ll = Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); target = host, output = :llvmir)
        text = read(ll, String)
        @test LLVM.normalize(String(match(r"target triple = \"([^\"]+)\"", text)[1])) == LLVM.normalize(host)
        @test occursin(r"define i32 @main\(i32", text)
        obj = Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); output = :object)
        @test isfile(obj) && filesize(obj) > 1000
    end

    # the kernels of BLAS that are written in Julia (for a program made for another target) fill and read fresh arrays through pointers: the arrays have to be preserved, or the stores that fill them are dropped
    @testset "Level 1 kernels of fresh arrays" begin
        LA = Base.get_extension(StaticRuntime, :StaticRuntimeLinearAlgebraExt)
        if LA !== nothing
            f() = (x = [1.0, 2.0, 3.0]; y = [10.0, 20.0, 30.0]; LA.wasm_axpy!(2.0, x, y); y)
            g() = (x = [3.0, 4.0]; (LA.wasm_nrm2(x), LA.wasm_dot(x, [1.0, 2.0]), LA.wasm_asum([-1.0, 2.0])))
            @test Base.invokelatest(f) == [12.0, 24.0, 36.0]
            @test Base.invokelatest(g) == (5.0, 11.0, 3.0)
        end
    end

    # replacements that a target registers (`replace_on_target!`, e.g. BLAS for WebAssembly) are found only while making a program for that system
    @testset "Replacements are for their target" begin
        f, g = () -> 1, () -> 2
        StaticRuntime.replace_on_target!(:wasm, f, g)
        try
            @test StaticRuntime.target_replacement(f) === nothing # (the host's own program)
            StaticRuntime.replace_on_target!(:cross, f, g)
            @test StaticRuntime.target_replacement(f) === nothing # (still: only for a program that is made for another target)
            @test StaticRuntime.Runtime.with_target(() -> StaticRuntime.target_replacement(f), :linux, :aarch64; cross = true) === g
            delete!(StaticRuntime.TARGET_REPLACEMENTS[:cross], f)
            @test StaticRuntime.Runtime.with_target(() -> StaticRuntime.target_replacement(f), :wasm, :wasm64) === g
            @test StaticRuntime.Runtime.with_target(() -> StaticRuntime.target_replacement(f), :linux, :aarch64) === nothing
            @test StaticRuntime.Runtime.with_target(() -> StaticRuntime.inference_key(StaticRuntime.Compilation(StaticRuntime.Settings())), :wasm, :wasm64) !=
                  StaticRuntime.inference_key(StaticRuntime.Compilation(StaticRuntime.Settings()))
        finally
            delete!(StaticRuntime.TARGET_REPLACEMENTS[:wasm], f); delete!(get(StaticRuntime.TARGET_REPLACEMENTS, :cross, Dict()), f)
        end
    end

    @testset "what is refused" begin
        @test_throws ArgumentError StaticRuntime.retarget_ir("target triple = \"aarch64-apple-macosx11.0.0\"\n%x = call i32 @llvm.aarch64.crc32b(i32 0, i32 0)\n", "x86_64-apple-macosx11.0.0")
        @test StaticRuntime.retarget_ir("target datalayout = \"e\"\ntarget triple = \"aarch64-apple-macosx11.0.0\"\nattributes #0 = { \"target-cpu\"=\"apple-m1\" \"target-features\"=\"+neon\" nounwind }\n", "x86_64-unknown-linux-gnu") ==
            "target triple = \"x86_64-unknown-linux-gnu\"\nattributes #0 = { nounwind }\n"
        @test_throws ArgumentError StaticRuntime.cross_link(StaticRuntime.cross_target("x86_64-pc-windows-msvc"), "a.o", "a", false, ``)
        # (the entry point that the wrapper calls: as the program has it)
        @test occursin("define i32 @main", StaticRuntime.main_wrapper("define i64 @entry(i64 %0, ptr %1) {\n}\n", "entry", "x86_64-apple-macosx11.0.0"))
        @test_throws ArgumentError StaticRuntime.main_wrapper("define i64 @entry(i64 %0) {\n}\n", "entry", "x86_64-apple-macosx11.0.0")
    end
end
