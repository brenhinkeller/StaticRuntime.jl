# Limitations, testing and reference

## Known limitations

What does not work yet, or works differently from Julia, gathered in one place. The sections above say more about each.

**Platforms**

* **macOS and Linux** only for the collector (`gc = true`, or `gc = :auto` for a program that needs it); elsewhere it is off by default, and a program that needs it is an error. **Linux is
  tested on CI** (x86 and aarch64), not by hand: the collector depends on the layout of the stack and `setjmp` of the C library, and BLAS on `dlopen`.
* **The host is the target.** The heap and the runtime are made for the machine that compiles, so cross-compiling (a `target` that is
  not the host) is not supported.
* BLAS and LAPACK need LBT and the libraries that back it **at the same paths when the program is run** (see
  [Linear algebra and BLAS](@ref)); they are not in the binary. The same is true of any other library that the program calls, unless `libraries = :bundle`
  is used (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)); BLAS is not bundled yet.

**Refused, because the answer would otherwise differ from Julia's**

* **Constant tables hashed by address.** A `const` `Dict` or `Set` whose keys are mutable objects (or hold one) with no `hash` method of
  their own, and any non-empty `IdDict`, are made in Julia with the addresses of their keys, which are not the addresses of the copies in the binary: a
  lookup would quietly find nothing. Compiling such a constant is an error that says so. Define `Base.hash` (and `==`) for the key type, or make the table
  when the program runs (a table that is made by the program is fine).
* **`deepcopy` of a type with a package's own `deepcopy_internal`.** The copy here is made field by field, which is not what that method does, so
  compiling warns, and the program stops if it reaches the copy.
* **Writes that fail.** A write, `flush` or `close` that libc reports as failed (a full disk, a closed pipe) throws, as in Julia. And if the system
  has no entropy for the default random number generator, the first `rand()` throws, rather than the program using a fixed seed (`Random.seed!` makes
  one that is meant to be fixed).
* Loops with `@simd` (so `sum`, `dot`, `mean`, ...) are vectorized and their reductions reordered, as in Julia, so the results are the same as
  Julia's, to the last digit, when it is run on the same machine type; other machines (SIMD widths) may differ in the last digits, in Julia as here.

**Standard libraries** (a survey of them is kept in `test/packages`, and what does not work, and what happens then, in `test/core/limitations.jl`)

* Work: Base64 (`base64encode` of strings, bytes, numbers, arrays of numbers and what a function writes, `base64decode`, and `Base64EncodePipe` and `Base64DecodePipe` of an `IOBuffer`), CRC32c, SHA, UUIDs (`uuid4()` too), `Random.RandomDevice`, Mmap (`Mmap.mmap(path, Vector{T}, dims, offset)`: the memory is not unmapped before the program ends), Statistics, Random, Printf, Logging (`NullLogger`), Libdl (`dlopen`, `dlsym` and `dlclose` of libraries opened when the program runs, not `DL_LOAD_PATH`), Future (`copy!`; not `randjump`), Serialization (`serialize` writes the bytes that Julia writes, and `deserialize` reads a value of one of the types that the program has: see [Serialization](@ref)), Dates, SparseArrays (with the factorizations), most of LinearAlgebra (`exp`, `sqrt`, `log` and powers of a matrix, `eigen`, `svd`, `qr`,
  `cholesky`, `lu`, `schur`, `ordschur`, `hessenberg`, `inv`, `det`, `\`, `opnorm`, ...), Sockets' address types, and the file system (see [The file system](@ref)).
* Do not: `Unicode.normalize`, `graphemes` and `isequal_normalized` (the tables are in libjulia's copy of utf8proc, which is not a library of its own); `readdlm` / `writedlm`; `@allocated` (the heap does not count the bytes of each allocation; `@allocations` gives -1); `@time` and `@timed` work, but measure only the time (the bytes, the time of the collector and of the compiler are zero, and `@time` writes only the seconds);
  `TOML.parse` (the parser keeps a `Module`); `Markdown.parse` is refused when compiling, or stops with a message when it is run (its parser needs Julia's own); `Mmap` of an open stream, and anonymous ones (only the files that are named by their path are mapped); `Test` (`@test` and `@testset`); `with_logger` with a logger other than `NullLogger`; starting other programs;
  `base64encode` of several values of different types in one call, and `base64encode(f, args...)` of a function with arguments. Also not supported, found by a survey of Base and the standard libraries: weak references (`WeakRef`, `WeakKeyDict`); `Printf.Format` of a format
  that the program makes (`@printf`, `@sprintf` and a constant `Format` work); `Dates.canonicalize` (a `CompoundPeriod` holds a `Vector{Period}`); `instances` of an `Enum`
  (`show` and comparisons of one work); `TOML.print`, and `Serialization` of a value that is a type or a module in a tuple or a field (`serialize((Int, 1))`), of a `UnionAll`, or whose type is not known when compiling (see [Serialization](@ref)); `Timer` and TCP sockets (libuv's
  loop of events); `stacktrace`, `catch_backtrace` and `current_exceptions`; `Meta.parse` and `Expr`s made when the program runs; `methods` and `which`; `Base.summarysize`; and
  `versioninfo`.

**Tasks, threads and `eval`**

* **Tasks run to their end** (see [Tasks](@ref)): `@async`, `Threads.@spawn`, `Task`, `schedule`, `wait`, `fetch`, `yield`, `@sync`, `Condition` and `Channel` work, on the one thread, and a task runs when something waits.

* **A `NamedTuple` (or the keywords of a call) that holds a value of a small union of types** (`f(x; bgcol = c)` with `c` a `UInt32` or `missing`, `merge` of such) has the union as the type of its field: `@NamedTuple{bgcol::Union{Missing,UInt32}}`, where Julia's is that of the value, `@NamedTuple{bgcol::UInt32}`. `typeof` says so, and a method for the one is not a method for the other. (The type of the value is only known when the program runs, and Julia's way would be a call of the runtime.) A keyword whose value is a type (`canvas = AsciiCanvas`) is of the type of Julia.
* There is **no `eval`**, and no keyword form of `invokelatest`; **`@cfunction`** of a function with captured state (a closure over a variable) does not work (see [Callbacks: `@cfunction`](@ref)). (`Regex`, `BigInt` and `BigFloat` work: see
  [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref).)
* **The heap is not thread-safe.** A program, or a library from `compile_shlib`, allocates from one thread at a time. A library that
  is called on a stack that is not that of the thread (a task of Julia running on another thread) **frees nothing** in that call
  (see [Memory and the garbage collector](@ref)).

**What is dynamic**

* **Dynamic dispatch** is resolved for abstract types with at most 16 concrete subtypes that can be listed, and for `Any` and the other
  abstract types over the registered types (see [Dynamic dispatch on abstract types and on `Any`](@ref)): a value of a type that is not
  registered aborts the program when it reaches such a call. It is not resolved for types that can't be listed and have no registered
  subtype (`IO`). These, `Core.Box` variables with a type that is not known, **non-`const` globals**, splatting a collection whose
  length is not known when compiling (`f(v...)`), and calls that compute a type at run time (`typejoin`, a `Dict` made from pairs
  with abstract values, `sum(f, v)` of a `Vector{Any}`, `isprime`) are rejected when compiling (`UnsupportedCodeError`), or abort the
  program if compiled with `strict = false`.
* **Values that are only known at run time** (an element of a `Vector{Any}`) can't be the argument of `objectid` or `hash` unless their types
  are registered, nor `===` of types and unions, and `show` of one is limited to the registered types (see [`show` of containers, types and structs](@ref)).
* `titlecase` of a string needs the grapheme breaks of utf8proc, which are in libjulia, and is not supported.

* **Tuples that have a `Union` as an element** (`Tuple{Union{Vector{Float64},Vector{ComplexF64}},Int}`: what a function returns when the type of one of two values depends on the data) are made and read as
  one of the tuples that they are made of (`Tuple{Vector{Float64},Int}` or `Tuple{Vector{ComplexF64},Int}`), as a call on a union is made over its cases, when there are at most as many of them as `split_limit`
  says (64): returned by a function that is not inlined, stored in an array, or made by `enumerate`. One of more cases, or of elements of abstract types, is made by Julia with the types that the values have
  when the program runs, which an executable can't make, and is rejected when compiling.
**What a binary starts with**

* **What the compiling Julia has is copied.** A `const` container, a `Ref`, a string, ... is in the binary as it was when compiling, and
  the program changes its own copy (so `ARGS` is set by the program, from its command line; and a global that the program changes
  does not change the Julia that compiled it). Only what is of a type that can be reproduced is copied: not a `Module`, a `Task`, ...
* **The collector is conservative:** it finds references by what looks like an address, so a number can keep an object that is not
  used, and a reference that is hidden (not in the stack, the registers, the data copied from the compiler, or an object of the heap)
  is not found. Memory that is allocated with `malloc` is not looked at (see [Memory and the garbage collector](@ref)). **The blocks of small objects
  are not returned to the system** once the heap has them (though they are used again); large objects are.

**Differences from Julia when the program runs**

* **At most 256 `try` blocks are active at once** (and 256 exceptions being handled): more prints `fatal: exception handler stack overflow`
  and exits. An exception that nothing catches prints `fatal: uncaught exception (no handler to catch it)` and exits with status 1,
  without a backtrace or the message of the exception.
* **An exception that is caught (`catch e`) is a value of the type `Any`**, and the calls on it are made over the registered types, which the
  exceptions of Base are not: `typeof(e)`, `e isa T` and the exceptions of your own types work, but `e.msg`, `showerror(e)` and `sprint(showerror, e)` of a
  `BoundsError`, `KeyError`, `DomainError`, `AssertionError`, or an `ErrorException` with a message that the program makes, stop the program with a
  `MethodError` (or are refused when compiling). A `lazy"..."` string that the program turns into a `String` is an error too (see the comment of
  `Base.String(::LazyString)` in `src/overrides/strings.jl`).
* **There is no stack overflow check:** infinite recursion crashes (segmentation fault) instead of throwing `StackOverflowError`.
* **Locks do nothing** (there is one thread), and `islocked` is `false`.
* **Files** are libc streams: `eachline` of a file closes it only when the loop reaches the end (not on `break`), `seek` and
  `skip` don't report errors, `open` takes only a C `fopen` mode, and the keyword arguments of `readline` and `eachline` (`keep = true`)
  are not supported. Sockets are not available (only the types of addresses of `Sockets` are).
* **`rand` without a seed** gets its state from the operating system (`getentropy`); if that fails the first `rand()` throws, rather than
  giving the same stream each time. `RandomDevice` and `uuid4()` read `getentropy` at each call.
* The output is **unbuffered beyond libc's**: `print` and `println` write through `FILE*`, which libc flushes when the program exits
  (not if it crashes).

## Testing that something compiles

```julia
julia> using StaticRuntime

julia> @static_test sum(rand(10)) < 10     # compile, run, and compare with Julia
Test Passed

julia> static_status(() -> length(string(12345)))
(:ok, "")
```

[`static_status`](@ref) reports how far something gets: `:compile_error`, `:link_error`,
`:runtime_error`, `:mismatch` or `:ok`. [`undefined_symbols`](@ref) lists what the compiled code
needs besides libc.

## Package internals and testing

### Source layout

* `src/method_table.jl`: our method table, `@device_override` and the parameters of our compilations; `src/StaticRuntime.jl`: the module, `compile_executable` and the other entry points; `src/extensions.jl`: the functions that package extensions add methods to; `src/registry.jl`: what packages register (`REGISTRY`, which each compilation copies when it starts).
* `src/overrides/`: the overlay methods of Base and of the standard libraries, by topic (`io.jl`, `printing.jl`, `strings.jl`, `collections.jl`, `system.jl`, `bignum.jl`, ...).
* `src/inference/`: what the compiler does with what Julia's inference leaves to the runtime. The state of a compilation and its keys (`compilation.jl`), our interpreter (`interpreter.jl`), the passes and what each reuses from the one before (`passes.jl`); calls on abstract types (`dispatch.jl`), tuples (`tuples.jl`), unknown functions, callbacks and listeners (`closures.jl`), boxes (`boxes.jl`), slots of abstract types (`slots.jl`) and of types (`types_as_values.jl`), constant objects (`objects.jl`, `object_calls.jl`), stated types (`assume.jl`), `@cfunction` (`cfunctions.jl`), replaced calls (`redirect.jl`), the optimizer's hooks (`optimize.jl`), and why a program does not infer (`diagnostics.jl`).
* `src/runtime/`: the runtime that is linked into a program: the allocator and collector (`heap.jl`, `heap_link.jl`), the objects that are copied into the binary (`objects.jl`, `embedder.jl`, `constants.jl`), types at run time (`types.jl`), what is refused (`strict.jl`), and the functions of libraries, BLAS among them (`libraries.jl`, `loader.jl`).
* `src/llvm/`: our LLVM passes (`pipeline.jl`, `tags.jl`); `src/testing.jl`: `static_status` and the other functions that compare a compiled program with Julia.
* `ext/`: the overlays that need another package or standard library (LinearAlgebra, SparseArrays, Printf, Random, StyledStrings, Mmap, Observables, Makie, CairoMakie, UnicodePlots, MPI, FunctionWrappers).

### Running the tests

`] test` runs all: the tests of the compiler, the runtime and the language (`test/core`), as well as those of the standard libraries and the packages that programs use (`test/packages`).
Most of them compile a program and compare what it prints with what Julia prints for the same code. Set `GROUP=Core` or `GROUP=Packages` to run one of the two, `PACKAGES=Dates,MPI` to run some of the files of `Packages` (the MPI tests need an MPI library, which MPI.jl installs), `TEST_TIMING=1` to print the time that each file took, and `TEST_FOLDED=0` to not fail the cases whose program is only a print of an answer that the compiler found (which is on by default: the test of such a case does not test the code that it is about) (`opaque` in `test/helpers.jl` makes values that the compiler does not know; whether a program computes something from them is read from its module, see `StaticRuntime.input_dependent_cases`; `TEST_FOLDED=report` lists those that do not, and goes on). `STATIC_RUNTIME_GC=3` runs the programs with the collector in stress mode, sweeping every three allocations.

`GROUP=Fuzzing` (not part of `] test`) runs random values and programs (`test/fuzz`): each seed is compiled and run in a process of its own, with a time limit, a few at a time, and compared with Julia. The seeds that failed
once are run every time (`test/fuzz/pinned.jl`), with random ones; `FUZZ_SEEDS=0x688,1:50` runs the seeds that you give, `FUZZ_COUNT` is the number of random ones for each kind (20), `FUZZ_TIME_LIMIT` the seconds for a case (120)
and `FUZZ_WORKERS` how many run at once. A seed that fails or does not finish is written with the command that runs it again by itself: `julia --project=test test/fuzz/case.jl embedfuzz 0x688`.

## Reference

```@index
```

```@autodocs
Modules = [StaticRuntime, StaticRuntime.Runtime]
```
