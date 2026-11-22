In general, we aim to support all generic, type-stable Julia code, 
with limited support for some kinds of runtime dynamism.
In contrast to using StaticCompiler and StaticTools alone, 
here we generally support 
* **Allocations**, with an optional static-compileable garbage collector
* **Closures**
* **Boxing**
* Some runtime **generation of known types**, including some deserialization
* Some support for **abstract types**, including `Any`
In more detail:

# Base and Standard Libraries (including linked libraries)

Most functions from Base should generally work, if they do not involve excessive runtime dynamism.
For example:
* **`deepcopy`** works for any struct, array, dictionary, tuple or string, with shared and cyclic references kept as in Julia. 
  Here each type is copied field by field, each of its own type, as known when compiling (`src/overrides/deepcopy.jl`).
  A field of the type `Any` or of an abstract type is copied over the registered types (see [`add_dispatch_candidates!`](@ref)). 
  A method of `deepcopy_internal` that a package defines for its own type can't be used;
  compiling warns, and the program stops if it reaches the copy of such a type 
  (it is not copied field by field, as this would yield a different result).
* **`IdDict`** works: the table is kept with Julia code, with the address of an object as its hash. 
  What is not a mutable object all has one hash, so an `IdDict` with many keys that are numbers is slow.
* **`reshape(x, :, n)`** is supported
* **`@assert cond "message $x"`** works (the message is a `String`, made when the assertion fails).

## Input and output

The standard streams of Julia are libuv streams, which need the Julia runtime. 
Compiled programs use those of libc, as [`StaticIO`](@ref)s: [`STDIN`](@ref), [`STDOUT`](@ref) and [`STDERR`](@ref).
`StaticIO` implements the `IO` interface, so all of the code of Base for printing and reading works with it (`print`, `show`, `write`, `read`, `readline`, `eof`, `flush`, ...).

`print`, `println` and `show` without an `IO` write to the standard output, as in Julia:

```julia
function main(args::Vector{String})
    println("Hello, ", isempty(args) ? "world" : args[1], "! ", 1 + 1, " ", 2.5, " ", 'λ', " ", :sym)
    println(STDERR, "this goes to the standard error")
    line = readline(STDIN)
    @show line
end
```

In Julia, `stdout` is a global variable of the abstract type `IO`, so a call like `println(stdout, x)` would be
resolved only when it runs, impeding compilation. 
To avoid this, during compilation we replace Base's `stdout`, `stderr` and `stdin` with our `STDOUT`,
`STDERR` and `STDIN`, so such code should work as-is.

### Formatted output: `printf` and `@printf`

Two ways, which write the same bytes into the same buffer, so can be mixed freely with `print`:

* **`printf` of StaticTools**: C's `printf`, with any number of arguments and a `c"..."` format. Its format
  specifiers are those of C: for example an `Int64` is `%lld` (`%d` is for a 32-bit `int`).
  It takes integers, floating-point numbers, pointers, and strings (`StaticString`s,
  `MallocString`s and `String`s) for `%s`, and a stream first: `printf(STDERR, c"...", x)`.
* **`Printf` of Julia**: `@sprintf` and `@printf(STDOUT, "...", x)` (or `STDERR`, or a file), with Julia's
  own formats, which are the same as in Julia: `%d` is for any integer, and so on. This is Julia's `Printf`,
  so what it writes is the same. A format with `*` (`%*d`) is not supported. The format has to be
  made once, as `@printf` does: a `Printf.Format("...")` made when the program runs can't be compiled.

```julia
printf(c"%s: %d of %lld, %5.2f%%\n", c"progress", 3, 10^12, 12.345)   # C
Printf.@printf(STDOUT, "%s: %d of %d, %5.2f%%\n", "progress", 3, 10^12, 12.345)   # Julia
name = Printf.@sprintf("%s-%03d.txt", "run", 7)
```

### `IOContext`, `text/plain` and `display`

`IOContext(io, :compact => true, :limit => true, ...)` of the streams of the program (`STDOUT`, `STDERR`, files, and what `sprint` writes to) has the properties in its *type*, so asking for them (`get(io, :compact, false)`) is a constant when compiling, and what depends on it is decided then. 
So their **values have to be known when compiling** (a `Bool`, a number, a type, a tuple of those): `IOContext(io, :compact => flag)` with a `flag` that is only known when the program runs cannot be resolved (compiling says so). 
`:SHOWN_SET` (the containers that contain themselves, which are not detected) and `:module` are not kept. 
The properties then do what they do in Julia:

```julia
show(IOContext(STDOUT, :compact => true), 0.1 + 0.2)          # 0.3
show(IOContext(STDOUT, :limit => true), collect(1:30))        # [1, 2, 3, 4, 5, 6, 7, 8, 9, 10  …  21, 22, 23, 24, 25, 26, 27, 28, 29, 30]
```

`show(io, MIME"text/plain"(), x)` and `display(x)` (which writes the `text/plain` form to the standard output, as the `TextDisplay` of a Julia script does) write matrices aligned, with the size and type above them, and vectors, ranges, dictionaries, sets and structured matrices (`Diagonal`, `Symmetric`, ...) as Julia does. 
Base lines up the numbers of a column by finding the decimal point (or the sign of the imaginary part, or the `//`) with regular expressions, which a program may not have: the same is found by a scan of the text. With `:limit` and `:displaysize` the output is cut as Julia cuts it.

### Color

`printstyled` (with `color`, `bold`, `italic`, `underline`, `blink`, `reverse` and `hidden`, and a color that is a name or a number of 0 to 255) writes the escape sequences of Julia when the stream has `:color => true` in its context, and plain text when it has not. 
A program is not told whether its output is a terminal, so it is as `julia script.jl > file`: `STDOUT` has no color, and
`Base.get_have_color()` (which Crayons, and so UnicodePlots, ask when the stream does not say) is `false`. 
A program that wants color asks for it: `printstyled(IOContext(STDOUT, :color => true), "text"; color = :red)`.

## Files and the filesystem

Files: `open` opens a file with libc's `fopen`, as a [`StaticFile`](@ref), which is an `IO` like the standard streams,
so what Base has for reading and writing an `IO` works: `open(f, path, mode)`, `read(path, String)`,
`readlines`, `eachline`, `readline`, `write(path, x, y)`, `println(io, x)`, `eof`, `position`, `seek`,
`filesize`, `close`, `@printf(io, ...)`, `printf(io, c"...", x)`, and numbers and arrays of numbers as binary data
(`write(io, x)`, `read(io, Int32)`, `read!(io, array)`, `read(io, n)`). The mode is the one of `fopen` (`"r"`, `"w"`, `"a"`,
`"r+"`, ...).

The filesystem: `stat` (and `isfile`, `isdir`, `ispath`, `filesize`, `mtime`, `filemode`), `mkdir`, `rm` (with `force` and `recursive`), `readdir` (with `join` and `sort`), `mv`, `cp` (of a file or a directory), `pwd`, `cd`, `realpath`, `homedir`, `tempdir`, `tempname`, `mktemp`, `mktempdir` (and with a function), `chmod` (and `recursive`), `symlink` and `readlink`, `walkdir`, `ENV[name] = value` and `delete!(ENV, name)`, `Libc.getpid`, `gethostname`, `Libc.strftime`, and `Sys.total_memory`, `Sys.free_memory` and their `physical` forms are done with the functions of the C library (the memory is not limited by a Linux control group, as libuv reads it). 
What is different: 
an error is a `SystemError` with the message of `strerror`, where Base's is an `IOError` that has the code of libuv (a program that catches `IOError` for a missing file catches `SystemError` here), and `touch`, `mmap` of an open stream and starting other programs (`run`, ``read(`cmd`, String)``) are not supported; `walkdir` walks the whole tree before the loop starts (its `Channel` is filled by a task that runs to its end). `Threads.@threads` runs the loop on the one thread, in order.

## Tasks

A compiled program here has one thread and one stack. 
However, in order to allow the broadest range of Julia code to compile, we attempt to provide a serial fallback:
`@async`, `Threads.@spawn` and `Task` make a task that is put in a queue (`schedule`); 
while `wait(task)`, `fetch(task)`, `wait(condition)`, `take!` of a `Channel`, `yield()`, `sleep` and the end of a `@sync` are blocking. 
A block runs the tasks of the queue, one after another, each to its end, until the task that waits can continue. 
For example:

```julia
log = Int[]
a = @async push!(log, 1)
b = @async push!(log, 2)
push!(log, 0)
wait(a); wait(b)
log   # [0, 1, 2], as in Julia
```

What is the same as in Julia: `current_task()` is a `Task` (the main one has no code), `task_local_storage` is the storage of the current task, the `ScopedValue`s that are set where a task is made are the ones that it has (and `@with` puts them back when it ends, also when it ends in an error), a task that fails gives a `TaskFailedException` to `fetch` and `wait`, and `@sync` gives a `CompositeException` of them.

What is not the same:
* A task that waits goes on when the tasks that it ran have returned, and **a task that is lower on the stack can't be resumed before the ones above it return**. A program in which tasks hand values to each other many times stops with a message that says so, as does one in which every task waits for something that none gives (a deadlock: in Julia it waits for ever).
* **A `Channel` never makes `put!` wait**: it holds what is put in it, whatever its size (also with no buffer), and `take!` waits. A producer that is a task runs to its end, and then the one that takes goes on, so what the tasks print is in that order, and not mixed.
* `sleep` runs the tasks that are scheduled, and then waits; `Timer` and tasks on other threads are not supported.
* **`atexit`**: the functions are run when the program ends, last registered first, by the C library: when `main` returns and when `exit` is called, before the streams are flushed. A function that fails does not stop the others. (`exit(code)` ends the program with that status.)

## Symbols

Julia keeps every symbol in one table, so that there is one object for each name and `===` of symbols compares addresses. 
A program has no such table, so:

* The symbols that the program has when it is compiled are copied into it, as any constant is, so `Dict`s and `Set`s of symbols that are `const` work (a symbol hashes by a number that is in it, which the copy has too), and so does `string(sym)`, `print`, `sort`, `startswith(string(sym), ...)`, and the like.
* `Symbol("abc")`, `Symbol("x", 1)`, `Symbol(uppercase(string(s)))` and `Symbol(::Vector{UInt8})` of a name that the program makes work too. The binary has a list of its symbols, sorted by name, that is looked in first, so `Symbol("abc") === :abc` and a `Dict` that was made when compiling finds a key that the program made; a name that is not in it is made into a new symbol, kept in a tree (the same as the table of Julia is: by hash and name). These symbols are never freed (40 bytes and the name for each different name), and their names can't have a NUL in them.
* `show` of a symbol writes `:name` for a name that is a plain ASCII identifier. For other symbols, Julia decides with tables of its parser (`:+`, `:(==)`, `:α`, `Symbol("a b")`): for those that the binary has, it writes what Julia writes (the text is made when linking); for those that the program makes, only the names that are certainly not identifiers or operators (empty, with a space or a control character or a quote, or starting with a digit) are written, as `Symbol("...")`; any other is an error.
* Types as keys: `==` of types, `hash` of a `DataType`, and so `Dict{DataType,...}` and `Set{DataType}`, work (a type hashes by the number that it has in it). `==` of types that are not both concrete (a `Union`, an abstract type with parameters) goes by `<:` (see [Dynamic dispatch on abstract types and on `Any`](@ref)).
* `getfield(x, name)`, `x.name`, and for a `NamedTuple` `nt[name]` and `get(nt, name, default)`, of a struct with a `Symbol` that is only known when the program runs work: the result has the union of the types of the fields (a table of functions that is indexed by the name of the one that a keyword asks for), which is split where it is used. Not supported: such a name for the fields of a type object.

## Finalizers

`finalizer(f, x)` works, for a Julia function `f` and a mutable object `x`, or for a C function (`finalizer(ptr, x)`). 
When a collection finds `x` unreachable, `f(x)` is run, as in Julia: after the collection, at an allocation, 
one finalizer after another and not one inside another, and once. 
This is what the wrappers of libraries do to free what the library allocated 
(a `Regex` made when the program runs, a sparse factorization, a PCRE or MPI handle). 
How it works, and what is different from Julia:

* The collector can't call the code of the program (it is compiled apart), so the object is kept and queued, 
  and the program runs its finalizer when collection is completed: 
  the call of `finalizer(f, x)` is a *site* of the types of `f` and `x`, 
  which has a list of the finalizers that were registered at it,
  and the linker writes a `switch` that gives each object to the function of its site (see [`src/overrides/gc.jl`](https://github.com/brenhinkeller/StaticRuntime.jl/blob/main/src/overrides/gc.jl)).
* A finalizer that throws is ignored (Julia prints the error). 
* A finalizer that stores `x` somewhere (resurrection) is run once; `x` stays alive, and a later collection frees it.
* Finalizers of any objects that are still alive when the program ends are not run.
* The collector is conservative: an object that a word of the stack happens to have the address of is not freed by that collection 
  (so a finalizer may run at a later collection than it would Julia, or, for one of the last objects made, not at all in a short program). 
* Memory that a library allocated is not counted by the collector, 
  so an object that has a finalizer is treated as if it contributed 1 KiB of allocation towards the next collection.

## Random numbers and the `Random` stdlib

`Random.default_rng()` (a `TaskLocalRNG`) keeps its state in the current task, which compiled programs do not have. It is
replaced by a global xoshiro256++ state, seeded from the operating system (`getentropy`) when first used, as Julia seeds a
new process; `Random.seed!(seed)` sets it, so a seeded program gives Julia's numbers. Generators that are made explicitly
(`Xoshiro(1)`, `MersenneTwister(1)`) and `RandomDevice` work as in Julia. There is one default generator for the whole
program, not one for each task.

## Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own

A `ccall` into a compiled library (e.g., `ccall((:name, "libname"), ...)`) should be supported as a dynamic call in the compiled program. 
Where the compiled code looks for those libraries may be specified with the `libraries` keyword argument:

```julia
compile_executable(f, types, dir, name)                       # libraries = :system, the default
compile_executable(f, types, dir, name; libraries = :bundle)
```

* `:system` — the program opens the library at the **path that it had when compiling** (for example, a JLL in `~/.julia/artifacts`). 
  The compiled program is not independent of that file. 
  If the library is missing when the compiled program is run, the program will error.

* `:bundle` — the libraries (and dependents: e.g.,  `libmpfr` needs `libgmp`) are copied to the folder `lib` next to the program, 
  and the program looks there first, relative to where *it* is, 
  so the folder of the program can be moved or copied to another machine of the same kind. 
  If a library is not there, the path that it had when compiling is tried.
  Libraries of the system (`/usr/lib`, `/lib`, ...) are not copied. 
  For `compile_shlib`, `lib` is next to the shared library.

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

Base features that work through this mechanism (and are included in the unit tests) include: 
**`BigInt`**, **`BigFloat`**, and **`Regex`** (PCRE).
Most other libraries, including JLLs and `LazyLibraries` in base or user code should be supported in the same way.
Exceptions are functions of the math library (`libm`, `libopenlibm`), which are linked by name instead,
and libraries of the Julia runtime (libjulia, libuv, ...), which are not included.

Limits: a `Ptr` field (i.e., an address) as a constant of the program is null in compiled code, 
and will trigger a warning during compilation.


## LinearAlgebra

Matrix products, `dot`, `norm`, `\`, `inv`, `det`, `lu`, `qr`, `cholesky`, `eigvals`, `svdvals` and so on should work, as usual via BLAS and LAPACK. 
The `LinearAlgebra` stdlib does these operations by calls to [libblastrampoline](https://github.com/JuliaLinearAlgebra/libblastrampoline)(LBT), which passes each on to the library that backs it: OpenBLAS by default, or another library if a package such as
[AppleAccelerate.jl](https://github.com/JuliaLinearAlgebra/AppleAccelerate.jl) or 
[MKL.jl](https://github.com/JuliaLinearAlgebra/MKL.jl) has been loaded. 
A compiled program does the same; it links to the libraries that were in use at the time it was compiled.

```julia
using StaticRuntime, LinearAlgebra
using AppleAccelerate; AppleAccelerate.load_accelerate()    # (or `using MKL`: any library that LBT forwards to)
compile_executable(main, (Int, Ptr{Ptr{UInt8}}), "build")   # the program calls Accelerate
```

How it works: LBT, and the libraries that it forwards to (those of `BLAS.get_config()`, in the order that they were loaded, with their suffixes), 
are not in the binary. Their paths are, and the first time that the program calls a function of BLAS or LAPACK it loads LBT (`dlopen`), forwards to those libraries as `lbt_forward` does, and looks the function up (`dlsym`), as Julia does for a `ccall`. 
So, to summarize:

* The libraries must be at the same paths when the program is run as when it was compiled. 
  A program that is run elsewhere complains that it `Cannot load libblastrampoline (for BLAS)` and exits.
* The program can use more than one thread, if the library does.
* Large calls of BLAS can't be cancelled (there are no tasks to cancel).

The element types and sizes are the ones that BLAS and LAPACK take (`Float64`, `Float32`, `ComplexF64`, `ComplexF32`);
other types use generic Julia code, which compiles like any other. 

## SparseArrays

SparseArrays are handled with SuiteSparse's libraries (UMFPACK, CHOLMOD, SPQR), which are called as any library is (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)): the program sets them up the first time that it needs them, 
as Julia does (`LibSuiteSparse.init_suitesparse`, with the C library's allocators), 
and tells libblastrampoline what BLAS it forwards to, as it does for BLAS. Support includes:
* `sparse`, `spzeros`, `SparseMatrixCSC`, sparse vectors, indexing and `setindex!`, `nnz`, `nonzeros`, `findnz`, sums, 
  products of sparse with dense and with sparse, `transpose`, `kron`, `spdiagm`, `I`, and `show` of sparse arrays should all work
* **factorizations**: `\` of a sparse matrix, `lu`, `cholesky`, `ldlt`, `qr` (and so least squares), `det`, `logdet`, `factorize`, with
  their errors (`PosDefException`, `SingularException`). 

What is different: CHOLMOD's error says the code of the failure (a `CHOLMODException("CHOLMOD error (status -3)")`) and not its message, 
and the settings that CHOLMOD keeps for each task are the program's one.

## StyledStrings

Styled strings (`styled"..."`, `AnnotatedString`, `AnnotatedChar`) are written to a stream with the escape sequences of Julia when its context has `:color => true`, and as plain text otherwise (loading `StyledStrings` is what enables this, as for the other standard libraries that have a part of their own). 
The faces are the ones that there are when compiling (the theme, and what has been added with `addface!`), as they are looked up by a comparison with each name; `withfaces`, `addface!` and the `faces.toml` of the user when the program runs are not supported. A terminal is taken to be one with italics, reverse and strikethrough (the terminfo of the terminal is not read), 24-bit color is used when the environment says so (`COLORTERM=truecolor`, ...) and else the closest of the 256 colors, and the underline of a color and style is a plain underline. 
Not supported: `show` of an `AnnotatedString` (`repr`), which shows annotations of the type `Any`.

Limits: containers that contain themselves are not detected (they recurse until the program crashes); the keyword `context` of `sprint` with a pair that is written in the call (`sprint(show, v; context = :compact => true)`) works for what is not an array, and is not yet supported for the show of an array (give `IOContext` the stream instead, or a context that is a stream); `text/plain` of a `UniformScaling` (`2I`) is not supported (it uses a regular expression); a `Symbol` that the program makes and that is not a plain ASCII identifier is written as Base writes it only if that is clear without the parser's tables (`Symbol("a b")`, `Symbol("1a")`, `Symbol("")`), and else it is an error (the symbols that were there when compiling, such as `:+` or `:α`, are written as Julia writes them: see [Symbols](@ref)); and the names of types of modules that are loaded after this package (`using` in the program) are written with their module (Base writes `Main`'s view of them).

## Serialization

`serialize(io, x)` of a value whose type is known when compiling writes the bytes that Julia writes (numbers, strings, tuples, arrays, `Dict`s and `Set`s, structs, objects that refer to themselves, ranges, `BigInt`), so a stream can be read by Julia, and by a program.

`deserialize(io)` gives a value of the type that the stream says, which a program can not make when it runs: it is made over the types that the program has. Those are the types that the program serializes (found when compiling, with the types of what they hold: the fields of a struct, the elements of an array, the keys and values of a `Dict`), and the ones that are registered with `add_deserialize_types!`, for a stream that another program wrote:

```julia
struct Point; x::Float64; y::Float64; end
add_deserialize_types!(Point, Vector{Point})     # before compiling

function main()
    p = deserialize(open("points.bin"))::Vector{Point}
    ...
end
```

What is read is, for the compiler, a value of one of those types (a union that Julia splits: `::T` after it says which, and is how a program that has many types is written). A stream with a value of another type stops the program, with a message that says so. A `Vector{Any}` (or a field of an abstract type) holds values of the types that are registered: register them too (`add_deserialize_types!(Vector{Any}, Int, String)`). Not supported: a `Symbol` that is read, tuples of more than 255 elements, `Union` and `UnionAll` values, modules, functions and `Expr`; and `serialize(s::Serializer, x)` of a `Serializer` that is made by the program (the types that it writes are found from `serialize(io, x)`). A program that does not use Serialization has nothing of it.

## Other standard libraries

* **Base64**
* **CRC32c**
* **Dates**: `Date`, `DateTime` and `Time` (construction, fields, arithmetic with periods, ranges, `dayofweek` and the like, `monthname`, `show`),  
  parsing a string (`Date("2021-12-25")`, `DateTime(...)`, `tryparse`, and with a format), 
  `now()` and `today()` (the time zone of the machine that runs the program). 
  A format made at compile-time with the macro works: `Dates.format(d, dateformat"dd/mm/yyyy")`.
  However, `Dates.format(d, "dd/mm/yyyy")` makes a format when the program runs, from the characters of the string, which is not supported.
* **Future**: `copy!`; not `randjump`
* **Libdl**: `dlopen`, `dlsym` and `dlclose` of libraries opened when the program runs, not `DL_LOAD_PATH`
* **Logging.** `@warn`, `@info` and `@error` write to the standard error, as the default logger of Julia does to something that is not a terminal
  (`┌ Warning: message`, the keywords as `│   key = value`, and `└ @ file:line`). 
  `@debug` is off, as it is in Julia without `JULIA_DEBUG`, and the code of it is not in the binary. 
  There is only one logger, and `maxlog` is not kept: the message is written each time.
* **Mmap**: `Mmap.mmap(path, Vector{T}, dims, offset)`; the memory is not unmapped before the program ends
* **Printf**: everything except runtime formats
* **SHA**
* **Statistics**
* **UUIDs**, including `uuid4()`

# Other packages

## Plotting

The example on the [home page](index.md) solves a differential equation with OrdinaryDiffEq and plots it with UnicodePlots. 
Each of the packages below, including these, is checked by programs whose output is compared with Julia's.

### UnicodePlots

`UnicodePlots` (plots written to the terminal) is supported for `lineplot`, `scatterplot`, `stairs`, `barplot`, `histogram` (horizontal and `vertical = true`), `boxplot`, `densityplot`, `heatmap` (of a matrix of `Float64`s), `polarplot`, `contourplot`, `surfaceplot`, `spy`, and the functions that change a plot (`lineplot!`, `scatterplot!`, `barplot!`, `hline!`, `vline!`, `annotate!`, `title!`, `xlabel!`, `ylabel!`), with a `title` and labels for the axes (`xlabel`, `ylabel`), `color`, `name` and `border` (an extension of this package, `StaticRuntimeUnicodePlotsExt`; tests in `test/packages/unicodeplots.jl`): `println(lineplot(x, y; width = 40, height = 10, xlabel = "x"))` in a program writes what Julia writes. The package decides the type of the canvas, and of the plot, by values that are only known when it runs (the scale of an axis, the keywords that are left after the plot's own are taken out, the limits of an axis and of the colors, a keyword that is of one of two types), which a program has to have as types: those are written again in the extension. Limits: only the default scale of an axis (`:identity`) is supported, and any other is an error when the program runs; the same for the `zscale` of a `surfaceplot` and its mesh lines (`lines = true`); a color map other than the default is an error when it is not of the type of the default; `histogram` is for vectors of numbers, and `polarplot`, `heatmap` and `surfaceplot` for vectors and matrices of `Float64`s (the limits of the colors and of the axes of the others are printed as their own types, which the overlays of the extension do not have: those are refused when compiling); the canvas can be chosen (`canvas = AsciiCanvas`, `BlockCanvas`, `DotCanvas`); the points of a 3D plot (`surfaceplot`) are projected with floating point numbers, and a point on the border of a pixel may be in another one than in Julia. Not supported: `isosurface`, `imageplot`, `geoplot`, `gridplot` and `savefig`.

### Makie

Makie is currently somewhat more challenging to support, and support is currently quite limited

A `Makie.Scene` that is made before the program is compiled, and is a constant of it (`const scene = Scene(...)`), can be read and changed by the program: its size, the viewport (`scene.viewport[] = Rect2i(...)`), and the inputs of its compute graph (`ComputePipeline.update!(scene.compute, viewport = ...)`, or `scene.compute.viewport = ...`), whose changes reach the nodes and the observables of the graph, as the camera. 
Call `StaticRuntime.prepare!(scene)` once, after the scene is made and before compiling: the typed edges get the names of their outputs, what the graph does when its outputs change is made again with the types of its observables, the functions of the inputs get the references of their nodes, a node that Makie keeps in a `RefValue{Any}` of a few types of value (`shading`) gets one of the union of them (the listeners of its observables are found when compiling, see [Observables](@ref)). 
The nodes of a graph are resolved when it is prepared: a node that a program resolves for the first time is an error. 
The observables that the program uses have to be asked for before (`get_observable!(graph, name)`, or `on(f, graph[name])`). 
Only the latest release of Makie is supported (0.24).

The nodes of a plot in a `Figure` (`plot.attributes`, a graph of its own, which is connected with those of its scene and of the other plots) are read and set through `StaticRuntime.typed_node(graph, key)` and `StaticRuntime.typed_input(graph, key)`, made before compiling and kept as constants, after `prepare!` was called on every scene and on the graph of every plot (`prepare!(plot.attributes)`):

```julia
const fig = Figure(size = (300, 200)); const ax = Axis(fig[1, 1]); const plt = lines!(ax, 1:10, Float64.(1:10) .^ 2)
# (prepare! of each scene of fig, and of each of their plots' attributes)
const POSITIONS = StaticRuntime.typed_node(plt.attributes, :positions)
const YS = StaticRuntime.typed_input(plt.attributes, :arg2)
function main(argv)
    YS[] = [i * 10.0 for i in 1:10] # (what `update!(plt.attributes, arg2 = ...)` does)
    println(POSITIONS[][3])         # (what `plt.attributes[:positions][]` gives)
    return 0
end
```

A read of `graph[key][]` resolves what the node comes from with the types of all the nodes of all the graphs of the figure (the functions of the inputs, the edges, the references of the values: a few hundred types of each), which is too large a program; a typed node has what it comes from as a list of steps of their own types (each edge and input that it depends on, in order). 
A typed input has the graphs that its changes reach, and their listeners.
The values have the types that they had when they were made: a value of another type (an input that was a `Vector{Float64}` set to a `Vector{Int}`) stops the program with a message. 
Changing the axis or the layout when the program runs (a resize, the limits of an axis) is not yet supported. `typed_node(graph, key; inputs = (YS,))` resolves only what depends on the inputs that are given (the rest is fixed: a change of it stops the program with a message that names it), which is a smaller program.

With CairoMakie loaded, a scene or a figure is drawn to a PNG by the program with `StaticRuntime.typed_drawing`, made before compiling and kept as a constant:

```julia
using CairoMakie
const fig = Figure(size = (300, 200))
lines!(Axis(fig[1, 1]), 1:10, Float64.(1:10) .^ 2)
const DRAWING = StaticRuntime.typed_drawing(fig) # (it prepares the graphs itself)
main(argv) = (DRAWING("plot.png"); 0)            # (or `DRAWING(screen)`, on a `CairoMakie.Screen` of the scene)
```

The scene is drawn once when the drawing is made (which adds to the graphs of the plots what drawing them needs), and a figure is made ready as saving it does (the limits of its axes).
Each plot is then a step with its own types, in the order that CairoMakie draws them. 
The image is what CairoMakie draws (the PNG is RGB, where `save` writes RGBA). 
The fonts of the text are in the program (FreeType reads them from the bytes that the figure has); 
`inputs` are the `typed_input`s that the program changes before drawing; what else changes is not drawn (it stops the program, as for `typed_node`), and plots that are added afterwards are not. Lines, line segments,
scatter, text and polygons are supported; images, heatmaps and shown meshes are not yet.

### Observables

`Observable`s (the package Makie is built on) work with `on`, `map`, `map!` and `onany`, with support in the Observables extension. 
A listener is called with a direct call, as the package does it with `invokelatest`, which a compiled program has no use for. 
Not supported: a connection that is `weak` is not removed when it is collected, and what shows a listener (`show` of an `Observable` with its listeners, which asks where the function is defined). 
The listeners of an `Observable` are kept as functions of the type `Any`: when the code compiles, the functions that were given to `on` (and `map`, `onany`) for an `Observable` of a type of value are the ones that are called when an `Observable` of that type is set, and
no others. 
So a listener has to compile for the type of the value of the `Observable` that it is given to (as it does in Julia), and an `Observable` that has no listener has no call. 
A function is found where it is given, so it is not found if the listeners are made by something that compiled code does not go through (`register_callback` is what they all go through).

An `Observable` that is made before the program is compiled (and is a constant of it, or is reached from one, as the observables of a scene are) has listeners that the code of the program did not give to `on`: they are found when the program is compiled, in its constants, and nothing is changed in them. 
The code that sets or notifies such an `Observable` is compiled for it, with its listeners as constants, so that what one of them stores in another `Observable` is known of that one (a pair of the values of two, in a third). 
A listener of one is called as it is called in Julia, but for those that use the mouse and the keyboard (which have a module in them), which a program has no events for.

## Differential equations and optimization

### SciML (differential equations)

`SciMLBase` and `OrdinaryDiffEq` work for ordinary differential equations (tests in `test/packages/sciml.jl`): a problem made with `ODEProblem{iip, FullSpecialize}(f, u0, tspan, p)` (`iip` is `false` for `f(u, p, t)` that gives the derivative and `true` for `f!(du, u, p, t)` that changes `du`) and solved with `solve(prob, alg; kwargs...)`: for the explicit methods (`Tsit5`, `Vern7`, `BS3`, `DP5`, `Euler` and `RK4` with a fixed step), the stiff ones (`Rodas5P`, `ImplicitEuler`), with `reltol`, `abstol`, `saveat`, `tstops`, `save_everystep`, `DiscreteCallback` and `ContinuousCallback`, for scalars, `Vector`s and `SVector`s, and the solution (`sol.u`, `sol.t`, `sol(t)`). 
Compiling takes about 10 to 20 seconds for each program. 
`ODEProblem(f, u0, tspan, p)`, which finds out whether `f` changes its first argument when it runs, is `Any` to the compiler (to Julia as well), so the problem has to be made with `{iip, FullSpecialize}`; `solve(prob)` without a method (the default one, that picks among many) and the packages that make equations from symbols (`ModelingToolkit`) are not supported. 
Two things that these packages do are done by extensions: `FunctionWrappers` keeps its function in a pointer to a function of the runtime, which a program does not have (`ext/StaticRuntimeFunctionWrappersExt.jl`: the call is made through the function that the wrapper holds), and a message of `SciMLLogging` (`lazy"..."`) is not made into text: its parts are a tuple whose types are not known when compiling, so a program that shows one stops with an error that says so (the messages are not shown by default).

### JuMP

`JuMP` with `HiGHS` works for a model made with `direct_model(HiGHS.Optimizer())`, 
and `MathOptInterface`'s functions called on a `HiGHS.Optimizer` itself (tests in `test/packages/jump.jl`): 
variables, constraints, the objective, `optimize!`, `termination_status`, `objective_value` and `value`. 
HiGHS is a library that the program opens at the path that it has when compiling. 
Not yet supported: `Model(HiGHS.Optimizer)`, whose backend is a `CachingOptimizer` of MOI's bridges 
(they find the types of the bridges when the program runs), and a program that has a model of each kind.

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

The MPI library is a compiled library that the program calls like any other 
(see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)): 
the one that MPI.jl is set to use (`MPICH_jll` by default, or a system one through `MPIPreferences`), 
opened from the path that it has when compiling, or from the folder `lib` next to the program with `libraries = :bundle`. 

As usual, an excutable compiled to use MPI must be run with the `mpiexec` of the same library it was compiled with (`MPI.mpiexec()` has the environment that the library needs). 
The point-to-point and collective operations (`Send`, `Recv!`, `Sendrecv!`, `Isend`, `Irecv!`, `Waitall`, `Probe`, `Bcast!`, `Reduce`, `Allreduce` with `+`, `*`, `max`, `min`, ..., `Gather`, `Scatter!`, `Gatherv!`, `Allgather`, `Alltoall`, `Scan`, `Exscan`, `Barrier`), communicators (`Comm_split`, `Comm_dup`, which are freed by their finalizers, `Cart_create`), one-sided communication (`Win_create`, `Put!`, `Win_fence`), parallel files (`MPI.File`), `Wtime`, the status of a message, and MPI errors (an `MPI.MPIError` that can be caught) are compared with Julia's in `test/packages/mpi.jl`. 

What is different:
* `MPI.Init` does not register `MPI.Finalize` to be called when the program ends (the extension does not register it with `atexit`): 
  **call `MPI.Finalize()` at the end** (`finalize_atexit` is ignored).

* The handles of the constants (`MPI.COMM_WORLD`, `MPI.INT`, `MPI.SUM`, ...) are the numbers that the library has them as when compiling, 
  which are the same on each run for the MPICH family (MPICH, Intel MPI, the MPI ABI libraries); 
  they are addresses in Open MPI, which a compiled program can't use, and will error.

* `MPI.send` / `MPI.recv` (and `bcast`, `gather`) of a Julia object work for the types that the program has when compiling. 
  Types that are not `isbits` types need to be serialized and deserialized under the hood in MPI.jl, 
  so this is dependent on the Serialization stdlib (see [Serialization](@ref)).
  A deserialized value will be returned as a union of the types that are serialized, plus any that are manually added (`add_deserialize_types!`), which can then be then split, so write with a type annotation when possible (e.g.) `MPI.recv(comm; source = 0)::T`.

* Not supported: a reduction with an operator that is a Julia function of yours (`MPI.Allreduce(x, f, comm)`).

## Package survey

The survey that this section reports is kept as tests in [`test/packages`](https://github.com/brenhinkeller/StaticRuntime.jl/tree/main/test/packages) covering all the standard libraries and other packages mentioned above, 
as well as a broader range of packages from the ecosystem, including:

* **Distributions.jl**: 65 of 65 cases, from `pdf`, `cdf`, `quantile`, `mean`, `var`, `entropy` for the usual distributions 
  (`Normal`,  `Gamma`, `Beta`, `TDist`, `Poisson`,`Binomial`, `Categorical`, `MvNormal`, `Dirichlet`, `Multinomial`, truncated and mixture models, ...), to `rand` with a generator that is given (`rand(Xoshiro(1), Normal())`), `fit`, `loglikelihood` and `kldivergence`.
* **NaNStatistics.jl**: all the cases of the survey 
  (`nanmean`, `nanstd`, `nanmedian`, `nanquantile`, `nanpctile`, `nancov`, `nancor`, `movmean`, `histcounts`, `nanbinmean`, `nansort!`, ...)
* **StatsBase.jl**: 96 of 97 cases
  Weighted and unweighted `mean`, `var`, `std`, `median`, `quantile`, `skewness`, `kurtosis`, `mad`, `iqr`, `cor`, `cov`, `autocor`, `pacf`, `corspearman`, `corkendall`, ranks, `countmap`, `proportionmap`, `entropy`, `kldivergence`, `Histogram`, `ecdf`, `zscore` and `ZScoreTransform`, `sample` and `wsample` (with and without replacement, weighted) with a generator that is given, ... 
  One function that does not compile: 
  `summarystats` (it splats a `Vector` of a length that is not known into a constructor, `SummaryStats(m, sd, qs..., n)`).

* **DataStructures.jl**: 47 of 47 cases of the survey: 
  `Stack`, `Queue`, `Deque`, `CircularBuffer`, `CircularDeque`, `MutableLinkedList`, `list`; `BinaryHeap` (min, max, custom order, mutable), `PriorityQueue`; `DefaultDict`, `counter`, `OrderedDict`, `OrderedSet`, `RobinDict`, `SwissDict`, `MultiDict`, `SparseIntSet`; `SortedDict`, `SortedSet`, `SortedMultiDict` (with semitokens and ranges); `IntDisjointSet`, `DisjointSet`, `FenwickTree`; and the balanced trees `AVLTree`, `RBTree` and `SplayTree`, whose nodes keep `Union{Node,Nothing}` fields. The methods that DataStructures has deprecated still work (the warning is not in the program).

* **StaticArrays.jl**: 27 of 27 cases of the survey: 
  `SVector`, `MVector`, `SMatrix`, `MMatrix` and `SArray` (arithmetic, broadcasts, `map`, `push` and `pop`, `vcat` and `hcat`, `sort`, as `Dict` keys, in a `Vector`), `FieldVector` structs, the macros `@SVector` and `@SMatrix`, and `det`, `inv`, `\`, `eigvals`, `qr`, `svdvals`, `cholesky` and `lu` of small matrices.

* **OrderedCollections.jl**: 12 of 12 cases surveyed: 
  `OrderedDict` (insertion, deletion, order of iteration, `merge`, `sort`, `pop!`), `OrderedSet` and `LittleDict`. 
  One function that is not expected to compile: `freeze` (it makes a tuple that has as many elements as the dictionary has, which is not known until the program runs).

* **Graphs.jl**: 42 of 42 cases of the survey: 
  `SimpleGraph` and `SimpleDiGraph` (building, querying, subgraphs, the generators, `erdos_renyi` with a seed), `bfs_tree`, `dfs_tree`, `dijkstra`, `bellman_ford`, `floyd_warshall`, `a_star`, connected and strongly connected components, `topological_sort`, `kruskal_mst` and `prim_mst`, `maximal_cliques`, `greedy_color`, `label_propagation`, `pagerank`, `betweenness_centrality`,
  `closeness_centrality`, `eigenvector_centrality`, and the adjacency and Laplacian matrices.

* **Parsers.jl** (version 3): 40 of 40 cases of the survey: 
  `parse` and `tryparse` of integers of every width (with `base` and `groupmark`), `Float16`, `Float32` and `Float64` (with `decimal`, hexadecimal floats, `Inf` and `NaN`), `Bool` (with other spellings), `Date`, `DateTime` and `Time` (with a format), `UUID`, `BigInt` and `BigFloat`, from strings and from spans of bytes; and `parsenext` and the kernels (`parseint`, `parsefloat`) that a reader of files is made of, in a loop over the fields of a line. The results of the floats are the same to the last bit as Julia's.
