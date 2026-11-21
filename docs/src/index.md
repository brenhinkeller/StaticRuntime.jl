```@meta
CurrentModule = StaticRuntime
```

# StaticRuntime

StaticRuntime compiles ordinary Julia code, packages included, to a standalone executable or shared library that does
not need `libjulia`. It builds on [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) and
[StaticTools.jl](https://github.com/brenhinkeller/StaticTools.jl), adding an overlay method table, its own passes of
inference, and a small runtime (allocator, garbage collector, exceptions, a loader of libraries) that is linked into each
program.

```julia
using StaticRuntime   # also loads (and re-exports) StaticCompiler and StaticTools

function main(argc::Int, argv::Ptr{Ptr{UInt8}})
    v = collect(1:argc+3)       # an ordinary Vector
    printf(c"%d\n", sum(v))
    return 0
end

compile_executable(main, (Int, Ptr{Ptr{UInt8}}))   # writes ./main
```

Julia 1.14 or later is required, on macOS or Linux.

## Example: a differential equation, plotted in the terminal

Packages compile like Base does. This program solves the Lorenz system with
[OrdinaryDiffEq](https://github.com/SciML/OrdinaryDiffEq.jl) and plots the attractor with
[UnicodePlots](https://github.com/JuliaPlots/UnicodePlots.jl), with the parameter ``\rho`` from the command line:

```julia
using StaticRuntime
using SciMLBase, OrdinaryDiffEqTsit5, StaticArrays, UnicodePlots

lorenz(u, p, t) = SVector(p[1] * (u[2] - u[1]), u[1] * (p[2] - u[3]) - u[2], u[1] * u[2] - p[3] * u[3])

function main(args::Vector{String})
    ρ = length(args) > 0 ? parse(Float64, args[1]) : 28.0
    prob = ODEProblem{false, SciMLBase.FullSpecialize}(lorenz, SVector(1.0, 0.0, 0.0), (0.0, 30.0), SVector(10.0, ρ, 8 / 3))
    sol = solve(prob, Tsit5(); saveat = 0.01)
    x = [u[1] for u in sol.u]
    z = [u[3] for u in sol.u]
    println(lineplot(x, z; title = "Lorenz attractor, ρ = $ρ", xlabel = "x", ylabel = "z", width = 60, height = 20))
    println(length(sol.t), " points, ", sol.stats.naccept, " steps")
    return 0
end

compile_executable(main, (Vector{String},), "build", "lorenz"; small = true)
```

```
shell> ./build/lorenz
        ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀Lorenz attractor, ρ = 28.0⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
        ┌────────────────────────────────────────────────────────────┐
     50 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⡠⠤⠤⡀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡠⠔⠒⠉⠀⠀⠀⠀⠈⢣│
        │⠀⠀⠀⠀⡠⠤⠤⠤⢄⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠔⠊⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸│
        │⠀⠀⠀⢠⠃⢠⡲⠮⠵⠶⢬⣕⡤⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⠤⠒⠉⢀⡠⢤⣔⣮⣭⣭⡉⠲⡀⠀⠀⠀⡸│
        │⠀⠀⠀⢸⠀⣷⠁⡴⢚⣿⣶⣶⣽⣷⠯⣖⡤⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⠀⠀⠀⠀⠀⣀⠤⠒⠁⢀⣠⣶⡷⢟⣛⠭⣉⡉⠑⣵⡀⡇⠀⠀⢀⠇│
        │⠀⠀⠀⠈⡆⣿⠀⣧⡿⣕⢮⣻⣿⣿⣿⣷⣯⣟⢵⣢⢄⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⠀⢀⡠⠔⠉⠀⡠⣔⡭⣗⣭⣵⣿⠯⠿⡭⡱⣱⠀⣿⢣⠃⠀⠀⡸⠀│
        │⠀⠀⠀⠀⢱⠸⡇⢇⣧⣿⣷⡱⣶⣿⣿⣿⣿⣿⣿⣷⣷⢯⣦⢄⠀⠀⠀⠀⠀⠀⡇⢀⡠⠔⠊⠁⢀⡠⡲⡽⣚⣽⣺⣿⡿⠷⠛⠻⡕⣼⡇⣿⢰⡿⡎⠀⠀⢠⠃⠀│
        │⠀⠀⠀⠀⠀⢇⢻⡜⣽⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣷⡮⣷⢯⣒⢄⣀⡠⠔⡏⠁⠀⠀⡠⣴⡵⢞⣽⡽⣿⡽⠋⠁⠀⠀⠀⠀⣷⣻⣻⠇⣾⢹⠀⠀⢀⠏⠀⠀│
        │⠀⠀⠀⠀⠀⠀⢇⢻⡱⣻⣿⣿⣿⣿⣿⣿⡿⢿⣿⣿⣿⣷⣿⣿⢷⢞⡻⣬⠑⢄⡇⣀⢔⣾⠾⣃⢮⣿⢮⠞⠁⠀⠀⠀⠀⠀⠀⣰⢯⣿⠟⣼⢣⠃⠀⢀⠎⠀⠀⠀│
   z    │⠀⠀⠀⠀⠀⠀⠈⢎⢳⡱⣿⡿⣯⣿⣿⣿⣷⣤⣹⣿⣿⣿⣿⡪⣗⢷⣵⣄⠫⡢⣏⣶⡟⡡⡪⣷⣫⠞⠁⠀⠀⠀⠀⠀⠀⠀⣰⣯⣫⢏⣾⣣⠃⠀⢀⠎⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠈⢣⠻⣜⢿⢿⣯⣿⡻⣿⣿⣿⣿⣿⣿⣿⡷⣽⡧⣻⣿⠻⣜⡿⡣⡸⣝⣼⡱⡝⠀⠀⠀⠀⠀⠀⠀⣠⣞⣿⢽⢣⡾⡟⠀⠀⢀⠎⠀⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠱⡙⢮⡱⣿⣾⣿⣽⣟⡿⣿⣿⣿⣟⣇⡏⣾⡗⣟⣿⡽⡇⡼⣝⣜⡏⡗⣇⡀⠀⠀⢀⣀⣔⣝⡵⣻⠕⣱⢟⠎⠀⠀⢠⠃⠀⠀⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢢⡳⣪⠻⡻⣟⣿⣾⢯⣶⣾⣭⡺⡴⡝⣜⡿⣿⡇⣷⡇⡏⢯⢧⡱⢌⣚⠭⣝⣳⣭⣞⣞⠏⣡⠞⡕⠁⠀⠀⡠⠃⠀⠀⠀⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠑⢜⠵⣌⠺⢟⡾⣿⣭⣵⠮⢭⣚⣕⢝⡟⣼⢳⣿⣧⣇⠘⢿⡿⢭⣶⡻⢭⡵⠝⢉⣤⠞⡣⠊⠀⠀⠀⡔⠁⠀⠀⠀⠀⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠱⢌⠫⢦⢌⠓⠯⢽⣛⣛⣩⠵⠋⢠⡿⣸⡟⡞⣿⣦⡀⠉⠉⠉⢉⡡⣤⡾⢛⡡⠊⠀⠀⠀⡠⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠑⠢⡉⠻⠶⣢⡤⣀⣀⠤⣔⡷⠁⡇⡇⠱⣈⠙⠻⠿⠿⠟⠛⣋⠥⠒⠁⠀⠀⠀⡠⠚⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠑⠢⢄⣈⠉⠉⠉⠀⣀⡜⠁⡇⠀⠈⠑⠒⠒⠒⠚⠉⠀⠀⠀⠀⠀⡠⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠉⠉⠉⠁⠀⠀⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡠⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
        │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⠀⠀⠀⠀⣀⠤⠊⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
      0 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⣀⣀⣀⠤⠴⠒⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
        └────────────────────────────────────────────────────────────┘
        ⠀-20⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀20⠀
        ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀x⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
3001 points, 358 steps
```

Compiling takes about 25 seconds. The program is a 3 MB file that needs nothing but the C library (`otool -L` lists only
`libSystem`), runs in a few milliseconds, and prints the same text as `main(String[])` does in Julia, for this and
other values of ``\rho`` (`./build/lorenz 15`). The problem is made with `ODEProblem{false, FullSpecialize}`, which
says whether `lorenz` changes its first argument: `ODEProblem(f, u0, tspan, p)` finds that out when it runs (see
[SciML (differential equations)](@ref)).

## What works

* **The language and Base.** Code that allocates (`Vector`, `Dict`, `Set`, `String`, structs, closures, boxed values),
  `try`/`catch`/`finally`, `deepcopy`, `IdDict`, symbols made when the program runs, non-`const` globals, tasks that run
  to completion (`@async`, `Channel`, `wait`, `fetch`), `atexit`, finalizers, and `@cfunction` callbacks; `Rational`,
  `Float16`, `Int128`, `BigInt` and `BigFloat`; `Enum`s and `@kwdef` structs; sorting, reductions with `dims`, views,
  `CartesianIndices`, the `Iterators`; `Threads.@threads` (on one thread), atomics, locks, `Event`s and semaphores.
* **Input and output.** `print`, `println`, `show`, `display` and `text/plain` of numbers, strings, containers, structs
  and matrices, as Julia writes them; `printf` and `@printf`; files, the standard streams and the file system; colors and
  styled strings (see [Input and output](@ref)).
* **Calls that Julia leaves to the runtime.** Calls on values of abstract types and of `Any` are made over the types that
  the program can have, and calls of functions taken from collections over the functions that the program has (see
  [Compiling: overrides, passes, and inference](compiling.md)).
* **Libraries.** BLAS and LAPACK (through libblastrampoline), `BigInt`, `BigFloat`, `Regex`, SuiteSparse, MPI, and any
  JLL or library of your own through `ccall` (see [Libraries and packages](packages.md)).
* **Standard libraries and packages.** Most of the standard libraries, and a survey of packages that is kept as tests:
  OrdinaryDiffEq, UnicodePlots, JuMP with HiGHS, Makie and CairoMakie, Distributions, StatsBase, NaNStatistics,
  DataStructures, StaticArrays, Graphs, Parsers, OrderedCollections and MPI.jl.

What can't work in a standalone binary is refused when compiling, with an explanation, rather than giving a different
answer from Julia's. [Known limitations](@ref) gathers what does not work yet, or works differently. The tests
(`test/core` and `test/packages`) are the up-to-date list of what is checked: most of them compile a program and compare
what it prints with what Julia prints.

## The manual

* [Input, output and writing overrides](usage.md): printing and reading, entry points and the command line, symbols, and
  writing overlay methods of your own.
* [Compiling: overrides, passes, and inference](compiling.md): how a compilation works, what is done to help inference,
  dynamic dispatch, and finding out why something does not compile.
* [The runtime](runtime.md): memory and the garbage collector, exceptions, and the size of binaries.
* [Libraries and packages](packages.md): BLAS, libraries, MPI, tasks, and the packages that are known to work.
* [Limitations, testing and reference](limits.md).
