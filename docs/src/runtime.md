# The Runtime: memory, exceptions, and types

## Memory and the garbage collector

Compiled programs have a garbage collector, so memory that the program is not using any more is freed, as in Julia. The `gc` option of `compile_executable` (and the other entry points) says
whether a program has it:

* `gc = :auto` (the default, on macOS and Linux): the collector is in the program if the program needs it, and not if everything that it allocates is allocated a finite number of times (see
  [Binary size](@ref) for what is counted). A program without it never frees anything, which is the simplest and fastest, and costs nothing as the program does not allocate for as long as it runs.
* `gc = true`: the collector is always in the program.
* `gc = false`: it never is, and **nothing is ever freed**, even if the program allocates for as long as it runs. This may suit a program that runs very briefly, but can easily use an unreasonable amount of memory if your code is not written with this in mind.

```julia
compile_executable(main, (Vector{String},), "build", "program")   # with the collector, if needed
compile_executable(main, (Vector{String},), "build", "program"; gc = true)  # with the collector
compile_executable(main, (Vector{String},), "build", "program"; gc = false) # without the collector
```

The collector and the allocator it works with (`src/runtime/heap.jl`) are written in Julia, and compiled with StaticCompiler into every
program that allocates. How it works:

* **Conservative and non-moving.** It doesn't need to know the types of what is in memory. Every word of the stack (and the
  registers), of the data that the program has copied from the compiler (a `const` container that is changed to refer to new
  objects, for instance), and of the objects that it reaches, that is the address of an object, or of anything inside it (or just
  after the end of it, which is what a loop that has gone past the end of an array holds), keeps that object. A number that looks
  like an address may keep an object that is not used, but can't make anything unsafe, and the objects don't move, so the addresses
  that the code holds stay right.
* **It knows what can't refer to anything.** Strings, arrays of numbers, boxed numbers and the like, which the compiler can tell
  from their type, are not looked inside, so a large array of numbers costs nothing to collect.
* **Small objects** are in blocks of 64 kB of one size class (23 of them, up to 2 kB), with a bitmap for the cells in use and
  one for those reached; **large objects** have memory of their own. An allocation is a few instructions. Nothing is zeroed
  twice: memory from the system is zero, and a cell is zeroed when it is reused.
* **When:** a collection is made when as much has been allocated since the last as is alive after it (and at least 8 MB), so
  the heap is at most about twice what the program uses, and a program that allocates less than 8 MB never collects.

In a loop that makes two small objects each time, 10 million times, the collector keeps the program at 9 MB, from 764 MB
without it, and it is faster as well (0.05 s, from 0.22 s), as the memory that is used again is in the cache.

`GC.gc()` collects, and `GC.enable(false)` stops collections until `GC.enable(true)`. In a compiled program, `gc_heap_bytes()`,
`gc_live_bytes()` and `gc_collections()` say how much memory the heap has from the system, how much was in use after the last
collection, and how many collections there have been.

!!! warning "What the collector can't see"
    A reference that is not in the stack, the registers, or an object of the heap, or in the data that the compiler copied, is not
    looked at, and what it refers to is freed if nothing else refers to it. That is the case for memory that the program gets by
    itself: a `MallocArray` or `malloc` that holds the address of an object (they are for plain data, and don't normally), and a
    `Ptr` that is hidden (made from a number that is changed). `pointer(x)` of an array or string is fine for as long as `x` is
    alive, as in Julia (use `GC.@preserve` when `x` is not used after it), and an address of an object that is kept in the stack,
    in a register, or in memory of the heap, is seen.

!!! warning "One thread"
    The heap is not thread-safe: a compiled program, or a library made with `compile_shlib`, must allocate from one thread at a
    time (a library that is called from several needs a lock around its calls: `gc = false` does not help; the non-freeing allocator 
    is not thread-safe either). The collector looks at the stack of the thread that calls it, from the base of that stack (on Linux, 
    that of the main thread). If the library is called on a stack that is not that, for instance from a task of Julia running on another
    thread, it does not know where the references are, so it **frees nothing** in that call (the memory grows until the program
    is called from a thread that it can collect from). 

### Without the collector (`gc = false`)

Everything that Julia would heap-allocate and later collect is never freed. What allocates:

* every array (`zeros(n)`, `collect(...)`, `[x for ...]`, a broadcast `a .+ b`), every `Dict`/`Set`, every `String` built at run
  time (`string(i)`, `"a" * "b"`, `repr`, ...), every escaping closure or mutable struct, every boxed value, and every thrown exception;
* and a container that grows (`push!` onto a `Vector` that is full) leaves its old storage: about twice the final size, and a
  container that is rebuilt in a loop leaves that each time.

What does not: anything the compiler can keep on the stack or remove, for instance a small `Ref` or tuple that does not escape, or
an array that is only used locally and that Julia's optimizer can eliminate. Isbits structs and `StackArray`s are always on the
stack. [`allocation_sites`](@ref) counts the places in the compiled code of a function that allocate (an upper bound, as an
allocation in a branch that is never taken, such as the construction of an exception, is counted too):

```julia
julia> allocation_sites(i -> sum(abs2, 1:i), (Int,))
0

julia> allocation_sites(i -> sum(collect(1:i)), (Int,))
2
```

To avoid leaking memory to repeated allocations in a program without the collector: allocate once, outside the loop, and reuse the memory (`resize!`, `fill!`, in-place `.=` and `mul!`, `empty!`); prefer `StackArray`s from StaticTools for small, fixed-size data; use `MallocArray`/`MallocString` and `free`, or `@no_escape`/`@alloc` from Bumper.jl, for memory with a clear lifetime; and write with `printf` or `print` instead of building strings in loops.

### Testing the collector

The collector is tested on the host against an oracle (random graphs of objects, of which what is reached is known), and by compiling programs with it. `gc = N` (a number) is a mode for finding mistakes: in this case, the collector is always included in the binary, and  runs every `N` allocations, immediately overwriting what it frees. All of the tests can be run in this manner with the environment variable `STATIC_RUNTIME_GC` (`auto`, `false`, `true`, or a number), which sets the default of `gc`.

## Exceptions

Standard `try`/`catch`/`finally` and `rethrow` should work, as long as the exception was thrown by code in the same program.  These are implemented with `setjmp`/`longjmp`, a fixed-depth stack of handlers (256 nested `try` blocks at once) and a stack of the exceptions that are being handled (256 as well).

`catch e` gives the exception object, and `e isa T` works with concrete types, and with abstract ones for constants (objects have type tags, and the types that the code mentions are in the binary; see [Type tags](@ref)). 

The following cases stop the program with a message on the **standard error** (what the program has written to the standard output is flushed first, and the standard output has nothing else) and exit status 1:

* An exception that no `try` catches: `ERROR: ` and the type of the exception, and its message if the first field of it is a string (`ArgumentError`, `ErrorException`, `AssertionError`, and exceptions of your own types, `struct MyError <: Exception; msg::String; end`), as in `ERROR: ArgumentError: invalid base 10 digit 'a' in "abc"`. Other exceptions say their type only (`ERROR: BoundsError`), and a thrown string is the string; the details that Julia gives (the array and the index of a `BoundsError`) and the backtrace are not given.
* More than 256 nested `try` blocks: `fatal: exception handler stack overflow`.
* `rethrow()` outside a `catch`: `fatal: rethrow() outside catch`.
* A call that no method fits (`nothing + 1`; a constructor given arguments that none takes) says which function or type it was. A type assertion that fails says the type that was wanted and where it is (`TypeError: in typeassert, expected String (in f, at file.jl:12 in `f`)`), and `BoundsError`s and `UndefVarError`s of the runtime say where they are.

Code that needs dynamic dispatch, or other things from the Julia runtime, is not an exception matter: it is rejected when compiling, by default (see [Code that needs the Julia runtime is rejected](@ref)). With `strict = false`, it compiles and aborts with `Dynamic behavior is not supported in standalone binaries (...)` if the call is reached.

## Type tags

Every object that a compiled program allocates has a type tag in its header, as in Julia: a small number for the built-in types and the address of the type object otherwise. `isa` with a concrete type, the type of a caught exception, and `show` of an `Any` element read this tag. The objects that the code refers to as constants (strings, tuples, types, ...) are copied into the binary with their tags, and so are the type objects that the tags and `isa` with abstract types read (names, parameters). Details may be found in `src/llvm/tags.jl` and `src/runtime/embedder.jl`.

`x isa Number` for an `x` that is only known when the program runs is `ijl_subtype(typeof(x), Number)` in libjulia, whose subtyping algorithm is not in the binary. The types that it is asked about are constants of the code, and the types that an object can have are those in the binary, so the answers are worked out when compiling, with Julia's own `<:`, and written out as the function `ijl_subtype`: a table of which types in the binary are subtypes of each type that is asked about. When the type is not a constant of the code (`isa(x, types[i])`, `a <: b` of two elements of a `Vector{DataType}`, `eltype(c) <: C`), the table has an answer for each pair of the types that are in the binary (a bit each, found by searching for the two types), and `jl_f_issubtype` and `jl_f_isa`, the builtins that these calls are, look in it. So `<:` and `isa` work for any types that are in the binary: the types of its objects, the types that it names, and the types that those refer to. A type that the program makes up (`Vector{T}` for a `T` that is computed, anything with a `TypeVar`) is not in the binary, and the program exits with a message if it is asked about; `a <: b` of types that a function builds this way is rejected when compiling. The table has a row and a column for each type in the binary, so it grows with the square of their number (about 125 kB for a thousand types), and is only there if the code asks about types that are not constants.

## Fields that are made again when the program runs

A field of a pointer of a constant (the face of FreeType of a font, a surface of a library) is an address of the process that compiled the program, and is null in the program. 
A package's extension says how the program makes it again with a method of `StaticRuntime.remade_by`, which gives a function of the object:

```julia
StaticRuntime.remade_by(::Type{FTFont}, ::Val{:ft_ptr}) = font -> open_face(font)   # (from what the font has)
```

A read of the field (`getfield(font, :ft_ptr)`, wherever the package's code makes it) then makes it, and stores it, the first time that the program finds it null; the warning that the field is null in the program is not given for it. Only fields of a `Ptr` type. (The extension for Makie does this for the fonts of a figure.)