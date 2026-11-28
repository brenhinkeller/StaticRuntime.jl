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
        # macOS: the same the other way, for a program that was made on a host with Linux's names (`stdout`, and glibc's `__sigsetjmp`, which macOS has not: it has `sigsetjmp`)
        m = parse_module("@stdout = external global ptr\n@stderr = external global ptr\ndeclare i32 @__sigsetjmp(ptr, i32)\ndefine ptr @f() {\n  %p = load ptr, ptr @stdout\n  ret ptr %p\n}\n")
        StaticRuntime.rename_system_symbols!(m, :macos)
        text = string(m)
        @test occursin("@__stdoutp", text) && occursin("@__stderrp", text) && occursin(r"@sigsetjmp\b", text) && !occursin(r"@(stdout|stderr)\b", text) && !occursin("@__sigsetjmp", text)
        LLVM.dispose(m)
        # (a name that is there already: the uses go to it)
        m = parse_module("@stdout = external global ptr\n@__stdoutp = external global ptr\ndefine ptr @f() {\n  %p = load ptr, ptr @__stdoutp\n  ret ptr %p\n}\n")
        StaticRuntime.rename_system_symbols!(m, :linux)
        @test count("@stdout", string(m)) == 2 && !occursin("__stdoutp", string(m))
        LLVM.dispose(m)
        # what the other system has and this has not is refused, as is what the host's packages chose for the host's system
        m = parse_module("declare ptr @_NSGetEnviron()\ndefine ptr @f() {\n  %p = call ptr @_NSGetEnviron()\n  ret ptr %p\n}\n")
        @test_throws ArgumentError StaticRuntime.rename_system_symbols!(m, :linux)
        LLVM.dispose(m)
        m = parse_module("declare i64 @mmap(ptr, i64, i32, i32, i32, i64)\ndefine i64 @f() {\n  %p = call i64 @mmap(ptr null, i64 1, i32 1, i32 1, i32 1, i64 0)\n  ret i64 %p\n}\n")
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

# A program for Windows: by the target, in the IR and with no tool that is not Julia (`output = :llvmir`: no code generator for x86-64 is needed, nor the libraries of MinGW-w64), and on any host
@testset "A program for Windows" begin
    triple = "x86_64-w64-mingw32"
    entry = (Int, Ptr{Ptr{UInt8}})
    ir(f) = (main = StaticRuntime.make_main(f); read(Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); target = triple, output = :llvmir), String))
    text = ir(() -> (println("hello, ", opaque(6) * 7); try; parse(Int, opaque("x")); catch e; showerror(STDERR, e); println(STDERR); end; println(time_ns() > 0); 0))
    has(pattern) = occursin(pattern, text) # (so that a failure does not print all of the IR)
    @test has("target triple = \"x86_64-w64-windows-gnu\"") && !has("target datalayout")
    # `try` and `throw` are LLVM's own setjmp and longjmp, which keep five words, and not the `sigsetjmp` that the host's Julia has, which Windows has not (and its `_setjmp` is 256 bytes, which a handler is not)
    @test has("@llvm.eh.sjlj.setjmp") && has("@llvm.eh.sjlj.longjmp") && !has(r"@(sigsetjmp|siglongjmp|__sigsetjmp)\b")
    # (the buffer has the frame register and the stack pointer as well, which the throw puts back: the register that the code addresses its frame by, which on Windows is not `llvm.frameaddress`)
    @test has("movq %rbp, \$0") && has("@llvm.stacksave.p0") && !has("@llvm.frameaddress")
    # the standard streams are what `__iob_func()` has, and no global of macOS or Linux is left
    @test has("@__iob_func") && !has(r"@(__stdoutp|__stderrp|__stdinp|stdout|stderr|stdin)\b")
    # they are binary before the entry point runs: no line feed becomes a carriage return and a line feed
    @test all(has("call i32 @_setmode(i32 $fd, i32 32768)") for fd in 0:2)
    # the collector asks the system for the stack of the thread
    @test has("@GetCurrentThreadStackLimits") && !has(r"@(getrlimit|pthread_self|pthread_get_stackaddr_np|__libc_stack_end)\b")
    # the clock is the performance counter, and the time of day the file time of the system
    @test has("@QueryPerformanceCounter") && !has("@clock_gettime")
    # only what the C library of Windows has, or what is for it: none of what a program for it is refused for
    declared = String[m.captures[1] for m in eachmatch(r"^declare [^@\n]*@\"?([^\"(\s]+)"m, text)]
    @test isempty(intersect(declared, StaticRuntime.ONLY_POSIX)) && isempty(intersect(declared, ["__errno_location", "__error", "pthread_self"]))

    # the C library has not the 128-bit division, nor the conversions of `Float16` where the CPU has not them: the program has them (the conventions of the library calls of Windows: the code generator for it passes
    # the operands by address and takes the result from `xmm0`, and passes a `Float16` in `xmm0`)
    # (a dividend that is larger than 64 bits: the division of what was widened from 64 bits is made in 64)
    text = ir(() -> (x = (UInt128(opaque(1)) << 100) + UInt128(opaque(5)); y = UInt128(opaque(7)); s = Int128(x) * Int128(opaque(-3)); println(x ÷ y, " ", x % y, " ", s ÷ Int128(opaque(5)), " ", s % Int128(opaque(5)), " ", Float16(opaque(2.5f0)) * Float16(opaque(1.5f0))); 0))
    @test has(r"define [^\n]*<2 x i64> @__udivti3\(ptr %pa, ptr %pb\)") && has(r"define [^\n]*half @__truncsfhf2\(float") && has("___chkstk_ms:") # (the probe of the stack, in assembly that the module has)

    # what is not made for Windows yet is refused when the program is made, with what it is: processes, and links (which need a privilege there)
    for (name, f) in ("posix_spawnp" => () -> (run(`echo hi`); 0), "symlink" => () -> (symlink(opaque("a"), opaque("b")); 0), "readlink" => () -> (println(readlink(opaque("a"))); 0))
        spawn = StaticRuntime.make_main(f)
        err = try; Base.invokelatest(compile_executable, spawn, entry, mktempdir(), string(nameof(spawn)); target = triple, output = :llvmir); nothing; catch e; e; end
        @test err isa ArgumentError && occursin(name, err.msg) && occursin("windows", err.msg)
    end

    # the libraries to link with are found when the program is linked, and not when the target is made (nothing is fetched for IR and objects), and a program for the MSVC runtime is refused: it is linked with MinGW-w64's
    @test StaticRuntime.cross_target(triple).toolchain isa StaticRuntime.MinGWToolchain
    @test StaticRuntime.cross_target(triple; sysroot = "/some/root").toolchain isa StaticRuntime.StaticCompiler.LLDToolchain
    @test StaticRuntime.cross_target("x86_64-pc-windows-msvc").toolchain isa StaticRuntime.NoLinker
end

# Files, directories, the environment and the system for Windows (src/overrides/windows.jl). The pure part, which is Julia code that runs here whatever the host is; and the programs, in the IR for the target, with the functions that they
# call: the wide ones of the C library and of Windows, and none that a program for Windows is refused for. The arguments are not constants (a constant is evaluated when the program is compiled, and what is wrong with a call is not seen).
@testset "Files and the system for Windows" begin
    SR = StaticRuntime
    # UTF-8 and UTF-16: what Windows's functions take, and give
    for s in ("", "abc", "héllo wörld", "日本語/テスト.txt", "emoji 😀 and 𝄞", "C:\\Users\\x\\a b.txt")
        w = SR.wide_cstring(s)
        @test w[end] == 0 && SR.narrow_string(w) == s && SR.narrow_string(pointer(w), length(w) - 1) == s
    end
    @test SR.wide_cstring("😀") == UInt16[0xd83d, 0xde00, 0] && SR.wide_cstring("é") == UInt16[0x00e9, 0]
    @test SR.narrow_string(UInt16[0xd83d, 0x0041, 0]) == "\ufffdA" && SR.narrow_string(UInt16[0xdc00, 0]) == "\ufffd" # (half of a pair of surrogates)
    @test SR.windows_trimmed("a/b//") == "a/b" && SR.windows_trimmed("a\\b\\") == "a\\b" && SR.windows_trimmed("/") == "/" && SR.windows_trimmed("C:\\") == "C:\\" && SR.windows_trimmed("C:/") == "C:/" && SR.windows_trimmed("a") == "a"
    # the errors of Windows, as `errno`: the numbers of the C library of Windows (`ENOTEMPTY` is 41, and the numbers of the other systems are not)
    @test SR.windows_errno(UInt32(2)) == 2 && SR.windows_errno(UInt32(3)) == 2 && SR.windows_errno(UInt32(5)) == 13 && SR.windows_errno(UInt32(183)) == 17 && SR.windows_errno(UInt32(80)) == 17
    @test SR.windows_errno(UInt32(17)) == 18 && SR.windows_errno(UInt32(267)) == 20 && SR.windows_errno(UInt32(123)) == 22 && SR.windows_errno(UInt32(112)) == 28 && SR.windows_errno(UInt32(99999)) == 5
    SR.Runtime.with_target(:windows, :x86_64) do
        @test SR.windows_errno(UInt32(145)) == 41 && SR.errno_enotempty() == 41 && SR.errno_eloop() == 114
    end
    SR.Runtime.with_target(:linux, :x86_64) do
        @test SR.errno_enotempty() == 39 && SR.errno_eloop() == 40
    end
    SR.Runtime.with_target(:macos, :aarch64) do
        @test SR.errno_enotempty() == 66 && SR.errno_eloop() == 62
    end
    # `struct _stat64`, as the C library of Windows has it (the offsets are those of its header)
    buf = zeros(UInt8, 64)
    put(T, offset, x) = GC.@preserve buf unsafe_store!(Ptr{T}(pointer(buf) + offset), x)
    put(UInt32, 0, UInt32(2)); put(UInt16, 6, UInt16(0o100666)); put(Int16, 8, Int16(1)); put(Int64, 24, Int64(1234)); put(Int64, 32, Int64(1700000000)); put(Int64, 40, Int64(1700000100)); put(Int64, 48, Int64(1600000000))
    st = SR.windows_stat_fields("a.txt", buf)
    @test st.size == 1234 && st.mode == 0o100666 && isfile(st) && !isdir(st) && st.mtime == 1700000100.0 && st.ctime == 1600000000.0 && st.nlink == 1 && st.blksize == 4096 && st.blocks == 3 && st.ioerrno == 0
    put(UInt16, 6, UInt16(0o040777))
    @test isdir(SR.windows_stat_fields("d", buf))
    # a mode of `fopen` is binary, a mode of `chmod` is whether the file can be written
    @test SR.windows_binary_mode("r") == "rb" && SR.windows_binary_mode("r+") == "r+b" && SR.windows_binary_mode("wb") == "wb" && SR.windows_binary_mode("a+") == "a+b"
    @test SR.windows_chmod_mode(0o644) == 0x180 && SR.windows_chmod_mode(0o444) == 0x100

    # each in a program, and in the IR of it for the target
    entry = (Int, Ptr{Ptr{UInt8}})
    ir(f) = (main = StaticRuntime.make_main(f); read(Base.invokelatest(compile_executable, main, entry, mktempdir(), string(nameof(main)); target = "x86_64-w64-mingw32", output = :llvmir), String))
    programs = [
        "open with a mode"  => (["_wfopen", "fclose", "fwrite"],        () -> (open(opaque("a.txt"), "w") do io; write(io, "x"); end; 0)),
        "open with flags"   => (["_wopen", "_fdopen"],                  () -> (io = open(opaque("a.txt"); write = true, create = true, append = true); println(io, "x"); close(io); 0)),
        "read a file"       => (["_wopen", "_fdopen"],                  () -> (println(read(opaque("a.txt"), String)); 0)),
        "offsets of 64 bits" => (["_fseeki64", "_ftelli64"],            () -> (io = open(opaque("a.txt")); seek(io, 3); println(position(io), " ", filesize(io)); close(io); 0)),
        "stat"              => (["_wstat64"],                           () -> (println(isfile(opaque("a")), isdir(opaque("a")), filesize(opaque("a")), mtime(opaque("a"))); 0)),
        "ispath"            => (["_waccess"],                           () -> (println(ispath(opaque("a"))); 0)),
        "mkdir and rm"      => (["_wmkdir", "_wrmdir", "_wunlink"],     () -> (mkdir(opaque("d")); rm(opaque("d")); rm(opaque("f")); 0)),
        "readdir"           => (["FindFirstFileW", "FindNextFileW", "FindClose"], () -> (println(readdir(opaque("."))); 0)),
        "mv"                => (["MoveFileExW"],                        () -> (mv(opaque("a"), opaque("b"); force = true); 0)),
        "cd and pwd"        => (["_wchdir", "_wgetcwd"],                () -> (cd(opaque(".")); println(pwd()); 0)),
        "realpath"          => (["GetFullPathNameW"],                   () -> (println(realpath(opaque("."))); 0)),
        "chmod"             => (["_wchmod"],                            () -> (chmod(opaque("a"), 0o644); 0)),
        "temporary names"   => (["GetTempPathW", "SystemFunction036", "_waccess", "_wopen", "_wmkdir"], () -> (println(tempname()); (path, io) = mktemp(); close(io); println(mktempdir()); 0)),
        "the environment"   => (["_wgetenv", "_wputenv_s"],             () -> (ENV[opaque("A")] = opaque("b"); println(get(ENV, opaque("A"), "none"), haskey(ENV, opaque("A"))); delete!(ENV, opaque("A")); 0)),
        "sleep"             => (["Sleep"],                              () -> (sleep(0.01); 0)),
        "entropy"           => (["SystemFunction036"],                  () -> (x = Vector{UInt8}(undef, 8); Base.Libc.getrandom!(x); println(sum(x)); 0)),
    ]
    for (name, (wanted, f)) in programs
        @testset "$name" begin
            text = ir(f)
            declared = String[m.captures[1] for m in eachmatch(r"^declare [^@\n]*@\"?([^\"(\s]+)"m, text)]
            @test all(w in declared for w in wanted)
            # no function that a program for Windows is refused for (they are the POSIX ones, and the names of the other systems), and no call that is a type error that always throws (the argument of a call of a function of
            # Windows has to be of the type that is said: `Int32(0)::Int32`, and not `0::Int32`)
            @test isempty(intersect(declared, SR.ONLY_POSIX)) && isempty(intersect(declared, ["__errno_location", "__error", "pthread_self"]))
            @test !occursin("in ccall argument", text)
        end
    end
end
