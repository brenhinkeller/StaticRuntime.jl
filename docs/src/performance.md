# Binary size and performance

## Binary size

A program has the code it uses, and the Julia objects that it refers to, copied into the binary (strings, constant arrays and `Dict`s, and the type objects that the type tags and `isa` read). What is not used is not included. Measured on macOS (arm64, Julia 1.14.0-beta1): the bytes of the sections of the executable that are in the file (code, constants and data; `size -m`), and the file, which is made of pages of 16 kB and has the table of the symbols of the entry point. The last column is with `small = true` (see below), which changes the file and not the sections (the sections differ by a few bytes at most). The collector is left out of a program that does not need it (`gc = :auto`), and the code that only runs to stop with an error is optimized for size:

| program                                            | sections | file    | file, `small` |
|:---------------------------------------------------|---------:|--------:|--------------:|
| `main(argc, argv)`: `println("hello")`             |   2.1 kB |   51 kB |     34 kB |
| `main(argc, argv)`: `println(fib(30))`             |   8.9 kB |   54 kB |     34 kB |
| `main(args)`: `println("hello")`                   |   2.1 kB |   51 kB |     34 kB |
| `main(args)`: `println(length(args) + 42)`         |   8.8 kB |   54 kB |     34 kB |
| a `Dict` of strings, a lookup                      |    33 kB |   75 kB |     51 kB |
| `parse(Int, ...)` in a `try`, the message printed  |    51 kB |   97 kB |     68 kB |
| `sqrt` and `println` of a `Float64`                |    47 kB |   89 kB |     67 kB |
| `sort(rand(100))`                                  |    67 kB |  110 kB |    101 kB |
| a sieve of Eratosthenes (the README example)       |    93 kB |  132 kB |    118 kB |
| a `Dict` of tuples, a matrix product, `display`    |   126 kB |  168 kB |    135 kB |

What a compiled binary includes, and when:

* **The collector** (20 kB of code and 8 kB of data) is there if the program needs it (`gc = :auto`, the default for executables; `gc = true` always has it, `gc = false` never does). With `gc = :auto`, there is no collector if the program allocates a "finite" amount of memory in all, which is to say nothing that it allocates is in a loop, or in a function that is called from a loop or that calls itself (or that something refers to without calling it, as in a callback of a library). The analysis is of the code, and not of the sizes: a program that allocates a gigabyte once has no collector.
* **GC Hooks for finalizers** (5 kB) are there if the program registers a finalizer (`BigInt`, the wrappers of libraries, `finalizer(f, x)`).
* **Tables of characters** are included, one for each question that is asked: `isspace` of a character that is not ASCII is a table of a few bytes; `show` of a string (the printable characters) 12 kB; `isletter` and the like 33 kB.
* **Code that runs only to stop with an error is optimized for size**, as `-Oz` does: it is about 10% of the code of a program that prints, parses or sorts, and nothing waits for it. The same for all of the program would be 18 to 23% smaller, but 12 to 34% slower.

What the program is known not not use is not included. For example, the infrastructure for `===` of types is included only if the code calls `jl_egal__unboxed`; and the table of the types of the small tags is made only if the code indexes it with something that is not a constant (`isa` on a boxed value does). Otherwise each of the types that the code names is one object. The `isa` table (`ijl_subtype`) is as large as the number of types asked about times the number of types in the binary that are subtypes of them. Meanwhile, `println(Any[...])` is substantially larger than `println` of a concrete type because it has the code to show each of the types that inference found to possibly exist in that slot,  plus any that were registered with [`add_dispatch_candidates!`](@ref).

As an example, the data section of a program that prints a number consists mostly of two things: 
* about 4.5 kB of objects, which includes the type of `Int64` that the error for a conversion that fails (an `InexactError`) holds, with the name of it; and
* about 5 kB that is zero at the start (the stack of the exception handlers and the task that the runtime stands in for, which are not in the file). 
A program without any code that can throw(`main(argc, argv)` with `println("hello")`) has neither. The objects that are types are copied for what a program does with them: telling the type of an object from another (the tag), its name (`nameof`) and its parameters. Not for what a type refers to: its supertypes, the wrapper and the names of the fields. A program does not have these (a call that would need them is dynamic anyway), and with them the objects of a small program were more than twice as many. Showing a string needs a table of the characters that can be printed, which is about 12 kB (and not that of the categories of all characters, which is 33 kB). `%f` of a `Float64` in `@printf` needs the tables of Ryu for the fixed format, which are 190 kB: `%g`, `%e` and `show` have much smaller ones.

### Optional flags

* **`small = true`** (for `compile_executable`) makes a smaller file where that makes no difference to what the program does.
In this case, the linker leaves out the **names of the functions** of the program, but its entry point (on macOS, `-x`: 5 to 25 kB; on Linux `-s`), and, on macOS, the segment for the **constants and the table of the addresses of functions** that is made read-only as a safety feature when the program starts (`-no_data_const`: a page of 16 kB, of which a small program uses a few hundred bytes). Passing your own `cflags` replaces these.

## Performance compared with C and C++

The same programs in C and C++ (Apple clang 14, `-O2`) and in Julia compiled by this package (macOS, Apple M1 Max; the time of the best of 5 runs, in seconds; the answers are the same). The Julia of the loops has `@inbounds` as the C has no checks, and the  data are laid out as in C. (The C is compiled with clang's default, which fuses a multiplication and an addition into one instruction: Julia does that only where `muladd` or `fma` is written.)

| program                          | C       | C++     | here    | here, `small` (file) |
|:---------------------------------|--------:|--------:|--------:|---------------------:|
| recursive `fib(38)`              | 0.120   |         | 0.150   | 34 kB (C: 33 kB)     |
| sieve of Eratosthenes (50M)      | 0.101   |         | 0.108   | 34 kB                |
| matrix product (500, loops)      | 0.022   |         | 0.022   | 34 kB                |
| Mandelbrot (1500)                | 0.122   |         | 0.130   | 34 kB                |
| n-body (5M steps, array of structs) | 0.265 |        | 0.292   | 34 kB                |
| Collatz (3M)                     | 0.429   |         | 0.430   | 34 kB                |
| `sin`, `exp`, `log`, `atan`, `sqrt` (20M) | 0.222 |    | 0.228   | 34 kB                |
| binary trees (allocation, depth 18) | 3.34 |         | 0.545   | 86 kB                |
| string building and parsing (2M) |         | 0.086   | 0.161   | 86 kB                |
| sort of 3M integers              | 0.28 (`qsort`) | 0.179 (`std::sort`) | 0.029 | 102 kB |
| hash table of 2M keys            |         | 0.573   | 0.093   | 86 kB                |

The first seven examples have `main(argc, argv)` and `atol` as in C; the others have `main(args)` and `parse`. Programs that allocate a finite amount of memory have no collector, which is why the examples with non-allocating loops are 34 kB. Those that print a `Float64` do it with `printf` of [StaticTools](https://github.com/brenhinkeller/StaticTools.jl), as C does; `println` of a `Float64` adds the code for Julia's shortest representation (about 33 kB).

For loop-heavy arithmetic, programs are within about 10% of C (`fib` aside). What is faster than C or C++ is the library (`sort!` of integers is a counting sort for a small range, and `Dict` is a flat table where `unordered_map` has a node for each key; the allocator and collector of the binary tree program). The things that are slower: recursion (`fib`, 25% behind; plain Julia is the same: it is LLVM's code for it), some functions of the math library (Julia's own `log`, `tan` and `^` take 1.1 to 1.3 times what those of the C library do on this machine; `sin`, `cos` and `atan` are as fast or faster. On Apple Silicon the code generator is told not to build constants from integer instructions (`fuse-literals`), which made them 1.3 to 1.5 times slower), and string building, where `string` of several pieces and `parse` of a `SubString` take 1.9 times what C++'s `std::string` and `strtol` do. With `optimize = true` the program is optimized once more after it is linked (`O2` on the whole program): `fib` takes 0.106 s (faster than C), the binary trees 0.43 s and the strings 0.149 s. It is not the default: it can add up the elements of a reduction in `@simd` (and of a `Float16` sum) in another order than Julia does, and so give a result that differs from Julia's in the last digits, and it has failed tests on CI that the default passes. A program that allocates and keeps memory in lists and hash tables has more of it than C does (the hash table program is 135 MB where C++'s is 75 MB). The files are as small as C's for a program that does not allocate (`small = true`, a raw `main(argc, argv)`), and tens of kilobytes more when it prints, parses, or allocates in loops (see [Binary size](@ref)).
