# Cross-compiling

`compile_executable` can make a program for another architecture than the one that compiles it:

```julia
using StaticRuntime
compile_executable(main, (Vector{String},), "build", "hello"; target = "x86_64-apple-macosx11.0.0")
```

`target` is a triple, or [`cross_target`](@ref)`(triple; ...)`, which also says how the machine code is made. A triple that is the architecture and the system of the host is the host's, and nothing is different.

## How it is made

Everything up to the last step is the host's: Julia's inference and code generation, the objects that the program has as constants, and the runtime of this package, which is linked in as LLVM IR. The layout of Julia's objects is the host's, so the target has to be 64-bit and little-endian (x86-64, AArch64, and, later, `wasm64`); `wasm32` is not possible.
That IR is then made for the target (its `target triple` is changed, and its data layout is left to the code generator), the machine code is made, and the program is linked.

The machine code is made as it is for the host: by the code generator alone, without optimizing the IR again, which Julia has done (making it with `clang -O2` changes what some programs do). It is made

* by Julia's own LLVM, in this process, if it has the code generator for the triple (Julia's has the host's architecture, and WebAssembly);
* otherwise by `llc` of an LLVM of **the same version as Julia's** (`Base.libllvm_version`), which has the code generator. Give it with `cross_target(triple; llc = ...)`, or with the environment variable `STATIC_RUNTIME_CROSS_LLC` (or `STATIC_RUNTIME_CROSS_CLANG`, whose neighbor `llc` is used).

On an Apple Silicon Mac, an `llc` for x86-64 can come from the `x86_64-apple-darwin` build of `LLVM_full_jll`, which runs with Rosetta (its artifact is about 2 GB):

```julia
using LLVM_full_jll, Pkg.Artifacts, Base.BinaryPlatforms
toml = joinpath(dirname(dirname(pathof(LLVM_full_jll))), "Artifacts.toml")
meta = artifact_meta("LLVM_full", toml; platform = Platform("x86_64", "macos"))
ensure_artifact_installed("LLVM_full", meta, toml; platform = Platform("x86_64", "macos"))
ENV["STATIC_RUNTIME_CROSS_CLANG"] = joinpath(artifact_path(Base.SHA1(meta["git-tree-sha1"])), "tools", "clang")
```

## Linux

A program for Linux needs the C library of the target to link with. `sysroot` is a directory with the `lib` of a glibc (`crt1.o`, `libc.so`, `libm.so`, ...), and the program is linked with the `lld` that Julia has, so nothing but the C library has to be found. The `Glibc_jll` artifact for the platform is one, and can be fetched for any host:

```julia
using Glibc_jll, Pkg.Artifacts, Base.BinaryPlatforms
toml = joinpath(dirname(dirname(pathof(Glibc_jll))), "Artifacts.toml")
platform = Platform("aarch64", "linux"; libc = "glibc")
meta = artifact_meta("Glibc", toml; platform)
ensure_artifact_installed("Glibc", meta, toml; platform)
sysroot = artifact_path(Base.SHA1(meta["git-tree-sha1"]))

compile_executable(main, (Vector{String},), "build", "hello"; target = cross_target("aarch64-unknown-linux-gnu"; sysroot))
```

The code of this package that differs between the systems (the flags of `open`, `struct stat`, `readdir`, the clock, the stack of the collector, the names of the standard streams and of `sigsetjmp`) is chosen by the target when the program is compiled, so a program that uses files, directories, processes, the collector and the clock is made for Linux as it is for macOS. The program links against glibc's own functions; a symbol that Linux does not have is refused when compiling (and `Mmap`, whose flags are chosen by the host's Julia, is not available for another system).

`output = :object` and `output = :llvmir` give the object file and the IR for the target instead of the executable, which is what to use to link somewhere else.

To check programs for a system that can't run here, `test/cross/build.jl <triple> <outdir> [sysroot]` makes a set of programs for it and records what the same programs do natively, and `test/cross/check.jl <outdir>` (which needs only Julia) runs them on the machine of the target and compares.

## What works

| host | target | state |
|:-----|:-------|:------|
| macOS, AArch64 | `x86_64-apple-macosx...` | works, with the `llc` above; the programs run with Rosetta. 13 programs (files, directories, processes, the collector among them) are checked in `test/cross/build.jl` and `test/core/cross.jl` |
| macOS, AArch64 | `aarch64-unknown-linux-gnu` | built and linked (13 programs) with Julia's LLVM and a glibc sysroot; to be run on a Linux machine with `test/cross/check.jl` |
| macOS, AArch64 | `x86_64-unknown-linux-gnu` | the same, with the `llc` above |
| others | | not tried; WebAssembly needs a runtime of its own |

Code that Base chooses by the host's system when Base is compiled is the host's: what a program that uses it does on another system is not checked (the standard library functions that this package replaces are, see above). Libraries that are loaded when the program runs (BigInt, BLAS) are the host's, and are not for another system. The conversions between `Float16` and `Float32` on x86-64 use the instructions of F16C (a CPU of 2012 or later).
