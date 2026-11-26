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
with_cross_target(f, cross::CrossTarget) = with_target(f, triple_system(cross.triple), Symbol(triple_arch(cross.triple)))

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
function emit_cross_object(text::AbstractString, cross::CrossTarget, path::AbstractString)
    if julia_llvm_has(cross.triple)
        LLVM.@dispose ctx = LLVM.Context() begin
            mod = parse(LLVM.Module, text)
            try
                tm = LLVM.TargetMachine(LLVM.Target(; triple = cross.triple), cross.triple; cpu = cross.cpu, features = cross.features, opt_level = LLVM.API.LLVMCodeGenLevelDefault, reloc = LLVM.API.LLVMRelocPIC)
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
function cross_link(cross::CrossTarget, obj::AbstractString, exe::AbstractString, small::Bool, extra::Cmd)
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
    else
        throw(ArgumentError("programs for $(cross.triple) ($(system)) can not be linked yet"))
    end
    return exe
end

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
    append!(found, String[w for w in HOST_FLAGS if occursin(Regex("@" * w * "\\b(?![\\w.\$])"), text)])
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
    return string(text, "\n", guard, "define i32 @main(i32 %argc, ptr %argv) {\n", nparams == 0 ? "" : "  %argc64 = sext i32 %argc to i64\n", "  ", call, "\n}\n")
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
        if output === :llvmir
            ll = joinpath(path, "$filename.$(cross.triple).ll")
            write(ll, text)
            return ll
        end
        emit_cross_object(text, cross, obj)
        output === :object && (push!(keep, obj); return joinpath(abspath(path), "$filename.$(cross.triple).o"))
        extra = cc === nothing ? `` : (cc isa Cmd ? cc : Cmd([String(cc)]))
        cross_link(cross, obj, exe, small, extra)
    finally
        rm(ir_path; force = true)
        obj in keep || rm(obj; force = true)
    end
    return joinpath(abspath(path), filename)
end

# the generator that `compile_executable` and the others of this package use for a cross target
function cross_generator(f::Symbol)
    f === :compile_executable && return cross_executable
    throw(ArgumentError("`target` is not the host's: only `compile_executable` can make a program for it (not `$f`)"))
end
