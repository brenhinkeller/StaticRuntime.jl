# Cross-compilation: a program for another architecture or system than the one that compiles it.
#
# The compiler of the program is the host's: Julia's code generation (types, inlining, the layout of objects) is the host's, and the
# runtime of this package is linked in as LLVM IR. What is different for another target is the last step: the code generator that makes the machine
# code from the IR, and the linker. The IR that is made for the host is made for the target by saying so (its `target triple`; its `target datalayout` is
# left out, so that the code generator has the target's: the two have the same alignments for 64-bit little-endian targets, which the objects
# that were embedded depend on, and the layout of objects is the host's, so a target with pointers that are not 8 bytes is not possible).
# The code is made as it is for the host: by the code generator alone, with no more optimization of the IR (which Julia has made: another round of it, as
# `clang -O1` makes, changes what some programs do). That is done in this process, by Julia's own LLVM, when it has the code generator for the target
# (the host's architecture, and WebAssembly), and else by the `llc` of an LLVM of the same version that has it (`STATIC_RUNTIME_CROSS_LLC`).
# The linker is the system's (`clang` as the driver).
#
# The target is a triple (`target = "x86_64-apple-macosx11.0.0"`), or a `CrossTarget` that also says how the code is made (`cross_target`).
# A target that is the architecture and the system of the host is the host's.

"""
    CrossTarget

A target that is not the host's: its triple, the `clang` that makes the code for it (one with the code generator for it, and of the version of
LLVM that Julia has), the flags that it is given, and the system root that it links with. See [`cross_target`](@ref).
"""
struct CrossTarget
    triple::String
    cpu::String
    features::String
    llc::Union{Nothing,Cmd}
    cc::Union{Nothing,Cmd}
    cflags::Cmd
    sysroot::Union{Nothing,String}
end

"""
    cross_target(triple; cpu = "generic", features = "", llc = nothing, cc = nothing, cflags = ``, sysroot = nothing)

A target for [`compile_executable`](@ref) (`target = cross_target("x86_64-apple-macosx11.0.0")`, or just the triple). The machine code is made by Julia's LLVM if it has the code generator for the
triple (the host's architecture and WebAssembly); else by `llc`, which has to be the one of an LLVM of the version that Julia has, with the code generator for it. If it is not given, the
one in the environment variable `STATIC_RUNTIME_CROSS_LLC`, and the one next to the `clang` in `STATIC_RUNTIME_CROSS_CLANG`, are tried. `cc` is the `clang` that links (the one of `Clang_jll`, or the system's, by default), and
`cflags` are added to its command; `sysroot` is the root of the system's headers and libraries (for macOS, the SDK of `xcrun` is the default).
"""
function cross_target(triple::AbstractString; cpu::AbstractString = "generic", features::AbstractString = "", llc = nothing, cc = nothing, cflags::Cmd = ``, sysroot = nothing)
    command(x) = x === nothing ? nothing : (x isa Cmd ? x : Cmd([String(x)]))
    return CrossTarget(String(triple), String(cpu), String(features), command(llc), command(cc), cflags, sysroot === nothing ? nothing : String(sysroot))
end

canonical_arch(a::AbstractString) = a in ("arm64", "aarch64") ? "aarch64" : a in ("x86_64", "amd64", "x64") ? "x86_64" : String(a)
triple_arch(triple::AbstractString) = canonical_arch(first(split(triple, '-')))
triple_system(triple::AbstractString) = occursin("apple", triple) ? :macos : occursin("linux", triple) ? :linux : startswith(triple, "wasm") ? :wasm : occursin("windows", triple) ? :windows : :unknown
host_arch() = canonical_arch(string(Sys.ARCH))
host_system() = Sys.isapple() ? :macos : Sys.islinux() ? :linux : Sys.iswindows() ? :windows : :unknown

# the target that `target` stands for: the host's if it is its architecture and system, and else a `CrossTarget`
function resolve_target(target::AbstractString)
    triple_arch(target) == host_arch() && triple_system(target) == host_system() && return default_target()
    return cross_target(target)
end
resolve_target(target) = target

# run `f` for the target: the system and the architecture of it are what the code of the runtime and of the overrides that differs between systems chooses by (runtime/target.jl)
with_cross_target(f, ::Nothing) = f()
with_cross_target(f, cross::CrossTarget) = with_target(f, triple_system(cross.triple), Symbol(triple_arch(cross.triple)); cross = true)

## The code generator and the linker

# whether `llc` is one of Julia's version of LLVM that has the code generator for `arch`
function llc_supports(llc::Cmd, arch::AbstractString)
    backend = Dict("x86_64" => "x86-64", "aarch64" => "aarch64", "wasm32" => "wasm32", "wasm64" => "wasm64")
    wanted = get(backend, arch, arch)
    text = try read(`$llc --version`, String) catch; return false, "`$llc` does not run" end
    m = match(r"LLVM version (\d+)\.", text)
    m === nothing && return false, "`$llc` is not an llc"
    major = parse(Int, m.captures[1])
    major == Base.libllvm_version.major || return false, "`$llc` is LLVM $major, and Julia's LLVM is $(Base.libllvm_version.major): its IR is not read by another version"
    occursin(Regex("^\\s+" * wanted * "\\s", "m"), text) || return false, "`$llc` has no code generator for $arch"
    return true, ""
end

# whether Julia's LLVM has the code generator for the triple
julia_llvm_has(triple::AbstractString) = try LLVM.Target(; triple = String(triple)); true catch; false end

function cross_llc(cross::CrossTarget)
    cross.llc === nothing || return cross.llc
    arch = triple_arch(cross.triple)
    candidates = Cmd[]
    haskey(ENV, "STATIC_RUNTIME_CROSS_LLC") && push!(candidates, Cmd([ENV["STATIC_RUNTIME_CROSS_LLC"]]))
    if haskey(ENV, "STATIC_RUNTIME_CROSS_CLANG")
        next_to = joinpath(dirname(ENV["STATIC_RUNTIME_CROSS_CLANG"]), "llc")
        isfile(next_to) && push!(candidates, Cmd([next_to]))
    end
    problems = String[]
    for llc in candidates
        ok, why = llc_supports(llc, arch)
        ok && return llc
        push!(problems, why)
    end
    isempty(problems) && push!(problems, "there is none to try")
    throw(ArgumentError(string("no way to make code for ", cross.triple, ": Julia's LLVM has no code generator for it, and ", join(unique(problems), "; "),
                               ". Give an `llc` with `cross_target(triple; llc = ...)` or the environment variable `STATIC_RUNTIME_CROSS_LLC` (or `STATIC_RUNTIME_CROSS_CLANG`, the `clang` next to it): it has to be of LLVM ",
                               Base.libllvm_version.major, " and have the code generator for ", arch, " (the `LLVM_full_jll` of the host's other architecture has, and runs under Rosetta on macOS).")))
end

# the machine code of the module `text` for the target, as an object file at `path`
function emit_cross_object(text::AbstractString, cross::CrossTarget, path::AbstractString; runtime::Bool = false)
    if triple_system(cross.triple) === :wasm
        !runtime && occursin(r"<\d+ x half>", text) && throw(ArgumentError("the program has vectors of `Float16`, which the code generator for WebAssembly can not make"))
        LLVM.clopts("-wasm-enable-sjlj", "-wasm-use-legacy-eh=false") # (the lowering of `setjmp` and `longjmp` of the code generator for WebAssembly: it is only for programs of that, so it does not change the others)
    end
    if julia_llvm_has(cross.triple)
        LLVM.@dispose ctx = LLVM.Context() begin
            mod = parse(LLVM.Module, text)
            try
                triple_system(cross.triple) === :wasm && !runtime && prepare_wasm_module!(mod)
                haskey(ENV, "STATIC_RUNTIME_CROSS_DUMP") && !runtime && write(ENV["STATIC_RUNTIME_CROSS_DUMP"], string(mod)) # (for looking at what the code generator is given)
                features = isempty(cross.features) && triple_system(cross.triple) === :wasm ? WASM_FEATURES : cross.features
                tm = LLVM.TargetMachine(LLVM.Target(; triple = cross.triple), cross.triple; cpu = cross.cpu, features, opt_level = LLVM.API.LLVMCodeGenLevelDefault, reloc = triple_system(cross.triple) === :wasm ? LLVM.API.LLVMRelocStatic : LLVM.API.LLVMRelocPIC)
                try
                    write(path, LLVM.emit(tm, mod, LLVM.API.LLVMObjectFile))
                finally
                    LLVM.dispose(tm)
                end
            finally
                LLVM.dispose(mod)
            end
        end
    else
        ir = path * ".ll"
        write(ir, text)
        try
            run(`$(cross_llc(cross)) -O2 -filetype=obj -mtriple=$(cross.triple) -mcpu=$(cross.cpu) -mattr=$(cross.features) -relocation-model=pic $ir -o $path`)
        finally
            rm(ir; force = true)
        end
    end
    return path
end

# The functions of the C library that the code generator for WebAssembly calls for `setjmp` and `longjmp` (they have to be in an object of their own: the code generator makes the declarations
# of them in the module that has the `setjmp`, and the same names in that module are other functions)
function emit_wasm_runtime_object(cross::CrossTarget, path::AbstractString)
    text = "target triple = \"$(cross.triple)\"\n" * WASM_SJLJ_RUNTIME * WASM_LIBC
    emit_cross_object(text, cross, path; runtime = true)
end

# the linker's driver: `clang`, which links for any target that the system has the linker and the libraries of
function cross_cc(cross::CrossTarget)
    cross.cc === nothing || return cross.cc
    Sys.isapple() && Sys.which("clang") !== nothing && return `clang` # (the system's: it has the linker's options of the SDK)
    return StaticCompiler.clang()
end

# the directory of a system root that has the start files of the C library (`crt1.o`)
function crt_directory(sysroot::AbstractString)
    for d in ("lib", "usr/lib", "lib64", "usr/lib64", "usr/lib/aarch64-linux-gnu", "usr/lib/x86_64-linux-gnu", "lib/aarch64-linux-gnu", "lib/x86_64-linux-gnu")
        isfile(joinpath(sysroot, d, "crt1.o")) && return joinpath(sysroot, d)
    end
    throw(ArgumentError("`$sysroot` has no `crt1.o`: the system root of the target (`sysroot`) is the one of a glibc, with its `lib` (the `Glibc_jll` artifact of the platform is one)"))
end

# the loader that a program of the architecture asks for, where it is on the system that it runs on
linux_dynamic_linker(arch::AbstractString) = arch == "x86_64" ? "/lib64/ld-linux-x86-64.so.2" : arch == "aarch64" ? "/lib/ld-linux-aarch64.so.1" : throw(ArgumentError("no loader is known for $arch"))

# link the object for the target: macOS with the system's `clang` and the SDK; Linux with the `lld` that Julia has (`-flavor gnu`) and the C library of the system root
function cross_link(cross::CrossTarget, obj::AbstractString, exe::AbstractString, small::Bool, extra::Cmd; objects::Vector{String} = String[])
    system = triple_system(cross.triple)
    if system === :macos
        sdk = cross.sysroot === nothing ? (Sys.isapple() && Sys.which("xcrun") !== nothing ? strip(read(`xcrun --show-sdk-path`, String)) : nothing) : cross.sysroot
        sdk === nothing && throw(ArgumentError("a program for macOS needs the SDK: give `sysroot = ...` to `cross_target`"))
        flags = String["--target=$(cross.triple)", "-isysroot", sdk, "-mlinker-version=900"]
        small && push!(flags, "-Wl,-x", "-Wl,-no_data_const")
        run(`$(cross_cc(cross)) $flags $(cross.cflags) $extra $obj -o $exe`)
    elseif system === :linux
        cross.sysroot === nothing && throw(ArgumentError("a program for $(cross.triple) needs the C library of the target: give `sysroot = ...` to `cross_target` (a directory with the `lib` of a glibc: the `Glibc_jll` artifact for the platform, or a root of the system)"))
        dir = crt_directory(cross.sysroot)
        arch = triple_arch(cross.triple)
        flags = String["-flavor", "gnu", "-o", exe, "-dynamic-linker", linux_dynamic_linker(arch), joinpath(dir, "crt1.o"), joinpath(dir, "crti.o"), obj, "-L$dir", "-lc", "-lm", "-ldl", joinpath(dir, "crtn.o")]
        small && push!(flags, "-s")
        run(`$(StaticCompiler.lld()) $flags $(cross.cflags) $extra`)
    elseif system === :wasm
        wasm = exe * ".wasm"
        flags = String["-flavor", "wasm", triple_arch(cross.triple) == "wasm64" ? "-mwasm64" : "-mwasm32", "--no-entry", "--export=main", "--export-memory", "--allow-undefined", "--stack-first", "-z", "stack-size=4194304", "-o", wasm, obj, objects...]
        small && push!(flags, "--strip-all")
        run(`$(StaticCompiler.lld()) $flags $(cross.cflags) $extra`)
        write(exe * ".mjs", wasm_host_source("node")) # (the host that runs it: `node name.mjs`)
        write(exe * ".browser.mjs", wasm_host_source("browser")) # (and the one for a browser: `import { run } from "./name.browser.mjs"`)
        return wasm
    else
        throw(ArgumentError("programs for $(cross.triple) ($(system)) can not be linked yet"))
    end
    return exe
end

# The host of a program for WebAssembly: the function that has the C library and the system (`wasm_host_core.js`), after the shell of the platform that gives it files, the clock and the streams.
wasm_host_source(platform::AbstractString) = read(joinpath(@__DIR__, "runtime", "wasm_host_$platform.mjs"), String) * "\n" * read(joinpath(@__DIR__, "runtime", "wasm_host_core.js"), String)

## The IR for the target

# the IR that was made for the host, for the target: its triple, and no data layout (the code generator has the target's); the attributes that name the
# host's CPU and features are left out. IR that has the host's intrinsics in it is refused.
function retarget_ir(text::AbstractString, triple::AbstractString)
    arch = triple_arch(triple)
    for m in eachmatch(r"\bllvm\.(aarch64|arm|x86)\.[A-Za-z0-9_.]+", text)
        made_for = m.captures[1] == "x86" ? "x86_64" : "aarch64" # (the intrinsics of the host's code generator, in the IR of the host)
        made_for == arch || throw(ArgumentError("the program uses `$(m.match)`, an intrinsic of another architecture than $arch: it can not be made for $triple"))
    end
    system = triple_system(triple)
    text = rename_system_symbols(text, system)
    system === :wasm && (text = wasm_sjlj_names(define_wasm_streams(text)))
    system === :wasm && (text = replace(text, r"^@_static_wasm_stack_top = external[^\n]*$"m => "@_static_wasm_stack_top = global ptr null, align 8"))
    text = replace(text, r"^target datalayout = .*\n"m => "")
    text = replace(text, r"^target triple = .*$"m => "target triple = \"$triple\"")
    text = replace(text, r" \"(target-cpu|target-features|tune-cpu)\"=\"[^\"]*\"" => "")
    return text
end

# What the C libraries of the systems call the same: the standard streams that StaticTools has as globals (it chooses by the host's system when it is compiled), and `sigsetjmp` (glibc has it as a macro of
# `__sigsetjmp`). And what the program may not have for a system that is not the host's: what only the host's system has (the code of this package for it is chosen by the target, so
# these are from what is not: packages that choose by the host's system, as `Mmap` does with the flags of `mmap`, which are Julia's).
const SYSTEM_RENAMES = Dict(:linux => ["__stdoutp" => "stdout", "__stderrp" => "stderr", "__stdinp" => "stdin", "sigsetjmp" => "__sigsetjmp"])
const ONLY_MACOS = ["_NSGetEnviron", "getattrlist", "mach_host_self", "host_statistics", "sysctlbyname", "__error", "pthread_get_stackaddr_np", "pthread_get_stacksize_np", "_NSGetExecutablePath"]
const ONLY_LINUX = ["__errno_location", "__libc_stack_end", "__sigsetjmp", "sysinfo"]
const HOST_FLAGS = ["mmap"]

function rename_system_symbols(text::AbstractString, system::Symbol)
    for (from, to) in get(SYSTEM_RENAMES, system, Pair{String,String}[])
        text = replace(text, Regex("@" * from * "\\b(?![\\w.\$])") => "@" * to)
    end
    wrong = system === :linux ? ONLY_MACOS : system === :macos ? ONLY_LINUX : String[]
    found = String[w for w in wrong if occursin(Regex("@" * w * "\\b(?![\\w.\$])"), text)]
    system === host_system() || append!(found, String[w for w in HOST_FLAGS if occursin(Regex("@" * w * "\\b(?![\\w.\$])"), text)]) # (what the host's packages chose for the host's system is right for the host's system)
    isempty(found) || throw(ArgumentError(string("the program uses ", join(("`$w`" for w in found), ", "), ", which a program for ", system, " does not have, or has other arguments for (the code of the host's system, chosen when a package was compiled)")))
    return text
end

# The conversions between `Float16` and `Float32` that the code generator for x86-64 calls where the CPU is not said to have them (they are in libgcc and compiler-rt, which the
# program is not linked with): defined here, with the instructions that do them (F16C: from 2012 on), so that the program does not need them.
const X86_HALF_BUILTINS = """
define linkonce_odr hidden float @__extendhfsf2(half %a) #9999 {
  %r = fpext half %a to float
  ret float %r
}
define linkonce_odr hidden half @__truncsfhf2(float %a) #9999 {
  %r = fptrunc float %a to half
  ret half %r
}
attributes #9999 = { nounwind "target-features"="+f16c" }
"""
needs_half_builtins(text::AbstractString, arch::AbstractString) = arch == "x86_64" && occursin(r"\bhalf\b", text)

# 128-bit division, which the code generator calls (`__udivti3` and the others of libgcc and compiler-rt, which a Linux program is not linked with): by shifting and subtracting,
# with instructions of `i128` that are not calls (a division of `i128` in them would be a call of themselves).
const LINUX_INT128_BUILTINS = """
define linkonce_odr hidden i128 @__static_udivmod(i128 %a, i128 %b, i1 %rem) {
entry:
  ; (operands of 64 bits, the usual: the instruction of the CPU; a divisor of zero is left to the loop, which does not trap)
  %ah = lshr i128 %a, 64
  %bh = lshr i128 %b, 64
  %hi = or i128 %ah, %bh
  %nohi = icmp eq i128 %hi, 0
  %bnz = icmp ne i128 %b, 0
  %small = and i1 %nohi, %bnz
  br i1 %small, label %fast, label %loop
fast:
  %a64 = trunc i128 %a to i64
  %b64 = trunc i128 %b to i64
  %fq = udiv i64 %a64, %b64
  %fr = urem i64 %a64, %b64
  %fqx = zext i64 %fq to i128
  %frx = zext i64 %fr to i128
  %fres = select i1 %rem, i128 %frx, i128 %fqx
  ret i128 %fres
loop:
  %i = phi i32 [ 127, %entry ], [ %i1, %loop ]
  %q = phi i128 [ 0, %entry ], [ %q2, %loop ]
  %r = phi i128 [ 0, %entry ], [ %r3, %loop ]
  %i128 = zext i32 %i to i128
  %sh = lshr i128 %a, %i128
  %bit = and i128 %sh, 1
  %r1 = shl i128 %r, 1
  %r2 = or i128 %r1, %bit
  %ge = icmp uge i128 %r2, %b
  %rs = sub i128 %r2, %b
  %r3 = select i1 %ge, i128 %rs, i128 %r2
  %one = shl i128 1, %i128
  %qo = or i128 %q, %one
  %q2 = select i1 %ge, i128 %qo, i128 %q
  %i1 = sub i32 %i, 1
  %done = icmp slt i32 %i1, 0
  br i1 %done, label %exit, label %loop
exit:
  %res = select i1 %rem, i128 %r3, i128 %q2
  ret i128 %res
}
define linkonce_odr hidden i128 @__udivti3(i128 %a, i128 %b) {
  %r = call i128 @__static_udivmod(i128 %a, i128 %b, i1 false)
  ret i128 %r
}
define linkonce_odr hidden i128 @__umodti3(i128 %a, i128 %b) {
  %r = call i128 @__static_udivmod(i128 %a, i128 %b, i1 true)
  ret i128 %r
}
define linkonce_odr hidden i128 @__divti3(i128 %a, i128 %b) {
  %sa = icmp slt i128 %a, 0
  %sb = icmp slt i128 %b, 0
  %na = sub i128 0, %a
  %nb = sub i128 0, %b
  %ua = select i1 %sa, i128 %na, i128 %a
  %ub = select i1 %sb, i128 %nb, i128 %b
  %q = call i128 @__static_udivmod(i128 %ua, i128 %ub, i1 false)
  %neg = xor i1 %sa, %sb
  %nq = sub i128 0, %q
  %r = select i1 %neg, i128 %nq, i128 %q
  ret i128 %r
}
define linkonce_odr hidden i128 @__modti3(i128 %a, i128 %b) {
  %sa = icmp slt i128 %a, 0
  %sb = icmp slt i128 %b, 0
  %na = sub i128 0, %a
  %nb = sub i128 0, %b
  %ua = select i1 %sa, i128 %na, i128 %a
  %ub = select i1 %sb, i128 %nb, i128 %b
  %m = call i128 @__static_udivmod(i128 %ua, i128 %ub, i1 true)
  %nm = sub i128 0, %m
  %r = select i1 %sa, i128 %nm, i128 %m
  ret i128 %r
}
"""
needs_int128_builtins(text::AbstractString, system::Symbol) = system === :linux && occursin(r"\b(udiv|sdiv|urem|srem) i128\b", text)

# The same for WebAssembly, which has no instruction for it: by integer arithmetic (the rounding is to the nearest, ties to even)
const WASM_HALF_BUILTINS = """
define linkonce_odr hidden float @__extendhfsf2(half %a) {
  %h = bitcast half %a to i16
  %hi = zext i16 %h to i32
  %s1 = lshr i32 %hi, 15
  %s2 = shl i32 %s1, 31
  %e1 = lshr i32 %hi, 10
  %e = and i32 %e1, 31
  %m = and i32 %hi, 1023
  %en = add i32 %e, 112
  %en2 = shl i32 %en, 23
  %m13 = shl i32 %m, 13
  %n1 = or i32 %s2, %en2
  %normal = or i32 %n1, %m13
  %i1 = or i32 %s2, 2139095040
  %infnan = or i32 %i1, %m13
  %mf = uitofp i32 %m to float
  %sub = fmul float %mf, 0x3E70000000000000
  %subb = bitcast float %sub to i32
  %subs = or i32 %subb, %s2
  %isz = icmp eq i32 %e, 0
  %isi = icmp eq i32 %e, 31
  %r1 = select i1 %isi, i32 %infnan, i32 %normal
  %r = select i1 %isz, i32 %subs, i32 %r1
  %f = bitcast i32 %r to float
  ret float %f
}
define linkonce_odr hidden half @__truncsfhf2(float %a) {
  %x = bitcast float %a to i32
  %s1 = lshr i32 %x, 16
  %sign = and i32 %s1, 32768
  %e1 = lshr i32 %x, 23
  %e = and i32 %e1, 255
  %m = and i32 %x, 8388607
  %ne = sub i32 %e, 112
  ; infinity and NaN
  %m13 = lshr i32 %m, 13
  %nanm = or i32 %m13, 512
  %hasm = icmp ne i32 %m, 0
  %nanbits = select i1 %hasm, i32 %nanm, i32 0
  %infnan = or i32 %nanbits, 31744
  ; normal
  %ne10 = shl i32 %ne, 10
  %hn = or i32 %ne10, %m13
  %rem = and i32 %m, 8191
  %gt = icmp ugt i32 %rem, 4096
  %eq = icmp eq i32 %rem, 4096
  %odd1 = and i32 %hn, 1
  %odd = icmp ne i32 %odd1, 0
  %tie = and i1 %eq, %odd
  %up = or i1 %gt, %tie
  %upi = zext i1 %up to i32
  %hn2 = add i32 %hn, %upi
  ; subnormal
  %mm = or i32 %m, 8388608
  %shift = sub i32 14, %ne
  %shiftc = call i32 @llvm.umin.i32(i32 %shift, i32 31)
  %hs = lshr i32 %mm, %shiftc
  %one = shl i32 1, %shiftc
  %mask = sub i32 %one, 1
  %rem2 = and i32 %mm, %mask
  %half1 = lshr i32 %one, 1
  %gt2 = icmp ugt i32 %rem2, %half1
  %eq2 = icmp eq i32 %rem2, %half1
  %odd2a = and i32 %hs, 1
  %odd2 = icmp ne i32 %odd2a, 0
  %tie2 = and i1 %eq2, %odd2
  %up2 = or i1 %gt2, %tie2
  %up2i = zext i1 %up2 to i32
  %hs2 = add i32 %hs, %up2i
  ; which
  %isinf = icmp eq i32 %e, 255
  %ovf = icmp sge i32 %ne, 31
  %isnorm = icmp sge i32 %ne, 1
  %issub = icmp sge i32 %ne, -10
  %r1 = select i1 %issub, i32 %hs2, i32 0
  %r2 = select i1 %isnorm, i32 %hn2, i32 %r1
  %r3 = select i1 %ovf, i32 31744, i32 %r2
  %r4 = select i1 %isinf, i32 %infnan, i32 %r3
  %r5 = or i32 %r4, %sign
  %r16 = trunc i32 %r5 to i16
  %h = bitcast i16 %r16 to half
  ret half %h
}
declare i32 @llvm.umin.i32(i32, i32)
; double to half: through float with the rounding to odd (inexact results get an odd last bit: the second rounding is then the one of the double), and half to double
define linkonce_odr hidden half @__truncdfhf2(double %a) {
  %f = fptrunc double %a to float
  %back = fpext float %f to double
  %exact = fcmp oeq double %back, %a
  %isnan = fcmp uno double %a, %a
  %fb = bitcast float %f to i32
  %odd = and i32 %fb, 1
  %isodd = icmp ne i32 %odd, 0
  %nb = fneg double %back
  %bneg = fcmp olt double %back, 0.0
  %ab = select i1 %bneg, double %nb, double %back
  %na = fneg double %a
  %aneg = fcmp olt double %a, 0.0
  %aa = select i1 %aneg, double %na, double %a
  %up = fcmp ogt double %ab, %aa
  %dec = sub i32 %fb, 1
  %inc = add i32 %fb, 1
  %adj = select i1 %up, i32 %dec, i32 %inc
  %isinf = fcmp oeq float %f, 0x7FF0000000000000
  %k1 = or i1 %exact, %isodd
  %k2 = or i1 %k1, %isnan
  %k3 = or i1 %k2, %isinf
  %r = select i1 %k3, i32 %fb, i32 %adj
  %rf = bitcast i32 %r to float
  %h = call half @__truncsfhf2(float %rf)
  ret half %h
}
define linkonce_odr hidden double @__extendhfdf2(half %a) {
  %f = call float @__extendhfsf2(half %a)
  %d = fpext float %f to double
  ret double %d
}
"""

## WebAssembly (wasm64)

# The functions of the C library that the host of a program for wasm64 has (src/runtime/wasm_host_core.js): a program that uses another is refused when it is made
const WASM_HOST_FUNCTIONS = ["calloc", "malloc", "realloc", "free", "exit", "strlen", "memchr", "memcmp", "memcpy", "memmove", "memset", "write", "fwrite", "fputc", "puts", "printf", "fflush",
                             # files, directories and the environment (Node's `fs`)
                             "__errno_location", "strerror", "open", "close", "fopen", "fdopen", "fclose", "fgetc", "ungetc", "fread", "fseek", "ftell", "stat", "lstat", "access", "mkdir", "rmdir", "unlink",
                             "rename", "chmod", "getcwd", "chdir", "realpath", "mkstemp", "mkdtemp", "opendir", "readdir", "closedir",
                             "getenv", "clock_gettime", "getentropy", "nanosleep", "_setjmp",
                             # (the system, the time, strings and sorting)
                             "getpid", "gettimeofday", "time", "gmtime_r", "localtime_r", "setenv", "unsetenv", "gethostname", "sysconf", "symlink", "readlink", "strcmp", "strncmp", "qsort", "bsearch",
                             # (the math library: the functions that Math has, and the error and gamma functions)
                             "asinh", "acosh", "atanh", "exp10", "erf", "erfc", "tgamma", "lgamma", "lgamma_r",
                             # (what the code generator makes of `setjmp` and `longjmp`, with the functions below: these are not imports)
                             "setjmp", "longjmp"]
const WASM_FEATURES = "+simd128,+bulk-memory,+sign-ext,+nontrapping-fptoint,+mutable-globals,+exception-handling"

# `try` of Julia is `sigsetjmp` and `throw` is `siglongjmp` (in the runtime of this package). The code generator for WebAssembly makes `setjmp` and `longjmp` (those names) into exceptions of WebAssembly,
# with these three functions of the C library: `__wasm_setjmp` and `__wasm_setjmp_test` keep which `setjmp` of which call of a function a `jmp_buf` is, and `__wasm_longjmp` throws, with the tag
# that the linker makes (`__c_longjmp`), a pointer to what the `setjmp` that catches it needs: the `jmp_buf` and the value. The `jmp_buf` is `{ ptr id; i32 label; { ptr env; i32 value } }`.
const WASM_SJLJ_RUNTIME = """
module asm ".globl __c_longjmp"
module asm ".tagtype __c_longjmp i64"
module asm "__c_longjmp:"
declare void @llvm.wasm.throw(i32, ptr)
define void @__wasm_setjmp(ptr %env, i32 %label, ptr %id) nounwind {
  store ptr %id, ptr %env, align 8
  %lp = getelementptr inbounds i8, ptr %env, i64 8
  store i32 %label, ptr %lp, align 4
  ret void
}
define i32 @__wasm_setjmp_test(ptr %env, ptr %id) nounwind {
  %cur = load ptr, ptr %env, align 8
  %same = icmp eq ptr %cur, %id
  %lp = getelementptr inbounds i8, ptr %env, i64 8
  %label = load i32, ptr %lp, align 4
  %r = select i1 %same, i32 %label, i32 0
  ret i32 %r
}
define void @__wasm_longjmp(ptr %env, i32 %val) noreturn {
  %argp = getelementptr inbounds i8, ptr %env, i64 16
  store ptr %env, ptr %argp, align 8
  %vp = getelementptr inbounds i8, ptr %argp, i64 8
  %zero = icmp eq i32 %val, 0
  %v = select i1 %zero, i32 1, i32 %val
  store i32 %v, ptr %vp, align 4
  call void @llvm.wasm.throw(i32 1, ptr %argp)
  unreachable
}
"""

# the code generator for WebAssembly finds `setjmp` and `longjmp` by these names (and `setjmp` takes the buffer only)
function wasm_sjlj_names(text::AbstractString)
    # (macOS has `sigsetjmp`, glibc `__sigsetjmp`, which is what a program made on Linux calls)
    text = replace(text, r"call i32 @(?:__)?sigsetjmp\(ptr ([^,)]+), i32 0\)" => s"call i32 @setjmp(ptr \1)")
    text = replace(text, r"declare i32 @(?:__)?sigsetjmp\(ptr, i32\)" => "declare i32 @setjmp(ptr)")
    return replace(text, "@siglongjmp(" => "@longjmp(")
end

# the standard streams of a program for wasm64 are the numbers of the descriptors (`fwrite` of the host writes to the one that it is given)
function define_wasm_streams(text::AbstractString)
    # (`__stdoutp` is the name on macOS, `stdout` on Linux)
    for (name, fd) in ("__stdoutp" => 1, "__stderrp" => 2, "__stdinp" => 0, "stdout" => 1, "stderr" => 2, "stdin" => 0)
        text = replace(text, Regex("^@" * name * " = external [^\\n]*\$", "m") => "@$name = local_unnamed_addr global ptr inttoptr (i64 $fd to ptr)")
    end
    return text
end

# Calls of C functions that were bound when the program runs (`@ccall_name` is a global that is null until the first call looks the function up, and `@jlplt_name_got` the address of a function that does that) are calls of
# the function that they find: it is the same one every time, and a call through a pointer of WebAssembly has to have the type of the function exactly (the call here is of a function with a varargs type)
function devirtualize_ccall_slots!(mod::LLVM.Module)
    slots = Dict{String,LLVM.Function}()
    for g in LLVM.globals(mod)
        name = LLVM.name(g)
        (startswith(name, "ccall_") || startswith(name, "dynccall_")) || continue
        stored = nothing
        for use in LLVM.uses(g)
            user = LLVM.user(use)
            user isa LLVM.StoreInst || continue
            v = LLVM.operands(user)[1]
            v isa LLVM.Function && (stored = v)
        end
        stored === nothing || (slots[name] = stored)
    end
    isempty(slots) && return 0
    count = 0
    for g in collect(LLVM.globals(mod))
        name = LLVM.name(g)
        function_of = (startswith(name, "ccall_") || startswith(name, "dynccall_")) ? get(slots, name, nothing) :
                      startswith(name, "jlplt_") && endswith(name, "_got") ? get(slots, "ccall_" * name[length("jlplt_")+1:end-length("_got")], nothing) : nothing
        function_of === nothing && continue
        for use in collect(LLVM.uses(g))
            load = LLVM.user(use)
            load isa LLVM.LoadInst || continue
            LLVM.replace_uses!(load, function_of)
            LLVM.erase!(load)
            count += 1
        end
    end
    # (the thunks that look the function up, called directly)
    for f in collect(LLVM.functions(mod))
        name = LLVM.name(f)
        startswith(name, "jlplt_") || continue
        target = get(slots, "ccall_" * name[length("jlplt_")+1:end], nothing)
        target === nothing || LLVM.replace_uses!(f, target)
    end
    # (a call that has the type that was guessed for the pointer, now of the function itself: the type of the function. The pointer is the function, or a phi of it that
    # only the two places that it was found at make. A C function that was declared with no arguments and no result, as a placeholder (what the lookup of a library function does),
    # has the type that its calls have: the same for all of them, or it is left alone)
    site_types = Dict{LLVM.Function,Set{LLVM.FunctionType}}()
    placeholder(F) = (ft = LLVM.function_type(F); !LLVM.isvararg(ft) && isempty(LLVM.parameters(ft)) && LLVM.return_type(ft) == LLVM.VoidType())
    LLVM.@dispose builder = LLVM.IRBuilder() begin
        for f in LLVM.functions(mod), bb in LLVM.blocks(f), inst in collect(LLVM.instructions(bb))
            inst isa LLVM.CallInst || continue
            callee = LLVM.called_operand(inst)
            F = nothing
            if callee isa LLVM.Function
                F = callee
            elseif callee isa LLVM.PHIInst
                incoming = [v for (v, _) in LLVM.incoming(callee)]
                !isempty(incoming) && all(==(first(incoming)), incoming) && first(incoming) isa LLVM.Function && (F = first(incoming))
            end
            F === nothing && continue
            args = LLVM.operands(inst)[1:end-1]
            if placeholder(F)
                push!(get!(Set{LLVM.FunctionType}, site_types, F), LLVM.called_type(inst))
                if callee !== F # (the phi: the call as it was, of the function)
                    LLVM.position!(builder, LLVM.before(inst))
                    replacement = LLVM.call!(builder, LLVM.called_type(inst), F, collect(args))
                    LLVM.replace_uses!(inst, replacement)
                    LLVM.erase!(inst)
                end
                continue
            end
            ft = LLVM.function_type(F)
            callee === F && LLVM.called_type(inst) == ft && continue
            (LLVM.isvararg(ft) || length(args) == length(LLVM.parameters(ft))) || continue
            LLVM.position!(builder, LLVM.before(inst))
            replacement = LLVM.call!(builder, ft, F, collect(args))
            LLVM.replace_uses!(inst, replacement)
            LLVM.erase!(inst)
            count += 1
        end
    end
    # (the calls that differ only in `ptr` and `i64` (the same on wasm64: one is the pointer that Julia has as a number, the other that C code has) are of one type)
    flat(t) = t isa LLVM.PointerType ? LLVM.IntType(64) : t
    same_lowering(a, b) = length(LLVM.parameters(a)) == length(LLVM.parameters(b)) && flat(LLVM.return_type(a)) == flat(LLVM.return_type(b)) &&
                          all(flat(x) == flat(y) for (x, y) in zip(LLVM.parameters(a), LLVM.parameters(b)))
    for (F, types) in site_types
        chosen = first(types)
        all(t -> same_lowering(t, chosen), types) || continue
        chosen == LLVM.function_type(F) && continue
        name = LLVM.name(F)
        replacement = LLVM.Function(mod, name * ".typed", chosen)
        LLVM.replace_uses!(F, replacement)
        LLVM.erase!(F)
        LLVM.name!(replacement, name)
        count += 1
    end
    return count
end

# The functions of the string library that are called a lot, in the module, and not imports of the host: a call of the host is a few hundred times as slow as the function (`Dict` of
# strings, `split`, `==` of strings are made of them). `memcpy`, `memmove` and `memset` are the instructions of bulk memory.
const WASM_LIBC = """
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
; 128-bit multiplication (what hashes are made of): the low half of the product, and the high half from the partial products of 32-bit halves (a multiplication of `i128` would be a call of this)
define void @__multi3(ptr %ret, i64 %al, i64 %ah, i64 %bl, i64 %bh) nounwind {
  %a0 = and i64 %al, 4294967295
  %a1 = lshr i64 %al, 32
  %b0 = and i64 %bl, 4294967295
  %b1 = lshr i64 %bl, 32
  %p00 = mul i64 %a0, %b0
  %p01 = mul i64 %a0, %b1
  %p10 = mul i64 %a1, %b0
  %p11 = mul i64 %a1, %b1
  %m1 = lshr i64 %p00, 32
  %m2 = and i64 %p01, 4294967295
  %m3 = and i64 %p10, 4294967295
  %m12 = add i64 %m1, %m2
  %mid = add i64 %m12, %m3
  %h1 = lshr i64 %p01, 32
  %h2 = lshr i64 %p10, 32
  %h3 = lshr i64 %mid, 32
  %h12 = add i64 %p11, %h1
  %h23 = add i64 %h2, %h3
  %hi = add i64 %h12, %h23
  %lo = mul i64 %al, %bl
  %c1 = mul i64 %al, %bh
  %c2 = mul i64 %ah, %bl
  %cc = add i64 %c1, %c2
  %hi2 = add i64 %hi, %cc
  store i64 %lo, ptr %ret, align 8
  %hp = getelementptr inbounds i8, ptr %ret, i64 8
  store i64 %hi2, ptr %hp, align 8
  ret void
}
define i64 @strlen(ptr %s) nounwind {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %p = getelementptr inbounds i8, ptr %s, i64 %i
  %c = load i8, ptr %p, align 1
  %next = add i64 %i, 1
  %end = icmp eq i8 %c, 0
  br i1 %end, label %done, label %loop
done:
  ret i64 %i
}
define i32 @memcmp(ptr %a, ptr %b, i64 %n) nounwind {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %cont ]
  %more = icmp ult i64 %i, %n
  br i1 %more, label %body, label %equal
body:
  %pa = getelementptr inbounds i8, ptr %a, i64 %i
  %pb = getelementptr inbounds i8, ptr %b, i64 %i
  %ca = load i8, ptr %pa, align 1
  %cb = load i8, ptr %pb, align 1
  %same = icmp eq i8 %ca, %cb
  br i1 %same, label %cont, label %differ
cont:
  %next = add i64 %i, 1
  br label %loop
differ:
  %za = zext i8 %ca to i32
  %zb = zext i8 %cb to i32
  %d = sub i32 %za, %zb
  ret i32 %d
equal:
  ret i32 0
}
define ptr @memchr(ptr %s, i32 %c, i64 %n) nounwind {
entry:
  %want = trunc i32 %c to i8
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %cont ]
  %more = icmp ult i64 %i, %n
  br i1 %more, label %body, label %none
body:
  %p = getelementptr inbounds i8, ptr %s, i64 %i
  %b = load i8, ptr %p, align 1
  %hit = icmp eq i8 %b, %want
  br i1 %hit, label %found, label %cont
cont:
  %next = add i64 %i, 1
  br label %loop
found:
  ret ptr %p
none:
  ret ptr null
}
define ptr @memcpy(ptr %d, ptr %s, i64 %n) nounwind {
  call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr %s, i64 %n, i1 false)
  ret ptr %d
}
define ptr @memmove(ptr %d, ptr %s, i64 %n) nounwind {
  call void @llvm.memmove.p0.p0.i64(ptr %d, ptr %s, i64 %n, i1 false)
  ret ptr %d
}
define ptr @memset(ptr %d, i32 %c, i64 %n) nounwind {
  %b = trunc i32 %c to i8
  call void @llvm.memset.p0.i64(ptr %d, i8 %b, i64 %n, i1 false)
  ret ptr %d
}
; string comparison, sorting and searching (`qsort` is a shell sort: it is not stable, and calls the comparison through the pointer that it is given)
define i32 @strcmp(ptr %a, ptr %b) nounwind {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %cont]
  %pa = getelementptr i8, ptr %a, i64 %i
  %pb = getelementptr i8, ptr %b, i64 %i
  %ca = load i8, ptr %pa
  %cb = load i8, ptr %pb
  %differ = icmp ne i8 %ca, %cb
  %end = icmp eq i8 %ca, 0
  %stop = or i1 %differ, %end
  br i1 %stop, label %done, label %cont
cont:
  %next = add i64 %i, 1
  br label %loop
done:
  %za = zext i8 %ca to i32
  %zb = zext i8 %cb to i32
  %d = sub i32 %za, %zb
  ret i32 %d
}
define i32 @strncmp(ptr %a, ptr %b, i64 %n) nounwind {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %cont]
  %out = icmp uge i64 %i, %n
  br i1 %out, label %equal, label %body
body:
  %pa = getelementptr i8, ptr %a, i64 %i
  %pb = getelementptr i8, ptr %b, i64 %i
  %ca = load i8, ptr %pa
  %cb = load i8, ptr %pb
  %differ = icmp ne i8 %ca, %cb
  %end = icmp eq i8 %ca, 0
  %stop = or i1 %differ, %end
  br i1 %stop, label %done, label %cont
cont:
  %next = add i64 %i, 1
  br label %loop
equal:
  ret i32 0
done:
  %za = zext i8 %ca to i32
  %zb = zext i8 %cb to i32
  %d = sub i32 %za, %zb
  ret i32 %d
}
define void @qsort(ptr %base, i64 %n, i64 %size, ptr %cmp) nounwind {
entry:
  %small = icmp ult i64 %n, 2
  %empty = icmp eq i64 %size, 0
  %skip = or i1 %small, %empty
  br i1 %skip, label %done, label %start
start:
  %gap0 = lshr i64 %n, 1
  br label %gapcheck
gapcheck:
  %gap = phi i64 [%gap0, %start], [%gapnext, %gapend]
  %gz = icmp eq i64 %gap, 0
  br i1 %gz, label %done, label %iloop
iloop:
  %i = phi i64 [%gap, %gapcheck], [%inext, %iend]
  %idone = icmp uge i64 %i, %n
  br i1 %idone, label %gapend, label %jloop
jloop:
  %j = phi i64 [%i, %iloop], [%jprev, %swapped]
  %jok = icmp uge i64 %j, %gap
  br i1 %jok, label %cmpblk, label %iend
cmpblk:
  %jprev = sub i64 %j, %gap
  %offa = mul i64 %jprev, %size
  %offb = mul i64 %j, %size
  %pa = getelementptr i8, ptr %base, i64 %offa
  %pb = getelementptr i8, ptr %base, i64 %offb
  %c = call i32 %cmp(ptr %pa, ptr %pb)
  %gt = icmp sgt i32 %c, 0
  br i1 %gt, label %sw, label %iend
sw:
  %k = phi i64 [0, %cmpblk], [%knext, %sw]
  %qa = getelementptr i8, ptr %pa, i64 %k
  %qb = getelementptr i8, ptr %pb, i64 %k
  %va = load i8, ptr %qa
  %vb = load i8, ptr %qb
  store i8 %vb, ptr %qa
  store i8 %va, ptr %qb
  %knext = add i64 %k, 1
  %kd = icmp eq i64 %knext, %size
  br i1 %kd, label %swapped, label %sw
swapped:
  br label %jloop
iend:
  %inext = add i64 %i, 1
  br label %iloop
gapend:
  %gapnext = lshr i64 %gap, 1
  br label %gapcheck
done:
  ret void
}
define ptr @bsearch(ptr %key, ptr %base, i64 %n, i64 %size, ptr %cmp) nounwind {
entry:
  br label %loop
loop:
  %lo = phi i64 [0, %entry], [%lo2, %step]
  %hi = phi i64 [%n, %entry], [%hi2, %step]
  %more = icmp ult i64 %lo, %hi
  br i1 %more, label %probe, label %missing
probe:
  %span = sub i64 %hi, %lo
  %half = lshr i64 %span, 1
  %mid = add i64 %lo, %half
  %off = mul i64 %mid, %size
  %p = getelementptr i8, ptr %base, i64 %off
  %c = call i32 %cmp(ptr %key, ptr %p)
  %found = icmp eq i32 %c, 0
  br i1 %found, label %hit, label %step
step:
  %less = icmp slt i32 %c, 0
  %midnext = add i64 %mid, 1
  %hi2 = select i1 %less, i64 %mid, i64 %hi
  %lo2 = select i1 %less, i64 %lo, i64 %midnext
  br label %loop
hit:
  ret ptr %p
missing:
  ret ptr null
}
"""

# the functions that the module imports that the host of wasm64 does not have
function wasm_missing_imports(mod::LLVM.Module)
    names = String[LLVM.name(f) for f in LLVM.functions(mod) if LLVM.isdeclaration(f) && !startswith(LLVM.name(f), "llvm.") && !isempty(collect(LLVM.uses(f)))]
    return sort!(filter(n -> !(n in WASM_HOST_FUNCTIONS), names))
end

## The collector on WebAssembly: roots

# The collector looks for what is in use on the stack of the machine, between the stack pointer and the base. A program for WebAssembly keeps values in locals, which are not in memory, so a
# pointer that a function holds only in a local, while a call that collects runs, would not be seen, and what it points to would be freed. So before each call that can reach a collection every
# pointer that is in use after the call is stored to a slot of the frame (a `volatile` store, which nothing removes: the slots are allocas, which stay in memory, and are on the stack that is looked at).
# The calls that can not reach a collection are not given any: a call graph says which can (the callers of the collector, and the calls of a function that is not known). Only pointers are
# stored (not integers), and not those of the stack or of the data of the program (it is looked at, as the roots).
function spill_gc_roots!(mod::LLVM.Module)
    collectors = [f for f in LLVM.functions(mod) if !LLVM.isdeclaration(f) && startswith(LLVM.name(f), "julia_collect_")]
    isempty(collectors) && return (calls = 0, stores = 0)
    defined = [f for f in LLVM.functions(mod) if !LLVM.isdeclaration(f)]
    skip(f) = startswith(LLVM.name(f), "__wasm_") || f in collectors
    # the functions that can reach a collection
    calls_in = Dict{Ptr{Cvoid},Vector{LLVM.Function}}()   # callee => callers
    allocating = Set{Ptr{Cvoid}}(Ptr{Cvoid}(f.ref) for f in collectors)
    queue = LLVM.Function[]
    for f in defined, bb in LLVM.blocks(f), inst in LLVM.instructions(bb)
        inst isa LLVM.CallInst || continue
        callee = LLVM.called_operand(inst)
        if callee isa LLVM.Function
            startswith(LLVM.name(callee), "llvm.") && continue
            push!(get!(Vector{LLVM.Function}, calls_in, Ptr{Cvoid}(callee.ref)), f)
        elseif !(callee isa LLVM.InlineAsm)
            Ptr{Cvoid}(f.ref) in allocating || (push!(allocating, Ptr{Cvoid}(f.ref)); push!(queue, f)) # (a call of a function that is not known)
        end
    end
    append!(queue, collectors)
    while !isempty(queue)
        callee = pop!(queue)
        for caller in get(calls_in, Ptr{Cvoid}(callee.ref), LLVM.Function[])
            Ptr{Cvoid}(caller.ref) in allocating && continue
            push!(allocating, Ptr{Cvoid}(caller.ref)); push!(queue, caller)
        end
    end
    total_calls = total_stores = 0
    for f in defined
        skip(f) && continue
        c, s = spill_function_roots!(f, allocating)
        total_calls += c; total_stores += s
    end
    return (calls = total_calls, stores = total_stores)
end

# whether a value is a pointer that can be one into the heap: not the address of something of the stack or of a global
function heap_pointer_candidate(v::LLVM.Value)
    LLVM.value_type(v) isa LLVM.PointerType || return false
    v isa LLVM.Constant && return false
    while true
        v isa LLVM.AllocaInst && return false
        v isa LLVM.Constant && return false
        if v isa LLVM.GetElementPtrInst || v isa LLVM.BitCastInst || v isa LLVM.AddrSpaceCastInst
            v = LLVM.operands(v)[1]
            continue
        end
        return true
    end
end

function spill_function_roots!(f::LLVM.Function, allocating::Set{Ptr{Cvoid}})
    blocks = collect(LLVM.blocks(f))
    index = Dict{Ptr{Cvoid},Int}(Ptr{Cvoid}(bb.ref) => i for (i, bb) in enumerate(blocks))
    key(v) = Ptr{Cvoid}(v.ref)
    # the calls to spill at
    sites = Tuple{Int,Int,LLVM.CallInst}[]       # (block, position in it, the call)
    insts = [collect(LLVM.instructions(bb)) for bb in blocks]
    for (b, list) in enumerate(insts), (k, inst) in enumerate(list)
        inst isa LLVM.CallInst || continue
        callee = LLVM.called_operand(inst)
        if callee isa LLVM.Function
            startswith(LLVM.name(callee), "llvm.") && continue
            key(callee) in allocating || continue
        elseif callee isa LLVM.InlineAsm
            continue
        end
        push!(sites, (b, k, inst))
    end
    isempty(sites) && return (0, 0)
    # liveness of the pointers: what each block defines and uses, and what is alive at its end
    n = length(blocks)
    candidate = Dict{Ptr{Cvoid},Bool}()
    is_candidate(v) = get!(() -> heap_pointer_candidate(v), candidate, key(v))
    defs = [Set{Ptr{Cvoid}}() for _ in 1:n]
    gen = [Set{Ptr{Cvoid}}() for _ in 1:n]
    edge = [Set{Ptr{Cvoid}}() for _ in 1:n]      # what the phis of the successors take from the block
    values = Dict{Ptr{Cvoid},LLVM.Value}()
    for p in LLVM.parameters(f)
        values[key(p)] = p
    end
    for (b, list) in enumerate(insts), inst in list
        push!(defs[b], key(inst)); values[key(inst)] = inst
    end
    for (b, list) in enumerate(insts), inst in list
        if inst isa LLVM.PHIInst
            for (v, from) in LLVM.incoming(inst)
                (v isa LLVM.Argument || v isa LLVM.Instruction) && is_candidate(v) && (push!(edge[index[key(from)]], key(v)); values[key(v)] = v)
            end
        else
            for v in LLVM.operands(inst)
                (v isa LLVM.Argument || v isa LLVM.Instruction) || continue
                is_candidate(v) || continue
                values[key(v)] = v
                key(v) in defs[b] || push!(gen[b], key(v))
            end
        end
    end
    succ = [Int[index[key(s)] for s in LLVM.successors(bb)] for bb in blocks]
    live_in = [Set{Ptr{Cvoid}}() for _ in 1:n]
    live_out = [Set{Ptr{Cvoid}}() for _ in 1:n]
    changed = true
    while changed
        changed = false
        for b in n:-1:1
            out = copy(edge[b])
            for s in succ[b]
                union!(out, live_in[s])
            end
            inn = union(gen[b], setdiff(out, defs[b]))
            if length(out) != length(live_out[b]) || length(inn) != length(live_in[b])
                changed = true
            end
            live_out[b] = out; live_in[b] = inn
        end
    end
    # the slots, and the stores
    entry = first(blocks)
    slots = Dict{Ptr{Cvoid},LLVM.AllocaInst}()
    stores = 0
    LLVM.@dispose builder = LLVM.IRBuilder() begin
        for (b, k, call) in sites
            list = insts[b]
            live = copy(live_out[b])
            defined_from = Set{Ptr{Cvoid}}(key(i) for i in list[k:end])
            for inst in list[k+1:end]
                inst isa LLVM.PHIInst && continue
                for v in LLVM.operands(inst)
                    (v isa LLVM.Argument || v isa LLVM.Instruction) && is_candidate(v) && push!(live, key(v))
                end
            end
            for id in live
                id in defined_from && continue
                v = values[id]
                slot = get!(slots, id) do
                    LLVM.position!(builder, LLVM.before(first(LLVM.instructions(entry))))
                    LLVM.alloca!(builder, LLVM.PointerType(), "root")
                end
                LLVM.position!(builder, LLVM.before(call))
                st = LLVM.store!(builder, v, slot)
                LLVM.volatile!(st, true)
                stores += 1
            end
        end
    end
    return (length(sites), stores)
end

# what is done to the module of a program for wasm64 before its code is made
function prepare_wasm_module!(mod::LLVM.Module)
    devirtualize_ccall_slots!(mod)
    spilled = haskey(ENV, "STATIC_RUNTIME_WASM_NO_SPILL") ? (calls = 0, stores = 0) : spill_gc_roots!(mod) # (the switch is for measuring what the stores cost: a program that has the collector and no stores is not safe)
    haskey(ENV, "STATIC_RUNTIME_TRACE") && spilled.calls > 0 && println(stderr, "[static-runtime] roots of the collector: ", spilled.stores, " stores before ", spilled.calls, " calls")
    # (the code generator for WebAssembly looks at the features of each function, and not only at those of the target machine: `setjmp` needs exception handling)
    for f in LLVM.functions(mod)
        LLVM.isdeclaration(f) && continue
        push!(LLVM.function_attributes(f), LLVM.StringAttribute("target-features", WASM_FEATURES))
    end
    missing_imports = wasm_missing_imports(mod)
    if !isempty(missing_imports) && haskey(ENV, "STATIC_RUNTIME_CROSS_WHY") # (`STATIC_RUNTIME_CROSS_WHY=1`: what in the program uses what the host does not have)
        function callers(f, depth)
            names = String[]
            for u in LLVM.uses(f)
                inst = LLVM.user(u)
                inst isa LLVM.Instruction || continue
                parent = LLVM.parent(LLVM.parent(inst))
                push!(names, LLVM.name(parent))
                depth > 1 && append!(names, callers(parent, depth - 1))
            end
            return unique!(names)
        end
        for n in missing_imports
            println("[static] ", n, " is called from ", join(first(callers(LLVM.functions(mod)[n], 3), 12), ", "))
        end
    end
    isempty(missing_imports) || throw(ArgumentError(string("the program uses ", join(("`$n`" for n in missing_imports), ", "), ", which the host of a program for WebAssembly does not have (`STATIC_RUNTIME_CROSS_WHY=1` says where they are called from; the host is src/runtime/wasm_host_core.js)")))
    return mod
end

# `main` of the executable, in IR: it calls the entry point, `fn`, which takes `(Int, Ptr{Ptr{UInt8}})` (or nothing) and returns an `Int` (or nothing)
function main_wrapper(text::AbstractString, fn::AbstractString, triple::AbstractString)
    m = match(Regex("^define [^@\n]*?(i64|i32|void) @" * fn * "\\(([^)]*)\\)", "m"), text)
    m === nothing && throw(ArgumentError("the entry point `$fn` is not in the program, or has a return type that is not `Int`, `Int32` or `Nothing`"))
    ret, params = m.captures[1], m.captures[2]
    nparams = isempty(strip(params)) ? 0 : count(==(','), params) + 1
    nparams in (0, 2) || throw(ArgumentError("the entry point `$fn` has $nparams arguments: it has two, `(argc::Int, argv::Ptr{Ptr{UInt8}})`, or none"))
    args = nparams == 0 ? "" : "i64 %argc64, ptr %argv"
    call = ret == "void" ? "call void @$fn($args)\n  ret i32 0" :
           ret == "i64" ? "%r = call i64 @$fn($args)\n  %r32 = trunc i64 %r to i32\n  ret i32 %r32" : "%r = call i32 @$fn($args)\n  ret i32 %r"
    guard = triple_system(triple) === :linux ? "@__stack_chk_guard = global ptr inttoptr (i64 $(rand(UInt) >> 1) to ptr)\n" : ""
    # (a program for WebAssembly that has a collector: the collector looks at the stack from where it is to where it was when the program started, which is the top of the stack of the module)
    top = triple_system(triple) === :wasm && occursin("@_static_wasm_stack_top", text) ? "  %sp = call ptr @llvm.stacksave.p0()\n  store ptr %sp, ptr @_static_wasm_stack_top, align 8\n" : ""
    declare = isempty(top) || occursin("@llvm.stacksave.p0", text) ? "" : "declare ptr @llvm.stacksave.p0()\n"
    return string(text, "\n", guard, declare, "define i32 @main(i32 %argc, ptr %argv) {\n", top, nparams == 0 ? "" : "  %argc64 = sext i32 %argc to i64\n", "  ", call, "\n}\n")
end

## Executables

# the generator of `compile_executable` for a target that is not the host's (it is given the entry point as StaticCompiler's is: `f`, its `types`, the `path` and
# the `name`), and the same keywords but the ones of the link, which are the target's
function cross_executable(f::Function, types = (), path::String = pwd(), name = StaticCompiler.fix_name(f);
                          cross::CrossTarget, small::Bool = false, output::Symbol = :executable, filename::String = String(name), demangle = true, also_expose = Tuple{Function,Tuple{DataType}}[],
                          cc = nothing, cflags = ``, llvm_to_clang = true, kwargs...)
    funcs = vcat([(f, types)], also_expose)
    StaticCompiler.check_signature(f, types; kwargs...)
    # (a function that is called `main` would be a second `main`: its symbol has a prefix, as `executable_kwargs` says)
    String(name) == "main" && (demangle = false)
    fn = demangle ? String(name) : "julia_$name"
    output in (:executable, :object, :llvmir) || throw(ArgumentError("`output` is `:executable`, `:object` or `:llvmir`, not `$(repr(output))`"))
    _, ir_path = StaticCompiler.generate_obj(funcs, path, filename; demangle, emit_llvm_only = true, kwargs...)
    obj = joinpath(path, "$filename.$(cross.triple).o")
    exe = joinpath(path, filename)
    keep = String[]
    try
        text = main_wrapper(retarget_ir(read(ir_path, String), cross.triple), fn, cross.triple)
        needs_half_builtins(text, triple_arch(cross.triple)) && (text *= "\n" * X86_HALF_BUILTINS)
        needs_int128_builtins(text, triple_system(cross.triple)) && (text *= "\n" * LINUX_INT128_BUILTINS)
        triple_system(cross.triple) === :wasm && occursin(r"\bhalf\b", text) && (text *= "\n" * WASM_HALF_BUILTINS)
        if output === :llvmir
            ll = joinpath(path, "$filename.$(cross.triple).ll")
            write(ll, text)
            return ll
        end
        emit_cross_object(text, cross, obj)
        output === :object && (push!(keep, obj); return joinpath(abspath(path), "$filename.$(cross.triple).o"))
        objects = String[]
        if triple_system(cross.triple) === :wasm
            runtime_obj = joinpath(path, "$filename.runtime.$(cross.triple).o")
            emit_wasm_runtime_object(cross, runtime_obj)
            push!(objects, runtime_obj)
        end
        extra = cc === nothing ? `` : (cc isa Cmd ? cc : Cmd([String(cc)]))
        try
            exe = cross_link(cross, obj, exe, small, extra; objects)
        finally
            foreach(o -> rm(o; force = true), objects)
        end
    finally
        rm(ir_path; force = true)
        obj in keep || rm(obj; force = true)
    end
    return abspath(exe)
end

# the generator that `compile_executable` and the others of this package use for a cross target
function cross_generator(f::Symbol)
    f === :compile_executable && return cross_executable
    throw(ArgumentError("`target` is not the host's: only `compile_executable` can make a program for it (not `$f`)"))
end
