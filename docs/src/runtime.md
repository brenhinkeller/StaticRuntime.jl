# The runtime: memory, exceptions, tags and size

## Memory and the garbage collector

Compiled programs have a garbage collector, so memory that the program is not using any more is freed, as in Julia. The `gc` option of `compile_executable` (and the other entry points) says
whether a program has it:

* `gc = :auto` (the default, on macOS and Linux): the collector is in the program if the program needs it, and not if everything that it allocates is allocated a finite number of times (see
  [Binary size](@ref) for what is counted). A program without it never frees anything, which is the simplest and fastest, and costs nothing as the program does not allocate for as long as it runs.
* `gc = true`: the collector is always in the program.
* `gc = false`: it never is, and **nothing is ever freed**, even if the program allocates for as long as it runs. (This suits a program that runs briefly, which the analysis can't see.)

```julia
exe = compile_executable(main, (Vector{String},), "build", "program")                # with the collector, if it needs it
exe = compile_executable(main, (Vector{String},), "build", "program"; gc = true)    # always with it
exe = compile_executable(main, (Vector{String},), "build", "program"; gc = false)   # never with it
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
    time (a library that is called from several needs a lock around its calls: `gc = false` does not help, that allocator is not
    thread-safe either). The collector looks at the stack of the thread that calls it, from the base of that stack (on Linux, that
    of the main thread). If the library is called on a stack that is not that, for instance from a task of Julia running on another
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

To avoid the growth in a program without the collector: allocate once, outside the loop, and reuse the memory (`resize!`, `fill!`,
in-place `.=` and `mul!`, `empty!`); prefer `StackArray`s from StaticTools for small, fixed-size data; use `MallocArray`/`MallocString`
and `free`, or `@no_escape`/`@alloc` from Bumper.jl, for memory with a clear lifetime; and write with `printf` or `print` instead
of building strings in loops.

### Testing the collector

The collector is tested on the host against an oracle (random graphs of objects, of which what is reached is known), and by
compiling programs with it. `gc = N` (a number) is a mode for finding mistakes: the collector is always in the program, and also runs every `N` allocations,
and what it frees is overwritten, so that a use of memory that was freed is seen at once. All of the tests can be run so with
the environment variable `STATIC_RUNTIME_GC` (`auto`, `false`, `true`, or a number), which sets the default of `gc`.

## Exceptions

`try`/`catch`/`finally` and `rethrow` work, as long as the exception was thrown by code in the
same program. They are implemented with `setjmp`/`longjmp` and a fixed-depth handler stack (256
nested `try` blocks).

An exception that no `try` catches prints `fatal: uncaught exception (no handler to catch it)`
and exits with status 1. The message does not say which exception it was.

Limitations, which are bugs rather than design choices:

* `catch e; e isa T` works with concrete types, and with abstract ones for constants (objects have type
  tags, and the types that the code mentions are in the binary; see [Type tags](@ref)). `isa` with an abstract type
  or a `Union` works on boxed values too; the answers come from a table that is made when compiling (see [Type tags](@ref)).
* Code that needs dynamic dispatch, or other things from the Julia runtime, is rejected when
  compiling, by default (see [Code that needs the Julia runtime is rejected](@ref)). With `strict = false`, it compiles and aborts with
  `Dynamic behavior is not supported in standalone binaries (...)` if the call is reached.

## Type tags

Every object that a compiled program allocates has a type tag in its header, as in Julia: a small number for
the built-in types and the address of the type object otherwise. `isa` with a concrete type, the type of a caught
exception, and `show` of an `Any` element read this tag. The objects that the code refers to as constants
(strings, tuples, types, ...) are copied into the binary with their tags, and so are the type objects that
the tags and `isa` with abstract types read (names, parameters). Details are in `src/llvm/tags.jl` and `src/runtime/embedder.jl`.

`x isa Number` for an `x` that is only known when the program runs is `ijl_subtype(typeof(x), Number)` in libjulia, whose
subtyping algorithm is not in the binary. The types that it is asked about are constants of the code, and the types
that an object can have are those in the binary, so the answers are worked out when compiling, with Julia's own `<:`, and
written out as the function `ijl_subtype`: a table of which types in the binary are subtypes of each type that is asked
about. When the type is not a constant of the code (`isa(x, types[i])`, `a <: b` of two elements of a `Vector{DataType}`, `eltype(c) <: C`), the table
has an answer for each pair of the types that are in the binary (a bit each, found by searching for the two types), and `jl_f_issubtype` and `jl_f_isa`, the
builtins that these calls are, look in it. So `<:` and `isa` work for any types that are in the binary: the types of its objects, the types that it names, and the
types that those refer to. A type that the program makes up (`Vector{T}` for a `T` that is computed, anything with a `TypeVar`) is not in the binary, and the program exits with a
message if it is asked about; `a <: b` of types that a function builds this way is rejected when compiling. The table has a row and a column for each type in the binary, so it
grows with the square of their number (about 125 kB for a thousand types), and is only there if the code asks about types that are not constants.

## Binary size

A program has the code it uses, and the Julia objects that it refers to, copied into the binary (strings, constant
arrays and `Dict`s, and the type objects that the type tags and `isa` read). What is not used is not there. Measured on macOS (arm64,
Julia 1.14.0-alpha2): the bytes of the sections of the executable that are in the file (code, constants and data; `size -m`), and the file, which is made of pages of 16 kB
and has the table of the symbols of the entry point. The last column is with `small = true` (see below), which changes the file and not the sections (the sections differ by a few bytes at most). The collector is left out of a program that does not need it (`gc = :auto`), and the code that only runs to stop with an error is optimized for size:

| program                                            | sections | file    | file, `small` |
|:---------------------------------------------------|---------:|--------:|--------------:|
| `main(argc, argv)`: `println("hello")`             |   2.1 kB |   51 kB |     34 kB |
| `main(argc, argv)`: `println(fib(30))`             |   7.6 kB |   53 kB |     34 kB |
| `main(args)`: `println("hello")`                   |    11 kB |   55 kB |     34 kB |
| `main(args)`: `println(length(args) + 42)`         |    15 kB |   57 kB |     35 kB |
| a `Dict` of strings, a lookup                      |    36 kB |   77 kB |     52 kB |
| `parse(Int, ...)` in a `try`, the message printed  |    54 kB |   99 kB |     69 kB |
| `sqrt` and `println` of a `Float64`                |    57 kB |   92 kB |     84 kB |
| `sort(rand(100))`                                  |    69 kB |  129 kB |    101 kB |
| a sieve of Eratosthenes (the README example)       |   101 kB |  135 kB |    118 kB |
| a `Dict` of tuples, a matrix product, `display`    |   134 kB |  171 kB |    151 kB |

What a program has, and when:

* **The collector** (20 kB of code and 8 kB of data) is there if the program needs it (`gc = :auto`, the default; `gc = true` always has it, `gc = false` never does): if something that it allocates is allocated again and
  again (see below). A program that allocates only where it is about to stop (the message and the exception of an error that nothing catches, or that a `try` only runs the `finally` of; a loop that builds the message
  is part of that, if it is in the error and not in the program) never frees anything, and has the allocator that doesn't collect: that is what `main(argc, argv)` with `println` is. The vector of the arguments of
  `main(args)` is not counted: it is as large as the command line, which the program does not decide.
* **The support for finalizers** (5 kB) is there if the program registers a finalizer (`BigInt`, the wrappers of libraries, `finalizer(f, x)`).
* **The tables of the characters** are one for each question that is asked: `isspace` of a character that is not ASCII is a table of a few bytes; `show` of a string (the printable characters) 12 kB; `isletter`
  and the like 33 kB.
* **The collector looks at** only the objects that can refer to objects of the heap: not strings, symbols, arrays of numbers, or types.
* **The code that runs only to stop with an error** (the exceptions that are made and thrown, their messages, and what shows them) is optimized for size, as `-Oz` does: it is about 10% of the code of a program that
  prints, parses or sorts, and nothing waits for it. The same for all of the program would be 18 to 23% smaller, and 12 to 34% slower.

**No collector if the program allocates a finite amount of memory in all** (`gc = :auto`, the default, for an executable: a library can be called any number of times, so there only what is allocated to stop with an error is not counted):
nothing that it allocates is in a loop, or in a function that is called from a loop or that calls itself (or that something refers to without
calling it: a callback of a library). The memory that it has is then what it allocates, and not what it would allocate for as long as it runs. A `try` that catches, and goes on, counts if it is not in a loop either. A `sort`, a `Dict` that grows,
or a `split` have loops that allocate, and keep the collector; so does anything that allocates in a loop, or in a function that is called from one.
(The arguments of the command line are made by a loop, which is as long as they are: that is not counted.) The analysis is of the code, and not of the sizes: a program that allocates a gigabyte once has no collector, and
the gigabyte.

**`small = true`** (for `compile_executable`; `compile_shlib` takes the flags only) makes a smaller file where that makes no difference to what the program does:

* The linker leaves out the **names of the functions** of the program, but its entry point (on macOS, `-x`: 5 to 25 kB; on Linux `-s`, not tried yet), and, on macOS, the segment for the **constants and the table of the addresses
  of functions** that is made read-only when the program starts (`-no_data_const`: a page of 16 kB, of which a small program uses a few hundred bytes; it is also a protection that the program then does not have).
  Passing your own `cflags` replaces these.

What is in the data of a program that prints a number is mostly two things: about 4.5 kB of objects, the type of `Int64`
that the error for a conversion that fails (an `InexactError`) holds, with the name of it; and 5 kB that is zero at the start (the stack of
the exception handlers and the task that the runtime stands in for, which are not in the file). A program without any code that can throw
(`main(argc, argv)` with `println("hello")`) has neither. The objects that are types are copied for what a program does with them: telling the type of an
object from another (the tag), its name (`nameof`) and its parameters. Not for what a type refers to: its supertypes, the wrapper
and the names of the fields. A program does not have these (a call that would need them is dynamic anyway), and with them
the objects of a small program were more than twice as many. Showing a string needs a table of the characters that can be printed,
which is about 12 kB (and not that of the categories of all characters, which is 33 kB).
`%f` of a `Float64` in `@printf` needs the tables of Ryu for the fixed format, which are 190 kB: `%g`, `%e` and `show` have much smaller ones.
What the program does not use is not there: the plans for `===` of the types, which are about 14% of the objects of a
program that compares objects, are made only if the code calls `jl_egal__unboxed`; and the table of the types of the small
tags is made only if the code indexes it with something that is not a constant (`isa` on a boxed value does), and
otherwise each of the types that the code names is the one object. The `isa` table (`ijl_subtype`) is as large as the
number of types asked about times the number of types in the binary that are subtypes of them.
`println(Any[...])` is larger because it has the code to show each of the types in the registered ones: add only the types
that you need with [`add_dispatch_candidates!`](@ref) (the defaults can't be removed yet).

## Compared with C and C++

The same programs in C and C++ (Apple clang 14, `-O2`) and in Julia compiled by this package (macOS, Apple M1 Max; the time of the best of 5 runs, in seconds; the answers are the same). The Julia of the loops has `@inbounds` as the C has no checks, and the
data are laid out as in C. (The C is compiled with clang's default, which fuses a multiplication and an addition into one instruction: Julia does that only where `muladd` or `fma` is written. Without it, the C of Mandelbrot takes 0.39 s and that of n-body 0.25 s.)

| program                          | C       | C++     | here    | here, `small` (file) |
|:---------------------------------|--------:|--------:|--------:|---------------------:|
| recursive `fib(38)`              | 0.12    |         | 0.15    | 34 kB (C: 33 kB)     |
| sieve of Eratosthenes (50M)      | 0.099   |         | 0.106   | 34 kB                |
| matrix product (500, loops)      | 0.021   |         | 0.022   | 34 kB                |
| Mandelbrot (1500)                | 0.33    |         | 0.38    | 34 kB                |
| n-body (5M steps, array of structs) | 0.19 |         | 0.21    | 34 kB                |
| Collatz (3M)                     | 0.43    |         | 0.43    | 34 kB                |
| `sin`, `exp`, `log`, `atan`, `sqrt` (20M) | 0.22 |      | 0.23    | 34 kB                |
| binary trees (allocation, depth 18) | 1.67 |         | 1.21    | 51 kB                |
| string building and parsing (2M) |         | 0.124   | 0.21    | 86 kB                |
| sort of 3M integers              | 0.28 (`qsort`) | 0.18 (`std::sort`) | 0.024 | 102 kB |
| hash table of 2M keys            |         | 0.64    | 0.091   | 86 kB                |

(The files are of programs made with `small = true`. The first eight have `main(argc, argv)` and `atol` as in C; the others have `main(args)` and `parse`. Programs that allocate a finite amount of memory have no collector, which is why the loops are 34 kB.)

For arithmetic that is made of loops the programs are within about 15% of C, and equal to it where the C has no fused multiply-add. What is faster than C or C++ is the library (`sort!` of integers is a counting sort for a small range, and `Dict` is a flat table where `unordered_map` has a node for each key; the allocator
and collector of the binary tree program). The things that are slower: recursion (`fib`, 25% behind; plain Julia is the same: it is LLVM's code for it), some functions of the math library (Julia's own `log`, `tan` and `^` take 1.1 to 1.3 times what those of the C library do on this machine; `sin`, `cos` and `atan` are as fast or faster. On Apple Silicon the code generator is told not to build constants from integer instructions (`fuse-literals`), which made them 1.3 to 1.5 times slower), and string building, where `string` of
several pieces and `parse` of a `SubString` take 1.7 times what C++'s `std::string` and `strtol` do.
With `optimize = true` the program is optimized once more after it is linked (`O2` on the whole program): `fib` takes 0.105 s (faster than C), the binary trees 1.16 s and the strings 0.19 s. It is not the default: it can add up the
elements of a reduction in `@simd` (and of a `Float16` sum) in another order than Julia does, and so give a result that differs from Julia's in the last digits, and it has failed tests on CI that the default passes.
A program that allocates and keeps memory in lists and hash tables has more of it than C does (the hash table program is 135 MB where C++'s is 75 MB). The files are as small as C's for a program that does not allocate (`small = true`, a raw `main(argc, argv)`), and
tens of kilobytes more when it prints, parses, or allocates in loops (see [Binary size](@ref)).

## Method tables

StaticCompiler replaces methods that can't be compiled using an overlay method table. Its own table
(`StaticCompiler.method_table`) includes overrides of the error helpers of Base (`error`,
`throw_boundserror`, `throw_inexacterror`, integer division by zero, ...) that print a message and
exit, which made sense when compiled code could not throw, but means that those errors cannot be
caught.

A compilation uses exactly one overlay table, with Base itself as the fallback, so this package has
a table of its own, [`StaticRuntime.method_table`](@ref), which does not contain those
overrides: errors throw, just as in Julia, and `try`/`catch` can catch them. Use the functions of
this package (`compile_executable`, `compile_shlib`, `static_code_llvm`, ...), which are
StaticCompiler's with this table as the default, and `@device_override` to add to it. These
replace the functions of the same name in StaticCompiler, so load only one of the packages
with `using`. To compile with StaticCompiler's table instead, pass
`method_table = StaticCompiler.method_table`.
