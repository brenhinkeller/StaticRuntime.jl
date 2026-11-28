# What cross-compilation can be tried from this machine, and the targets for it: `include`d by the tests (`test/cross/runtests.jl`) and by `test/cross/matrix.jl`. It needs StaticRuntime to be loaded.
#
# A target can be made here if there is a code generator for it (Julia's LLVM has the host's architecture and WebAssembly; an `llc` of the same version of LLVM has another one: `STATIC_RUNTIME_CROSS_LLC`, or
# `STATIC_RUNTIME_CROSS_CLANG` and the `llc` next to it, or on an Apple Silicon Mac the `llc` of `LLVM_full_jll` for x86-64, which Rosetta runs: fetched by a run of the cross-compilation tests (`GROUP=Cross` or `All`) outside CI, see `host.jl`), and the libraries to link with (the glibc of `Glibc_jll`, which
# is fetched for any host; for macOS Xcode's SDK on a Mac, and else the directory in `SDKROOT`; nothing for WebAssembly). What is missing is fetched, and where it cannot be, the reason that the target
# is not made is said (`CrossSupport.target_for`). A target can be run here if the machine can run what it makes (`runs_here`).

using Glibc_jll, Pkg # (the extension of StaticCompiler that fetches the glibc of a Linux target)
include("host.jl")

# the targets: the triples of the systems that StaticRuntime makes programs for (Windows too: the programs that need no processes yet, which the others are refused)
const CROSS_TARGETS = ["aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu", "aarch64-apple-macosx11.0.0", "x86_64-apple-macosx11.0.0", "x86_64-w64-mingw32", "wasm64-unknown-unknown"]

# the version of Julia's LLVM, which an `llc` has to be (`18.1.7`, `23.1.4`: the versions of `LLVM_full_jll`)
llvm_version() = Base.libllvm_version

# An `llc` that has the code generator for `arch`: the one that the environment names, or where Rosetta runs it, the one that `LLVM_full_jll` has for x86-64 macOS
function other_llc(arch::AbstractString)
    candidates = Cmd[]
    haskey(ENV, "STATIC_RUNTIME_CROSS_LLC") && push!(candidates, Cmd([ENV["STATIC_RUNTIME_CROSS_LLC"]]))
    haskey(ENV, "STATIC_RUNTIME_CROSS_CLANG") && push!(candidates, Cmd([joinpath(dirname(ENV["STATIC_RUNTIME_CROSS_CLANG"]), "llc")]))
    for llc in candidates
        isfile(llc.exec[1]) && first(StaticRuntime.llc_supports(llc, arch)) && return llc
    end
    if arch == "x86_64" && rosetta()
        dir = fetch_artifact("LLVM_full_jll", "LLVM_full"; platform = Base.BinaryPlatforms.Platform("x86_64", "macos"), version = llvm_version(), big = true)
        dir === nothing && return nothing
        llc = Cmd([joinpath(dir, "tools", "llc")])
        isfile(llc.exec[1]) && first(StaticRuntime.llc_supports(llc, arch)) && return llc
    end
    return nothing
end

"""
    target_for(triple) -> (target, why)

The `StaticTarget` that makes programs for `triple` on this machine (retargeted, even for the host's own triple: the program is then linked by `lld` and the sysroot, as it is for another system), or `nothing`
and the reason that there is none.
"""
function target_for(triple::AbstractString)
    arch, system = triple_arch(triple), triple_system(triple)
    llc = nothing
    if !StaticRuntime.julia_llvm_has(triple)
        llc = other_llc(arch)
        if llc === nothing
            fetchable = arch == "x86_64" && rosetta() && !fetch_allowed(big = true)
            return (nothing, "no code generator for $arch: it needs an `llc` of LLVM $(llvm_version().major) that has it (`STATIC_RUNTIME_CROSS_LLC`)" *
                             (fetchable ? ", and the one that Rosetta runs is a 2 GB download, which is fetched by a run of the cross-compilation tests outside CI (`GROUP=Cross`, or `All`), or with `STATIC_RUNTIME_CROSS_FETCH=all`" : ""))
        end
    end
    sysroot = nothing
    if system == "linux"
        hasmethod(StaticRuntime.StaticCompiler.glibc_sysroot, Tuple{String}) || return (nothing, "no C library for Linux: it needs `Glibc_jll` and `Pkg` to be loaded (the test environment has them)")
        sysroot = :glibc
    elseif system == "macos" && !Sys.isapple()
        haskey(ENV, "SDKROOT") || return (nothing, "no SDK of macOS: it needs the directory of one in `SDKROOT` (Apple's license has it used on Apple hardware)")
        sysroot = ENV["SDKROOT"]
    elseif system == "macos" && !(Sys.which("clang") !== nothing && Sys.which("xcrun") !== nothing) && !haskey(ENV, "SDKROOT")
        return (nothing, "no SDK of macOS: install Xcode or the Command Line Tools, or set `SDKROOT`")
    end
    target = try
        StaticRuntime.cross_target(triple; sysroot, llc)
    catch e
        return (nothing, first(split(sprint(showerror, e), '\n')))
    end
    return (target, "")
end
