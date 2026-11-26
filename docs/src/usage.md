# Basic Usage 
## Entry points

An executable is compiled from a function, in one of three forms, or from a whole script:

| form                                    | `compile_executable(f, ...)`  | command line arguments passed as  |
|:----------------------------------------|:------------------------------|:----------------------------------|
| `main()`                                | `()`, or omitted              | none                              |
| `main(args::Vector{String})`            | `(Vector{String},)`           | `args`                            |
| `main(argc::Int, argv::Ptr{Ptr{UInt8}})` | `(Int, Ptr{Ptr{UInt8}})`      | `argc` & `argv`, as in C          |
| a file, `script.jl`                     | `compile_script("script.jl")` | `ARGS`, as in `julia script.jl`   |

That is to say:
* `main()`, for a program that has no arguments, and wants none. You may return an integer status, or nothing (in which case `0` will be returned by default).
* `main(args)` is the form to use for a program that is written like a Julia script: it has the command-line arguments in the same form and order as `Base.ARGS` has them. Again, you may return an integer status, or nothing (in which case `0` will be returned by default).
* The third form is C's: it compiles `f(argc, argv)` to the `main` of a C program, with no code of ours between the two, which is as small as a program can be (the others add a kilobyte or less). Its status is the return value as C has it, so the function has to return an `Int` (or an `Int32`); if you try to return `nothing`, the return value is then whatever the machine had in the register, and the compiler will warn of this.

`compile_script(path)` (or `compile_script_string(code)`) is the entry point for a `.jl` file that runs from the top, as in `julia script.jl args...`: the program has `ARGS`, and the top-level code is the program. See [Compiling scripts](scripts.md) for what is done when compiling and how the variables of a script are treated.

`target = "x86_64-apple-macosx11.0.0"` (or any triple) makes the program for another architecture than the host's: see [Cross-compiling](cross.md).

## Compilation

See [Compiling: overrides, passes, and inference](compiling.md) and [The Runtime](runtime.md) for how it works, and [`compile_executable`](@ref) or [`compile_shlib`](@ref) for options and syntax:

```julia
hello() = println("hello")
compile_executable(hello)                      
# `./hello` prints "hello" and exits with status 0

main(args) = (println("got ", length(args), " arguments"); length(args))
compile_executable(main, (Vector{String},))    
# `./main a b c` prints "got 3 arguments" and exits with status 3
```

See also [Binary size and performance](performance.md) for factors that influence the size and performance of the resulting binary

### Testing that something compiles

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

See also: [Supported libraries and packages](support.md) and [Limitations](limits.md) for what is and is not expected to compile, respectively.

## Overrides

`@device_override` adds a method to the method table of this package (see below), which replaces the method of Base for the code that is compiled.
One key thing to know, if you wish to write your own overrides: **an override is used for every call that it covers entirely, instead of any matching methods of Base and packages, even those that are more specific.** 
Consequently, an override `print(x1, x2) = print(STDOUT, x1, x2)` would also be used for `print(io, x)`, which must go to the methods of Base for printing to an `IO`: `print(io, 'c')`, `print(io, "string")`... 
Overrides therefore need to be written so that they don't cover calls that they should not: with the same signature as the method that they replace, with restricted argument types, or by doing for those calls the same thing that the method of Base (or a package) that you are overriding does (see `src/overrides/io.jl`).

### The Method Table

StaticCompiler replaces methods that can't be compiled using an overlay method table. Its own table (`StaticCompiler.method_table`) includes overrides of the error helpers of Base (`error`, `throw_boundserror`, `throw_inexacterror`, integer division by zero, ...) that print a message and exit, which made sense when compiled code could not throw, but means that those errors cannot be caught.

A compilation uses exactly one overlay table, with Base itself as the fallback, so this package has a table of its own, [`StaticRuntime.method_table`](@ref), which does not contain those overrides: errors throw, just as in Julia, and `try`/`catch` can catch them. Use the functions of this package (`compile_executable`, `compile_shlib`, `static_code_llvm`, ...), which are StaticCompiler's with this table as the default, and `@device_override` to add to it. These replace the functions of the same name in StaticCompiler, so disambiguation will be necessary if you load both packages. To compile with StaticCompiler's table instead, pass `method_table = StaticCompiler.method_table`.

### Stating a type instead of copying code

Many overrides of code from a package are a copy of a function with a type put in it, because the compiler finds a wide type (a `Union`, `Any`) where the code knows what it is. 
However, a copy of package internals drifts out of date when the package changes. 
To avoid this, `@assume` states the type, and the code of the package stays as it is.
For example:

```julia
# Assert that the call returns an `Attributes` object
StaticRuntime.@assume Makie.theme(::Nothing, ::Symbol)::Attributes

# Assert that the `listeners` field holds a Vector{Pair{Int,Any}}
StaticRuntime.@assume_field Observable.listeners::Vector{Pair{Int,Any}}
```

* **The type of a call**: `@assume f(::A, ::B)::R` says that the methods that the arguments `A` and `B` (or subtypes) fit give a `R`. Those methods are inferred as they are, with what they give narrowed to `R` (the intersection of the two types), and every `return` of them is a `typeassert` to `R`: callers have a type that is right, and a program in which the method gives another type stops with a type error that says so, and does not go on as if it had the type. A function with keyword arguments is stated by its method without them, and a constructor `T(...)` by `Type{T}`.
* **The type of a field**: `@assume_field S.name::T` says that a field of the type `Any` (or another that is not concrete) of the struct `S` holds a `T` where it is read, and the read is a `typeassert`.
* Both are given where the module is initialized (`__init__`), as `add_dispatch_candidates!` is: they are kept for the session, and not by what is precompiled. A package extension is the place. What is stated is a number in the key of what is inferred, so a change of it is a new inference.

## Running the package tests

`] test` runs all standard tests: the tests of the compiler, the runtime and the language (`test/core`), as well as those of the standard libraries and the packages that programs use (`test/packages`).
Most of these compile a program and compare what it prints with what Julia prints for the same code. Set `GROUP=Core` or `GROUP=Packages` to run one of the two, `PACKAGES=Dates,MPI` to run some of the files of `Packages` (the MPI tests need an MPI library, which MPI.jl installs), `TEST_TIMING=1` to print the time that each file took, and `TEST_FOLDED=0` to not fail the cases whose program is only a print of an answer that the compiler found (which is on by default: the test of such a case does not test the code that it is about) (`opaque` in `test/helpers.jl` makes values that the compiler does not know; whether a program computes something from them is read from its module, see `StaticRuntime.input_dependent_cases`; `TEST_FOLDED=report` lists those that do not, and goes on). `STATIC_RUNTIME_GC=3` runs the programs with the collector in stress mode, sweeping every three allocations.

`GROUP=Fuzzing` (not part of `] test`) runs random values and programs (`test/fuzz`): each seed is compiled and run in a process of its own, with a time limit, a few at a time, and compared with Julia. The seeds that failed once are run every time (`test/fuzz/pinned.jl`), with random ones; `FUZZ_SEEDS=0x688,1:50` runs the seeds that you give, `FUZZ_COUNT` is the number of random trials for each kind (20), `FUZZ_TIME_LIMIT` the seconds for a case (120) and `FUZZ_WORKERS` how many run at once. A seed that fails or does not finish is written with the command that runs it again by itself: `julia --project=test test/fuzz/case.jl embedfuzz 0x688`.
