# Cross-compiling

`compile_executable` can make a program for another architecture than the one that compiles it:

```julia
using StaticRuntime
compile_executable(main, (Vector{String},), "build", "hello"; target = "x86_64-apple-macosx11.0.0")
```

`target` is a triple, or [`cross_target`](@ref)`(triple; ...)`, which also says how the machine code is made and how it is linked. It is a `StaticTarget` of StaticCompiler.jl: made for by retargeting (`target.machine` has the triple, the CPU and the features, and `target.llc` the `llc` if one is given), with the toolchain that links it (`target.toolchain`: the `lld` of Julia for Linux and WebAssembly, `clang` with the SDK for macOS). What is missing for the link (the SDK, the C library) is said when the program is linked, so `output = :llvmir` and `output = :object` need neither. A triple that is the architecture and the system of the host is the host's, and nothing is different.

## How it is made

Everything up to the last step is the host's: Julia's inference and code generation, the objects that the program has as constants, and the runtime of this package, which is linked in as LLVM IR. The layout of Julia's objects is the host's, so the target has to be 64-bit and little-endian (x86-64, AArch64, and  `wasm64`); `wasm32` is not feasible.
That IR is then made for the target, by [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) (the target is a `StaticTarget(triple; retarget = ...)`, see its documentation): the IR gets the triple of the target and no data layout (the code generator has the target's) and loses the host's CPU and features, and IR that has the intrinsics of another architecture is refused. The `main` that calls the entry point, and the builtins that the link has not (`__udivti3` and the other functions that a C runtime library has: `i128` division on Linux, the conversions of `Float16` on x86-64 and WebAssembly), are added to it. This package then changes what is the system's: the names of its C library, the standard streams, `setjmp` and the top of the stack on WebAssembly (`finalize_cross_module!`, with LLVM and not text). The machine code is made, and the program is linked by a toolchain of StaticCompiler: `LLDToolchain` with the `lld` that Julia has for Linux and WebAssembly, and the system's `clang` with the SDK for macOS (`StaticCompiler.link`).

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
using StaticRuntime, Glibc_jll, Pkg # (the extension of StaticCompiler that fetches the glibc of the platform, for any host)
compile_executable(main, (Vector{String},), "build", "hello"; target = cross_target("aarch64-unknown-linux-gnu"; sysroot = :glibc))
```

`sysroot = :glibc` is the `Glibc_jll` artifact for the architecture of the triple (`StaticCompiler.glibc_sysroot(triple)` is the directory). Another glibc is given as the directory: `sysroot = "/path/to/root"`.

### Which glibc, and where the program runs

The glibc that a program is linked with is the **oldest that it runs on**, and it is the version of the `Glibc_jll` of the environment, which is 2.35 unless it is pinned: a program made with it needs glibc 2.34 or newer, and does not run on Ubuntu 20.04, Debian 11, RHEL 8 or Amazon Linux 2. To make programs that run on older systems, pin an older one, with `Pkg.add(name = "Glibc_jll", version = "2.17")` or in `[compat]`:

| `Glibc_jll` | architectures | programs need |
|:------------|:--------------|:--------------|
| 2.17.1 | x86_64, i686, powerpc64le | glibc 2.17 (CentOS 7, Ubuntu 14.04, ...) |
| 2.19.1 | also aarch64, armv7l, armv6l | glibc 2.17 |
| 2.35.0 (the default) | all of them | glibc 2.34 (Ubuntu 22.04, Debian 12, ...) |

`StaticCompiler.glibc_version(sysroot)` says which a directory has. What a newer glibc has cannot be linked with an older one: `Process` needs 2.29 (`posix_spawn_file_actions_addchdir_np`), so a program that uses it is made with 2.35 (the link fails with that function as an undefined symbol, and says so). The programs of `test/cross/programs.jl` but that one all link with 2.19.1 for aarch64, and then need only glibc 2.17; `julia test/cross/sysroot.jl aarch64 2.19` fetches that sysroot.

The code of this package that differs between the systems (the flags of `open`, `struct stat`, `readdir`, the clock, the stack of the collector, the names of the standard streams and of `sigsetjmp`) is chosen by the target when the program is compiled, so a program that uses files, directories, processes, the collector and the clock is made for Linux as it is for macOS. The program links against glibc's own functions; a symbol that Linux does not have is refused when compiling (and `Mmap`, whose flags are chosen by the host's Julia, is not available for another system).

`output = :object` and `output = :llvmir` give the object file and the IR for the target instead of the executable, which is what to use to link somewhere else.

**Testing.** The cross-compilation tests are a group of their own, `GROUP=Cross` (`test/cross/runtests.jl`; `] test` runs it too, as part of `All`), and CI does not run it (the Core tests do run `test/core/cross.jl`, which needs no tool): the workflow `.github/workflows/cross.yml` does, in the form of a matrix. `test/cross/matrix.jl` makes every program of `test/cross/programs.jl` for every target that each kind of host can make (a table of what each made, in the summary of each job), and `test/cross/run.jl` runs them on a machine of the target (Linux and macOS on x86-64 and AArch64, and WebAssembly with Node.js) and compares them with the native ones. On a machine of your own the group makes programs for every target that the machine can make and run, and compares what they do with what the same programs do made for the host (`test/cross/here.jl`; the tests that make nothing to run, the targets and the IR, are in `test/core/cross.jl`, and run in CI with the Core tests): what is missing is fetched (the glibc, Node.js 24 for WebAssembly, and on an Apple Silicon Mac the `llc` for x86-64 that Rosetta runs: 2 GB, outside CI; `STATIC_RUNTIME_CROSS_FETCH=0` stops this, and `all` fetches it for any group), and a target that cannot be tried is skipped with the reason in the log. By hand, `test/cross/matrix.jl` does the same as in CI for one machine, `test/cross/build.jl <triple> <outdir> [sysroot]` makes the programs for one target (with the sysroot that you give), `test/cross/sysroot.jl <arch> [glibc version]` fetches a glibc, an older one for programs that have to run on older systems, and `test/cross/check.jl <outdir>` (which needs only Julia) runs programs on the machine of the target.

## macOS

On a Mac a program for macOS is linked by Apple's `clang` and linker, with the SDK of Xcode (`sysroot` gives another). On any other host it is linked by `lld` (`StaticCompiler.LLDToolchain(:darwin)`), which needs an SDK of macOS: the directory is `sysroot = "/path/MacOSX11.3.sdk"`, or the environment variable `SDKROOT`. An SDK is Apple's, and has to be provided (BinaryBuilder uses the ones of [phracker/MacOSX-SDKs](https://github.com/phracker/MacOSX-SDKs)). **What has been checked:** on a Mac, `lld` with the SDK of Xcode and with the downloaded 11.3 one: a program that `lld` links is signed (ad hoc) as the arm64 system asks, and behaves as the one that Apple's linker makes (a program of this package that prints, uses math and catches an exception was run both ways, with the same output and a size that differs by less than 1%). And **from Linux**, x86-64 and AArch64 hosts with the downloaded SDK (the workflow of `test/cross/matrix.jl`, in StaticCompiler.jl): the programs that were made there ran on macOS, on Apple Silicon (an x86-64 one with Rosetta) and on Intel. Those were programs of StaticCompiler.jl; programs of this package for macOS from Linux have not been tried. And **from Windows** (x86-64, the same workflow, which extracts the SDK with real symbolic links: `MSYS=winsymlinks:nativestrict`): the program for x86-64 macOS is made and linked there, the same as on Linux, and it ran on macOS, on Intel and on Apple Silicon (with Rosetta). Those too were programs of StaticCompiler.jl: programs of this package for macOS from Windows have not been tried.

The code generator for the architecture has to be there too: Julia's LLVM has the host's. A program for x86-64 macOS from an Apple Silicon Mac needs the `llc` above, and a program for AArch64 macOS from an x86-64 host needs an `llc` that has AArch64 (see `STATIC_RUNTIME_CROSS_LLC`).

## Windows

`target = "x86_64-w64-mingw32"` makes a program for 64-bit Windows, from any host, and on Windows itself (where the programs that are made without a `target` are made this way too). The program is linked by the `lld` that Julia has, with the libraries of
MinGW-w64 (`Mingw_jll`, fetched for any host, when the program is linked: IR and objects need none) and the C library of Windows that they link with, `msvcrt`; it is an `.exe` that needs no DLL but the system's. A program for the runtime of
MSVC (`x86_64-pc-windows-msvc`) is refused. The architecture is x86-64 (the code for the host has to be made by a code generator for it, as for any other target: see above).

**What it has, so far:** programs that print, that catch errors, that allocate and have the collector, that read the clock (`time_ns`, `time`), the arguments of the command line, **files, directories and the environment**, and that use the numbers of 128 bits and of
`Float16` that the C library of Windows has no functions for (the program has them). How it is different from the other systems:

* **Exceptions.** `try` and `throw` are LLVM's `llvm.eh.sjlj.setjmp` and `llvm.eh.sjlj.longjmp`, with a buffer of five words (the frame register, where to go, and the stack pointer), and not `sigsetjmp` and `siglongjmp`, which Windows has not (its `_setjmp`
  keeps 256 bytes, which the handler of a program is not, and its `longjmp` unwinds by the information of the frames).
* **The standard streams** are what `__iob_func()` of the C library has, and not the global variables that macOS and Linux have; and they are **binary** (`_setmode`) before the program starts, so that a line feed that a program writes is not turned into a
  carriage return and a line feed, as it is not in Julia.
* **The collector** asks the system for the stack of the thread (`GetCurrentThreadStackLimits`); the registers are saved by `_setjmp` of the C library. The stack of the main thread is 8 MiB, as it is on Linux and macOS (the linker's own is smaller).
* **The clock** is the performance counter (`QueryPerformanceCounter`) and the file time of the system (`GetSystemTimePreciseAsFileTime`); `sleep` is `Sleep`, and the entropy of the system is `SystemFunction036`.
* **Paths are UTF-8 in Julia**, and what the C library of Windows takes by default is the code page of the system: the functions that take a path are the wide ones (`_wfopen`, `_wopen`, `_wstat64`, `_wmkdir`, `_wunlink`, `_wgetcwd`, ...), given UTF-16 (`wide_cstring` in
  `src/overrides/windows.jl`), so a file can have any name.
* **Files** are streams of the C library, **binary** (the mode of `fopen` and the flags of `open` have `b` and `_O_BINARY`), with offsets of 64 bits (`_ftelli64`, `_fseeki64`: `ftell` and `fseek` take a `long`, which is 32 bits on Windows). **`rename`** (and so `mv`)
  replaces what is there, and works from one volume to another, as Julia's (`MoveFileExW`); **directories** are read with `FindFirstFileW`; **`stat`** is `_wstat64` (the blocks and the size of a block are made up as libuv makes them, the number of links and the
  times are the system's, and there are no links: `lstat` is `stat`); **`realpath`** is the full path of a file that is there (`GetFullPathNameW`); **temporary names** are made of the system's entropy and made new (`O_EXCL`); **`ENV`** is `_wgetenv` and `_wputenv_s`
  (a variable that is set to nothing is removed); and **`chmod`** is whether the file can be written, which is all that Windows has of a mode.
* **The numbers of `errno`** are those of the C library of Windows (`ENOTEMPTY` is 41, where Linux has 39 and macOS 66), and an error of one of Windows's own functions (`GetLastError()`) is turned into the `errno` that the C library would have (`windows_errno`).
* **The paths follow the host's `Base`** in what is chosen by the system when Base is compiled (the separator of `joinpath`, what an absolute path looks like): a program for Windows that is made on Linux or macOS joins paths with `/`, which Windows accepts.

**What it has not, yet:** processes (`run`, `pipeline`, `success`), links (`symlink` and `readlink` need a privilege), loading libraries when the program runs, `mmap`, locks, ownership and permissions other than whether a file can be written, and paths that are longer than 260
characters (they need the prefix `\\?\`). A program that uses them is refused when it is made, with the functions that it uses (`ONLY_POSIX` in `src/cross.jl`). Shared libraries (`compile_shlib`) are not made for Windows. The code page of the console is not
changed: text that is not ASCII is written as UTF-8, which a console shows as it is set to.

**What has been checked.** The programs are made, linked (against the libraries of MinGW-w64, so every function that they call is one that the libraries have) and, on a Mac, the IR and the code that LLVM makes for the exceptions are looked at; the tests
(`test/core/target.jl`, "A program for Windows") check the IR on any host. That the programs run is checked in CI, on Windows (`.github/workflows/cross.yml`: the programs of `test/cross/programs.jl` that Windows is not refused for are made on every kind of host and
run on a Windows machine): that is the one thing here that has not been run by the person who wrote it, as there was no Windows machine to run it on.

## WebAssembly

`target = "wasm64-unknown-unknown"` makes a program for WebAssembly with 64-bit memory (`memory64`), which is the only kind that is possible: the objects of Julia have 8-byte pointers in them, so `wasm32` is not. `compile_executable` writes `name.wasm` and, next to it, `name.mjs`, the host that runs it with Node.js 24 or later (where `memory64` is on by default): `node name.mjs arguments...`. The host is a file of JavaScript, `src/runtime/wasm_host_core.js` (with `wasm_host_node.mjs`), that has the functions of the C library that the runtime and the programs call (`write`, `fwrite`, `printf`, `calloc`, the `memcpy` family, the clock, `getentropy`, the system (process id, host name, time zone, `sysconf`, environment variables), libm (`erf`, `erfc`, `tgamma` and `lgamma` are series and continued fractions that are accurate to a unit or two of the last digit: not those of a C library), and the 128-bit integer arithmetic that WebAssembly has no instructions for). The string functions (`strlen`, `strcmp`, `memcmp`, ...), `qsort` and `bsearch` are not the host's: they are in the module (a call of the host costs a few hundred times a call of a function), and `qsort` is a shell sort, which is not stable.

* The program is made with the code generator for WebAssembly of Julia's LLVM and linked with the `lld` that Julia has. Exceptions are WebAssembly's own: `try` and `throw` of the runtime are `setjmp` and `longjmp`, which the code generator makes into them (with the three functions of the C library for that, in `src/cross.jl`).
* **Memory.** The memory is the module's linear memory, which grows when the program needs it (4 MiB or more at a time) as far as the machine allows, or as far as `--max-memory` says: `cross_target("wasm64-unknown-unknown"; cflags = ``--max-memory=268435456``)` (the initial size is `--initial-memory`). When it can't grow, `malloc` and `calloc` give `NULL` and the program stops as a native one does: `Out of memory error` on the standard error, and status 1. The host has a `malloc`, `calloc`, `realloc` and `free` of the C library, with the blocks that are freed reused by size.
* **The collector** of the runtime is in a program for WebAssembly that needs it (one that allocates in a loop), as in a native one (`gc = :auto`; `gc = true`, or a number for stress mode, as for native programs). It looks for what is in use in the memory of the stack, but a WebAssembly function keeps pointers in locals, which are not in memory, where a call that collects could not see them. So before each call that can reach a collection, a pass (`spill_gc_roots!`) stores every pointer that is in use after the call to a slot in the frame: only the calls of functions that can allocate are given stores (a call graph says which), and only pointers that can point into the heap are stored (not those of the stack or of the data). The program has about 22 kB more for it. Stress mode (`gc = 3`: a collection every 3 allocations, what is freed overwritten) is how it is tested: the programs of `test/cross` do what the native ones do in it. Integers that hold addresses (`UInt(pointer(x))`) are not stored, as they are not pointers to the pass.
* **Files, directories and the environment** are those of the machine that Node.js runs on, through its `fs` module (`open`, `fopen` and the stdio functions, `stat`, `readdir`, `mkdir`, `rename`, `unlink`, `mkstemp`, `getenv`, ...): the position of a file is kept in the host (Node has no `lseek`), the layouts of `struct stat` and of the entries of a directory are Linux's, and the error numbers (`errno`, `strerror`) are Linux's whatever the system. In a browser there is no file system to give: the host has to be another.
* A program that needs what the host does not have (processes, `Mmap`, ...) is refused when it is made, with a list of what it needs. The host is where to add them.
* **Linear algebra** has no BLAS or LAPACK to load in a program for WebAssembly, so the functions of them that programs use are replaced by Julia ones when `LinearAlgebra` is loaded (`ext/StaticRuntimeLinearAlgebraExt.jl`; `replace_on_target!`): level 1 (`dot`, `nrm2`, `asum`, `axpy!`, `scal!`), `gemv!`, `gemm!`, `syrk!`, `trsv!` and `trsm!`, and from LAPACK the LU factorization (`getrf!`, `getrs!`, `getri!`: `lu`, `\`, `det`, `inv`), Cholesky (`potrf!`, `potrs!`), pivoted QR (`geqp3!`, `ormqr!`, `laic1!`: the fallback of `\` for singular matrices) and triangular solves. They are the reference algorithms, with the factors that LAPACK gives (the results are the same to rounding: the sums are in another order). Not yet: the eigenvalue and singular value decompositions (`eigen`, `svd`: `dlopen` is refused), the blocked QR (`qr` of a matrix without pivoting), and what is in SuiteSparse (`SparseArrays` factorizations). `STATIC_RUNTIME_CROSS_WHY=1` says which functions of the program call what the host does not have.
* **What works** was surveyed by running the cases of the test suite as programs for WebAssembly (`test/cross/survey.jl` for the files of `test/core`, and `STATIC_RUNTIME_SURVEY=report.tsv GROUP=Packages PACKAGES=dates,statistics julia --project -e 'using Pkg; Pkg.test()'` for the packages; `test/cross/classify.jl report.tsv` groups what fails by reason; `STATIC_RUNTIME_NODE` is the `node` that runs them). The cases that fail do so for one reason: the program needs a native library (`dlopen`: `eigen`/`svd`, SuiteSparse, GMP and MPFR (`BigInt`, `BigFloat`), `Rmath` and other libraries of JLL packages, which have no WebAssembly build) or something of the system that has no equivalent (`/proc`, `wcsftime`, processes).
* Not yet: vectors of `Float16` (the code generator can't make them; refused), processes, and files in a browser.

### In a browser

`compile_executable` also writes `name.browser.mjs`, the host for a page (or Deno, Bun, a Web Worker), which has the same functions as the one for Node.js but keeps the files in memory:

```js
import { run } from './name.browser.mjs';
const result = await run('name.wasm', {
    args: ['--iterations', '100'],
    files: { '/data/input.csv': csvText },          // the files that the program can open (text or bytes)
    stdin: '',
    stdout: (text) => output.append(text),
    stderr: (text) => console.error(text),
});
result.exitCode; result.readFile('/out.csv');       // what the program wrote (bytes); result.list('/') lists a directory
```

The program runs to its end where `run` is called, so in a page it belongs in a Web Worker (`new Worker(url, { type: 'module' })`). `/tmp` is there for `tempname` and `mktempdir`; `env` and `cwd` are options. The browser needs `memory64` (Firefox 134 or later, Chrome 133 or later; not Safari yet), WebAssembly exceptions with `exnref` and SIMD. The 18 programs that `test/cross/programs.jl` had when this was last checked do what the native ones do in headless Firefox 162: `BROWSER=/Applications/Firefox.app/Contents/MacOS/firefox node test/cross/check_browser.mjs <outdir>` (without `BROWSER`, the same host runs in Node.js, which checks its logic). The layers of the host are `src/runtime/wasm_host_core.js` (the C library and the system, for all platforms), `wasm_host_node.mjs` (Node's `fs`, the clock and the streams) and `wasm_host_browser.mjs` (the in-memory file system, `run`); `cross_link` joins the core to each shell.

## What works

| host | target | state |
|:-----|:-------|:------|
| macOS, AArch64 | `x86_64-apple-macosx...` | works, with the `llc` above; the programs run with Rosetta (all 21 programs of `test/cross/programs.jl`, files, directories, processes and the collector among them, in a local run of the tests) |
| macOS, AArch64 | `aarch64-apple-macosx...`, `aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-gnu` | made and linked (21 programs) by `lld` with a glibc sysroot (Linux: with the `llc` above for x86-64), and by Apple's linker for macOS; the Linux ones are run in CI on a Linux machine of the architecture (`cross.yml`) |
| Linux, x86-64 and AArch64 | Linux and macOS of the architecture | made in CI (macOS with a downloaded SDK), and run on a machine of the target: Linux on both architectures, macOS on Intel and on Apple Silicon |
| any | `wasm64-unknown-unknown` | works, with Node.js 24 or later; 19 of the 21 programs of `test/cross/programs.jl` do what the native ones do, exceptions, files and the collector included (the others use processes, or vectors of `Float16`) |
| any | `x86_64-w64-mingw32` | made and linked (20 of the 21 programs: all but the one that uses processes); run in CI on Windows (see above) |
| others | | not tried |

Code that Base chooses by the host's system when Base is compiled is the host's: what a program that uses it does on another system is not checked (the standard library functions that this package replaces are, see above). Libraries that are loaded when the program runs (BigInt, BLAS) are the host's, and are not for another system. The conversions between `Float16` and `Float32` on x86-64 use the instructions of F16C (a CPU of 2012 or later); on WebAssembly they are made by integer arithmetic.
