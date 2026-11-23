# Compiling: overrides, passes, and inference

## How a compilation works

`compile_executable(f, types)` runs these steps, in a compilation of its own (`src/inference/compilation.jl`):

1. **Inference, in passes** (`src/inference/passes.jl`). Julia's type inference runs on the program with our interpreter,
   whose hooks resolve what Julia would leave to the runtime: calls on abstract types and on `Any` (split over the types
   that values can have), calls of functions that are not known, reads of slots of abstract types, boxes of closures,
   constant objects. After each inference, analyses look at the code that the program reaches and record what it stores,
   what functions it makes, and what objects it writes. If a pass finds something that it was not made with (a new
   function type, different slot types, ...), another pass is made with it, until nothing changes. Later passes reuse
   what earlier passes inferred, except for methods whose answers changed (`src/inference/passes.jl`).
2. **Optimization.** Julia's optimizer runs, with our rewrites before and after it (`src/inference/optimize.jl`): replaced
   calls are written into the code (see below), reads of slots are checked, and constructs that a binary can not run
   are rewritten.
3. **Code generation.** GPUCompiler and LLVM generate the code, with our LLVM passes (`src/llvm/`): type tags on the
   objects that the program allocates, and the vectorizers.
4. **Linking.** The runtime is linked into the module (`src/runtime/`): the allocator and the collector, the functions
   of the runtime that the code calls, and the constants that the code refers to, copied into the binary. By default,
   whatever still needs the Julia runtime is refused.

Nothing of a compilation is left for the next one: what it inferred is removed when it ends.

### What is done to help inference

A binary has no runtime to look up what inference did not find, so the compiler works to make inference find more than
Julia's own would. Most of it is in the hooks of our interpreter (`src/inference/`):

- **Calls on abstract types and on `Any`** are given the union of the types that the argument can have (the subtypes of
  the type, where they can all be listed; otherwise the registered types and the types that the program makes), which
  Julia then splits into a call for each (see [Dynamic dispatch on abstract types and on `Any`](@ref)). Julia splits
  unions of up to 4 types; ours, up to `SPLIT_LIMIT`.
- **Slots of abstract types** (the elements of a `Vector{Any}`, a field of type `Any`) are given the types that the
  program stores in them, found in its code and in its constants, and every read of them is checked by default.
  Knowing more can also make code reachable that does not compile (a branch that is never taken, now with types that
  it can't be compiled for). When a pass fails, the slots that the methods of the failing code read are given up, and
  the program is compiled again with the others (at most twice: `SLOT_NARROWINGS`); only then is it compiled without
  any slot types.
- **Slots that hold types** (`Vector{Type}`) are given the types they hold, each as a constant, and calls on what is
  read from them are split over those (see [Types as values](@ref)).
- **Boxes of closures** (variables a closure captures and that are assigned again) are given the types assigned to
  them.
- **Functions that are not known** (from a `Vector{Function}`, a callback, a listener of an `Observable`) are called as
  a union of the function types that the program makes (see [Functions that are not known: closures in collections and
  in boxes](@ref)).
- **Constant objects** are known one by one: reads of their fields that the program never writes are constants, and a
  package function called on one gets code of its own for that object, so a recursion over objects is known at each
  level (see [Objects that the program has as constants](@ref)).
- **Tuples, types and keywords of a few kinds** (a tuple with a `Union` element, `Vector{T}` of a `T` that is one of a
  few types, keywords that are types, `NamedTuple`s of `Any` values) are split into one call for each case, or given an
  exact type.
- **Julia's own limits are relaxed** where they would leave a dynamic call: `@nospecializeinfer` methods are inferred
  for the types of the call, functions that return a tuple with a `Union` element are inlined more readily, `invokelatest`
  is the call it makes, and Base's `stdout`, `stderr` and `stdin` are the program's `STDOUT`, `STDERR` and `STDIN`.
- **What cannot be found can be stated**: `@assume` gives the result type of a call, and `@assume_field` the type of a
  field (see [Stating a type instead of copying code](@ref)).

What these find depends on the whole program, which is why a compilation is made in passes.

### Two ways of replacing code

Code that a binary can not run is replaced in one of two ways.

**`@device_override` replaces a method** (see [Writing overrides](usage.md#Overrides)). It adds a method to this
package's method table, which method lookup prefers to Base's for the argument types that it matches. It is plain
Julia: every call that dispatches to that signature gets the replacement. Examples: `prod` of a tuple of integers,
`print_to_string`, `time_ns`, `getproperty(::Nothing, ::Symbol)`.

**A redirect replaces one call** (`src/inference/redirect.jl`). A hook of inference decides, for each call as it is
inferred, to treat it as a call of another function: the replacement is inferred in its place (so the code after it
is inferred with what the replacement gives), and the call is written into the code before it is optimized.

|                    | `@device_override`                               | redirect                                                                                       |
|:-------------------|:-------------------------------------------------|:-----------------------------------------------------------------------------------------------|
| Decided by         | the argument types, by dispatch                  | anything inference knows of the call: constants, unions, the compilation's state (slot types, object keys) |
| Can replace        | generic functions, which have methods            | also builtins and intrinsics (`getfield`, `tuple`, `apply_type`, `isdefined`), which have none |
| Replacement        | a method of the same function                    | any function, with extra arguments made when compiling (`ObjectKey{N}`, `Val(name)`, a function) |
| What the call gives | what the replacing method infers to             | can be adjusted (to keep a type that Julia would have merged)                                  |
| Cost               | none beyond writing the method                   | a hook of inference and a rewrite of the code; only calls that are statements of their own     |
| Applies to         | every call, in every program                     | only where the hook's conditions hold                                                          |

The two combine: a redirect happens before methods are looked up, and the replacement is then looked up in the
method table, overrides first, as any call is.

Use `@device_override` when the argument types alone decide the replacement and the function is a generic one: it is
simpler and needs no change to the compiler. A redirect is for what depends on more than the types of the call (whether
an argument is a constant, which object it is, what the slots hold), for builtins, and for replacements that need
arguments that only exist when compiling. The redirects of this package:

| Call                                                                  | Made a call of                                   | Why                                                                         |
|:----------------------------------------------------------------------|:-------------------------------------------------|:----------------------------------------------------------------------------|
| `getfield(x, name)` with a `name` that is not a constant              | `struct_field`, `index_field`: a comparison with each name | otherwise `jl_f_getfield`, of the runtime                          |
| a read of a pointer field that an extension makes again               | `remade_field`                                   | the field is null in the binary, and is made again when it is first read (FreeType faces, Cairo surfaces) |
| `apply_type(F, A)` with `A` one of a few types                        | `split_apply_type`                               | a binary can not make types                                                 |
| `tuple(...)`, and `getfield` of a tuple, with an element of a `Union` | `split_tuple`, `split_getfield`                  | otherwise `jl_f_tuple`, of the runtime                                      |
| `isdefined(x, name)` with a `name` that is not a constant             | `struct_isdefined`                               | a builtin of the runtime                                                    |
| a vector literal with a splat of something that is not a tuple        | `splat_vector`                                   | otherwise the runtime's apply                                               |
| `show(io, T)` of a type that is a value (`DataType`)                  | `show_type_value`                                | the text of the type is in a table that the linker makes                    |
| `setindex!` and `notify` of a constant object, where an extension says | the extension's function, with the object's key | code of its own for each object                                             |
| `f(x, args...)` of a package function, with a constant object `x`     | `object_call(f, key, ...)`                       | code of its own for each object, so that a recursion over objects is known at each level |

## Code that needs the Julia runtime is rejected

A lot of Julia code can't work in a standalone binary because it needs the Julia runtime: most
often *dynamic dispatch* (a call whose argument types are not known when compiling), but also
anything that refers to a Julia object by its address in the compiling process. Left alone, such
code compiles and links, and then crashes (or, worse, misbehaves) when it is run. So by default
the functions of this package reject it when compiling, naming what is wrong:

```julia
julia> compile_executable(main_that_prints, (Int, Ptr{Ptr{UInt8}}))
ERROR: UnsupportedCodeError: the code cannot run as a standalone binary

It needs the Julia runtime (e.g. for dynamic dispatch, which means that the types in some call are not known at compile time):
  ijl_apply_generic, called from show, print
  ijl_get_nth_field_checked, called from print

It refers to Julia objects by their address in this process, which are not in the binary:
  in static_main: %stdout.checked = load atomic ptr, ptr inttoptr (i64 5043311736 to ptr), ...
```

The names are those of the functions of the Julia runtime that the code needs, and of the Julia
functions that call them. For a `ccall` into a library that could not be resolved, it says which function.
(`undefined_symbols` lists the same things for a function, without compiling it.)

The names are followed by where in the Julia code each is: the function and the types of its
arguments (`<unknown type>` is an argument that the compiler did not know the type of, which is
usually the cause), the source lines, including what each was inlined into, and the way there from the
entry point. (When it fails, the program is compiled again with the debug information, which is
removed before the check, to find the lines.)

**Code that is only on the way to an error is not refused.** The code involved is often only reached
on a path that fails, for instance to build the message of an error, or to say which method was
not found. A call that needs the runtime and that is only reached on the way to a `throw` (no path
from it goes on with the rest of the program: the path ends in a `throw`, or an `exit`) is replaced by a stop with a message that says what it was
(`JULIA_DEBUG=StaticRuntime` lists them). The program is the same until it gets there; what it
prints is not what Julia prints, and an exception that would have been caught stops the program.
`stub_errors = false` refuses these too. The same call on a path that goes on is refused.

With `strict = false`, all of the code is compiled anyway, with those runtime functions defined to print
a message and abort if they are ever called (and the addresses will crash the program if used).
`allow = ("function_name", ...)` accepts specific runtime functions, and keeps the check for the rest.
Run with `JULIA_DEBUG=StaticRuntime` to see which are defined this way.

By default, a read of the elements of a `Vector{Any}`, or of a field of an abstract type, that the compiler gave a narrower type than it declares (from the types that
the program stores there) is also checked when the program runs: a value of another type stops the program with a type error, where it would otherwise be treated as one of the types that
were found. The compiler finds the stores in the code that it compiles and in the constants that this refers to, and this is for any that it does not find. It costs nothing that the benchmarks
(`bench/dispatch.jl`) could measure. The environment variable `STATIC_RUNTIME_CHECK_TYPES` is `0` to leave the check out, or `1` to have it with `strict = false`.

## Finding out why a compilation is slow, or does not finish

A compilation is made in passes (the types of functions, callbacks, boxes and the slots of containers that one pass finds are what the next is made with). Nothing is written about them by default. Two variables, for
looking at a compilation that takes long, or ends in "did not settle":

- **A compilation is made of its program and of nothing else.** What was compiled before does not change what is compiled: the tables that compilations keep are forgotten when one begins, and what inference makes (the code instances of Julia's compiler) has a cache of its own for each compilation, which is emptied when it ends.
  Only what is not made by compiling persists: the overrides, the registrations (`add_dispatch_candidates!`, `add_callback!`, `prepare!`, ...) and the settings. `STATIC_RUNTIME_CACHE=1` makes compilations share what they infer (a compilation is then
  quicker, and the facts that the analysis finds of each method are kept with it, so that it should not matter; `test/core/determinism.jl` compiles the same programs in other orders, and again, and checks that they are the same).
- `STATIC_RUNTIME_TRACE=1` writes a line for each pass on the error output: how long it took, whether it was cut short by a change of the types of the slots or completed or failed, the candidates of the calls of
  unknown functions that it has and found (and why they were taken, or not), the number of methods that were optimized (and how many of them were different: a pass that optimizes the same methods again and again is
  where the time goes), and whether there is another pass. `STATIC_RUNTIME_TRACE=methoderrors` also lists the calls that have no method for the types that reach them (most are on paths that are never taken: they are what
  union splitting leaves; one that is reached is the `MethodError` that the program stops with), and the calls that give no value because an argument has a type that no value has (`Type{Union{}}`), which is
  where inference got a type wrong. `STATIC_RUNTIME_TRACE=embed` says why each object that can not be in the binary can not, with the way from it to the constant that the program refers to.
  `STATIC_RUNTIME_TRACE=ir:<text>` writes the code of each method whose name has the text in it (`ir:elliptical_arc_to_beziers(`), as it is optimized, after the changes of this package. The setting is read
  when a compilation starts: what is not traced costs nothing.
- When a program is refused for references to objects of the process that compiled it, the message says what each object is (its type) and why it could not be copied into the binary. A part of a program that
  needs the Julia runtime and is only on the way to an error stops the program with a message that says where in the Julia code it is (the file and line, and what that was inlined into).
- `STATIC_RUNTIME_SLOTS_WHY=1` says why slots are given up, and what each pass found in them.

The passes have two budgets: the passes that are cut short because the types of the slots changed (`SLOT_PASS_LIMIT`: the program is compiled without the types when they do not settle), and the others
(`MAX_FUNCTION_PASSES`). The message of a compilation that runs out of either says which.

## Dynamic dispatch on abstract types and on `Any`

*How this is done without changing other compilations.* The changes to inference (resolving the dispatch, `invokelatest`) are methods of functions of Julia's compiler
for an interpreter of a type that only our compilations have: the type of GPUCompiler's `GPUInterpreter` has the view of the method tables that it looks methods up in as a
parameter, and our compilations choose a view of a type of their own (`OverridesTableView`, through `GPUCompiler.method_table_view`). What StaticCompiler compiles on its own, in the
same session, has GPUCompiler's own interpreter and is not changed.

A call whose argument has an abstract type, such as `area(x)` for an `x` from a `Vector{Shape}`, runs the method that fits the
type that `x` has when the program is run. In Julia that is a lookup in the method tables, which a standalone binary does not
have. Here it is resolved when compiling, by what Julia does for a `Union`: test which of the types the argument has, and call
the method for that type.

```julia
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Rect <: Shape; w::Float64; h::Float64; end
area(c::Circle) = pi * c.r^2
area(r::Rect) = r.w * r.h

shapes() = Shape[Circle(1.0), Rect(2.0, 3.0)]
main(argc::Int, argv::Ptr{Ptr{UInt8}}) = (println(sum(area, shapes())); 0)
compile_executable(main, (Int, Ptr{Ptr{UInt8}}), "build")      # works
```

Which types the union has depends on the type of the argument:

* **An abstract type that has up to 16 concrete subtypes, which can all be listed**: the union is of all of them, defined when
  compiling, and that is all of the types that an object of the program can have. Nothing is left to chance: an object of a type
  that was not there is a `MethodError`, as in Julia. A package that defines more subtypes of `Shape` adds them to the union, and
  their methods to the code. (`StaticRuntime.DISPATCH_LIMIT[]` is the limit of 16.)
* **`Any`, and abstract types that can't be listed** (`Number`, `AbstractString`, `AbstractArray`, or one that has a parametric
  subtype whose instances are not known): the union is of
  - the types that the program makes, or that are in its constants, that are not Julia's own (yours and those of packages: found
    when compiling, see the slots below);
  - the types that are *registered*: the numbers, `String`, `Char`, `Symbol`, `Nothing` and `Missing` (the same types that `show`
    of a value of `Any` uses, so `println(x)` of an element of a `Vector{Any}` works), and what you add.

  What is read from a container or a field of the type `Any` is first given the types that the program stores in it (see the slots
  below), so most programs need to add nothing. What is left is a value of one of Julia's own types other than those (a
  `Vector{Int}`, a `Tuple{Int,Float64}`) that reaches a call as an `Any` in a way that is not a store that is seen (a value from an
  `inferencebarrier`, say), or a program compiled with `STATIC_RUNTIME_UNIVERSE=0`:

  ```julia
  add_dispatch_candidates!(Tuple{Int,Float64})   # before compiling
  ```

  A value of a type that is not registered **aborts the program when it reaches such a call**, with a message that says which
  call (`MethodError: no method matches the types of the arguments of a call of `f``), because it is not known when compiling
  which types the values of an `Any` can have. So compiling says, once for what it did this way, what was resolved over the
  registered types, in a debug message (set `JULIA_DEBUG=StaticRuntime` to see it). Calls on values whose types are all registered
  are as fast as any other call: it is a few comparisons of the type tag. A binary that does not have such a call is not
  bigger for the list.

  `Vector{Any}` is not among the usual types for dispatch (though it is for `show`), because it has methods of arithmetic and the like
  that a call on a number would need: register it if the values that you call things on include lists.

It applies to a call that is a dispatch on the types of its arguments (more than one method fits, or the one that does doesn't fit
all that the arguments can be). A call of one method that fits all of them is not changed. A call with several arguments of
these types has a case for each combination, up to 64 of them (`StaticRuntime.SPLIT_LIMIT[]`): `x + y` of two values of
`Any` is split, and `sort` of a `Vector{Any}` too.

Still dynamic, and rejected when compiling:

* Types that can't be listed, with no registered subtype (`IO`: use `STDOUT`, `STDERR`, `STDIN`, or a type that you know).
* Types and methods that are made after compiling (there is no `eval`).
* Calls that compute a type from the types of the arguments at run time (`Dict(k => v)` of pairs with abstract values, `typejoin`,
  `sum(f, v)` of a `Vector{Any}`, whose element type is a union of the results).

### Types as values

A type that the program has as a value, and does not know which when compiling (`T = types[i]` of a `Vector{Type}`, the key of a `Dict{Type,...}`, an element of a `Set{Type}`, a tuple of types in a
`Vector{Tuple{Type,Type}}`), is one of the types that the program stores in that kind of container: the compiler finds them in the code (as it does for the elements of a `Vector{Any}`, see above), and what is
read is a union of a few `Type{X}`, which a call on it is made over, with a constant in each case. This is what makes `kind(T)` (a function with a method for each type), `T <: Integer`, `hash(T)`, `Set{Type}` and
`Dict{Type,...}`, `Vector{T}`, `Tuple{T,String}`, `eltype(T)`, `T()` and `show` of a type work when `T` is a value that is only known when the program runs. Every read of such a container is checked: a type that
the compiler did not find (stored by a method that the compiler did not see the argument of) stops the program, and is not taken for one of the others. A type that is a `UnionAll` or a `Union` has a hash that is
made from its parts, which is not the number that Julia gives (a table that is made when the program runs is not affected).

What is not found is a type that is made by the program from values that are not types (`Vector{eltype(x)}` of a value `x` of a type that is not known is the call of `eltype` on the type of `x`, which is the same as above),
and a type that reaches the program as a `Type` argument of a function that the compiler does not see the callers of (an entry point, a `@cfunction`).

### Objects that the program has as constants

An object that the program has as a constant (`const GRAPH = ...`, made before compiling) is known as that object where the code has it as a constant, and so is what is read of it where the program does not change that:

- a field of it that the program never writes (of any object of its type) is what it holds when compiling;
- a lookup in a `Dict` or a `Vector` that is a constant, with a key that is a constant (`d[:k]`, `get(d, :k, x)`, `v[2]`), is what the container holds, where the program never changes a container of its type (a
  `Vector` only of elements that are not bits). The lookup is made by the program; its result is known.

What the program writes is found in its code: the fields that it sets, and the elements of memory that it sets or whose address it takes (`pointer(v)`). What is known is only what the fields and the elements that hold
references hold, and a reference is taken not to be written through a pointer (`unsafe_store!` of an address of an object into a field of another, which Julia's collector does not see either): a function of C that fills
in a struct writes its fields of bits, which are not what is known.

A function of a package that is called with such an object (`resolve!(node)`) is code of its own for that object (as if it had been written for it), and so is what it calls with the objects that it reads from it: a
recursion over a graph of objects (a node that is resolved from the nodes that it comes from) is known at every level, where Julia would know the first one only. It is not done for functions of Julia, nor for an
object with no field of an abstract type and none that holds another object (there is nothing more to know of it), nor for an argument of a type that is not concrete, a type, or a function with more than eight other
arguments.

### Functions that are not known: closures in collections and in boxes

A call `f(x)` of an `f` whose type is not known when compiling (a `Function` from a `Vector{Function}`, a `Dict` of functions, a field of the
type `Function`, a `Ref{Function}`, a value of `Any`, and a closure that calls itself, whose variable is boxed) is a call of the method that fits the
function that `f` is when the program runs. It is made over the types of the functions that the code has, which the compiler tests for one after the other, as it
does for the registered types above. Those are the closures that the code of the program makes, the functions that it passes or stores (`sin` in
`Function[sin, cos]`, `Base.Fix2(+, 1)`), and the ones in the constants that it refers to (`const FS = Function[sin, x -> 2x]`): not those of Base and the standard
libraries, which pass the functions of the program around and are the ones that call them.

```julia
fs = Function[sin, cos, x -> 2x]
function main()
    s = 0.0
    for f in fs        # f is a Function: a case for each function of the program that has a method for a Float64
        s += f(1.0)
    end
    printf(c"%.3f\n", s)
    return 0
end
```

Where the functions are is not known before the code has been inferred, so a compilation that has such a call and fails (or, with `strict = false`, would abort at the call) is made
again with the functions that it found, until it finds no more: it takes longer, but only for a program that has such a call. A function that the program only gets from
somewhere that it can't see (a function that a library calls back, a function made by code that is not part of the program) is not one of the cases, and the call
is rejected when compiling, as before. So is a call that none of the functions has a method for.

### Callbacks: `@cfunction`

`@cfunction` makes a C function pointer of a function of the program, which C code calls (the comparison function of `qsort` and `bsearch`, the callback of a library):

```julia
cmp(a::Ptr{Cint}, b::Ptr{Cint})::Cint = (x = unsafe_load(a); y = unsafe_load(b); x < y ? -1 : x > y ? 1 : 0)

function main()
    v = Cint[3, 1, 2]
    f = @cfunction(cmp, Cint, (Ptr{Cint}, Ptr{Cint}))
    ccall(:qsort, Cvoid, (Ptr{Cint}, Csize_t, Csize_t, Ptr{Cvoid}), v, 3, 4, f)
    println(v)
    return 0
end
```

The function is compiled with the types of C, and can allocate and call anything else that the program can (an exception that is thrown in it must be caught in it: it can not unwind the C frames). What Julia generates for it looks the method up
when it is first called (`jl_get_abi_converter`), which a program can't do; so the code is compiled again with a function for each `@cfunction` that calls the method,
where the entry point can't reach it, and the C function is made to call that: as with the functions of closures, that takes a second pass, for a program that has a `@cfunction`.
What it does not do: a function that has captured state (a closure over a variable, `@cfunction($f, ...)` of a `f` that is not a function without fields), a function that is not
known when compiling, arguments that are not C types (`Ref`, `Any`), and the callback of a library that is called from a thread that Julia did not make. (Callbacks run on the
stack of the caller, which the collector scans, so what they allocate is collected.)
