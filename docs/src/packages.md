# Libraries and packages

## Linear algebra and BLAS

Matrix products, `dot`, `norm`, `\`, `inv`, `det`, `lu`, `qr`, `cholesky`, `eigvals`, `svdvals` and so on work, for the
element types that BLAS and LAPACK have. `LinearAlgebra` does these by calls of [libblastrampoline](https://github.com/JuliaLinearAlgebra/libblastrampoline)
(LBT), which passes each on to the library that backs it: OpenBLAS by default, and another when a package such as
[AppleAccelerate.jl](https://github.com/JuliaLinearAlgebra/AppleAccelerate.jl) or [MKL.jl](https://github.com/JuliaLinearAlgebra/MKL.jl) forwards to it
(`BLAS.lbt_forward`). A program does the same: **it uses the libraries that were in use when it was compiled.**

```julia
using StaticRuntime, LinearAlgebra
using AppleAccelerate; AppleAccelerate.load_accelerate()    # (or `using MKL`: any library that LBT forwards to)
compile_executable(main, (Int, Ptr{Ptr{UInt8}}), "build")   # the program calls Accelerate
```

How it works: LBT, and the libraries that it forwards to (those of `BLAS.get_config()` that something is forwarded to, in the
order that they were loaded, with their suffixes), are not in the binary. Their paths are, and the first time that
the program calls a function of BLAS or LAPACK it loads LBT (`dlopen`), forwards to those libraries as `lbt_forward` does, and looks the function up
(`dlsym`), as Julia does for a `ccall` that is made the first time. A program that does not call BLAS loads nothing. So:

* The libraries must be at the same paths when the program is run as when it was compiled (for the ones that come with
  Julia, that is the `lib` directory of the Julia that was used, and the artifacts of its packages). A program that is run
  elsewhere says `Cannot load libblastrampoline (for BLAS)` and exits.
* The program can use more than one thread, if the library does.
* Large calls of BLAS can't be cancelled (there are no tasks to cancel).
* This is tested with OpenBLAS and Accelerate. MKL is not available for the machines that we test on (macOS on ARM), but it is
  a library that LBT forwards to like the others.

The element types and sizes are the ones that BLAS and LAPACK take (`Float64`, `Float32`, `ComplexF64`, `ComplexF32`): other
types use generic Julia code, which compiles like any other. Functions of other packages that call into their own
libraries (SuiteSparse, Arpack, ...) need those libraries, and don't work yet.

## Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own

A `ccall` into a library is a function that the program looks up when it first needs it. Where that library is, is a choice that the compiler takes as
`libraries`:

```julia
compile_executable(f, types, dir, name)                       # libraries = :system, the default
compile_executable(f, types, dir, name; libraries = :bundle)
```

* `:system` — the program opens the library at the **path that it had when compiling** (the file of the JLL in `~/.julia/artifacts`, or your own
  `libfoo.so`). The program is not independent of that file. If the library has gone, the program says `Cannot use a library that the program calls
  functions of: cannot open <path>` on the standard error and exits (the same if a function is not in it).
* `:bundle` — the libraries (and those that they need: `libmpfr` needs `libgmp`) are copied to the folder `lib` next to the program, and the program looks
  there first, relative to where *it* is, so the folder of the program can be moved or copied to another machine of the same kind. If a library is not there, the path that
  it had when compiling is tried. Libraries of the system (`/usr/lib`, `/lib`, ...) are not copied. For `compile_shlib`, `lib` is next to the shared library.

```julia
function main(args::Vector{String})
    println("30! = ", factorial(big(30)))                      # BigInt (GMP)
    println("sqrt(2) = ", sqrt(big(2)))                        # BigFloat (MPFR)
    m = match(r"(?<key>[a-z]+)=(?<val>\d+)", get(args, 1, "answer=42"))   # Regex (PCRE2)
    m === nothing && return 1
    println(m[:key], " is ", parse(Int, m[:val]) + 1)
    return 0
end

compile_executable(main, (Vector{String},), "build", "bignums"; libraries = :bundle)   # build/lib has libgmp, libmpfr, libpcre2
```

What works through this, and is tested: **`BigInt`** and **`BigFloat`** (GMP and MPFR; the memory that GMP allocates is freed by the collector when the number is,
by the finalizer that Base gives it), **`Regex`** (PCRE2: `match`, `occursin`, `replace`, `split`, `eachmatch`, named captures, `Regex(string)` made when the program
runs), zlib and any other function that a JLL or library has (`ccall((:name, "libname"), ...)`, a `LazyLibrary` such as `Zlib_jll.libz`, or the path of a file).
The functions of the math library (`libm`, `libopenlibm`) are linked by name instead. The libraries of the runtime of Julia (libjulia, libuv, ...) are not there.

Limits: a `Ptr` field of a constant of the program
(an address of this process) is null there, with a warning (a `Regex` is compiled when the program first uses it, so those are fine); `setprecision(f, BigFloat, n)`
(a scoped value) does not work yet. **Linux is only tested on CI for the libraries** (the program finds its own folder with `dladdr`, and `/proc/self/exe`).

## Dates and SparseArrays

Both standard libraries compile, and are checked against Julia in `test/packages/dates.jl` and `test/packages/sparsearrays.jl`.

* **Dates**: `Date`, `DateTime` and `Time` (construction, fields, arithmetic with periods, ranges, `dayofweek` and the like, `monthname`, `show`), parsing a string
  (`Date("2021-12-25")`, `DateTime(...)`, `tryparse`, and with a format), `now()` and `today()` (the time zone of the machine that runs the program). A format is
  made when compiling with the macro: `Dates.format(d, dateformat"dd/mm/yyyy")`. `Dates.format(d, "dd/mm/yyyy")` makes it when the program runs, from the characters of
  the string, which does not compile. (The tokens of a format are of types that differ by a letter, so a package extension of this package registers them for dispatch when
  `Dates` is loaded.)
* **SparseArrays**: `sparse`, `spzeros`, `SparseMatrixCSC`, sparse vectors, indexing and `setindex!`, `nnz`, `nonzeros`, `findnz`, sums, products of sparse with dense and with
  sparse, `transpose`, `kron`, `spdiagm`, `I`, and `show`, and the **factorizations**: `\` of a sparse matrix, `lu`, `cholesky`, `ldlt`, `qr` (and so least squares), `det`, `logdet`, `factorize`, with
  their errors (`PosDefException`, `SingularException`). These are SuiteSparse's libraries (UMFPACK, CHOLMOD, SPQR) and are called as any library is (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)):
  the program sets them up the first time that it needs them, as Julia does (`LibSuiteSparse.init_suitesparse`, with the C library's allocators), and tells libblastrampoline what BLAS it forwards to, as
  it does for BLAS. What is different: CHOLMOD's error says the code of the failure (a `CHOLMODException("CHOLMOD error (status -3)")`) and not its message, and the settings that CHOLMOD keeps for each task are the program's one.

Also: `sleep` (as `nanosleep`), `splice!`, and `string(a, b, ...)` / interpolation with a value of `Any` (`"x = $(x)"` where the type of `x` is not known) work.

## MPI

Programs that use [MPI.jl](https://github.com/JuliaParallel/MPI.jl) compile, and run on several processes with `mpiexec`:

```julia
using MPI, StaticRuntime

function main(args::Vector{String})
    MPI.Init()
    comm = MPI.COMM_WORLD
    rank, size = MPI.Comm_rank(comm), MPI.Comm_size(comm)
    total = MPI.Allreduce(rank + 1, +, comm)
    x = Float64[10rank + i for i in 1:4]
    received = zeros(4)
    MPI.Sendrecv!(x, received, comm; dest = mod(rank + 1, size), source = mod(rank - 1, size))
    println("rank ", rank, " of ", size, ": total = ", total, ", received ", received)
    MPI.Finalize()
    return 0
end

compile_executable(main, (Vector{String},), "build", "ring")
# $ mpiexec -n 3 ./build/ring
```

The MPI library is a library that the program calls like any other (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)): the one that MPI.jl is set to use (`MPICH_jll` by default, or a system one
through `MPIPreferences`), opened from the path that it has when compiling, or from the folder `lib` next to the program with `libraries = :bundle`. Run it with the `mpiexec` of the same library (`MPI.mpiexec()` has the environment that
the library needs). The point-to-point and collective operations (`Send`, `Recv!`, `Sendrecv!`, `Isend`, `Irecv!`, `Waitall`, `Probe`, `Bcast!`, `Reduce`, `Allreduce` with `+`, `*`, `max`, `min`, ..., `Gather`, `Scatter!`, `Gatherv!`, `Allgather`,
`Alltoall`, `Scan`, `Exscan`, `Barrier`), communicators (`Comm_split`, `Comm_dup`, which are freed by their finalizers, `Cart_create`), one-sided communication (`Win_create`, `Put!`, `Win_fence`), parallel files (`MPI.File`),
`Wtime`, the status of a message, and MPI errors (an `MPI.MPIError` that can be caught) are compared with Julia's in `test/packages/mpi.jl`. What is different:

* `MPI.Init` does not register `MPI.Finalize` to be called when the program ends (the extension does not register it with `atexit`): **call `MPI.Finalize()` at the end** (`finalize_atexit` is ignored).
* The handles of the constants (`MPI.COMM_WORLD`, `MPI.INT`, `MPI.SUM`, ...) are the numbers that the library has them as when compiling, which are the same on each run for the MPICH family (MPICH, Intel MPI, the MPI ABI libraries);
  they are addresses in Open MPI, which a compiled program can't use.
* Not supported: a reduction with an operator that is a function of yours (`MPI.Allreduce(x, f, comm)`): MPI.jl makes its C function with `@cfunction($w, ...)` of a value that holds the function, which Julia makes with a trampoline that it generates when the program runs (see [Callbacks: `@cfunction`](@ref)); and `MPI.send` / `MPI.recv` of any object (they use `Serialization`): use the
  operations on buffers (arrays and numbers).

## Finalizers

`finalizer(f, x)` works, for a Julia function `f` (a closure that captures values too) and a mutable object `x`, and for a C function (`finalizer(ptr, x)`, which is what `BigInt` has). When a collection finds
`x` unreachable, `f(x)` is run, as Julia does it: after the collection, at an allocation, one finalizer after another and not one inside another, and once. This is what the wrappers of libraries do to free what the
library allocated (a `Regex` made when the program runs, a sparse factorization, a PCRE or MPI handle). How it works, and what is different:

* The collector can't call the code of the program (it is compiled apart), so the object is kept and queued, and the program runs its finalizer when the collection is over: the call of `finalizer(f, x)` is a *site* of the
  types of `f` and `x`, which has a list of the finalizers that were registered at it (a function, and the address of the object, as a number: the list does not keep the object alive), and the linker writes a `switch` that gives
  each object to the function of its site (see `src/finalizers.jl`).
* A finalizer that throws is ignored (Julia prints the error). One that stores `x` somewhere (resurrection) is run once; `x` stays alive, and a later collection frees it.
* Finalizers of the objects that are alive when the program ends are not run.
* The collector is conservative: an object that a word of the stack happens to have the address of is not freed by that collection (so a finalizer may run at a later collection than in Julia, or, for one of the last
  objects made, not at all in a short program). The collector zeroes the unused part of the stack before it looks at it, which is most of the cases.
* Memory that a library allocated is not counted by the collector, so an object that has a finalizer counts as 1 KiB of allocation towards the next collection.

## Tasks

A program has one thread and one stack, so a task is not run beside the others: it runs to its end when something waits. `@async`, `Threads.@spawn` and `Task` make a task that is put in a queue (`schedule`); `wait(task)`, `fetch(task)`, `wait(condition)`, `take!` of a `Channel`, `yield()`, `sleep` and the end of a `@sync` block are what block, and what a block does is run the tasks of the queue, one after another, each to its end, until the task that waits can go on. A task that waits itself runs the others in the same way, on top of the first. As in Julia, the tasks run when the one that made them waits or yields, in the order that they were scheduled:

```julia
log = Int[]
a = @async push!(log, 1)
b = @async push!(log, 2)
push!(log, 0)
wait(a); wait(b)
log   # [0, 1, 2], as in Julia
```

What is the same as in Julia: `current_task()` is a `Task` (the main one has no code), `task_local_storage` is the storage of the current task, the `ScopedValue`s that are set where a task is made are the ones that it has (and `@with` puts them back when it ends, also when it ends in an error), a task that fails gives a `TaskFailedException` to `fetch` and `wait`, and `@sync` gives a `CompositeException` of them.

What is not:

* A task that waits goes on when the tasks that it ran have returned, and **a task that is lower on the stack can't be resumed before the ones above it return**. A program in which tasks hand values to each other many times stops with a message that says so, as does one in which every task waits for something that none gives (a deadlock: in Julia it waits for ever).
* **A `Channel` never makes `put!` wait**: it holds what is put in it, whatever its size (also with no buffer), and `take!` waits. A producer that is a task runs to its end, and then the one that takes goes on, so what the tasks print is in that order, and not mixed.
* `sleep` runs the tasks that are scheduled, and then waits; `Timer` and tasks on other threads are not supported.
* **`atexit`**: the functions are run when the program ends, last registered first, by the C library: when `main` returns and when `exit` is called, before the streams are flushed. A function that fails does not stop the others. (`exit(code)` ends the program with that status.)

## Random numbers

`Random.default_rng()` (a `TaskLocalRNG`) keeps its state in the current task, which does not
exist in compiled programs. It is replaced by a global xoshiro256++ state, seeded from the
operating system (`getentropy`) when first used, like Julia seeds a new process. `Random.seed!(rng,
seed)` works for explicitly constructed generators. The default generator is not thread-safe, as
there are no threads. `Random.seed!(seed)` on the default generator does not work yet.

### UnicodePlots

`UnicodePlots` (plots written to the terminal) is supported for `lineplot`, `scatterplot`, `stairs`, `barplot`, `histogram` (horizontal and `vertical = true`), `boxplot`, `densityplot`, `heatmap` (of a matrix of numbers), `polarplot`, `contourplot`,
`surfaceplot`, `spy`, and the functions that change a plot (`lineplot!`, `scatterplot!`, `barplot!`, `hline!`, `vline!`, `annotate!`, `title!`, `xlabel!`, `ylabel!`), with a `title` and labels for the axes (`xlabel`, `ylabel`), `color`, `name` and `border` (an extension
of this package, `StaticRuntimeUnicodePlotsExt`; tests in `test/packages/unicodeplots.jl`): `println(lineplot(x, y; width = 40, height = 10, xlabel = "x"))` in a program writes what Julia writes. The package decides the type of the canvas, and of the plot, by values that are only known
when it runs (the scale of an axis, the keywords that are left after the plot's own are taken out, the limits of an axis and of the colors, a keyword that is of one of two types), which a program has to have as types: those are written again in the extension. Limits: only the default scale
of an axis (`:identity`) is supported, and any other is an error when the program runs; the same for the `zscale` of a `surfaceplot` and its mesh lines (`lines = true`); a color map other than the default is an error when it is not of the type of the default; `histogram`, `polarplot`,
`heatmap` and `surfaceplot` are for vectors and matrices of numbers; the canvas can be chosen (`canvas = AsciiCanvas`, `BlockCanvas`, `DotCanvas`); the points of a 3D plot (`surfaceplot`) are
projected with floating point numbers, and a point on the border of a pixel may be in another one than in Julia. Not supported: `isosurface`, `imageplot`, `geoplot`, `gridplot` and `savefig`.

## Code from packages

(The survey that this section reports is kept as tests, `test/packages` — Distributions.jl, NaNStatistics.jl and StatsBase.jl, each program compared with Julia — and
run on CI as a job of its own.)

Code of packages compiles like the code of Base: nothing is needed from the package. What packages do that Base's code seldom does is
handled here, found by compiling [Distributions.jl](https://github.com/JuliaStats/Distributions.jl),
[NaNStatistics.jl](https://github.com/brenhinkeller/NaNStatistics.jl) and [StatsBase.jl](https://github.com/JuliaStats/StatsBase.jl):

* **Logging.** `@warn`, `@info` and `@error` write to the standard error, as the default logger of Julia does to something that is not a terminal
  (`┌ Warning: message`, the keywords as `│   key = value`, and `└ @ file:line`). `@debug` is off, as it is in Julia without `JULIA_DEBUG`, and the code of it is not in
  the binary. There is one logger (`with_logger` and `global_logger` have no effect), and `maxlog` is not kept: the message is written each time.
* **`invokelatest`.** `invokelatest(f, args...)` (and `@invokelatest f(args...)`) is the call `f(args...)`: there are no newer methods in a program. The keyword
  form (`invokelatest(f, x; k = 1)`) is not supported.
* **`@assert cond "message $x"`** works (the message is a `String`, made when the assertion fails).
* **Deprecated methods** can be called: the warning (`Base.depwarn`) is not shown, as it is not in Julia by default.
* **Functions of libraries that a package calls by the name of the library** (`ccall((:erfc, libopenlibm), ...)`, as SpecialFunctions.jl, which Distributions.jl
  uses, does). The functions of the math library of the machine are linked by name: the values can differ from openlibm's in the last bit. Those of
  other libraries (OpenSpecFun, Rmath, GMP, ...) are looked up when the program runs (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)):
  by default the binary needs the file at the **path that the library had when compiling**, as it needs libblastrampoline for BLAS; `libraries = :bundle` copies them next to the program.
* **`IdDict`** works: the table is kept with Julia code, with the address of an object as its hash. What is not a mutable object all has one hash, so an `IdDict` with many
  keys that are numbers is slow.
* **`deepcopy`** works for any struct, array, dictionary, tuple or string, with shared and cyclic references kept as in Julia. Base reads the fields of a struct by a number that
  is only known when the program runs; here each type is copied field by field, each of its own type, made when compiling (`src/deepcopy.jl`). A field of the type `Any` or of an
  abstract type is copied over the registered types (see [`add_dispatch_candidates!`](@ref)). A method of `deepcopy_internal` that a package defines for its own type can't be used:
  compiling warns, and the program stops if it reaches the copy of such a type (it is not copied field by field, which would be a different result). Locks and `SimpleVector`s are not supported.
* **`reshape(x, :, n)`**, and **functions and `Colon()` in messages** (`string(sin)`, `show(:)`).

Compiled and compared with Julia in the survey (the results rounded to 6 digits, because of the last bit of libm):

* **Distributions.jl**: 65 of 65 cases, from `pdf`, `cdf`, `quantile`, `mean`, `var`, `entropy` for the usual distributions (`Normal`, `Gamma`, `Beta`, `TDist`, `Poisson`,
  `Binomial`, `Categorical`, `MvNormal`, `Dirichlet`, `Multinomial`, truncated and mixture models, ...), to `rand` with a generator that is given (`rand(Xoshiro(1), Normal())`),
  `fit`, `loglikelihood` and `kldivergence`.
* **NaNStatistics.jl**: all the cases of the survey (`nanmean`, `nanstd`, `nanmedian`, `nanquantile`, `nanpctile`, `nancov`, `nancor`, `movmean`, `histcounts`, `nanbinmean`, `nansort!`, ...)
  but `nanmean(A; dim = (1, 2))`: with the dimensions as a tuple the result is an `Array` of a size that is only known when the program runs (a function
  that is not type-stable), see [Dynamic dispatch on abstract types and on `Any`](@ref).
* **StatsBase.jl**: 92 of the 97 cases of the survey, of which 4 were not valid in Julia either. Weighted and unweighted `mean`, `var`, `std`, `median`, `quantile`,
  `skewness`, `kurtosis`, `mad`, `iqr`, `cor`, `cov`, `autocor`, `pacf`, `corspearman`, `corkendall`, ranks, `countmap`, `proportionmap`, `entropy`, `kldivergence`, `Histogram`, `ecdf`,
  `zscore` and `ZScoreTransform`, `sample` and `wsample` (with and without replacement, weighted) with a generator that is given, ... The one that doesn't: `summarystats` (it splats a
  `Vector` of a length that is not known into a constructor, `SummaryStats(m, sd, qs..., n)`).

* **DataStructures.jl**: 47 of 47 cases of the survey: `Stack`, `Queue`, `Deque`, `CircularBuffer`, `CircularDeque`, `MutableLinkedList`, `list`; `BinaryHeap` (min, max, custom order, mutable), `PriorityQueue`;
  `DefaultDict`, `counter`, `OrderedDict`, `OrderedSet`, `RobinDict`, `SwissDict`, `MultiDict`, `SparseIntSet`; `SortedDict`, `SortedSet`, `SortedMultiDict` (with semitokens and ranges); `IntDisjointSet`,
  `DisjointSet`, `FenwickTree`; and the balanced trees `AVLTree`, `RBTree` and `SplayTree`, whose nodes keep `Union{Node,Nothing}` fields. The methods that DataStructures has deprecated still work (the warning is not in the program).

* **StaticArrays.jl**: 27 of 27 cases of the survey: `SVector`, `MVector`, `SMatrix`, `MMatrix` and `SArray` (arithmetic, broadcasts, `map`, `push` and `pop`, `vcat` and `hcat`, `sort`, as `Dict` keys,
  in a `Vector`), `FieldVector` structs, the macros `@SVector` and `@SMatrix`, and `det`, `inv`, `\`, `eigvals`, `qr`, `svdvals`, `cholesky` and `lu` of small matrices.
* **OrderedCollections.jl**: 12 of 12 cases: `OrderedDict` (insertion, deletion, order of iteration, `merge`, `sort`, `pop!`), `OrderedSet` and `LittleDict`. The one that doesn't: `freeze` (it makes a tuple
  that has as many elements as the dictionary has, which is not known until the program runs).

* **Graphs.jl**: 42 of 42 cases of the survey: `SimpleGraph` and `SimpleDiGraph` (building, querying, subgraphs, the generators, `erdos_renyi` with a seed), `bfs_tree`, `dfs_tree`, `dijkstra`, `bellman_ford`,
  `floyd_warshall`, `a_star`, connected and strongly connected components, `topological_sort`, `kruskal_mst` and `prim_mst`, `maximal_cliques`, `greedy_color`, `label_propagation`, `pagerank`, `betweenness_centrality`,
  `closeness_centrality`, `eigenvector_centrality`, and the adjacency and Laplacian matrices.

* **Parsers.jl** (version 3): 40 of 40 cases of the survey: `parse` and `tryparse` of integers of every width (with `base` and `groupmark`), `Float16`, `Float32` and `Float64` (with `decimal`, hexadecimal floats, `Inf` and `NaN`),
  `Bool` (with other spellings), `Date`, `DateTime` and `Time` (with a format), `UUID`, `BigInt` and `BigFloat`, from strings and from spans of bytes; and `parsenext` and the kernels (`parseint`,
  `parsefloat`) that a reader of files is made of, in a loop over the fields of a line. The results of the floats are the same to the last bit as Julia's.

* **[Thermochron.jl](https://github.com/brenhinkeller/Thermochron.jl)** (forward models; 19 cases in the survey): helium diffusion (`SphericalHe`, `PlanarHe`, `ZirconHe`, `ApatiteHe` with RDAAM and ZRDAAM
  annealing, `SphericalAr`), fission track ages (`ZirconFT`, `ApatiteFT` with the Ketcham and Yamada/Guenthner models), vitrinite reflectance with a `NielsenBasinRo` that is a constant, and
  `model!` over a `Vector` of one concrete type of chronometer (`Vector{ApatiteHe{...}}`), with the chronometers built when compiling or by the program. Not yet: `model!` over a vector
  of chronometers of several types (`AbsoluteChronometer`, `FissionTrackSample`), because `model!` prints chronometers in a debugging message (`@info chrons[imax]`) and takes `argmax` over a union of many types, both dynamic
  (`eltype(c) <: C` now works, see [Binary size](@ref)); `NielsenBasinRo()` built by the program (it splats a vector into a tuple); and the MCMC functions, which are not tried yet.

* **[Isoplot.jl](https://github.com/brenhinkeller/Isoplot.jl)** (28 of 29 cases of the survey, after the changes below; `metropolis_min` compiles, but draws from the global generator, so its numbers are not
  Julia's): the weighted means, `mswd`, `chauvenet`, `yorkfit`, `lsqfit`, `mcleanfit`, `isochron`, the concordia functions (`age`, `discordance`, `isconcordant`, `upperintercept`, `ageconcordia`),
  `stacey_kramers`, `CI`, `Age`, `rand` of an analysis with a generator that is given, `distwmean` and `Measurement` arithmetic. Written with sizes that are only known when the
  program runs, five things did not compile, and were made to by small changes to a copy of the package: `Analysis(μ, Σ)` of a `Vector` and a `Matrix` is an `Analysis{length(μ)}` (given
  `SVector`s, whose length is in the type, it compiles); `SVector{npoints}` in `Ellipse` with a number of points that is a keyword (a `Val`, `Ellipse(d, Val(50))`); `ntuple(f, length(x))` of a
  `Vector` in `yorkfit` and `distwmean` (a `Tuple` or `SVector` of analyses compiles); `eigen` of an `SMatrix` that has complex eigenvalues for all that the compiler can tell
  (`eigen(Symmetric(Σ))`); and a local function that returns a number or a tuple depending on an argument (`mcleanfit`), which is two functions.
