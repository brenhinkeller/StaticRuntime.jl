# Cross-compilation infrastructure, stopping short of any full compilation (see test/cross instead)

using Glibc_jll, Pkg # (the extension of StaticCompiler that fetches the glibc of a Linux target, for any host: `sysroot = :glibc`)

# `output = :llvmir` and `:object` are for any target, the host's own too (and none: the default), where there is no other system to be made for
@testset "Output for the host's own target" begin
    # (what is made for a target that is not the host's has no vectors that only the host's CPU has, as the scalable ones of SVE)
    generic = StaticRuntime.generic_host_target()
    @test generic.machine.cpu == "generic" && StaticRuntime.StaticCompiler.target_triple(generic) == StaticRuntime.StaticCompiler.target_triple(StaticRuntime.default_target())
    main = StaticRuntime.make_main(() -> (println("hello"); 0))
    entry = (Int, Ptr{Ptr{UInt8}})
    host = StaticRuntime.StaticCompiler.target_triple(StaticRuntime.default_target())
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

# the module of the program is made for the target by LLVM operations (`finalize_cross_module!`), which these check without a tool or a target: the names of the C library of the system, the setjmp of WebAssembly,
# the standard streams and the top of the stack
# `cross_target` is StaticCompiler's `StaticTarget`: made for by retargeting (the triple, the CPU and the features of the target), with the toolchain that links it
@testset "A target is a StaticTarget" begin
    SC = StaticRuntime.StaticCompiler
    linux = StaticRuntime.cross_target("aarch64-unknown-linux-gnu"; sysroot = "/some/root", cflags = `-lfoo`, cpu = "cortex-a72", features = "+neon")
    @test linux isa SC.StaticTarget && SC.is_retargeted(linux) && SC.target_triple(linux) == "aarch64-unknown-linux-gnu"
    @test linux.machine.cpu == "cortex-a72" && linux.machine.features == "+neon" && isnothing(linux.llc)
    @test linux.toolchain isa SC.LLDToolchain && linux.toolchain.flavor === :gnu && linux.toolchain.sysroot == "/some/root" && occursin("-lfoo", string(linux.toolchain.flags)) # (`cflags` are the linker's flags)
    wasm = StaticRuntime.cross_target("wasm64-unknown-unknown"; cflags = `--max-memory=65536`)
    @test wasm.toolchain isa SC.LLDToolchain && wasm.toolchain.flavor === :wasm && occursin("--max-memory=65536", string(wasm.toolchain.flags)) && occursin("stack-size", string(wasm.toolchain.flags))
    @test wasm.machine.features == StaticRuntime.WASM_FEATURES # (the features that WebAssembly needs, if none are given)
    @test StaticRuntime.cross_target("wasm64-unknown-unknown"; features = "+simd128").machine.features == "+simd128"
    mac = StaticRuntime.cross_target("x86_64-apple-macosx11.0.0"; sysroot = "/some/sdk", llc = "myllc")
    if Sys.isapple() && !isnothing(Sys.which("clang"))
        @test mac.toolchain isa SC.CCToolchain && mac.toolchain.builtins && occursin("/some/sdk", string(mac.toolchain.cc)) && occursin("--target=x86_64-apple-macosx11.0.0", string(mac.toolchain.cc)) # (on a Mac: Apple's `clang` and linker)
        @test StaticRuntime.small_flags(mac.toolchain, :macos) == `-Wl,-x -Wl,-no_data_const`
    else
        @test mac.toolchain isa SC.LLDToolchain && mac.toolchain.flavor === :darwin && mac.toolchain.sysroot == "/some/sdk" # (anywhere else: `lld`, with an SDK)
        @test StaticRuntime.small_flags(mac.toolchain, :macos) == `-x -no_data_const`
    end
    @test StaticRuntime.cross_target("x86_64-apple-macosx11.0.0"; cc = "myclang", sysroot = "/some/sdk").toolchain isa SC.CCToolchain # (a `clang` that is given is used)
    @test mac.llc == `myllc`
    # (what is missing is said when the program is linked: the IR and the objects need neither the SDK nor the C library)
    @test StaticRuntime.cross_target("aarch64-unknown-linux-gnu").toolchain isa StaticRuntime.NoLinker
    @test_throws ArgumentError StaticRuntime.cross_link(StaticRuntime.cross_target("aarch64-unknown-linux-gnu"), "a.o", "a", false, ``)
    @test_throws ArgumentError StaticRuntime.cross_link(StaticRuntime.cross_target("x86_64-pc-windows-msvc"), "a.o", "a", false, ``)
    # the host's own triple is the host's target, and a `StaticTarget` of another system than the host's is made for by retargeting, with the toolchain that it has
    host = StaticRuntime.default_target()
    @test StaticRuntime.resolve_target(string(first(split(StaticRuntime.StaticCompiler.target_triple(host), '-')), "-", Sys.isapple() ? "apple-macosx11.0.0" : "unknown-linux-gnu")) isa SC.StaticTarget
    other = SC.StaticTarget(Sys.isapple() ? "aarch64-unknown-linux-gnu" : "aarch64-apple-macosx11.0.0"; toolchain = SC.LLDToolchain(:gnu; sysroot = "/mine"))
    resolved = StaticRuntime.resolve_target(other)
    @test StaticRuntime.is_cross(resolved) && resolved.toolchain.sysroot == "/mine" && !StaticRuntime.is_cross(host)
    @test StaticRuntime.resolve_target(resolved) === resolved
end

# a Linux target's C library is the glibc of its platform, by the extension of StaticCompiler for `Glibc_jll` (fetched for any host)
@testset "sysroot = :glibc" begin
    # (without the extension, which is loaded here (above), the request is refused and says what to load: in a process of its own)
    code = "using StaticRuntime; try; StaticRuntime.cross_target(\"aarch64-unknown-linux-gnu\"; sysroot = :glibc); print(\"no error\"); catch e; print(e isa ArgumentError && occursin(\"Glibc_jll\", e.msg)); end"
    @test read(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $code`, String) == "true"
    t = Base.invokelatest(() -> StaticRuntime.cross_target("aarch64-unknown-linux-gnu"; sysroot = :glibc))
    sysroot = t.toolchain.sysroot # (the toolchain that links it has it)
    @test t.toolchain isa StaticRuntime.StaticCompiler.LLDToolchain && sysroot isa String && isdir(sysroot) && isfile(joinpath(StaticRuntime.StaticCompiler.crt_directory(sysroot), "crt1.o"))
    @test Base.invokelatest(() -> StaticRuntime.cross_target("aarch64-unknown-linux-gnu"; sysroot = "/some/root").toolchain.sysroot) == "/some/root"
end

# a link that fails for a function that the glibc has not says why it may (the glibc that is pinned can be older than the program needs)
@testset "A link that the glibc is too old for" begin
    SC = StaticRuntime.StaticCompiler
    arch = String(first(split(LLVM.default_triple(), '-')))
    triple = "$arch-unknown-linux-gnu"
    sysroot = Base.invokelatest(() -> StaticRuntime.StaticCompiler.glibc_sysroot(triple))
    target = StaticRuntime.cross_target(triple; sysroot)
    # (a function that is called by its name, as the runtime does, so that the symbol is what the linker is asked for: `ccall(:name, ...)` is a lookup by the runtime of Julia, and the link would fail for that)
    entry(argc::Int, argv::Ptr{Ptr{UInt8}}) = ccall("extern a_function_that_no_glibc_has", llvmcall, Int, ())
    dir = mktempdir()
    _, obj = SC.generate_obj(((entry, Tuple{Int,Ptr{Ptr{UInt8}}}),), dir, "entry"; target = SC.StaticTarget(triple; retarget = true, toolchain = target.toolchain), main_wrapper = SC.fix_name(entry))
    # (what `lld` says goes to a file, and not to the log of the tests: it is what is checked, and it is an error that is meant)
    logger = Test.TestLogger(; min_level = Base.CoreLogging.Warn)
    lld_output = joinpath(dir, "lld.log")
    failed = open(lld_output, "w") do io
        redirect_stderr(io) do
            Test.with_logger(logger) do
                try
                    StaticRuntime.cross_link(target, obj, joinpath(dir, "entry_exe"), false, ``)
                    false
                catch e
                    e isa ProcessFailedException
                end
            end
        end
    end
    @test failed
    @test occursin("undefined symbol: a_function_that_no_glibc_has", read(lld_output, String))
    # (the warning, with the version of the glibc that was linked with)
    v = SC.glibc_version(sysroot)
    @test any(r -> r.level == Base.CoreLogging.Warn && occursin("glibc", string(r.message)) && occursin("version $v", string(r.message)) && occursin("2.29", string(r.message)), logger.logs)
end

@testset "The module for the target" begin
    parse_module(text) = parse(LLVM.Module, text)
    LLVM.@dispose ctx = LLVM.Context() begin
        # Linux: the names that its C library has
        m = parse_module("@__stdoutp = external global ptr\n@__stderrp = external global ptr\ndeclare i32 @sigsetjmp(ptr, i32)\ndefine ptr @f() {\n  %p = load ptr, ptr @__stdoutp\n  ret ptr %p\n}\n")
        StaticRuntime.rename_system_symbols!(m, :linux)
        text = string(m)
        @test occursin("@stdout", text) && occursin("@stderr", text) && occursin("@__sigsetjmp", text) && !occursin("__stdoutp", text) && !occursin(r"@sigsetjmp\b", text)
        LLVM.dispose(m)
        # (a name that is there already: the uses go to it)
        m = parse_module("@stdout = external global ptr\n@__stdoutp = external global ptr\ndefine ptr @f() {\n  %p = load ptr, ptr @__stdoutp\n  ret ptr %p\n}\n")
        StaticRuntime.rename_system_symbols!(m, :linux)
        @test count("@stdout", string(m)) == 2 && !occursin("__stdoutp", string(m))
        LLVM.dispose(m)
        # what the other system has and this has not is refused, as is what the host's packages chose for the host's system
        m = parse_module("declare ptr @_NSGetEnviron()\n")
        @test_throws ArgumentError StaticRuntime.rename_system_symbols!(m, :linux)
        LLVM.dispose(m)
        m = parse_module("declare i64 @mmap(ptr, i64, i32, i32, i32, i64)\n")
        @test_throws ArgumentError StaticRuntime.rename_system_symbols!(m, :wasm)
        LLVM.dispose(m)

        # WebAssembly: `setjmp` and `longjmp` by those names, `setjmp` that takes the buffer only and returns twice (Linux's name too)
        for setjmp in ("sigsetjmp", "__sigsetjmp")
            m = parse_module("declare i32 @$setjmp(ptr, i32) returns_twice\ndeclare void @siglongjmp(ptr, i32) noreturn\ndefine i32 @g(ptr %buf) {\n  %r = call i32 @$setjmp(ptr %buf, i32 0) returns_twice\n  ret i32 %r\n}\n")
            StaticRuntime.wasm_sjlj!(m)
            text = string(m)
            @test occursin(r"call i32 @setjmp\(ptr %buf\)", text) && occursin("returns_twice", text) && occursin("@longjmp", text) && !occursin("sigsetjmp", text) && !occursin("siglongjmp", text)
            @test LLVM.verify(m) === nothing
            LLVM.dispose(m)
        end
        # the streams are the numbers of the descriptors, and the top of the stack is a variable of the module
        m = parse_module("@__stdoutp = external global ptr\n@stderr = external global ptr\n@__stdinp = external global ptr\n@_static_wasm_stack_top = external global ptr\n")
        StaticRuntime.define_wasm_streams!(m)
        StaticRuntime.define_wasm_stack_top!(m)
        text = string(m)
        @test occursin("@__stdoutp = global ptr inttoptr (i64 1 to ptr)", text) && occursin("@stderr = global ptr inttoptr (i64 2 to ptr)", text) && occursin("@__stdinp = global ptr null", text) # (descriptor 0 is the null pointer, as LLVM writes it)
        @test !LLVM.isdeclaration(LLVM.globals(m)["_static_wasm_stack_top"]) && occursin("@_static_wasm_stack_top = global ptr null", text)
        LLVM.dispose(m)
    end
end

@testset "what is refused" begin
    # (the IR of the host is refused by `StaticCompiler.retarget!`, which a program of the host's intrinsics for another architecture meets)
    @test_throws ArgumentError StaticRuntime.cross_link(StaticRuntime.cross_target("x86_64-pc-windows-msvc"), "a.o", "a", false, ``)
end
