# Programs made for another system or architecture than the host's, and run here: they do what they do when made for the host. Every target that this machine can make and run is tried, and the targets that
# cannot are skipped one by one, with the reason in the log (`support.jl` says what a target needs, and fetches what it can: see `host.jl`). The programs are those of `programs.jl`, which the matrix of CI makes for
# every target of every kind of host (`matrix.jl`).

# (what a target of a system is, in the output of `file`)
file_arch(arch) = arch == "x86_64" ? r"x86[-_]64" : r"arm64|aarch64"

# the programs that are made for each target that can be made and run here: they print and exit as the ones made for the host do
@testset verbose=true "Programs for another target, run here" begin
    quick = [p for p in CrossPrograms.PROGRAMS if first(p) in CrossPrograms.QUICK]
    entry = (Int, Ptr{Ptr{UInt8}})
    tried = String[]
    for triple in CROSS_TARGETS
        runs_here(triple) || @info "Programs for $triple cannot be run here; testing compilation only"
        target, why = target_for(triple)
        if target === nothing
            @info "Cross-compilation to $triple is not run: $why"
            continue
        end
        push!(tried, triple)
        @testset "$triple (run=$(runs_here(triple)))" begin
            for (name, f) in quick
                @testset "$name" begin
                    main = StaticRuntime.make_main(f)
                    native = compile_executable(main, entry, mktempdir(), string(nameof(main)); filename = "native")
                    dir = mktempdir()
                    crossed = Base.invokelatest(compile_executable, main, entry, dir, string(nameof(main)); target, filename = "exe")
                    command = triple_system(triple) == "wasm" ? `$(node_command()) $(joinpath(dir, "exe.mjs"))` : `$crossed`
                    if runs_here(triple)
                        @test run_program(command) == run_program(`$native`)
                    else
                        @test isfile(crossed)
                    end
                    if triple_system(triple) != "wasm" && Sys.which("file") !== nothing
                        @test occursin(file_arch(triple_arch(triple)), read(`file $crossed`, String))
                    end
                end
            end
        end
    end
    @info "Cross-compilation attempted for: $(isempty(tried) ? "no target" : join(tried, ", "))"
end

# a program for WebAssembly (wasm64): the module and its host are made with Julia's own LLVM and its `lld`; what it does is checked with Node.js 24 or later (`STATIC_RUNTIME_NODE`, the path of `node`; else fetched) where there is one
@testset "A program for WebAssembly" begin
    node = node_command() # (`STATIC_RUNTIME_NODE`, a `node` that is 24 or later, or the one of `NodeJS_24_jll`, fetched)
    node === nothing && @info "The programs for WebAssembly are not run: no Node.js 24 or later (`STATIC_RUNTIME_NODE`)"
    entry = (Int, Ptr{Ptr{UInt8}})
    # the module and its host are files of their own (`prog.wasm` and `prog.mjs`): what the program does is checked with the others, for every target (the loop above, and `test/cross/matrix.jl`)
    main = StaticRuntime.make_main(CrossPrograms.program("hello"))
    dir = mktempdir()
    wasm = Base.invokelatest(compile_executable, main, entry, dir, string(nameof(main)); target = "wasm64-unknown-unknown", filename = "prog", gc = false)
    @test endswith(wasm, "prog.wasm") && isfile(wasm) && isfile(joinpath(dir, "prog.mjs"))
    @test read(wasm)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d] # \0asm
    # what the host does not have is refused when the program is made, with what it is (starting a process, here)
    spawn = StaticRuntime.make_main(() -> (run(`echo hi`); 0))
    err = try; Base.invokelatest(compile_executable, spawn, entry, mktempdir(), string(nameof(spawn)); target = "wasm64-unknown-unknown", gc = false); nothing; catch e; e; end
    @test err isa ArgumentError && occursin(r"`posix_spawn", err.msg) && occursin("a program for WebAssembly does not have", err.msg)
    # memory: the collector of the runtime is in a program for WebAssembly that needs it (one that allocates in a loop), and finds what is in use in the frames of the functions, where the
    # pointers that functions keep in locals are stored before a call that can collect (`spill_gc_roots!`)
    churn = StaticRuntime.make_main(CrossPrograms.program("churn"))
    collected = Base.invokelatest(compile_executable, churn, entry, mktempdir(), string(nameof(churn)); target = "wasm64-unknown-unknown", gc = true)
    @test read(collected)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    if node !== nothing
        native = Base.invokelatest(compile_executable, churn, entry, mktempdir(), string(nameof(churn)); filename = "native", gc = false)
        expected = run_program(`$native`)
        # (in stress mode: a collection every 3 allocations, and what is freed is overwritten, so a pointer that the collector does not find shows)
        for gc in (true, 3)
            dir = mktempdir()
            Base.invokelatest(compile_executable, churn, entry, dir, string(nameof(churn)); target = "wasm64-unknown-unknown", filename = "churn", gc)
            @test run_program(`$node $(joinpath(dir, "churn.mjs"))`) == expected
        end
        # (the memory has a limit: with the collector a program that allocates 180 MB in all fits in 32 MiB, and without it the program does not)
        long = StaticRuntime.make_main(() -> (keep = Vector{Vector{Int}}(); s = 0; for i in 1:opaque(200000); x = fill(i, 100); s += x[50]; i % 1000 == 0 && push!(keep, x); end; println(s, " ", length(keep), " ", sum(sum, keep)); 0))
        long_native = Base.invokelatest(compile_executable, long, entry, mktempdir(), string(nameof(long)); filename = "native", gc = false)
        long_expected = run_program(`$long_native`)
        for (gc, ok) in ((true, true), (false, false))
            dir = mktempdir()
            Base.invokelatest(compile_executable, long, entry, dir, string(nameof(long)); target = cross_target("wasm64-unknown-unknown"; cflags = `--max-memory=33554432`), filename = "long", gc)
            out, err, code = run_program(`$node $(joinpath(dir, "long.mjs"))`)
            @test ok ? (out, err, code) == long_expected : (code == 1 && occursin("Out of memory error", err))
        end
    end
    # (the memory has a limit, which the program meets as a native one does when the system has no more: "Out of memory error", status 1)
    if node !== nothing
        big = StaticRuntime.make_main(() -> (v = [zeros(UInt8, 10_000_000) for _ in 1:opaque(100)]; println(length(v)); 0))
        dir = mktempdir()
        Base.invokelatest(compile_executable, big, entry, dir, string(nameof(big)); target = cross_target("wasm64-unknown-unknown"; cflags = `--max-memory=67108864`), filename = "big", gc = false)
        out, err = tempname(), tempname()
        p = run(ignorestatus(pipeline(`$node $(joinpath(dir, "big.mjs"))`; stdout = out, stderr = err)))
        @test p.exitcode == 1 && occursin("Out of memory error", read(err, String)) && isempty(read(out, String))
    end
end
