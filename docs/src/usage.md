# Input, output and writing overrides

## Input and output

The standard streams of Julia are libuv streams, which need the Julia runtime. Compiled programs
use those of libc, as [`StaticIO`](@ref)s: [`STDIN`](@ref), [`STDOUT`](@ref) and [`STDERR`](@ref).
`StaticIO` implements the `IO` interface, so all of the code of Base for printing and reading works
with it (`print`, `show`, `write`, `read`, `readline`, `eof`, `flush`, ...).

`print`, `println` and `show` without an `IO` write to the standard output, as in Julia:

```julia
function main(args::Vector{String})
    println("Hello, ", isempty(args) ? "world" : args[1], "! ", 1 + 1, " ", 2.5, " ", 'λ', " ", :sym)
    println(STDERR, "this goes to the standard error")
    line = readline(STDIN)
    @show line
end
```

!!! warning "`stdout`, `stderr` and `stdin` of Base can't be used: use `STDOUT`, `STDERR` and `STDIN`"
    In Julia, `stdout` is a global variable of the abstract type `IO`, so a call like
    `println(stdout, x)` can only be resolved when it is run, and a compiled program can't do that.
    It is rejected when compiling (see strict mode), with a message that says what to use instead. Code
    that uses `stdout` will work if it is written in a way that doesn't (`println(x)`, or `STDOUT`).

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

### The file system

`stat` (and `isfile`, `isdir`, `ispath`, `filesize`, `mtime`, `filemode`), `mkdir`, `rm` (with `force` and `recursive`), `readdir` (with `join` and `sort`), `mv`, `cp` (of a file or a directory), `pwd`, `cd`,
`realpath`, `homedir`, `tempdir`, `tempname`, `mktemp`, `mktempdir` (and with a function), `ENV[name] = value` and `delete!(ENV, name)`, and `Libc.getpid` are done with the functions of the C library. What is different: an
error is a `SystemError` with the message of `strerror`, where Base's is an `IOError` that has the code of libuv (a program that catches `IOError` for a missing file catches `SystemError` here), and `symlink`,
`chmod`, `touch`, `mmap` and starting other programs (`run`, ``read(`cmd`, String)``) are not supported. `Threads.@threads` runs the loop on the one thread, in order.

### Files

`open` opens a file with libc's `fopen`, as a [`StaticFile`](@ref), which is an `IO` like the standard streams,
so what Base has for reading and writing an `IO` works: `open(f, path, mode)`, `read(path, String)`,
`readlines`, `eachline`, `readline`, `write(path, x, y)`, `println(io, x)`, `eof`, `position`, `seek`,
`filesize`, `close`, `@printf(io, ...)`, `printf(io, c"...", x)`, and numbers and arrays of numbers as binary data
(`write(io, x)`, `read(io, Int32)`, `read!(io, array)`, `read(io, n)`). The mode is the one of `fopen` (`"r"`, `"w"`, `"a"`,
`"r+"`, ...). The keyword arguments of `open`, `readline` and `eachline` (`read = true`, `keep = true`)
are not supported; and so far there is nothing for the file system itself (`isfile`, `mkdir`, `rm`, `readdir`, ...).

### What works, and what doesn't

What works: numbers, strings, characters, symbols, `nothing`, `missing`, and anything built from
those by `string`, interpolation, `sprint`, `repr`, `@show`... and their `show` (with the quotes
and escapes), **arrays** (also nested, and of `Any`), **tuples**, **pairs**, **dictionaries**, **sets**, **types** and plain **structs**
(see [`show` of containers, types and structs](@ref)), Unicode text and its properties (`isletter`, `uppercase`,
`textwidth`, ...), formatting, and files.

What doesn't work yet:
* `show` of matrices, and of containers that are not arrays, tuples, pairs,
  dictionaries or sets. (Print the elements.)
* **`Dict{K,Any}` or `Dict{Any,Any}` built from pairs** (`Dict{String,Any}("a" => 1)`), and iterating a `Pair` of two
  different types (`for x in "a" => 1`): both are dynamic. Fill a `Dict{K,Any}()` with `d[k] = v`.
* **`===` of unions and of types**: `===` of two objects that are not the same one (so `Dict` and `Set` lookups)
  compares Strings, numbers, tuples and immutable structs (with Strings, Symbols, or other structs in them) by
  their contents, as in Julia. A struct with a field that is a `Union` of types stored inline
  (`Union{Int,Nothing}`), types, and `svec`s report and exit when run, instead.
* **`objectid` and `hash` of a value whose type is not known when compiling** (an element of a `Vector{Any}`, a field of
  an abstract type that is not a Union): they need the type when the program is run, and are rejected. Structs,
  tuples, Strings and the like are fine as keys of a `Dict` or `Set`, with the same `objectid` as Julia's.
* **`@printf` without an `io`**, which uses `stdout`: write `@printf(STDOUT, ...)`.
* The **file system** (`isfile`, `mkdir`, `readdir`, `rm`, ...). (`filesize(path)` works.) And memory-mapped
  files, sockets, processes.

The tables for the properties of characters are made when the package is compiled, with the Unicode
data of the Julia that compiles it, and so are the same as in Julia.

### `show` of containers, types and structs

Base's `show` for a container asks the `IOContext` of the stream what is known about the types of the
elements (an `ImmutableDict` of `Any`s), and writes type names by looking up modules and bindings: all
dynamic. Here the same output is made with what is known when compiling (`src/show.jl`, `src/context.jl`), and most of what Base does is Base's own code:

* the name of a type is a constant string made by Base's own `show` when compiling, so it is what Base prints;
* the **properties of the context** (`:typeinfo`, `:compact`, `:limit`, `:displaysize`, ...) are in the type of the stream (`ContextIO`), so that asking for one is a
  constant (see the next section);
* what Base's `typeinfo_prefix` does with the type of the elements is done when compiling, for the type of the container;
* an element of an abstract type (an element of a `Vector{Any}`, a field of a struct of type `Any`) is shown by
  a chain of `isa` over a closed set of types: the numbers, `String`, `Char`, `Symbol`, `Nothing`,
  `Missing`, `Vector{Any}`, and those you add with [`add_show_candidates!`](@ref). Showing a value of another
  type is an error *when the program runs* (the message says so).

```julia
struct Point; x::Int; y::Float64; end
add_show_candidates!(Point, Tuple{Int,Float64})   # before compiling

main() = (println(Any[1, "a", Point(2, 3.5), (4, 5.0)]); 0)
# Any[1, "a", Point(2, 3.5), (4, 5.0)]
```

Arrays of any number of dimensions are shown by Base's code (`println(A)`, `repr(A)`, `"$A"`): the overlays only take away what makes Base compile the code once for all
arrays, a matrix made a value of the type `Any` for the compiler (`inferencebarrier`), which would be a dynamic call. `Dict`s, `Set`s and vectors are Base's too; tuples, pairs and structs are written by
methods of this package (Base's reads the dictionary of an `IOContext` directly).

### `IOContext`, `text/plain` and `display`

`IOContext(io, :compact => true, :limit => true, ...)` of the streams of the program (`STDOUT`, `STDERR`, files, and what `sprint` writes to) has the properties in its *type*, so asking
for them (`get(io, :compact, false)`) is a constant when compiling, and what depends on it is decided then. So their **values have to be known when compiling** (a `Bool`, a number, a type, a tuple of
those): `IOContext(io, :compact => flag)` with a `flag` that is only known when the program runs cannot be resolved (compiling says so). `:SHOWN_SET` (the containers that contain
themselves, which are not detected) and `:module` are not kept. The properties then do what they do in Julia:

```julia
show(IOContext(STDOUT, :compact => true), 0.1 + 0.2)          # 0.3
show(IOContext(STDOUT, :limit => true), collect(1:30))        # [1, 2, 3, 4, 5, 6, 7, 8, 9, 10  …  21, 22, 23, 24, 25, 26, 27, 28, 29, 30]
```

`show(io, MIME"text/plain"(), x)` and `display(x)` (which writes the `text/plain` form to the standard output, as the `TextDisplay` of a Julia script does) write matrices aligned, with the
size and type above them, and vectors, ranges, dictionaries, sets and structured matrices (`Diagonal`, `Symmetric`, ...) as Julia does. Base lines up the numbers of a column by finding the
decimal point (or the sign of the imaginary part, or the `//`) with regular expressions, which a program does not have: the same is found by a scan of the text. With `:limit` and
`:displaysize` the output is cut as Julia cuts it (`display` does not set them, as on a terminal that is not one).

### Color

`printstyled` (with `color`, `bold`, `italic`, `underline`, `blink`, `reverse` and `hidden`, and a color that is a name or a number of 0 to 255) writes the escape sequences of Julia when the stream has
`:color => true` in its context, and plain text when it has not. A program is not told whether its output is a terminal, so it is as `julia script.jl > file`: `STDOUT` has no color, and
`Base.get_have_color()` (which Crayons, and so UnicodePlots, ask when the stream does not say) is `false`. A program that wants color asks for it: `printstyled(IOContext(STDOUT, :color => true), "text"; color = :red)`.

### StyledStrings

Styled strings (`styled"..."`, `AnnotatedString`, `AnnotatedChar`) are written to a stream with the escape sequences of Julia when its context has `:color => true`, and as plain text otherwise (loading
`StyledStrings` is what enables this, as for the other standard libraries that have a part of their own). The faces are the ones that there are when compiling (the theme, and what has been added with
`addface!`), as they are looked up by a comparison with each name; `withfaces`, `addface!` and the `faces.toml` of the user when the program runs are not supported. A terminal is taken to be one with
italics, reverse and strikethrough (the terminfo of the terminal is not read), 24-bit color is used when the environment says so (`COLORTERM=truecolor`, ...) and else the closest of the 256 colors, and the underline of a color
and style is a plain underline. Not supported: `show` of an `AnnotatedString` (`repr`), which shows annotations of the type `Any`.

### Observables

`Observable`s (the package Makie is built on) work with `on`, `map`, `map!` and `onany`, as the package that has them is loaded (`Observables`: an extension of this package). A listener is
called with a direct call, as the package does it with `invokelatest`, which a program has no use for. Not supported: a connection that is `weak` is not removed when it is collected, and what
shows a listener (`show` of an `Observable` with its listeners, which asks where the function is defined). The listeners of an `Observable` are kept as functions of the type `Any`: when the
code compiles, the functions that were given to `on` (and `map`, `onany`) for an `Observable` of a type of value are the ones that are called when an `Observable` of that type is set, and
no others. So a listener has to compile for the type of the value of the `Observable` that it is given to (as it does in Julia), and an `Observable` that has no listener has no call. A function
is found where it is given, so it is not found if the listeners are made by something that compiled code does not go through (`register_callback` is what they all go through).

An `Observable` that is made before the program is compiled (and is a constant of it, or is reached from one, as the observables of a scene are) has listeners that the code of the program did not give to `on`: they are
found when the program is compiled, in its constants, and nothing is changed in them. The code that sets or notifies such an `Observable` is compiled for it, with its listeners as constants, so that what one of them stores
in another `Observable` is known of that one (a pair of the values of two, in a third). A listener of one is called as it is called in Julia, but for those that use the mouse and the keyboard (which have a module in
them), which a program has no events for.

### Makie

A `Makie.Scene` that is made before the program is compiled, and is a constant of it (`const scene = Scene(...)`), can be read and changed by the program: its size, the viewport (`scene.viewport[] = Rect2i(...)`), and the inputs of its compute graph
(`ComputePipeline.update!(scene.compute, viewport = ...)`, or `scene.compute.viewport = ...`), whose changes reach the nodes and the observables of the graph, as the camera. Call `StaticRuntime.prepare!(scene)` once, after the scene is made
and before compiling: the typed edges get the names of their outputs, what the graph does when its outputs change is made again with the types of its observables, the functions of the inputs get the references of their nodes, a node
that Makie keeps in a `RefValue{Any}` of a few types of value (`shading`) gets one of the union of them (the listeners of its observables are found when compiling, see [Observables](@ref)). The nodes of a graph are resolved when it is prepared: a node that
a program resolves for the first time is an error. The observables that the program uses have to be asked for before (`get_observable!(graph, name)`, or `on(f, graph[name])`). Only the latest release of Makie is supported (0.24).

The nodes of a plot in a `Figure` (`plot.attributes`, a graph of its own, which is connected with those of its scene and of the other plots) are read and set through `StaticRuntime.typed_node(graph, key)` and
`StaticRuntime.typed_input(graph, key)`, made before compiling and kept as constants, after `prepare!` was called on every scene and on the graph of every plot (`prepare!(plot.attributes)`):

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

A read of `graph[key][]` resolves what the node comes from with the types of all the nodes of all the graphs of the figure (the functions of the inputs, the edges, the references of the values: a few hundred types of each), which is
too large a program; a typed node has what it comes from as a list of steps of their own types (each edge and input that it depends on, in order). A typed input has the graphs that its changes reach, and their listeners.
The values have the types that they had when they were made: a value of another type (an input that was a `Vector{Float64}` set to a `Vector{Int}`) stops the program with a message. Changing the axis or the layout
when the program runs (a resize, the limits of an axis) is not yet supported. `typed_node(graph, key; inputs = (YS,))` resolves only what depends on the inputs that are given (the rest is fixed: a change of it stops the program
with a message that names it), which is a smaller program.

With CairoMakie loaded, a scene or a figure is drawn to a PNG by the program with `StaticRuntime.typed_drawing`, made before compiling and kept as a constant:

```julia
using CairoMakie
const fig = Figure(size = (300, 200))
lines!(Axis(fig[1, 1]), 1:10, Float64.(1:10) .^ 2)
const DRAWING = StaticRuntime.typed_drawing(fig) # (it prepares the graphs itself)
main(argv) = (DRAWING("plot.png"); 0)            # (or `DRAWING(screen)`, on a `CairoMakie.Screen` of the scene)
```

The scene is drawn once when the drawing is made (which adds to the graphs of the plots what drawing them needs), and a figure is made ready as saving it does (the limits of its axes). Each plot is then a step with its own types,
in the order that CairoMakie draws them. The image is what CairoMakie draws (the PNG is RGB, where `save` writes RGBA). The fonts of the text are in the program (FreeType reads them from the bytes that the figure has).
`inputs` are the `typed_input`s that the program changes before drawing; what else changes is not drawn (it stops the program, as for `typed_node`), and plots that are added afterwards are not. Lines, line segments,
scatter, text and polygons are supported; images, heatmaps and shown meshes are not yet.

Limits: containers that contain themselves are not detected (they recurse until the program crashes); the keyword `context` of `sprint` with a pair that is written in the call
(`sprint(show, v; context = :compact => true)`) works for what is not an array, and is not yet supported for the show of an array (give `IOContext` the stream instead, or a context that is
a stream); `text/plain` of a `UniformScaling` (`2I`) is not supported (it uses a regular expression); a
`Symbol` that the program makes and that is not a plain ASCII identifier is written as Base writes it only if that is clear without the parser's tables
(`Symbol("a b")`, `Symbol("1a")`, `Symbol("")`), and else it is an error (the symbols that were there when compiling, such as `:+` or `:α`, are written as Julia writes them: see
[Symbols](@ref)); and the names of types of modules that are loaded after this package (`using` in the program) are written with their module (Base writes
`Main`'s view of them).

## Symbols

Julia keeps every symbol in one table, so that there is one object for each name and `===` of symbols compares addresses. A program has no such table, so:

* The symbols that the program has when it is compiled are copied into it, as any constant is, so `Dict`s and `Set`s of symbols that are `const` work (a symbol
  hashes by a number that is in it, which the copy has too), and so does `string(sym)`, `print`, `sort`, `startswith(string(sym), ...)`, and the like.
* `Symbol("abc")`, `Symbol("x", 1)`, `Symbol(uppercase(string(s)))` and `Symbol(::Vector{UInt8})` of a name that the program makes work too. The binary has a list of
  its symbols, sorted by name, that is looked in first, so `Symbol("abc") === :abc` and a `Dict` that was made when compiling finds a key that the program made; a name
  that is not in it is made into a new symbol, kept in a tree (the same as the table of Julia is: by hash and name). These symbols are never freed (40 bytes and the name
  for each different name), and their names can't have a NUL in them.
* `show` of a symbol writes `:name` for a name that is a plain ASCII identifier. For other symbols, Julia decides with tables of its parser (`:+`, `:(==)`, `:α`, `Symbol("a b")`):
  for those that the binary has, it writes what Julia writes (the text is made when linking); for those that the program makes, only the names that are certainly not
  identifiers or operators (empty, with a space or a control character or a quote, or starting with a digit) are written, as `Symbol("...")`; any other is an error.
* Types as keys: `==` of types, `hash` of a `DataType`, and so `Dict{DataType,...}` and `Set{DataType}`, work (a type hashes by the number that it has in it). `==` of types
  that are not both concrete (a `Union`, an abstract type with parameters) goes by `<:` (see [Dynamic dispatch on abstract types and on `Any`](@ref)).
* `getfield(x, name)`, `x.name`, and for a `NamedTuple` `nt[name]` and `get(nt, name, default)`, of a struct with a `Symbol` that is only known when the program runs work: the result has the union of the types of the fields (a table of functions that is indexed by the name of the one that a keyword asks for), which is split where it is used. Not supported: such a name for the fields of a type object.

## Entry points

An executable is made of a function, in one of three forms:

| form                                    | `compile_executable(f, ...)`  | the arguments of the command line | exit status                                            | file, `small = true` |
|:----------------------------------------|:------------------------------|:----------------------------------|:-------------------------------------------------------|---------------------:|
| `main(args::Vector{String})`            | `(Vector{String},)`           | `args` (and `ARGS`)               | the integer that it returns, 0 for anything else       | 34.4 kB              |
| `main()`                                | `()`, or no types             | none (`ARGS` is empty)            | the integer that it returns, 0 for anything else       | 33.6 kB              |
| `main(argc::Int, argv::Ptr{Ptr{UInt8}})` | `(Int, Ptr{Ptr{UInt8}})`      | as C has them                     | the integer that it returns: **not defined** for anything else | 33.6 kB      |

`main(args)` is the form to use for a program that is written like a Julia script: it has the arguments as `ARGS` has them, and the status of the program is what it returns if that is an
integer (a function that ends with `println` returns `nothing`, and exits with 0). `main()` is the same for a program that takes no arguments. The third form is C's: it compiles `f(argc, argv)` to the
`main` of a C program, with no code of ours between the two, which is as small as a program can be (the others add a kilobyte or less), and what the examples of the sizes and speeds below use. Its
status is the return value as C has it, so the function has to return an `Int` (or an `Int32`): for `nothing` it is whatever the machine had in the register, and the compiler warns of it.
See [`compile_executable`](@ref).

```julia
main(args) = (println("got ", length(args), " arguments"); length(args))
compile_executable(main, (Vector{String},))    # `./main a b c` prints "got 3 arguments" and exits with 3

hello() = println("hello")
compile_executable(hello)                      # `./hello` prints "hello" and exits with 0
```

## Writing overrides

`@device_override` adds a method to the method table of this package (see below), which replaces
the method of Base for the code that is compiled. One thing to know: **an override is used for every
call that it covers entirely, instead of all of the methods of Base, including those that are more
specific than it.** So an override `print(x1, x2) = print(STDOUT, x1, x2)` would also be used for
`print(io, x)`, which must go to the methods of Base for printing to an `IO`: `print(io, 'c')`,
`print(io, "string")`... Overrides therefore need to be written so that they don't cover calls that
they should not: with the same signature as the method that they replace, with restricted argument
types, or by doing for those calls what the method of Base does (see `src/io.jl`).

### Fields that are made again when the program runs

A field of a pointer of a constant (the face of FreeType of a font, a surface of a library) is an address of the process that compiled the program, and is null in the program. A package's extension says how the
program makes it again with a method of `StaticRuntime.remade_by`, which gives a function of the object:

```julia
StaticRuntime.remade_by(::Type{FTFont}, ::Val{:ft_ptr}) = font -> open_face(font)   # (from what the font has)
```

A read of the field (`getfield(font, :ft_ptr)`, wherever the package's code makes it) then makes it, and stores it, the first time that the program finds it null; the warning that the field is null in the program is
not given for it. Only fields of a `Ptr` type. (The extension for Makie does this for the fonts of a figure.)

### Stating a type instead of copying code

Many overrides of code from a package are a copy of a function with a type put in it, because the compiler finds a wide type (a `Union`, `Any`) where the code knows what it is. A copy drifts when the package changes. `@assume` states the
type, and the code of the package stays as it is:

```julia
function __init__()
    StaticRuntime.@assume Makie.theme(::Nothing, ::Symbol)::Attributes   # the call gives an `Attributes`
    StaticRuntime.@assume_field Observable.listeners::Vector{Pair{Int,Any}}  # the field holds this
end
```

* **The type of a call**: `@assume f(::A, ::B)::R` says that the methods that the arguments `A` and `B` (or subtypes) fit give a `R`. Those methods are inferred as they are, with what they give narrowed to `R` (the intersection of the
  two types), and every `return` of them is a `typeassert` to `R`: callers have a type that is right, and a program in which the method gives another type stops with a type error that says so, and does not go on as if it had the type.
  A function with keyword arguments is stated by its method without them, and a constructor `T(...)` by `Type{T}`.
* **The type of a field**: `@assume_field S.name::T` says that a field of the type `Any` (or another that is not concrete) of the struct `S` holds a `T` where it is read, and the read is a `typeassert`.
* Both are given where the module is initialized (`__init__`), as `add_dispatch_candidates!` is: they are kept for the session, and not by what is precompiled. A package extension is the place. What is stated is a number in the key of
  what is inferred, so a change of it is a new inference.
