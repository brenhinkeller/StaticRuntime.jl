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
        main = StaticRuntime.make_main(() -> (println("hello"); try; parse(Int, opaque("x")); catch e; showerror(STDERR, e); end; 0))
        entry = (Int, Ptr{Ptr{UInt8}})
        for triple in ("aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu")
            dir = mktempdir()
            ll = Base.invokelatest(compile_executable, main, entry, dir, string(nameof(main)); target = triple, output = :llvmir)
            text = read(ll, String)
            @test occursin("target triple = \"$triple\"", text)
            @test !occursin("target datalayout", text)
            @test occursin(r"define i32 @main\(i32", text)
            if Sys.isapple()
                @test occursin("@stdout", text) && !occursin("__stdoutp", text) && occursin("@stderr", text)
                @test occursin("@__sigsetjmp", text) && !occursin(r"@sigsetjmp\b", text)
                @test !occursin("pthread_get_stack", text) && !occursin(r"@__error\b", text)
            end
        end
        if StaticRuntime.julia_llvm_has("aarch64-unknown-linux-gnu")
            obj = Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); target = "aarch64-unknown-linux-gnu", output = :object)
            bytes = read(obj)
            @test bytes[1:4] == UInt8[0x7f, 0x45, 0x4c, 0x46] # ELF
            @test reinterpret(UInt16, bytes[19:20])[1] == 183 # EM_AARCH64
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
