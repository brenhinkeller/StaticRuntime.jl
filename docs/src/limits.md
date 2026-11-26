# Known Limitations

What does not work yet, or works differently from Julia, gathered in one place. The sections above say more about each.

**Platforms**

* **macOS and Linux only** for the garbage collector. Linux is tested on CI (x86 and aarch64), but not by hand. The collector depends on the layout of the stack and `setjmp` of the C library, and BLAS on `dlopen`.
* **The host is the target.** The heap and the runtime are made for the machine that compiles, so cross-compiling (a `target` that is not the host) is not supported.
* BLAS and LAPACK need LBT and the libraries that back it **at the same paths when the program is run** (see [LinearAlgebra](@ref)); they are not in the binary. The same is true of any other library that the program calls, unless `libraries = :bundle` is used (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)); BLAS is not bundled yet.

**Refused, because the answer would otherwise differ from Julia's**

* **Constant tables hashed by address.** A `const` `Dict` or `Set` whose keys are mutable objects (or hold one) with no `hash` method of their own, and any non-empty `IdDict`, are made in Julia with the addresses of their keys, which are not the addresses of the copies in the binary: a lookup would quietly find nothing. Compiling such a constant is an error that says so. Define `Base.hash` (and `==`) for the key type, or make the table when the program runs (a table that is made by the program is fine).
* **`deepcopy` of a type with a package's own `deepcopy_internal`.** The copy here is made field by field, which is not what that method does, so compiling warns, and the program stops if it reaches the copy.
* **Writes that fail.** A write, `flush` or `close` that libc reports as failed (a full disk, a closed pipe) throws, as in Julia. And if the system has no entropy for the default random number generator, the first `rand()` throws, rather than the program using a fixed seed (`Random.seed!` makes one that is meant to be fixed).
* Loops with `@simd` (so `sum`, `dot`, `mean`, ...) are vectorized and their reductions reordered, as in Julia, so the results are the same as Julia's, to the last digit, when it is run on the same machine type; other machines (SIMD widths) may differ in the last digits, in Julia as here.

**Base and Standard Libraries** 

Works: see [Supported libraries and packages](support.md).

Does not work:
* `Unicode.normalize` and `isequal_normalized` (the tables are in libjulia's copy of utf8proc, which is not a library of its own). Grapheme breaks (`graphemes`, `titlecase` of a string, `textwidth` of a string) work: they are tabulated when this package is compiled, from the utf8proc of the Julia that compiles it.
* `base64encode` of several values of different types in one call, and `base64encode(f, args...)` of a function with arguments. 
* `with_logger`
* `Test` (`@test` and `@testset`)
* `Timer`
* `@allocated` (the heap does not count the bytes of each allocation; @allocations` gives -1)
* `@time` and `@timed` work, but measure only the time (the bytes, the time of the collector and of the compiler are zero, and `@time` writes only the seconds); `TOML.parse` (the parser keeps a `Module`)
* `Dates.canonicalize`
* `Printf.Format` of a format that the program makes at runtime
* `Markdown.parse` is refused when compiling, or stops with a message when it is run (its parser needs Julia's own); `Mmap` of an open stream, and anonymous ones (only the files that are named by their path are mapped)
* `TOML.print` 
* TCP sockets 
* `Serialization` of a value that is a type or a module in a tuple or a field (`serialize((Int, 1))`), of a `UnionAll`, or whose type is not known when compiling (see [Serialization](@ref)); 
* DelimitedFiles' `readdlm` / `writedlm` are not yet supported
* weak references (`WeakRef`, `WeakKeyDict`)
* `stacktrace`, `catch_backtrace` and `current_exceptions`
* `Meta.parse` and `Expr`s made when the program runs; `methods` and `which`; `Base.summarysize`; and `versioninfo`.

**Tasks and threads**

* **Tasks run to their end** (see [Tasks](@ref)): `@async`, `Threads.@spawn`, `Task`, `schedule`, `wait`, `fetch`, `yield`, `@sync`, `Condition` and `Channel` work, on the one thread, and a task runs when something waits.
* **Locks do nothing** (there is one thread), and `islocked` is `false`.
* **The heap is not thread-safe.** A program, or a library from `compile_shlib`, allocates from one thread at a time. A library that is called on a stack that is not that of the thread (a task of Julia running on another thread) **frees nothing** in that call (see [Memory and the garbage collector](@ref)).

**Limited support for dynamism**

* There is **no `eval`**, and no keyword form of `invokelatest`

* **Dynamic dispatch** is resolved for abstract types with at most 16 concrete subtypes that can be listed, and for `Any` and the other abstract types over the registered types (see [Dynamic dispatch on abstract types and on `Any`](@ref)): a value of a type that is not registered aborts the program when it reaches such a call. It is not resolved for types that can't be listed and have no registered subtype (`IO`). These, `Core.Box` variables with a type that is not known,  splatting a collection whose length is not known when compiling (`f(v...)`), and calls that compute a type at run time (e.g., `typejoin`, a `Dict` made from pairs with abstract values, `sum(f, v)` of a `Vector{Any}`, `isprime`) are rejected when compiling (`UnsupportedCodeError`), or abort the program if compiled with `strict = false`.

* **Values that are only known at run time** (an element of a `Vector{Any}`) can't be the argument of `objectid` or `hash` unless their types are registered, nor `===` of types and unions, and `show` of one is limited to the registered types (see [`add_dispatch_candidates!`](@ref)).

* **Tuples that have a `Union` as an element** (`Tuple{Union{Vector{Float64},Vector{ComplexF64}},Int}`: what a function returns when the type of one of two values depends on the data) are made and read as one of the tuples that they are made of (`Tuple{Vector{Float64},Int}` or `Tuple{Vector{ComplexF64},Int}`), as a call on a union is made over its cases, when there are at most as many of them as `split_limit` says (64): returned by a function that is not inlined, stored in an array, or made by `enumerate`. One of more cases, or of elements of abstract types, is made by Julia with the types that the values have when the program runs, which an executable can't make, and is rejected when compiling.

* **What the compiling Julia has is copied.** A `const` container, a `Ref`, a string, ... is in the binary as it was when compiling, and the program changes its own copy. Only what is of a type that can be reproduced is copied: not a `Module`, a `Task`, ...

* **The garbage collector is conservative:** it finds references by what looks like an address, so a number can keep an object that is not used, and a reference that is hidden (not in the stack, the registers, the data copied from the compiler, or an object of the heap) is not found. Memory that is allocated with `malloc` is not looked at (see [Memory and the garbage collector](@ref)). **The blocks of small objects are not returned to the system** once the heap has them (though they are used again); large objects are.

**Other limitations**

* **`@cfunction`** of a function with captured state (a closure over a variable) does not work (see [Callbacks: `@cfunction`](@ref)). 
* **A `NamedTuple` (or the keywords of a call) that holds a value of a small union of types** (`f(x; bgcol = c)` with `c` a `UInt32` or `missing`, `merge` of such) has the union as the type of its field: `@NamedTuple{bgcol::Union{Missing,UInt32}}`, where Julia's is that of the value, `@NamedTuple{bgcol::UInt32}`. `typeof` says so, and a method for the one is not a method for the other. (The type of the value is only known when the program runs, and Julia's way would be a call of the runtime.) A keyword whose value is a type (`canvas = AsciiCanvas`) is of the type of Julia.
* **At most 256 `try` blocks are active at once** (and 256 exceptions being handled): more prints `fatal: exception handler stack overflow` and exits. An exception that nothing catches prints `ERROR: ` and its type and message (where its first field is a string) on the standard error and exits with status 1, without a backtrace or the other details that Julia gives (see [Exceptions](@ref)).
* **There is no stack overflow check:** infinite recursion crashes (segmentation fault) instead of throwing `StackOverflowError`.
* **An exception that is caught (`catch e`) is a value of the type `Any`**, and a call that has it as an argument (`showerror(io, e)`, `println(e)`) is made over the registered types, the exceptions of your own that the program makes, and the common exceptions of Base that the code throws (`ErrorException`, `ArgumentError`, `OverflowError`, `AssertionError`, `EOFError`, `DivideError`, `StringIndexError`): `showerror(STDERR, e)` of those gives Julia's text, without anything registered. Other exceptions of Base (`BoundsError`, `KeyError`, `DomainError`, `MethodError`, ...: their messages need more of Julia than a program has, or make the call too large to compile) are not: `typeof(e)`, `e isa T` and the exceptions of your own types work, but `showerror(e)` of one of them stops the program with a `MethodError` (or is refused when compiling). The exception has to be the argument of the call itself: `sprint(showerror, e)` and what is passed on to another function are made over the registered types only. 
* A `lazy"..."` string that the program turns into a `String` is an error (see the comment of `Base.String(::LazyString)` in `src/overrides/strings.jl`).
* **Files** are libc streams: `eachline` of a file closes it only when the loop reaches the end (not on `break`), `seek` and `skip` don't report errors. Sockets are not available (only the types of addresses of `Sockets` are).
* **`rand` without a seed** gets its state from the operating system (`getentropy`); if that fails the first `rand()` throws, rather than giving the same stream each time. `RandomDevice` and `uuid4()` read `getentropy` at each call.
* The output is **unbuffered beyond libc's**: `print` and `println` write through `FILE*`, which libc flushes when the program exits (not if it crashes).
